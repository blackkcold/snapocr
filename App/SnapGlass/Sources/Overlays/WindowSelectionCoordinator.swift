import AppKit
import CaptureCore
import SharedKit
import SwiftUI

@preconcurrency import ScreenCaptureKit

struct SelectableWindow {
    let windowID: CGWindowID
    let appName: String?
    let windowTitle: String?
    let frame: CGRect
    let bundleIdentifier: String?

    var displayName: String {
        let app = appName?.isEmpty == false
            ? appName ?? AppLocalization.string("Unknown App")
            : AppLocalization.string("Unknown App")
        let title = windowTitle?.isEmpty == false
            ? windowTitle ?? AppLocalization.string("Untitled")
            : AppLocalization.string("Untitled")
        return "\(app) — \(title)"
    }

    var subtitle: String {
        let size = "\(Int(frame.width)) × \(Int(frame.height))"
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return size }
        return "\(bundleIdentifier)  ·  \(size)"
    }
}

// MARK: - WindowPickerCell

/// 复用的窗口预览行。
///
/// 复用的关键不是省下 `NSTableCellView` 的分配，而是**异步缩略图不能贴错行**：
/// 每次配置都会记录 `representedWindowID`，异步结果回来时只有在 id 仍然匹配时才写入。
@MainActor
final class WindowPickerCell: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("WindowPickerCell")

    private let preview = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private(set) var representedWindowID: CGWindowID?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUpSubviews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUpSubviews()
    }

    private func setUpSubviews() {
        identifier = Self.reuseIdentifier

        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 7
        preview.layer?.masksToBounds = true
        preview.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        preview.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(preview)
        addSubview(titleLabel)
        addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            preview.centerYAnchor.constraint(equalTo: centerYAnchor),
            preview.widthAnchor.constraint(equalToConstant: 120),
            preview.heightAnchor.constraint(equalToConstant: 70),

            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 17),
            titleLabel.leadingAnchor.constraint(equalTo: preview.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
        ])
    }

    func configure(window: SelectableWindow, thumbnail: NSImage?) {
        representedWindowID = window.windowID
        titleLabel.stringValue = window.displayName
        subtitleLabel.stringValue = window.subtitle
        preview.image = thumbnail ?? Self.placeholderImage
        preview.setAccessibilityLabel(window.displayName)
    }

    /// 只换图，不重建行、不 reload，避免滚轮/定时刷新时整行闪一下。
    func setThumbnail(_ image: NSImage) {
        preview.image = image
    }

    private static let placeholderImage = NSImage(
        systemSymbolName: "macwindow",
        accessibilityDescription: nil
    )
}

// MARK: - WindowSelectionCoordinator

@MainActor
final class WindowSelectionCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    weak var panel: WindowSelectionPanel?
    weak var tableView: NSTableView?
    private let windows: [SelectableWindow]
    private let content: SCShareableContent
    private var thumbnails: [CGWindowID: NSImage] = [:]
    private var loadingWindowIDs: Set<CGWindowID> = []
    private var thumbnailTasks: [CGWindowID: Task<Void, Never>] = [:]
    private var rowByWindowID: [CGWindowID: Int] = [:]
    private var refreshTimer: Timer?

    /// 刷新间隔。原来 3 秒会为所有可见行重截一次；改成只刷新「当前选中行 + 首行」，
    /// 并把间隔拉到 9 秒，空闲时对 SCK 的调用从几十次/分钟降到 ~13 次/分钟。
    private static let refreshInterval: TimeInterval = 9.0

    init(windows: [SelectableWindow], content: SCShareableContent) {
        self.windows = windows
        self.content = content
        super.init()
        for (index, window) in windows.enumerated() {
            rowByWindowID[window.windowID] = index
        }
    }

    /// Starts a low-frequency timer that re-captures the selected row's preview.
    func startRefreshTimer() {
        guard refreshTimer == nil else { return }
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshSelectedThumbnail()
            }
        }
        timer.tolerance = 1.0
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// 面板关闭时调用：取消所有在途缩略图任务，避免关闭后还有 SCK 调用回到已释放的 UI。
    func cancelPendingThumbnails() {
        for task in thumbnailTasks.values {
            task.cancel()
        }
        thumbnailTasks.removeAll()
        loadingWindowIDs.removeAll()
    }

    private func refreshSelectedThumbnail() {
        // Do not burn GPU/CPU on live previews while the picker is in the
        // background or another app/window is key.
        guard let panel, panel.isVisible, panel.isKeyWindow else { return }

        var rows = Set<Int>()
        if let selected = tableView?.selectedRow, selected >= 0 {
            rows.insert(selected)
        }
        if !windows.isEmpty {
            rows.insert(0)
        }

        for row in rows where windows.indices.contains(row) {
            let window = windows[row]
            guard thumbnails[window.windowID] != nil,
                  !loadingWindowIDs.contains(window.windowID) else { continue }
            loadThumbnail(for: window, forceRefresh: true)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        windows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard windows.indices.contains(row) else { return nil }

        let window = windows[row]
        let reusable = tableView.makeView(
            withIdentifier: WindowPickerCell.reuseIdentifier,
            owner: self
        ) as? WindowPickerCell
        let cell = reusable ?? WindowPickerCell(frame: .zero)
        cell.identifier = WindowPickerCell.reuseIdentifier
        cell.configure(window: window, thumbnail: thumbnails[window.windowID])

        loadThumbnailIfNeeded(for: window)

        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        panel?.setActionButtonsEnabled(tableView?.selectedRow ?? -1 >= 0)
    }

    @MainActor @objc func captureSelectedWindow(_ sender: NSTableView) {
        let row = sender.clickedRow >= 0 ? sender.clickedRow : sender.selectedRow
        guard windows.indices.contains(row) else { return }
        sender.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        // Double-click opens the preview directly in the annotation editor.
        panel?.finishSelectedWindow(action: .edit)
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

    private func loadThumbnailIfNeeded(for window: SelectableWindow) {
        guard thumbnails[window.windowID] == nil,
              !loadingWindowIDs.contains(window.windowID) else { return }
        loadThumbnail(for: window, forceRefresh: false)
    }

    private func loadThumbnail(for window: SelectableWindow, forceRefresh: Bool) {
        guard loadingWindowIDs.insert(window.windowID).inserted else { return }

        let windowID = window.windowID
        let sharedContent = content
        let task = Task { @MainActor [weak self] in
            defer {
                self?.loadingWindowIDs.remove(windowID)
                self?.thumbnailTasks[windowID] = nil
            }
            let image = await WindowThumbnailLoader.shared.thumbnail(
                for: windowID,
                content: sharedContent,
                forceRefresh: forceRefresh
            )
            guard let self, !Task.isCancelled, let image else { return }
            let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            self.thumbnails[windowID] = nsImage
            self.applyThumbnail(nsImage, to: windowID)
        }
        thumbnailTasks[windowID] = task
    }

    /// 把缩略图写回**当前仍代表该窗口**的行；被复用到别的窗口的 cell 一律跳过。
    private func applyThumbnail(_ image: NSImage, to windowID: CGWindowID) {
        guard let row = rowByWindowID[windowID],
              let tableView,
              let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? WindowPickerCell,
              cell.representedWindowID == windowID else { return }
        cell.setThumbnail(image)
    }
}
