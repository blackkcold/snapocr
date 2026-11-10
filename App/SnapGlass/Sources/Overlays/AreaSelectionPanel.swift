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
    private var coordinator: WindowSelectionCoordinator
    private let captureButton = NSButton()
    private let editButton = NSButton()
    private let scrollCaptureButton = NSButton()
    private let searchField = NSSearchField()
    private let refreshButton = NSButton()
    private let emptyStateView = NSStackView()
    private let emptyStateLabel = NSTextField(labelWithString: "")
    private let retryButton = NSButton()
    private var content: SCShareableContent?
    private var loadError: String?
    private var listScrollView: NSScrollView?
    private var didFinish = false
    private var onActivity: (() -> Void)?

    private struct WindowLoadResult {
        let content: SCShareableContent?
        let windows: [SelectableWindow]
        let error: String?
    }

    static func show(
        onComplete: @escaping (WindowSelectionResult?) -> Void,
        onActivity: @escaping () -> Void = {}
    ) {
        Task { @MainActor in
            let result = await loadWindows()

            // Start with a clean thumbnail cache so the previews reflect each
            // window's current contents, not a stale frame from a prior picker.
            await WindowThumbnailLoader.shared.clearCache()

            let panel = WindowSelectionPanel(
                windows: result.windows,
                content: result.content,
                loadError: result.error,
                onComplete: onComplete
            )
            panel.onActivity = onActivity
            retain(panel)
            panel.orderFrontRegardless()
            panel.makeKey()
        }
    }

    private static func loadWindows() async -> WindowLoadResult {
        do {
            let (content, windows) = try await fetchAvailableWindows()
            return WindowLoadResult(content: content, windows: windows, error: nil)
        } catch {
            return WindowLoadResult(
                content: nil,
                windows: [],
                error: error.localizedDescription
            )
        }
    }

    private static func retain(_ panel: WindowSelectionPanel) {
        retainedPanels.append(panel)
    }

    private static func release(_ panel: WindowSelectionPanel) {
        retainedPanels.removeAll { $0 === panel }
    }

    /// Closes any picker still on screen. Used only by the capture-side
    /// timeout so a panel that never appeared cannot block the next capture.
    @MainActor
    static func closeActivePanel() {
        // `close()` routes through `finish(with:)`, which resolves the pending
        // continuation and releases the panel.
        for panel in retainedPanels {
            panel.close()
        }
    }

    private init(
        windows: [SelectableWindow],
        content: SCShareableContent?,
        loadError: String?,
        onComplete: @escaping (WindowSelectionResult?) -> Void
    ) {
        self.windows = windows
        self.onComplete = onComplete
        self.content = content
        self.loadError = loadError
        self.coordinator = WindowSelectionCoordinator(windows: windows, content: content)

        let panelSize = NSSize(
            width: 760,
            height: min(680, max(420, windows.count * 96 + 190))
        )
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? NSScreen.main
        let screenFrame = targetScreen?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 800, height: 600)
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
        coordinator.cancelPendingThumbnails()
        Self.release(self)
        super.close()
        completion(result)
    }

    /// 列表下方的提示；未选中窗口时改为说明为什么按钮不可用。
    private var subtitleLabel: NSTextField?

    // The constraints are intentionally kept in one place so the search row,
    // empty state, and action buttons cannot drift apart during layout changes.
    // swiftlint:disable:next function_body_length
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
            AppLocalization.string("Capture follows your After Capture settings."),
            font: .systemFont(ofSize: 11),
            color: .secondaryLabelColor
        )
        self.subtitleLabel = subtitleLabel

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = AppLocalization.string("Search windows")
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.isEnabled = !windows.isEmpty

        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        refreshButton.bezelStyle = .inline
        refreshButton.isBordered = false
        refreshButton.image = NSImage(
            systemSymbolName: "arrow.clockwise",
            accessibilityDescription: AppLocalization.string("Refresh window list")
        )
        refreshButton.target = self
        refreshButton.action = #selector(reloadWindows)
        refreshButton.toolTip = AppLocalization.string("Refresh window list")

        let scrollView = makeWindowListScrollView()
        listScrollView = scrollView

        let emptyIcon = NSImageView()
        emptyIcon.image = NSImage(
            systemSymbolName: "macwindow",
            accessibilityDescription: nil
        )
        emptyIcon.contentTintColor = .secondaryLabelColor
        emptyIcon.imageScaling = .scaleProportionallyUpOrDown
        emptyIcon.translatesAutoresizingMaskIntoConstraints = false
        emptyIcon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        emptyIcon.heightAnchor.constraint(equalToConstant: 24).isActive = true

        emptyStateLabel.font = .systemFont(ofSize: 12)
        emptyStateLabel.textColor = .secondaryLabelColor
        emptyStateLabel.alignment = .center
        emptyStateLabel.maximumNumberOfLines = 3
        emptyStateLabel.lineBreakMode = .byWordWrapping
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false

        retryButton.title = AppLocalization.string("Retry")
        retryButton.bezelStyle = .rounded
        retryButton.target = self
        retryButton.action = #selector(reloadWindows)

        emptyStateView.orientation = .vertical
        emptyStateView.alignment = .centerX
        emptyStateView.spacing = 8
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.addArrangedSubview(emptyIcon)
        emptyStateView.addArrangedSubview(emptyStateLabel)
        emptyStateView.addArrangedSubview(retryButton)
        emptyStateView.isHidden = true

        let buttonStack = makeActionButtonStack()

        container.addSubview(titleLabel)
        container.addSubview(subtitleLabel)
        container.addSubview(searchField)
        container.addSubview(refreshButton)
        container.addSubview(scrollView)
        container.addSubview(emptyStateView)
        container.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            searchField.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            searchField.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -8),

            refreshButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            refreshButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            refreshButton.widthAnchor.constraint(equalToConstant: 24),
            refreshButton.heightAnchor.constraint(equalToConstant: 24),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            emptyStateView.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyStateView.leadingAnchor.constraint(
                greaterThanOrEqualTo: scrollView.leadingAnchor,
                constant: 24
            ),
            emptyStateView.trailingAnchor.constraint(
                lessThanOrEqualTo: scrollView.trailingAnchor,
                constant: -24
            ),
            emptyStateLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420),

            buttonStack.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 12),
            buttonStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            buttonStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            buttonStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            buttonStack.heightAnchor.constraint(equalToConstant: 34),
        ])

        if windows.isEmpty {
            setEmptyStateVisible(true)
            setActionButtonsEnabled(false)
        } else {
            Task { @MainActor in
                guard coordinator.tableView?.numberOfRows ?? 0 > 0 else { return }
                coordinator.tableView?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                self.setActionButtonsEnabled(true)
                // Keep previews fresh while the picker is open.
                self.coordinator.startRefreshTimer()
            }
        }

        if let loadError {
            subtitleLabel.stringValue = loadError
        }

        return container
    }

    func setEmptyStateVisible(_ visible: Bool) {
        emptyStateView.isHidden = !visible
        listScrollView?.isHidden = visible
        if visible {
            emptyStateLabel.stringValue = loadError
                ?? AppLocalization.string("No capturable windows found")
        }
    }

    func notifyActivity() {
        onActivity?()
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        notifyActivity()
        coordinator.setFilter(sender.stringValue)
    }

    @objc private func reloadWindows() {
        notifyActivity()
        refreshButton.isEnabled = false
        Task { @MainActor in
            let result = await Self.loadWindows()
            self.content = result.content
            self.loadError = result.error
            self.coordinator.replaceWindows(result.windows, content: result.content)
            self.setActionButtonsEnabled(self.coordinator.visibleWindowCount > 0)
            self.setEmptyStateVisible(result.windows.isEmpty)
            if let error = result.error {
                self.subtitleLabel?.stringValue = error
            }
            self.refreshButton.isEnabled = true
        }
    }

    private func makeLabel(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func makeActionButtonStack() -> NSStackView {
        let buttonStack = NSStackView(views: [captureButton, editButton, scrollCaptureButton])
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
            editButton,
            title: AppLocalization.string("Edit Window"),
            symbol: "pencil",
            action: #selector(editSelectedWindow)
        )

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
        editButton.isEnabled = enabled
        scrollCaptureButton.isEnabled = enabled

        if let loadError, !enabled {
            subtitleLabel?.stringValue = loadError
            return
        }

        if enabled {
            subtitleLabel?.stringValue = AppLocalization.string(
                "Capture follows your After Capture settings. Choose Edit to annotate first."
            )
        } else {
            let hasRows = coordinator.visibleWindowCount > 0
            subtitleLabel?.stringValue = AppLocalization.string(
                hasRows ? "Select a window to continue" : "No capturable windows found"
            )
        }
    }

    /// Captures the selected window using the normal After Capture settings.
    @objc private func captureStillWindow() {
        finishSelectedWindow(action: .still)
    }

    /// Opens the selected window directly in the annotation editor.
    @objc private func editSelectedWindow() {
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
            .map { window -> SelectableWindow in
                let displayCount = content.displays.filter { display in
                    window.frame.intersects(display.frame)
                }.count
                return SelectableWindow(
                    windowID: window.windowID,
                    appName: window.owningApplication?.applicationName,
                    windowTitle: window.title,
                    frame: window.frame,
                    bundleIdentifier: window.owningApplication?.bundleIdentifier,
                    displayCount: displayCount
                )
            }
            .sorted { (lhs: SelectableWindow, rhs: SelectableWindow) in
                lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }

        return (content, windows)
    }
}
