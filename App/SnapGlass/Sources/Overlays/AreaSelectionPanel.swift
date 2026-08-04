import AppKit
import CaptureCore
import SharedKit
import SwiftUI

@preconcurrency import ScreenCaptureKit

/// 全屏透明覆盖面板，用于区域截图的交互式选择。
enum AreaCaptureAction {
    case copy
    case edit
}

struct AreaSelectionResult {
    let screenRect: CGRect
    let normalizedPath: [CGPoint]?
    let action: AreaCaptureAction

    var isFreeform: Bool { normalizedPath != nil }
}

/// Coordinates the per-display panels that make up one area-selection session.
@MainActor
private final class AreaSelectionSession {
    private static var retainedSessions: [AreaSelectionSession] = []

    private let onComplete: (AreaSelectionResult?) -> Void
    private var panels: [AreaSelectionPanel] = []
    private var didFinish = false

    static func show(
        style: CaptureSelectionStyle,
        onComplete: @escaping (AreaSelectionResult?) -> Void
    ) {
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            onComplete(nil)
            return
        }

        let session = AreaSelectionSession(onComplete: onComplete)
        retainedSessions.append(session)
        session.present(on: screens, style: style)
    }

    private init(onComplete: @escaping (AreaSelectionResult?) -> Void) {
        self.onComplete = onComplete
    }

    private func present(on screens: [NSScreen], style: CaptureSelectionStyle) {
        panels = screens.map { screen in
            AreaSelectionPanel(screen: screen, style: style) { [weak self] result in
                self?.finish(with: result)
            }
        }

        for panel in panels {
            panel.orderFrontRegardless()
        }

        let mouseLocation = NSEvent.mouseLocation
        let initialPanel = panels.first { $0.frame.contains(mouseLocation) } ?? panels.first
        initialPanel?.makeKey()
    }

    private func finish(with result: AreaSelectionResult?) {
        guard !didFinish else { return }
        didFinish = true

        let completion = onComplete
        let activePanels = panels
        panels.removeAll()
        for panel in activePanels {
            panel.dismissWithoutCompleting()
        }
        Self.retainedSessions.removeAll { $0 === self }
        DispatchQueue.main.async {
            completion(result)
        }
    }
}

final class AreaSelectionPanel: NSPanel {
    private let onComplete: (AreaSelectionResult?) -> Void
    private var trackingView: AreaTrackingView!
    private var didFinish = false

    static func show(
        style: CaptureSelectionStyle,
        onComplete: @escaping (AreaSelectionResult?) -> Void
    ) {
        AreaSelectionSession.show(style: style, onComplete: onComplete)
    }

