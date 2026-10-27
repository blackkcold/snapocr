import AppKit
import BarcodeCore
import CaptureCore
import SharedKit
import SwiftUI

@preconcurrency import ScreenCaptureKit

// MARK: - AreaTrackingView

final class AreaTrackingView: NSView {
    var onSelectionComplete: ((AreaSelectionResult?) -> Void)?

    enum Phase { case idle, drawing, adjusting, choosingAction }
    enum ResizeHandle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }
    enum DragAction {
        case resize(ResizeHandle, initial: CGRect, start: CGPoint)
        case move(initial: CGRect, start: CGPoint)
    }

    let style: CaptureSelectionStyle
    let overlayMode: CaptureOverlayMode
    let screen: NSScreen
    var capturedFrames: [CGDirectDisplayID: CGImage]
    private let onColorPicked: ((SampledColor) -> Void)?
    /// 重新截取选区（动作栏「重新识别」用）；`nil` 时只能读预截原图。
    let onRecaptureRegion: (@MainActor (CGRect) async -> CGImage?)?
    var phase: Phase = .idle
    private var startPoint: CGPoint?
    var selectionRect: CGRect = .zero
    var freeformPoints: [CGPoint] = []
    private var dragAction: DragAction?
    var hoverPoint: CGPoint = .zero
    var hoverColor: SampledColor?
    /// 取色标签当前实际占用的矩形；夹取后可能翻到光标另一侧，
    /// 失效必须用这个矩形而不是光标附近的固定框。
    var hoverLabelRect: CGRect = .zero
    /// 当前悬停的缩放手柄；用于手柄高亮与方向光标。
    var hoveredHandle: ResizeHandle?
    /// Throttles per-pixel sampling so moving the pointer across a 5K overlay
    /// does not allocate a new 1×1 CGContext on every mouse event.
    private var lastHoverSampleTime: TimeInterval = 0
    private var trackingAreaReference: NSTrackingArea?
    let actionBar = CaptureActionBarView(frame: .zero)

    /// 选区条码识别的状态；变化时同步动作栏按钮与结果浮层。
    var scanState: ScanState = .idle {
        didSet {
            actionBar.setScanning(scanState.isScanning)
            refreshBarcodePanel()
        }
    }
    let barcodePanel = BarcodeResultPanel(frame: .zero)
    let barcodeEngine = VisionBarcodeEngine()
    var scanTask: Task<Void, Never>?
    var scanGeneration = 0

    init(
        frame frameRect: NSRect,
        style: CaptureSelectionStyle,
        overlayMode: CaptureOverlayMode,
        screen: NSScreen,
        capturedFrames: [CGDirectDisplayID: CGImage],
        onColorPicked: ((SampledColor) -> Void)?,
        onRecaptureRegion: (@MainActor (CGRect) async -> CGImage?)? = nil
    ) {
        self.style = style
        self.overlayMode = overlayMode
        self.screen = screen
        self.capturedFrames = capturedFrames
        self.onColorPicked = onColorPicked
        self.onRecaptureRegion = onRecaptureRegion
        super.init(frame: frameRect)

        actionBar.isHidden = true
        // 浮层打开时 esc 只关浮层、↵ 复制识别内容；第二次 esc 才收动作栏。
        actionBar.onBack = { [weak self] in
            guard let self else { return }
            if self.dismissBarcodePanel() { return }
            self.hideActionChooser()
        }
        actionBar.onCopy = { [weak self] in
            guard let self else { return }
            if self.copyFirstScanPayload() { return }
            self.completeSelection(action: .copy)
        }
        actionBar.onEdit = { [weak self] in self?.completeSelection(action: .edit) }
        actionBar.onPin = { [weak self] in self?.completeSelection(action: .pin) }
        actionBar.onScan = { [weak self] in self?.scanSelectedRegion() }
        addSubview(actionBar)
        configureBarcodePanel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        positionActionBar()
        positionBarcodePanel()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        hoverPoint = window?.mouseLocationOutsideOfEventStream ?? .zero
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func cursorUpdate(with event: NSEvent) {
        if phase == .choosingAction {
            NSCursor.arrow.set()
        } else if phase == .adjusting,
                  let handle = hitHandle(at: convert(event.locationInWindow, from: nil)) {
            handle.cursor.set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    /// Accepts pre-captured frames that finished after the overlay appeared.
    func updateCapturedFrames(_ frames: [CGDirectDisplayID: CGImage]) {
        capturedFrames = frames
        if hoverColor == nil {
            hoverColor = sampleColor(at: hoverPoint)
            updateHoverLabelRect()
        }
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let previousPoint = hoverPoint
        let previousLabelRect = hoverLabelRect
        let point = convert(event.locationInWindow, from: nil)
        hoverPoint = point

        let now = ProcessInfo.processInfo.systemUptime
        if now - lastHoverSampleTime >= 1.0 / 30.0 {
            lastHoverSampleTime = now
            hoverColor = sampleColor(at: point)
        }
        updateHoverLabelRect()

        if phase == .adjusting {
            let handle = hitHandle(at: point)
            if handle != hoveredHandle {
                hoveredHandle = handle
                (handle?.cursor ?? .crosshair).set()
                setNeedsDisplay(selectionRect.insetBy(dx: -20, dy: -20))
            }
        } else if hoveredHandle != nil {
            hoveredHandle = nil
        }

        // Only the crosshair and the color label follow the pointer. Repainting
        // just their union keeps AppKit from invalidating the whole 5K overlay.
        guard phase != .choosingAction else { return }
        let dirty =
            crosshairInvalidationRect(for: previousPoint)
            .union(crosshairInvalidationRect(for: point))
            .union(previousLabelRect)
            .union(hoverLabelRect)
            .insetBy(dx: -4, dy: -4)
        setNeedsDisplay(dirty)
    }

    /// Crosshair 的包围盒。标签单独用实际矩形，因为它会被夹取到边缘另一侧。
    private func crosshairInvalidationRect(for point: CGPoint) -> CGRect {
        CGRect(x: point.x - 24, y: point.y - 24, width: 48, height: 48)
    }

    /// 标签尺寸只随色值文本变化；位置每次都跟着光标重算。
    private func updateHoverLabelRect() {
        guard phase != .choosingAction, let hoverColor else {
            hoverLabelRect = .zero
            return
        }
        let hexSize = AreaHoverLabelMetrics.hexSize(for: hoverColor.hexString)
        let rgbSize = AreaHoverLabelMetrics.rgbSize(for: hoverColor.rgbString)
        let size = CGSize(
            width: 10 + 5 + max(hexSize.width, rgbSize.width) + 6 * 2,
            height: max(hexSize.height, rgbSize.height) * 2 + 8
        )
        hoverLabelRect = LabelPlacement.rect(
            size: size,
            near: hoverPoint,
            offset: CGSize(width: 16, height: 16),
            inside: bounds
        )
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hoverPoint = point
        if phase == .choosingAction {
            let actionPoint = actionBar.convert(point, from: self)
            if actionBar.performAction(at: actionPoint) { return }
            // 卡片内的点击永远不算「点空白」：事件偶尔会绕过控件落到这里，
            // 按坐标补派一次，避免一次正文点击把结果浮层整个关掉。
            if !barcodePanel.isHidden, barcodePanel.frame.contains(point) {
                _ = barcodePanel.handleClick(at: barcodePanel.convert(point, from: self))
                return
            }
            // 点空白先收浮层，动作栏留在原处。
            if dismissBarcodePanel() {
                actionBar.focusDefaultAction()
                needsDisplay = true
                return
            }
            actionBar.focusDefaultAction()
            return
        }
        if event.clickCount == 2, phase == .adjusting {
            showActionChooser()
            return
        }

        if style == .rectangle, phase == .adjusting {
            if let handle = hitHandle(at: point) {
                dragAction = .resize(handle, initial: selectionRect, start: point)
                return
            }
            if selectionRect.contains(point) {
                dragAction = .move(initial: selectionRect, start: point)
                return
            }
        }

        phase = .drawing
        startPoint = point
        selectionRect = .zero
        freeformPoints = style == .freeform ? [point] : []
        dragAction = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard phase != .choosingAction else { return }
        let point = convert(event.locationInWindow, from: nil)
        hoverPoint = point

        if let dragAction {
            updateAdjustedSelection(action: dragAction, current: point)
        } else if style == .freeform {
            if let last = freeformPoints.last, hypot(point.x - last.x, point.y - last.y) >= 2 {
                freeformPoints.append(point.clamped(to: bounds))
                selectionRect = boundingRect(for: freeformPoints)
            }
        } else if let startPoint {
        selectionRect = CGRect(spanning: startPoint, and: point.clamped(to: bounds))
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard phase != .choosingAction else { return }
        defer {
            dragAction = nil
            startPoint = nil
            needsDisplay = true
        }
        guard dragAction == nil else { return }

        if style == .freeform {
            guard freeformPoints.count >= 3 else {
                resetSelection()
                return
            }
            selectionRect = boundingRect(for: freeformPoints)
        }

        guard selectionRect.width > 5, selectionRect.height > 5 else {
            if onColorPicked != nil {
                pickColorAndFinish(at: hoverPoint)
            } else {
                resetSelection()
            }
            return
        }
        phase = .adjusting
    }

    private func pickColorAndFinish(at point: CGPoint) {
        guard let color = sampleColor(at: point) else {
            resetSelection()
            return
        }
        onColorPicked?(color)
        onSelectionComplete?(nil)
    }

    /// Catches the pin shortcut when the event carries key-equivalent modifiers
    /// (⌘ / ⌃ / ⌥), which AppKit resolves before dispatching `keyDown`.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleScanCommand(event) { return true }
        guard PinSelectionShortcut.matches(event: event), isPinShortcutPhase else {
            return super.performKeyEquivalent(with: event)
        }
        performPinShortcut()
        return true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            handleEscapeKey()
        case 36, 76:
            handleReturnKey()
        case 123, 124, 125, 126:
            if nudgeSelection(with: event) { return }
            super.keyDown(with: event)
        default:
            handleDefaultKey(event)
        }
    }

    private func showActionChooser() {
        guard phase == .adjusting, selectionRect.width > 5, selectionRect.height > 5 else { return }
        phase = .choosingAction
        hoveredHandle = nil
        actionBar.isHidden = false
        actionBar.updatePinShortcutHint()
        positionActionBar()
        actionBar.focusDefaultAction()
        needsDisplay = true
    }

    private func hideActionChooser() {
        guard phase == .choosingAction else { return }
        dismissBarcodePanel()
        actionBar.isHidden = true
        hoveredHandle = nil
        phase = .adjusting
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    func completeSelection(action: AreaCaptureAction) {
        guard phase == .choosingAction, selectionRect.width > 5, selectionRect.height > 5 else { return }
        dismissBarcodePanel()
        onSelectionComplete?(makeSelectionResult(action: action))
    }

    /// 同时产出 Quartz 选区矩形（截图用）与 AppKit 点矩形（置顶面板用）。
    func makeSelectionResult(action: AreaCaptureAction) -> AreaSelectionResult {
        let normalizedPath: [CGPoint]?
        if style == .freeform {
            normalizedPath = freeformPoints.map {
                CGPoint(
                    x: ($0.x - selectionRect.minX) / selectionRect.width,
                    y: ($0.y - selectionRect.minY) / selectionRect.height
                )
            }
        } else {
            normalizedPath = nil
        }
        let rects = selectionRects()
        return AreaSelectionResult(
            screenRect: rects.quartz,
            appKitRect: rects.appKit,
            normalizedPath: normalizedPath,
            action: action
        )
    }

    private func positionActionBar() {
        guard !actionBar.isHidden, !selectionRect.isEmpty else { return }

        let fittingSize = actionBar.fittingSize
        let size = CGSize(width: max(fittingSize.width, 400), height: max(fittingSize.height, 44))
        let margin: CGFloat = DS.Space.s12
        let horizontalInset: CGFloat = DS.Space.s8
        let proposedX = selectionRect.midX - size.width / 2
        let originX = min(
            max(proposedX, bounds.minX + horizontalInset),
            bounds.maxX - size.width - horizontalInset
        )

        var originY = selectionRect.minY - size.height - margin
        if originY < bounds.minY + horizontalInset {
            originY = selectionRect.maxY + margin
        }
        if originY + size.height > bounds.maxY - horizontalInset {
            originY = max(bounds.minY + horizontalInset, selectionRect.midY - size.height / 2)
        }

        actionBar.frame = CGRect(origin: CGPoint(x: originX, y: originY), size: size)
    }

    private func resetSelection() {
        dismissBarcodePanel()
        actionBar.isHidden = true
        hoveredHandle = nil
        phase = .idle
        selectionRect = .zero
        freeformPoints = []
    }

    /// 将当前选区同时映射为 AppKit 全局点矩形与 Quartz 全局矩形。
    ///
    /// AppKit 矩形直接透传用于置顶面板（面板 frame 即 AppKit 点坐标），
    /// Quartz 矩形仅用于截图裁剪路径。
    func selectionRects() -> (appKit: CGRect, quartz: CGRect) {
        guard let window else { return (selectionRect, selectionRect) }
        let windowRect = convert(selectionRect, to: nil)
        let appKitRect = window.convertToScreen(windowRect)
        let center = CGPoint(x: appKitRect.midX, y: appKitRect.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }),
              let displayID = screen.deviceDescription[
                  NSDeviceDescriptionKey("NSScreenNumber")
              ] as? CGDirectDisplayID else {
            return (appKitRect, appKitRect)
        }

        let quartz = ScreenCoordinateGeometry.quartzRect(
            from: appKitRect,
            appKitScreenFrame: screen.frame,
            quartzScreenFrame: CGDisplayBounds(displayID)
        ) ?? appKitRect
        return (appKitRect, quartz)
    }

    func freeformPath() -> CGPath {
        let path = CGMutablePath()
        guard let first = freeformPoints.first else { return path }
        path.move(to: first)
        for point in freeformPoints.dropFirst() { path.addLine(to: point) }
        if phase == .adjusting || phase == .choosingAction { path.closeSubpath() }
        return path
    }

    func handlePoints() -> [ResizeHandle: CGPoint] {
        [
            .topLeft: CGPoint(x: selectionRect.minX, y: selectionRect.maxY),
            .top: CGPoint(x: selectionRect.midX, y: selectionRect.maxY),
            .topRight: CGPoint(x: selectionRect.maxX, y: selectionRect.maxY),
            .right: CGPoint(x: selectionRect.maxX, y: selectionRect.midY),
            .bottomRight: CGPoint(x: selectionRect.maxX, y: selectionRect.minY),
            .bottom: CGPoint(x: selectionRect.midX, y: selectionRect.minY),
            .bottomLeft: CGPoint(x: selectionRect.minX, y: selectionRect.minY),
            .left: CGPoint(x: selectionRect.minX, y: selectionRect.midY),
        ]
    }

    private func hitHandle(at point: CGPoint) -> ResizeHandle? {
        handlePoints().first { _, center in
            CGRect(
                x: center.x - DS.Hit.handle / 2,
                y: center.y - DS.Hit.handle / 2,
                width: DS.Hit.handle,
                height: DS.Hit.handle
            ).contains(point)
        }?.key
    }

    private func updateAdjustedSelection(action: DragAction, current: CGPoint) {
        switch action {
        case .move(let initial, let start):
            let deltaX = min(max(current.x - start.x, bounds.minX - initial.minX), bounds.maxX - initial.maxX)
            let deltaY = min(max(current.y - start.y, bounds.minY - initial.minY), bounds.maxY - initial.maxY)
            selectionRect = initial.offsetBy(dx: deltaX, dy: deltaY)
        case .resize(let handle, let initial, _):
            var minX = initial.minX
            var maxX = initial.maxX
            var minY = initial.minY
            var maxY = initial.maxY
            let point = current.clamped(to: bounds)
            if [.topLeft, .left, .bottomLeft].contains(handle) { minX = min(point.x, maxX - 5) }
            if [.topRight, .right, .bottomRight].contains(handle) { maxX = max(point.x, minX + 5) }
            if [.bottomLeft, .bottom, .bottomRight].contains(handle) { minY = min(point.y, maxY - 5) }
            if [.topLeft, .top, .topRight].contains(handle) { maxY = max(point.y, minY + 5) }
            selectionRect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }

    private func boundingRect(for points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { rect, point in
            rect.union(CGRect(origin: point, size: .zero))
        }
    }
}

extension AreaTrackingView {
    private func handleEscapeKey() {
        if dismissBarcodePanel() { return }
        if phase == .choosingAction {
            hideActionChooser()
        } else {
            onSelectionComplete?(nil)
        }
    }

    private func handleReturnKey() {
        if phase == .choosingAction {
            if copyFirstScanPayload() { return }
            completeSelection(action: .copy)
        } else {
            showActionChooser()
        }
    }

    private func handleDefaultKey(_ event: NSEvent) {
        if handleScanShortcut(event) { return }
        if PinSelectionShortcut.matches(event: event), isPinShortcutPhase {
            performPinShortcut()
        } else {
            super.keyDown(with: event)
        }
    }

    /// Moves the rectangle selection with the arrow keys (1 pt, 10 pt with
    /// Shift). Returns false when the event should fall through to AppKit.
    private func nudgeSelection(with event: NSEvent) -> Bool {
        guard style == .rectangle, phase == .adjusting, !selectionRect.isEmpty else {
            return false
        }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        let deltaX: CGFloat = event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0
        let deltaY: CGFloat = event.keyCode == 125 ? -step : event.keyCode == 126 ? step : 0
        let maxX = max(bounds.minX, bounds.maxX - selectionRect.width)
        let maxY = max(bounds.minY, bounds.maxY - selectionRect.height)
        selectionRect.origin.x = min(max(selectionRect.origin.x + deltaX, bounds.minX), maxX)
        selectionRect.origin.y = min(max(selectionRect.origin.y + deltaY, bounds.minY), maxY)
        positionActionBar()
        needsDisplay = true
        return true
    }

}


extension AreaTrackingView.ResizeHandle {
    /// 八方向手柄对应的系统光标（对角线在 macOS 15 以下退回十字）。
    var cursor: NSCursor {
        switch self {
        case .left, .right: return NSCursor.resizeLeftRight
        case .top, .bottom: return NSCursor.resizeUpDown
        case .topLeft, .bottomRight:
            if #available(macOS 15.0, *) {
                return NSCursor.frameResize(position: .topLeft, directions: .all)
            }
            return .crosshair
        case .topRight, .bottomLeft:
            if #available(macOS 15.0, *) {
                return NSCursor.frameResize(position: .topRight, directions: .all)
            }
            return .crosshair
        }
    }
}
