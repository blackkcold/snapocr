import AppKit
import HistoryCore
import ImageIO
import SwiftUI

// MARK: - HistoryView Data Loading & Actions

extension HistoryView {
    /// Single place that presents a toast and schedules its dismissal, so every
    /// history action looks and expires the same way.
    ///
    /// - Parameters:
    ///   - message: Localized text to show.
    ///   - type: Success, error or informational styling.
    ///   - actionLabel: Optional button title, e.g. "Undo".
    ///   - action: Invoked when the user presses the button.
    ///   - duration: Seconds the toast stays on screen. Destructive actions get
    ///     longer so the undo button is reachable.
    func showToast(
        _ message: String,
        type: ToastType = .success,
        actionLabel: String? = nil,
        action: (@MainActor () -> Void)? = nil,
        duration: TimeInterval = 3
    ) {
        guard toastDeduplicator.shouldPresent(message) else { return }
        let toast = ToastMessage(
            message: message,
            type: type,
            actionLabel: actionLabel,
            action: action
        )
        toastMessage = toast
        Task {
            try? await Task.sleep(for: .seconds(duration))
            if toastMessage?.id == toast.id {
                toastMessage = nil
            }
        }
    }

    /// 把失败归类后交给视图统一呈现出口。
    func reportFailure(
        _ kind: HistoryFailure.Kind,
        message: String,
        entryID: UUID? = nil
    ) {
        failure = HistoryFailure(kind: kind, message: message, entryID: entryID)
    }

    /// 按失败类型给出口：加载→重试，复制→再次复制，资源丢失→打开目录。
    func present(_ failure: HistoryFailure) {
        let actionLabel: String?
        let action: (@MainActor () -> Void)?

        switch failure.recovery {
        case .retryLoad:
            actionLabel = AppLocalization.string("Retry")
            action = { Task { await loadEntries() } }
        case .retryCopy:
            if let entryID = failure.entryID,
               let entry = entries.first(where: { $0.id == entryID }) {
                actionLabel = AppLocalization.string("Copy Again")
                action = { Task { await copyImage(entry) } }
            } else {
                actionLabel = AppLocalization.string("Open Storage Folder")
                action = { openHistoryFolder() }
            }
        case .revealStorage:
            actionLabel = AppLocalization.string("Open Storage Folder")
            action = { openHistoryFolder() }
        case .dismiss:
            actionLabel = nil
            action = nil
        }

        showToast(
            failure.message,
            type: .error,
            actionLabel: actionLabel,
            action: action,
            duration: action == nil ? 4 : 6
        )
    }

    func loadEntries() async {
        switch segment {
        case .screenshots:
            await loadScreenshotEntries()
        case .colors:
            await loadColorEntries()
        }
    }

    /// Retries creating the shared history actor after an initialization
    /// failure (for example, a transient permissions or key-access problem).
    func retryHistoryInitialization() async {
        if history == nil {
            // A permanently cached failure would make Retry a no-op forever;
            // drop the cached instance so the next access re-initializes it.
            HistoryActor.resetSharedForRetry()
            history = try? HistoryActor.sharedResult().get()
        }
        await loadEntries()
    }

    func loadScreenshotEntries() async {
        let loadID = UUID()
        screenshotLoadID = loadID
        isLoadingScreenshots = true
        defer {
            if screenshotLoadID == loadID { isLoadingScreenshots = false }
        }
        guard let history else {
            entries = []
            return
        }

        do {
            let query = searchQuery
            let loaded: [HistoryEntry]
            if query.isEmpty {
                let count = await history.count()
                loaded = try await history.recent(limit: max(count, 1))
            } else {
                loaded = try await history.search(query: query)
            }
            var sizes: [UUID: CGSize] = [:]
            for entry in loaded {
                guard !Task.isCancelled, screenshotLoadID == loadID else { return }
                if let size = await pixelSize(for: entry) {
                    sizes[entry.id] = size
                }
            }
            guard !Task.isCancelled, query == searchQuery, screenshotLoadID == loadID else { return }
            thumbnailSizes = sizes
            entries = loaded
            loadError = nil
        } catch {
            guard screenshotLoadID == loadID else { return }
            entries = []
            loadError = error.localizedDescription
            reportFailure(.load, message: error.localizedDescription)
        }
    }

