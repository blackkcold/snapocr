import AppKit
import CaptureCore
import SharedKit
import SwiftUI

@preconcurrency import ScreenCaptureKit

// MARK: - WindowSelectionPanel

enum WindowCaptureAction {
    case still
    case scrolling
    case edit
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
                let (content, windows) = try await fetchAvailableWindows()
                guard !windows.isEmpty else {
                    onComplete(nil)
                    return
                }

                // Start with a clean thumbnail cache so the previews reflect each
                // window's current contents, not a stale frame from a prior picker.
                await WindowThumbnailLoader.shared.clearCache()

                let panel = WindowSelectionPanel(
                    windows: windows,
                    content: content,
                    onComplete: onComplete
                )
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

    private init(
        windows: [SelectableWindow],
        content: SCShareableContent,
        onComplete: @escaping (WindowSelectionResult?) -> Void
    ) {
        self.windows = windows
        self.onComplete = onComplete
        self.coordinator = WindowSelectionCoordinator(windows: windows, content: content)

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
        // No native `title`: with `.fullSizeContentView` + transparent titlebar the
        // native title would overlap the custom `titleLabel` below. The picker's
        // heading is rendered entirely by the custom label in `makeContentView()`.
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        acceptsMouseMovedEvents = true
        titlebarAppearsTransparent = true

        configureActionButtons()
        contentView = makeContentView()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        // The user clicked elsewhere (another SnapGlass window or another app).
        // Finish the picker so the pending capture continuation always resolves
        // and `isCapturing` is released instead of leaving the UI stuck.
        finish(with: nil)
    }

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

    func finish(with result: WindowSelectionResult?) {
        guard !didFinish else { return }
        didFinish = true

        let completion = onComplete
        coordinator.stopRefreshTimer()
        Self.release(self)
        super.close()
        completion(result)
    }

    private func makeContentView() -> NSView {
        let container = NSVisualEffectView()
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active

        let titleLabel = makeLabel(
            AppLocalization.string("Choose a window to capture"),
            font: .systemFont(ofSize: 14, weight: .semibold),
            color: .labelColor
        )
        let subtitleLabel = makeLabel(
            AppLocalization.string("Select a preview, then choose a still or scrolling capture."),
            font: .systemFont(ofSize: 11),
            color: .secondaryLabelColor
        )

        let scrollView = makeWindowListScrollView()
        let buttonStack = makeActionButtonStack()

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

        Task { @MainActor in
            guard coordinator.tableView?.numberOfRows ?? 0 > 0 else { return }
            coordinator.tableView?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            self.setActionButtonsEnabled(true)
            // Keep previews fresh while the picker is open.
            self.coordinator.startRefreshTimer()
        }

        return container
    }

    private func makeLabel(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func makeActionButtonStack() -> NSStackView {
        let buttonStack = NSStackView(views: [captureButton, scrollCaptureButton])
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.distribution = .fillEqually
        buttonStack.spacing = 10
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        return buttonStack
    }

    private func makeWindowListScrollView() -> NSScrollView {
        let tableView = NSTableView()
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
        return scrollView
    }

    private func configureActionButtons() {
        configure(
            captureButton,
            title: AppLocalization.string("Capture Window"),
            symbol: "macwindow",
            action: #selector(captureStillWindow)
        )
        captureButton.keyEquivalent = "\r"

        configure(
            scrollCaptureButton,
            title: AppLocalization.string("Scrolling Capture"),
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

    func setActionButtonsEnabled(_ enabled: Bool) {
        captureButton.isEnabled = enabled
        scrollCaptureButton.isEnabled = enabled
    }

    /// Captures the selected window and opens the result directly in the editor.
    /// This mirrors double-click behavior so a single click on "Capture Window"
    /// always enters the editor regardless of the general capture preference.
    @objc private func captureStillWindow() {
        finishSelectedWindow(action: .edit)
    }

    @objc private func captureScrollingWindow() {
        finishSelectedWindow(action: .scrolling)
    }

    func finishSelectedWindow(action: WindowCaptureAction) {
        guard let result = coordinator.selectedResult(action: action) else { return }
        finish(with: result)
    }

    private static func fetchAvailableWindows() async throws -> (SCShareableContent, [SelectableWindow]) {
        let content = try await withThrowingTimeout(
            milliseconds: 8_000,
            timeoutError: {
                CaptureError.captureFailed(reason: "Window enumeration timed out after 8000ms")
            },
            operation: {
                try await SCShareableContent.excludingDesktopWindows(
                    true,
                    onScreenWindowsOnly: true
                )
            }
        )
        let currentBundleID = Bundle.main.bundleIdentifier
        let systemWindowLevel = Int(CGWindowLevelForKey(.dockWindow))

        let windows = content.windows
            .filter { window in
                WindowCapturePolicy.isSelectable(
                    WindowCaptureCandidate(
                        bundleIdentifier: window.owningApplication?.bundleIdentifier,
                        layer: window.windowLayer,
                        frame: window.frame,
                        isOnScreen: window.isOnScreen,
                        windowTitle: window.title
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

        return (content, windows)
    }
}