    fileprivate init(
        screen: NSScreen,
        style: CaptureSelectionStyle,
        onComplete: @escaping (AreaSelectionResult?) -> Void
    ) {
        self.onComplete = onComplete

        super.init(
            contentRect: screen.frame,
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
        acceptsMouseMovedEvents = true
        isMovableByWindowBackground = false
        setFrame(screen.frame, display: true)

        guard let contentView else { return }
        trackingView = AreaTrackingView(frame: contentView.bounds, style: style)
        trackingView.onSelectionComplete = { [weak self] rect in self?.finish(with: rect) }
        trackingView.autoresizingMask = [.width, .height]
        contentView.addSubview(trackingView)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func close() {
        finish(with: nil)
    }

    fileprivate func dismissWithoutCompleting() {
        guard !didFinish else { return }
        didFinish = true
        super.close()
    }

    private func finish(with result: AreaSelectionResult?) {
        guard !didFinish else { return }
        didFinish = true

        let completion = onComplete
        super.close()
        completion(result)
    }
}

// MARK: - WindowSelectionPanel

enum WindowCaptureAction {
    case still
    case scrolling
}

struct WindowSelectionResult {
    let windowID: CGWindowID
    let appName: String?
    let windowTitle: String?
    let action: WindowCaptureAction
}

/// Floating window picker for interactive window capture.
final class WindowSelectionPanel: NSPanel {
    private static var retainedPanels: [WindowSelectionPanel] = []

    private let windows: [SelectableWindow]
    private let onComplete: (WindowSelectionResult?) -> Void
    private let coordinator: WindowSelectionCoordinator
    private let captureButton = NSButton()
    private let scrollCaptureButton = NSButton()
    private var didFinish = false

    static func show(onComplete: @escaping (WindowSelectionResult?) -> Void) {
        Task { @MainActor in
            do {
                let windows = try await fetchAvailableWindows()
                guard !windows.isEmpty else {
                    onComplete(nil)
                    return
                }

                let panel = WindowSelectionPanel(windows: windows, onComplete: onComplete)
                retain(panel)
                panel.orderFrontRegardless()
                panel.makeKey()
            } catch {
                onComplete(nil)
            }
        }
    }

    private static func retain(_ panel: WindowSelectionPanel) {
        retainedPanels.append(panel)
    }

    private static func release(_ panel: WindowSelectionPanel) {
        retainedPanels.removeAll { $0 === panel }
    }

    private init(windows: [SelectableWindow], onComplete: @escaping (WindowSelectionResult?) -> Void) {
        self.windows = windows
        self.onComplete = onComplete
        self.coordinator = WindowSelectionCoordinator(windows: windows)

        let panelSize = NSSize(
            width: 720,
            height: min(640, max(340, windows.count * 92 + 150))
        )
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

        configureActionButtons()
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

    override func close() {
        finish(with: nil)
    }

    fileprivate func finish(with result: WindowSelectionResult?) {
        guard !didFinish else { return }
        didFinish = true

        let completion = onComplete
        Self.release(self)
        super.close()
        completion(result)
    }

    private func makeContentView() -> NSView {
        let container = NSVisualEffectView()
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active

        let titleLabel = NSTextField(labelWithString: NSLocalizedString(
            "Choose a window to capture",
            comment: "Window picker heading"
        ))
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let subtitleLabel = NSTextField(labelWithString: NSLocalizedString(
            "Select a preview, then choose a still or scrolling capture.",
            comment: "Window picker instruction"
        ))
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        let tableView = HoverTableView()
        tableView.headerView = nil
        tableView.rowHeight = 84
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = false
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        tableView.target = coordinator
        tableView.doubleAction = #selector(WindowSelectionCoordinator.captureSelectedWindow(_:))
        coordinator.tableView = tableView

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("window"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let buttonStack = NSStackView(views: [captureButton, scrollCaptureButton])
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.distribution = .fillEqually
        buttonStack.spacing = 10
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(titleLabel)
        container.addSubview(subtitleLabel)
        container.addSubview(scrollView)
        container.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            buttonStack.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 12),
            buttonStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            buttonStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            buttonStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            buttonStack.heightAnchor.constraint(equalToConstant: 34),
        ])

        DispatchQueue.main.async {
            guard tableView.numberOfRows > 0 else { return }
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            self.setActionButtonsEnabled(true)
        }

        return container
    }

    private func configureActionButtons() {
        configure(
            captureButton,
            title: NSLocalizedString("Capture Window", comment: "Still window capture action"),
            symbol: "macwindow",
            action: #selector(captureStillWindow)
        )
        captureButton.keyEquivalent = "\r"

        configure(
            scrollCaptureButton,
            title: NSLocalizedString("Scrolling Capture", comment: "Scrolling window capture action"),
            symbol: "arrow.up.arrow.down",
            action: #selector(captureScrollingWindow)
        )

        setActionButtonsEnabled(false)
    }

    private func configure(_ button: NSButton, title: String, symbol: String, action: Selector) {
        button.title = title
        button.bezelStyle = .rounded
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.target = self
        button.action = action
    }

    fileprivate func setActionButtonsEnabled(_ enabled: Bool) {
        captureButton.isEnabled = enabled
        scrollCaptureButton.isEnabled = enabled
    }

    @objc private func captureStillWindow() {
        finishSelectedWindow(action: .still)
    }

    @objc private func captureScrollingWindow() {
        finishSelectedWindow(action: .scrolling)
    }

    fileprivate func finishSelectedWindow(action: WindowCaptureAction) {
        guard let result = coordinator.selectedResult(action: action) else { return }
        finish(with: result)
    }

    private static func fetchAvailableWindows() async throws -> [SelectableWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        )
        let currentBundleID = Bundle.main.bundleIdentifier
        let systemWindowLevel = Int(CGWindowLevelForKey(.dockWindow))

        return content.windows
            .filter { window in
                WindowCapturePolicy.isSelectable(
                    WindowCaptureCandidate(
                        bundleIdentifier: window.owningApplication?.bundleIdentifier,
                        layer: window.windowLayer,
                        frame: window.frame,
                        isOnScreen: window.isOnScreen
                    ),
                    currentBundleIdentifier: currentBundleID,
                    systemWindowLevel: systemWindowLevel
                )
            }
            .map { window in
                SelectableWindow(
                    windowID: window.windowID,
                    appName: window.owningApplication?.applicationName,
                    windowTitle: window.title,
                    frame: window.frame,
                    bundleIdentifier: window.owningApplication?.bundleIdentifier
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
    let bundleIdentifier: String?

    var displayName: String {
        let app = appName?.isEmpty == false ? appName ?? "Unknown App" : "Unknown App"
        let title = windowTitle?.isEmpty == false ? windowTitle ?? "Untitled" : "Untitled"
        return "\(app) — \(title)"
    }

    var subtitle: String {
        let size = "\(Int(frame.width)) × \(Int(frame.height))"
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return size }
        return "\(bundleIdentifier)  ·  \(size)"
    }
}

@MainActor
private final class WindowSelectionCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    fileprivate weak var panel: WindowSelectionPanel?
    fileprivate weak var tableView: NSTableView?
    private let windows: [SelectableWindow]
    private var thumbnails: [CGWindowID: NSImage] = [:]
    private var loadingWindowIDs: Set<CGWindowID> = []

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

        let preview = NSImageView()
        preview.image = thumbnails[window.windowID]
            ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: window.displayName)
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 7
        preview.layer?.masksToBounds = true
        preview.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        preview.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: window.displayName)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(labelWithString: window.subtitle)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(preview)
        cell.addSubview(title)
        cell.addSubview(subtitle)

        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            preview.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            preview.widthAnchor.constraint(equalToConstant: 120),
            preview.heightAnchor.constraint(equalToConstant: 70),

            title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 17),
            title.leadingAnchor.constraint(equalTo: preview.trailingAnchor, constant: 12),
            title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),

            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),
        ])

        loadThumbnailIfNeeded(for: window, row: row)

        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        panel?.setActionButtonsEnabled(tableView?.selectedRow ?? -1 >= 0)
    }

    @MainActor @objc func captureSelectedWindow(_ sender: NSTableView) {
        let row = sender.clickedRow >= 0 ? sender.clickedRow : sender.selectedRow
        guard windows.indices.contains(row) else { return }
        sender.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        panel?.finishSelectedWindow(action: .still)
    }

    func selectedResult(action: WindowCaptureAction) -> WindowSelectionResult? {
        let row = tableView?.selectedRow ?? -1
        guard windows.indices.contains(row) else { return nil }
        let window = windows[row]
        return WindowSelectionResult(
            windowID: window.windowID,
            appName: window.appName,
            windowTitle: window.windowTitle,
            action: action
        )
    }

    private func loadThumbnailIfNeeded(for window: SelectableWindow, row: Int) {
        guard thumbnails[window.windowID] == nil,
              loadingWindowIDs.insert(window.windowID).inserted else { return }

        Task { @MainActor [weak self] in
            let image = await WindowThumbnailLoader.shared.thumbnail(for: window.windowID)
            guard let self else { return }
            loadingWindowIDs.remove(window.windowID)
            if let image {
                thumbnails[window.windowID] = NSImage(
                    cgImage: image,
                    size: NSSize(width: image.width, height: image.height)
                )
            }
            guard windows.indices.contains(row),
                  windows[row].windowID == window.windowID else { return }
            tableView?.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
        }
    }
}

