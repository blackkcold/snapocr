import AppKit
import SwiftUI

@preconcurrency import ScreenCaptureKit

/// 全屏透明覆盖面板，用于区域截图的交互式选择。
final class AreaSelectionPanel: NSPanel {
    private let onComplete: (CGRect?) -> Void
    private var trackingView: AreaTrackingView!

    static func show(onComplete: @escaping (CGRect?) -> Void) {
        let panel = AreaSelectionPanel(onComplete: onComplete)
        panel.orderFrontRegardless()
        panel.trackingView.prepareBackgroundSnapshot()
    }

    private init(onComplete: @escaping (CGRect?) -> Void) {
        self.onComplete = onComplete
        let allScreensFrame = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }

        super.init(
            contentRect: allScreensFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ignoresMouseEvents = false
        isMovableByWindowBackground = false
        setFrame(allScreensFrame, display: true)

        guard let contentView else { return }
        trackingView = AreaTrackingView(frame: contentView.bounds)
        trackingView.onSelectionComplete = { [weak self] rect in
            self?.close()
            self?.onComplete(rect)
        }
        trackingView.autoresizingMask = [.width, .height]
        contentView.addSubview(trackingView)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func close() {
        trackingView.clearBackgroundSnapshot()
        super.close()
    }
}

// MARK: - WindowSelectionPanel

struct WindowSelectionResult {
    let windowID: CGWindowID
    let appName: String?
    let windowTitle: String?
}

/// Floating window picker for interactive window capture.
final class WindowSelectionPanel: NSPanel {
    private let windows: [SelectableWindow]
    private let onComplete: (WindowSelectionResult?) -> Void
    private let coordinator: WindowSelectionCoordinator

    static func show(onComplete: @escaping (WindowSelectionResult?) -> Void) {
        Task { @MainActor in
            do {
                let windows = try await fetchAvailableWindows()
                guard !windows.isEmpty else {
                    onComplete(nil)
                    return
                }

                let panel = WindowSelectionPanel(windows: windows, onComplete: onComplete)
                panel.orderFrontRegardless()
                panel.makeKey()
            } catch {
                onComplete(nil)
            }
        }
    }

    private init(windows: [SelectableWindow], onComplete: @escaping (WindowSelectionResult?) -> Void) {
        self.windows = windows
        self.onComplete = onComplete
        self.coordinator = WindowSelectionCoordinator(windows: windows)

        let panelSize = NSSize(width: 420, height: min(520, max(180, windows.count * 44 + 72)))
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let panelOrigin = NSPoint(
            x: screenFrame.midX - panelSize.width / 2,
            y: screenFrame.midY - panelSize.height / 2
        )

        super.init(
            contentRect: NSRect(origin: panelOrigin, size: panelSize),
            styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        self.coordinator.panel = self
        title = "Select Window"
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        acceptsMouseMovedEvents = true
        titlebarAppearsTransparent = true

        contentView = makeContentView()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            finish(with: nil)
        } else {
            super.keyDown(with: event)
        }
    }

    fileprivate func finish(with result: WindowSelectionResult?) {
        close()
        onComplete(result)
    }

    private func makeContentView() -> NSView {
        let container = NSVisualEffectView()
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active

        let titleLabel = NSTextField(labelWithString: "Choose a window to capture")
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let tableView = HoverTableView()
        tableView.headerView = nil
        tableView.rowHeight = 40
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        tableView.target = coordinator
        tableView.action = #selector(WindowSelectionCoordinator.selectWindow(_:))

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("window"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(titleLabel)
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),

            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])

        return container
    }

    private static func fetchAvailableWindows() async throws -> [SelectableWindow] {
        let content = try await SCShareableContent.current
        let currentBundleID = Bundle.main.bundleIdentifier

        return content.windows
            .filter { window in
                guard window.isOnScreen,
                      window.windowLayer >= 0,
                      let app = window.owningApplication else {
                    return false
                }

                if let currentBundleID, app.bundleIdentifier == currentBundleID {
                    return false
                }

                return true
            }
            .map { window in
                SelectableWindow(
                    windowID: window.windowID,
                    appName: window.owningApplication?.applicationName,
                    windowTitle: window.title,
                    frame: window.frame
                )
            }
            .sorted { lhs, rhs in
                lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }
}