    func loadColorEntries() async {
        isLoadingColors = true
        defer { isLoadingColors = false }
        guard let colorHistory else {
            colorEntries = []
            return
        }

        let count = await colorHistory.count()
        colorEntries = await colorHistory.recent(limit: max(count, 1))
    }

    /// Resolves a grid cell's pixel size without touching thumbnail files when
    /// the entry already carries it.
    private func pixelSize(for entry: HistoryEntry) async -> CGSize? {
        if let size = entry.imagePixelSize { return size }
        if let cached = thumbnailSizes[entry.id] { return cached }
        guard let history else { return nil }
        guard let data = try? await history.thumbnailData(for: entry.id) else { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        guard
            let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
            let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
        else { return nil }
        return CGSize(width: width.doubleValue, height: height.doubleValue)
    }

    func deleteEntry(_ entry: HistoryEntry) async {
        guard let history else { return }

        do {
            // Keep the bytes so the deletion can be undone from the toast.
            let imageData = try await history.imageData(for: entry.id)
            let thumbnailData = try await history.thumbnailData(for: entry.id)
            // Delete moves the original and the edited media into a transaction
            // folder that is removed immediately, so the undo payload must carry
            // both or "Restore Original Image" becomes a dead menu item.
            let originalImageData = entry.canRestoreOriginal
                ? try? await history.originalImageData(for: entry.id)
                : nil
            try await history.delete(id: entry.id)
            await loadEntries()
            showToast(
                AppLocalization.string("Screenshot deleted"),
                type: .info,
                actionLabel: AppLocalization.string("Undo"),
                action: {
                    Task {
                        await restoreDeletedEntry(
                            entry,
                            imageData: imageData,
                            thumbnailData: thumbnailData,
                            originalImageData: originalImageData
                        )
                    }
                },
                duration: 6
            )
        } catch {
            reportFailure(.action, message: error.localizedDescription)
        }
    }

    private func restoreDeletedEntry(
        _ entry: HistoryEntry,
        imageData: Data?,
        thumbnailData: Data?,
        originalImageData: Data?
    ) async {
        guard let history else { return }
        do {
            try await history.restore(
                entry,
                imageData: imageData,
                thumbnailData: thumbnailData,
                originalImageData: originalImageData
            )
            await loadEntries()
        } catch {
            reportFailure(.action, message: error.localizedDescription)
        }
    }

    func toggleFavourite(_ entry: HistoryEntry) async {
        guard let history, !updatingFavourites.contains(entry.id) else { return }
        updatingFavourites.insert(entry.id)
        defer { updatingFavourites.remove(entry.id) }
        do {
            if let updated = try await history.setFavourite(id: entry.id, isFavourite: !entry.isFavourite),
               let index = entries.firstIndex(where: { $0.id == entry.id }) {
                entries[index] = updated
            }
        } catch {
            reportFailure(.action, message: error.localizedDescription)
        }
    }

    func deleteColorEntry(_ entry: ColorHistoryEntry) async {
        guard let colorHistory else { return }

        do {
            try await colorHistory.delete(id: entry.id)
            await loadEntries()
        } catch {
            reportFailure(.action, message: error.localizedDescription)
        }
    }

    func copyColor(_ entry: ColorHistoryEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.hexString, forType: .string)
        showToast(AppLocalization.string("Color %@ copied", entry.hexString))
    }