private actor WindowThumbnailLoader {
    static let shared = WindowThumbnailLoader()

    private let orchestrator = CaptureOrchestrator()
    private var cache: [CGWindowID: CGImage] = [:]

    func thumbnail(for windowID: CGWindowID) async -> CGImage? {
        if let cached = cache[windowID] {
            return cached
        }
        do {
            let image = try await orchestrator.captureWindowThumbnail(
                windowID: windowID,
                maximumSize: CGSize(width: 240, height: 140)
            )
            cache[windowID] = image
            return image
        } catch {
            return nil
        }
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
            title: NSLocalizedString("Edit Screenshot", comment: "Capture action that opens the selected area in the editor"),
            symbol: "pencil.and.outline",
            toolTip: NSLocalizedString(
                "Open the screenshot in the annotation editor",
                comment: "Capture action bar edit button help"
            ),
            action: #selector(editScreenshot)
        )
        editButton.keyEquivalent = "e"

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
        setAccessibilityLabel(NSLocalizedString("Screenshot Actions", comment: "Capture action bar accessibility label"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        for button in [backButton, copyButton, editButton] {
            if button.convert(button.bounds, to: self).contains(point) {
                return button
            }
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

private final class AreaTrackingView: NSView {
    var onSelectionComplete: ((AreaSelectionResult?) -> Void)?

    private enum Phase { case idle, drawing, adjusting, choosingAction }
    private enum ResizeHandle: CaseIterable { case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left }
    private enum DragAction {
        case resize(ResizeHandle, initial: CGRect, start: CGPoint)
        case move(initial: CGRect, start: CGPoint)
    }

    private let style: CaptureSelectionStyle
    private var phase: Phase = .idle
    private var startPoint: CGPoint?
    private var selectionRect: CGRect = .zero
    private var freeformPoints: [CGPoint] = []
    private var dragAction: DragAction?
    private var hoverPoint: CGPoint = .zero
    private var trackingAreaReference: NSTrackingArea?
    private let actionBar = CaptureActionBarView(frame: .zero)

    init(frame frameRect: NSRect, style: CaptureSelectionStyle) {
        self.style = style
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
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        context.setFillColor(NSColor.black.withAlphaComponent(0.32).cgColor)
        context.fill(bounds)

        if style == .freeform, freeformPoints.count >= 2 {
            let path = freeformPath()
            context.saveGState()
            context.addPath(path)
            context.clip()
            context.clear(bounds)
            context.restoreGState()
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(2)
            context.addPath(path)
            context.strokePath()
        } else if !selectionRect.isEmpty {
            context.clear(selectionRect)
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(2)
            context.stroke(selectionRect.insetBy(dx: -1, dy: -1))
            if phase == .adjusting { drawHandles() }
        }

        if !selectionRect.isEmpty {
            drawSizeLabel(for: selectionRect)
            if phase == .adjusting { drawActionHint(for: selectionRect) }
        }
        if phase != .choosingAction { drawCrosshair(at: hoverPoint) }
    }

    private func drawCrosshair(at point: CGPoint) {
        guard bounds.contains(point), let context = NSGraphicsContext.current?.cgContext else { return }
        let length: CGFloat = 18
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: point.x - length, y: point.y))
        context.addLine(to: CGPoint(x: point.x + length, y: point.y))
        context.move(to: CGPoint(x: point.x, y: point.y - length))
        context.addLine(to: CGPoint(x: point.x, y: point.y + length))
        context.strokePath()
    }

    private func drawHandles() {
        NSColor.white.setFill()
        for point in handlePoints().values {
            NSBezierPath(ovalIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)).fill()
        }
    }

    private func drawSizeLabel(for rect: CGRect) {
        drawLabel("\(Int(rect.width)) × \(Int(rect.height))", at: CGPoint(x: rect.midX, y: rect.maxY + 18))
    }

    private func drawActionHint(for rect: CGRect) {
        let text = NSLocalizedString(
            "Return / double-click to choose an action",
            comment: "Area capture selection confirmation hint"
        )
        drawLabel(text, at: CGPoint(x: rect.midX, y: rect.minY - 18))
    }

    private func drawLabel(_ text: String, at point: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let rect = CGRect(x: point.x - size.width / 2 - 6, y: point.y - size.height / 2 - 4, width: size.width + 12, height: size.height + 8)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        (text as NSString).draw(at: CGPoint(x: rect.minX + 6, y: rect.minY + 4), withAttributes: attributes)
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
                freeformPoints.append(clamped(point))
                selectionRect = boundingRect(for: freeformPoints)
            }
        } else if let startPoint {
            selectionRect = normalizedRect(from: startPoint, to: clamped(point))
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
            resetSelection()
            return
        }
        phase = .adjusting
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
        let x = min(
            max(proposedX, bounds.minX + horizontalInset),
            bounds.maxX - size.width - horizontalInset
        )

        var y = selectionRect.minY - size.height - margin
        if y < bounds.minY + horizontalInset {
            y = selectionRect.maxY + margin
        }
        if y + size.height > bounds.maxY - horizontalInset {
            y = max(bounds.minY + horizontalInset, selectionRect.midY - size.height / 2)
        }

        actionBar.frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
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

    private func freeformPath() -> CGPath {
        let path = CGMutablePath()
        guard let first = freeformPoints.first else { return path }
        path.move(to: first)
        for point in freeformPoints.dropFirst() { path.addLine(to: point) }
        if phase == .adjusting || phase == .choosingAction { path.closeSubpath() }
        return path
    }

    private func handlePoints() -> [ResizeHandle: CGPoint] {
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
            let dx = min(max(current.x - start.x, bounds.minX - initial.minX), bounds.maxX - initial.maxX)
            let dy = min(max(current.y - start.y, bounds.minY - initial.minY), bounds.maxY - initial.maxY)
            selectionRect = initial.offsetBy(dx: dx, dy: dy)
        case .resize(let handle, let initial, _):
            var minX = initial.minX
            var maxX = initial.maxX
            var minY = initial.minY
            var maxY = initial.maxY
            let point = clamped(current)
            if [.topLeft, .left, .bottomLeft].contains(handle) { minX = min(point.x, maxX - 5) }
            if [.topRight, .right, .bottomRight].contains(handle) { maxX = max(point.x, minX + 5) }
            if [.bottomLeft, .bottom, .bottomRight].contains(handle) { minY = min(point.y, maxY - 5) }
            if [.topLeft, .top, .topRight].contains(handle) { maxY = max(point.y, minY + 5) }
            selectionRect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
    }

    private func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    private func boundingRect(for points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { rect, point in rect.union(CGRect(origin: point, size: .zero)) }
    }
}