private struct SelectableWindow {
    let windowID: CGWindowID
    let appName: String?
    let windowTitle: String?
    let frame: CGRect

    var displayName: String {
        let app = appName?.isEmpty == false ? appName ?? "Unknown App" : "Unknown App"
        let title = windowTitle?.isEmpty == false ? windowTitle ?? "Untitled" : "Untitled"
        return "\(app) — \(title)"
    }

    var subtitle: String {
        "\(Int(frame.width)) × \(Int(frame.height))"
    }
}

private final class WindowSelectionCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    fileprivate weak var panel: WindowSelectionPanel?
    private let windows: [SelectableWindow]

    init(windows: [SelectableWindow]) {
        self.windows = windows
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        windows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard windows.indices.contains(row) else { return nil }

        let window = windows[row]
        let cell = NSTableCellView()

        let title = NSTextField(labelWithString: window.displayName)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(labelWithString: window.subtitle)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(title)
        cell.addSubview(subtitle)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4),
            title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),

            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),
        ])

        return cell
    }

    @MainActor @objc func selectWindow(_ sender: NSTableView) {
        let row = sender.clickedRow >= 0 ? sender.clickedRow : sender.selectedRow
        guard windows.indices.contains(row) else { return }

        let window = windows[row]
        let result = WindowSelectionResult(
            windowID: window.windowID,
            appName: window.appName,
            windowTitle: window.windowTitle
        )
        panel?.finish(with: result)
    }
}

private final class HoverTableView: NSTableView {
    private var trackingAreaRef: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaRef = trackingArea
    }

    override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let hoveredRow = row(at: location)
        if hoveredRow >= 0, hoveredRow != selectedRow {
            selectRowIndexes(IndexSet(integer: hoveredRow), byExtendingSelection: false)
        }
        super.mouseMoved(with: event)
    }
}

// MARK: - AreaTrackingView

private final class AreaTrackingView: NSView {
    var onSelectionComplete: ((CGRect?) -> Void)?

    private var startPoint: NSPoint?
    private var selectionRect: NSRect = .zero
    private var isSelecting = false
    private var backgroundSnapshot: CGImage?
    private var backgroundSnapshotRect: CGRect = .zero
    private var backgroundSnapshotScale: CGFloat = 1

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    func prepareBackgroundSnapshot() {
        let screenRect = convertToScreenCoordinates(bounds)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let snapshot = autoreleasepool {
                CGWindowListCreateImage(screenRect, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution])
            }
            let downsampled = snapshot.flatMap { Self.downsample($0, maxPixelSize: 1920) }
            let scale = Self.scale(for: downsampled, originalRect: screenRect)

