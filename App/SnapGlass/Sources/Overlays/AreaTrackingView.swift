import AppKit
import CaptureCore
import SharedKit
import SwiftUI

@preconcurrency import ScreenCaptureKit

// MARK: - AreaTrackingView

private final class CaptureActionBarView: NSVisualEffectView {
    var onBack: (() -> Void)?
    var onCopy: (() -> Void)?
    var onEdit: (() -> Void)?

    private let backButton = NSButton()
    private let copyButton = NSButton()
    private let editButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true

        configureActionButtons()

        let stack = NSStackView(views: [backButton, copyButton, editButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(
            NSLocalizedString("Screenshot Actions", comment: "Capture action bar accessibility label")
        )
    }

    private func configureActionButtons() {
        configure(
            backButton,
            title: NSLocalizedString("Back", comment: "Return from capture actions to selection adjustment"),
            symbol: "chevron.backward",
            toolTip: NSLocalizedString(
                "Return to selection adjustments",
                comment: "Capture action bar back button help"
            ),
            action: #selector(back)
        )
        backButton.keyEquivalent = "\u{1b}"

        configure(
            copyButton,
            title: NSLocalizedString("Copy Image", comment: "Capture action that copies the selected area"),
            symbol: "doc.on.doc",
            toolTip: NSLocalizedString(
                "Copy the screenshot to the clipboard",
                comment: "Capture action bar copy button help"
            ),
            action: #selector(copyImage)
        )
        copyButton.keyEquivalent = "\r"

        configure(
            editButton,
            title: NSLocalizedString(
                "Edit Screenshot",
                comment: "Capture action that opens the selected area in the editor"
            ),
            symbol: "pencil.and.outline",
            toolTip: NSLocalizedString(
                "Open the screenshot in the annotation editor",
                comment: "Capture action bar edit button help"
            ),
            action: #selector(editScreenshot)
        )
        editButton.keyEquivalent = "e"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        for button in [backButton, copyButton, editButton]
        where button.convert(button.bounds, to: self).contains(point) {
            return button
        }
        return super.hitTest(point)
    }

    func focusDefaultAction() {
        window?.makeFirstResponder(copyButton)
    }

    func performAction(at point: NSPoint) -> Bool {
        let actions: [(NSButton, () -> Void)] = [
            (backButton, { [weak self] in self?.onBack?() }),
            (copyButton, { [weak self] in self?.onCopy?() }),
            (editButton, { [weak self] in self?.onEdit?() }),
        ]
        guard let action = actions.first(where: { button, _ in
            button.convert(button.bounds, to: self).contains(point)
        })?.1 else {
            return false
        }
        action()
        return true
    }

    private func configure(
        _ button: NSButton,
        title: String,
        symbol: String,
        toolTip: String,
        action: Selector
    ) {
        button.title = title
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
        button.toolTip = toolTip
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
    }

    @objc private func back() { onBack?() }
    @objc private func copyImage() { onCopy?() }
    @objc private func editScreenshot() { onEdit?() }
}

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
    let capturedFrames: [CGDirectDisplayID: CGImage]
    private let onColorPicked: ((SampledColor) -> Void)?
    var phase: Phase = .idle
    private var startPoint: CGPoint?
    var selectionRect: CGRect = .zero
    var freeformPoints: [CGPoint] = []
    private var dragAction: DragAction?
    var hoverPoint: CGPoint = .zero
    var hoverColor: SampledColor?
    private var trackingAreaReference: NSTrackingArea?
    private let actionBar = CaptureActionBarView(frame: .zero)

    init(
        frame frameRect: NSRect,
        style: CaptureSelectionStyle,
        overlayMode: CaptureOverlayMode,
        screen: NSScreen,
        capturedFrames: [CGDirectDisplayID: CGImage],
        onColorPicked: ((SampledColor) -> Void)?
    ) {
        self.style = style
        self.overlayMode = overlayMode
        self.screen = screen
        self.capturedFrames = capturedFrames
        self.onColorPicked = onColorPicked
        super.init(frame: frameRect)

        actionBar.isHidden = true
        actionBar.onBack = { [weak self] in self?.hideActionChooser() }
        actionBar.onCopy = { [weak self] in self?.completeSelection(action: .copy) }
        actionBar.onEdit = { [weak self] in self?.completeSelection(action: .edit) }
        addSubview(actionBar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        positionActionBar()
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
        } else {
            NSCursor.crosshair.set()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        hoverPoint = convert(event.locationInWindow, from: nil)
        hoverColor = sampleColor(at: hoverPoint)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hoverPoint = point
        if phase == .choosingAction {
            let actionPoint = actionBar.convert(point, from: self)
            if !actionBar.performAction(at: actionPoint) {
                actionBar.focusDefaultAction()
            }
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

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            if phase == .choosingAction {
                hideActionChooser()
            } else {
                onSelectionComplete?(nil)
            }
        case 36, 76:
            if phase == .choosingAction {
                completeSelection(action: .copy)
            } else {
                showActionChooser()
            }
        default:
            super.keyDown(with: event)
        }
    }

    private func showActionChooser() {
        guard phase == .adjusting, selectionRect.width > 5, selectionRect.height > 5 else { return }
        phase = .choosingAction
        actionBar.isHidden = false
        positionActionBar()
        actionBar.focusDefaultAction()
        needsDisplay = true
    }

    private func hideActionChooser() {
        guard phase == .choosingAction else { return }
        actionBar.isHidden = true
        phase = .adjusting
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    private func completeSelection(action: AreaCaptureAction) {
        guard phase == .choosingAction, selectionRect.width > 5, selectionRect.height > 5 else { return }
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
        onSelectionComplete?(AreaSelectionResult(
            screenRect: quartzScreenRect(from: selectionRect),
            normalizedPath: normalizedPath,
            action: action
        ))
    }

    private func positionActionBar() {
        guard !actionBar.isHidden, !selectionRect.isEmpty else { return }

        let fittingSize = actionBar.fittingSize
        let size = CGSize(width: max(fittingSize.width, 320), height: max(fittingSize.height, 44))
        let margin: CGFloat = 12
        let horizontalInset: CGFloat = 8
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
        actionBar.isHidden = true
        phase = .idle
        selectionRect = .zero
        freeformPoints = []
    }

    private func quartzScreenRect(from viewRect: CGRect) -> CGRect {
        guard let window else { return viewRect }
        let windowRect = convert(viewRect, to: nil)
        let appKitRect = window.convertToScreen(windowRect)
        let center = CGPoint(x: appKitRect.midX, y: appKitRect.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }),
              let displayID = screen.deviceDescription[
                  NSDeviceDescriptionKey("NSScreenNumber")
              ] as? CGDirectDisplayID else {
            return appKitRect
        }

        return ScreenCoordinateGeometry.quartzRect(
            from: appKitRect,
            appKitScreenFrame: screen.frame,
            quartzScreenFrame: CGDisplayBounds(displayID)
        ) ?? appKitRect
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
            CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14).contains(point)
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