    func copyImage(_ entry: HistoryEntry) async {
        guard let history else { return }
        do {
            guard let data = try await history.imageData(for: entry.id),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                reportFailure(.copy, message: AppLocalization.string("Unable to copy image"), entryID: entry.id)
                return
            }
            let nsImage = NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
            )
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.writeObjects([nsImage]) else {
                reportFailure(.copy, message: AppLocalization.string("Unable to copy image"), entryID: entry.id)
                return
            }
            showToast(AppLocalization.string("Screenshot copied to clipboard"))
        } catch {
            reportFailure(.copy, message: AppLocalization.string("Unable to copy image"), entryID: entry.id)
        }
    }

    func openInEditor(_ entry: HistoryEntry) async {
        guard let history else { return }
        do {
            guard let data = try await history.imageData(for: entry.id) else {
                reportFailure(
                    .storage,
                    message: AppLocalization.string(
                        // swiftlint:disable:next line_length
                        "The original screenshot is no longer available. It may have been removed by the retention policy."
                    ),
                    entryID: entry.id
                )
                return
            }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                reportFailure(
                    .storage,
                    message: AppLocalization.string("The stored screenshot could not be decoded."),
                    entryID: entry.id
                )
                return
            }
            captureViewModel.openEditor(
                with: image,
                captureMode: entry.captureMode,
                sourceEntryID: entry.id
            )
        } catch {
            reportFailure(.action, message: error.localizedDescription)
        }
    }

    func clearAll() async {
        guard let history else { return }

        do {
            try await history.clear()
            entries = []
            // Color history is a separate dataset with its own "Clear Colors"
            // action; wiping screenshots must not take it down silently.
        } catch {
            reportFailure(.action, message: error.localizedDescription)
        }
    }

    func clearColors() async {
        guard let colorHistory else { return }

        do {
            try await colorHistory.clear()
            colorEntries = []
        } catch {
            reportFailure(.action, message: error.localizedDescription)
        }
    }

    func restoreOriginal(_ entry: HistoryEntry) async {
        guard let history else { return }
        do {
            try await history.restoreOriginal(id: entry.id)
            await loadEntries()
            showToast(AppLocalization.string("Original image restored"))
        } catch {
            reportFailure(.action, message: error.localizedDescription)
        }
    }

    enum ExportFormat {
        case json, csv, plaintext
    }

    func exportHistory(format: ExportFormat) async {
        guard let history else { return }

        // Export what the user is looking at, not the whole archive.
        let ids = visibleEntries.map(\.id)
        guard !ids.isEmpty else { return }

        let panel = NSSavePanel()

        switch format {
        case .json:
            panel.nameFieldStringValue = "snapglass-history.json"
            panel.allowedContentTypes = [.json]
        case .csv:
            panel.nameFieldStringValue = "snapglass-history.csv"
            panel.allowedContentTypes = [.commaSeparatedText]
        case .plaintext:
            panel.nameFieldStringValue = "snapglass-history.txt"
            panel.allowedContentTypes = [.plainText]
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let historyFormat: HistoryExportFormat
            switch format {
            case .json:
                historyFormat = .json
            case .csv:
                historyFormat = .csv
            case .plaintext:
                historyFormat = .plainText
            }

            let data = try await history.export(ids: ids, format: historyFormat)
            try data.write(to: url, options: .atomic)
            showToast(AppLocalization.string("Exported %lld entries to %@", ids.count, url.lastPathComponent))
        } catch {
            reportFailure(.action, message: error.localizedDescription)
        }
    }

    /// Moves the grid selection with the arrow keys, skipping a row at a time
    /// for up and down.
    func moveSelection(_ direction: MoveCommandDirection) {
        guard !visibleEntries.isEmpty else { return }
        let entries = visibleEntries
        let currentIndex = selectedEntryID.flatMap { id in
            entries.firstIndex(where: { $0.id == id })
        }

        let targetIndex: Int
        switch direction {
        case .left:
            targetIndex = max(0, (currentIndex ?? 1) - 1)
        case .right:
            targetIndex = min(entries.count - 1, (currentIndex ?? -1) + 1)
        case .up:
            targetIndex = max(0, (currentIndex ?? visibleColumnCount) - visibleColumnCount)
        case .down:
            targetIndex = min(entries.count - 1, (currentIndex ?? -1) + visibleColumnCount)
        @unknown default:
            return
        }

        selectedEntryID = entries[targetIndex].id
    }
}