            DispatchQueue.main.async { [weak self] in
                self?.backgroundSnapshot = downsampled
                self?.backgroundSnapshotRect = screenRect
                self?.backgroundSnapshotScale = scale
                self?.needsDisplay = true
            }
        }
    }

    func clearBackgroundSnapshot() {
        backgroundSnapshot = nil
        backgroundSnapshotRect = .zero
        backgroundSnapshotScale = 1
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        context.setFillColor(NSColor.black.withAlphaComponent(0.3).cgColor)
        context.fill(bounds)

        if isSelecting && !selectionRect.isEmpty {
            context.clear(selectionRect)
            drawScreenContent(in: selectionRect, context: context)

            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(2.0)
            context.stroke(selectionRect.insetBy(dx: -1, dy: -1))

            drawSizeLabel(for: selectionRect)
            drawCrosshair(at: NSPoint(x: selectionRect.midX, y: selectionRect.midY))
        } else if let window {
            drawCrosshair(at: window.mouseLocationOutsideOfEventStream)
        }
    }

    private func drawCrosshair(at point: NSPoint) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let length: CGFloat = 20
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.8).cgColor)
        context.setLineWidth(1.0)

        context.move(to: CGPoint(x: point.x - length, y: point.y))
        context.addLine(to: CGPoint(x: point.x + length, y: point.y))
        context.strokePath()

        context.move(to: CGPoint(x: point.x, y: point.y - length))
        context.addLine(to: CGPoint(x: point.x, y: point.y + length))
        context.strokePath()
    }

    private func drawSizeLabel(for rect: NSRect) {
        let sizeText = "\(Int(rect.width)) × \(Int(rect.height))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.7)
        ]

        let textSize = (sizeText as NSString).size(withAttributes: attributes)
        let padding: CGFloat = 6
        let labelRect = NSRect(
            x: rect.midX - textSize.width / 2 - padding,
            y: rect.maxY + 8,
            width: textSize.width + padding * 2,
            height: textSize.height + padding * 2
        )

        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 4, yRadius: 4).fill()
        (sizeText as NSString).draw(
            at: NSPoint(x: labelRect.origin.x + padding, y: labelRect.origin.y + padding),
            withAttributes: attributes
        )
    }

    /// 截取选区下方的屏幕内容并绘制
    private func drawScreenContent(in viewRect: NSRect, context: CGContext) {
        // 转换为屏幕坐标（Quartz，Y↓，原点在主显示器左上角）
        let screenRect = convertToScreenCoordinates(viewRect)
        let screenImage: CGImage?
        if let cachedImage = cachedCrop(for: screenRect) {
            screenImage = cachedImage
        } else {
            screenImage = CGWindowListCreateImage(screenRect, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution])
        }

        guard let screenImage else { return }

        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(screenImage, in: NSRect(x: viewRect.origin.x, y: bounds.height - viewRect.maxY, width: viewRect.width, height: viewRect.height))
        context.restoreGState()
    }

    private func cachedCrop(for screenRect: CGRect) -> CGImage? {
        guard let backgroundSnapshot,
              !backgroundSnapshotRect.isEmpty,
              backgroundSnapshotRect.contains(screenRect) else {
            return nil
        }

        let cropRect = CGRect(
            x: (screenRect.minX - backgroundSnapshotRect.minX) * backgroundSnapshotScale,
            y: (screenRect.minY - backgroundSnapshotRect.minY) * backgroundSnapshotScale,
            width: screenRect.width * backgroundSnapshotScale,
            height: screenRect.height * backgroundSnapshotScale
        ).integral

        return backgroundSnapshot.cropping(to: cropRect)
    }

    nonisolated private static func scale(for image: CGImage?, originalRect: CGRect) -> CGFloat {
        guard let image, originalRect.width > 0 else { return 1 }
        return CGFloat(image.width) / originalRect.width
    }

    nonisolated private static func downsample(_ image: CGImage, maxPixelSize: CGFloat) -> CGImage? {
        let maxDimension = CGFloat(max(image.width, image.height))
        guard maxDimension > maxPixelSize else { return image }

        let ratio = maxPixelSize / maxDimension
        let targetWidth = max(1, Int(CGFloat(image.width) * ratio))
        let targetHeight = max(1, Int(CGFloat(image.height) * ratio))

        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: image.bitsPerComponent,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: image.bitmapInfo.rawValue
        ) else {
            return image
        }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage() ?? image
    }

    /// NSView 坐标（Y↑）→ 屏幕坐标（Quartz Y↓）
    private func convertToScreenCoordinates(_ viewRect: NSRect) -> CGRect {
        guard let window else {
            return CGRect(x: viewRect.origin.x, y: bounds.height - viewRect.maxY, width: viewRect.width, height: viewRect.height)
        }
        let windowPoint = convert(viewRect.origin, to: nil)
        let screenPoint = window.convertToScreen(NSRect(origin: windowPoint, size: .zero)).origin
        return CGRect(x: screenPoint.x, y: screenPoint.y, width: viewRect.width, height: viewRect.height)
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        isSelecting = true
        selectionRect = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let current = convert(event.locationInWindow, from: nil)

        selectionRect = NSRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isSelecting, let start = startPoint else { return }
        let end = convert(event.locationInWindow, from: nil)

        let finalRect = NSRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )

        isSelecting = false
        startPoint = nil

        guard finalRect.width > 5, finalRect.height > 5 else {
            needsDisplay = true
            return
        }

        let screenRect = convertToScreenCoordinates(finalRect)
        onSelectionComplete?(screenRect)
    }

    // MARK: - Keyboard Events

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            onSelectionComplete?(nil)
        } else {
            super.keyDown(with: event)
        }
    }
}
