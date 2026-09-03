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
            ? appName ?? String(localized: "Unknown App")
            : String(localized: "Unknown App")
        let title = windowTitle?.isEmpty == false
            ? windowTitle ?? String(localized: "Untitled")
            : String(localized: "Untitled")
        return "\(app) — \(title)"
    }

    var subtitle: String {
        let size = "\(Int(frame.width)) × \(Int(frame.height))"
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return size }
        return "\(bundleIdentifier)  ·  \(size)"
    }
}

@MainActor
final class WindowSelectionCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    weak var panel: WindowSelectionPanel?
    weak var tableView: NSTableView?
    private let windows: [SelectableWindow]
    private let content: SCShareableContent
    private var thumbnails: [CGWindowID: NSImage] = [:]
    private var loadingWindowIDs: Set<CGWindowID> = []
    private var refreshTimer: Timer?

    /// How often to re-capture thumbnails for the currently visible rows so the
    /// previews track each window's live contents without capturing every row.
    private static let refreshInterval: TimeInterval = 3.0

    init(windows: [SelectableWindow], content: SCShareableContent) {
        self.windows = windows
        self.content = content
    }

    /// Starts a low-frequency timer that re-captures thumbnails for the rows
    /// currently visible in the table, keeping previews fresh while the picker
    /// is open.
    func startRefreshTimer() {
        guard refreshTimer == nil else { return }
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshVisibleThumbnails()
            }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func refreshVisibleThumbnails() {
        guard let tableView, let scrollView = tableView.enclosingScrollView else { return }
        let visibleRect = scrollView.contentView.bounds
        let visibleRange = tableView.rows(in: visibleRect)
        guard visibleRange.length > 0 else { return }

        for row in visibleRange.location ..< visibleRange.location + visibleRange.length
        where windows.indices.contains(row) {
            let window = windows[row]
            guard thumbnails[window.windowID] != nil,
                  !loadingWindowIDs.contains(window.windowID) else { continue }
            loadThumbnail(for: window, row: row, forceRefresh: true)
        }
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

    private func loadThumbnailIfNeeded(for window: SelectableWindow, row: Int) {
        guard thumbnails[window.windowID] == nil,
              !loadingWindowIDs.contains(window.windowID) else { return }
        loadThumbnail(for: window, row: row, forceRefresh: false)
    }

    private func loadThumbnail(for window: SelectableWindow, row: Int, forceRefresh: Bool) {
        guard loadingWindowIDs.insert(window.windowID).inserted else { return }

        let sharedContent = content
        Task { @MainActor [weak self] in
            let image = await WindowThumbnailLoader.shared.thumbnail(
                for: window.windowID,
                content: sharedContent,
                forceRefresh: forceRefresh
            )
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
