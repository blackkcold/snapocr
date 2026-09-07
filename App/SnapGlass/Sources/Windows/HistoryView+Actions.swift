import AppKit
import HistoryCore
import ImageIO
import SwiftUI

// MARK: - HistoryView Data Loading & Actions

extension HistoryView {
    func loadEntries() async {
        switch segment {
        case .screenshots:
            await loadScreenshotEntries()
        case .colors:
            await loadColorEntries()
        }
    }

    func loadScreenshotEntries() async {
        let loadID = UUID()
        screenshotLoadID = loadID
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
                if let cached = thumbnailSizes[entry.id] { sizes[entry.id] = cached; continue }
                if let data = try? await history.thumbnailData(for: entry.id),
                   let source = CGImageSourceCreateWithData(data as CFData, nil),
                   let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                   let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                   let height = properties[kCGImagePropertyPixelHeight] as? NSNumber {
                    sizes[entry.id] = CGSize(width: width.doubleValue, height: height.doubleValue)
                }
            }
            guard !Task.isCancelled, query == searchQuery, screenshotLoadID == loadID else { return }
            thumbnailSizes = sizes
            entries = loaded
        } catch {
            guard screenshotLoadID == loadID else { return }
            entries = []
            errorMessage = error.localizedDescription
        }
    }

    func loadColorEntries() async {
        guard let colorHistory else {
            colorEntries = []
            return
        }

        do {
            let count = await colorHistory.count()
            colorEntries = try await colorHistory.recent(limit: max(count, 1))
        } catch {
            colorEntries = []
            errorMessage = error.localizedDescription
        }
    }

    func deleteEntry(_ entry: HistoryEntry) async {
        guard let history else { return }

        do {
            try await history.delete(id: entry.id)
            await loadEntries()
        } catch {
            errorMessage = error.localizedDescription
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
            await loadScreenshotEntries()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteColorEntry(_ entry: ColorHistoryEntry) async {
        guard let colorHistory else { return }

        do {
            try await colorHistory.delete(id: entry.id)
            await loadEntries()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func copyColor(_ entry: ColorHistoryEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.hexString, forType: .string)
        let toast = ToastMessage(
            message: String(
                format: NSLocalizedString(
                    "Color %@ copied",
                    comment: "History color copy success"
                ),
                entry.hexString
            ),
            type: .success
        )
        toastMessage = toast
        Task {
            try? await Task.sleep(for: .seconds(3))
            if toastMessage?.id == toast.id {
                toastMessage = nil
            }
        }
    }

    func openInEditor(_ entry: HistoryEntry) async {
        guard let history else { return }
        do {
            guard let data = try await history.imageData(for: entry.id) else {
                errorMessage = "The original screenshot is no longer available. "
                    + "It may have been removed by the retention policy."
                return
            }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                errorMessage = String(localized: "The stored screenshot could not be decoded.")
                return
            }
            captureViewModel.openEditor(with: image, captureMode: entry.captureMode)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearAll() async {
        guard let history else { return }

        do {
            try await history.clear()
            entries = []
            // 清空截图历史时同步清空取色历史，避免 colors/ 目录残留。
            if let colorHistory {
                try? await colorHistory.clear()
                colorEntries = []
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearColors() async {
        guard let colorHistory else { return }

        do {
            try await colorHistory.clear()
            colorEntries = []
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    enum ExportFormat {
        case json, csv, plaintext
    }

    func exportHistory(format: ExportFormat) async {
        guard let history else { return }

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

            let data = try await history.export(ids: [], format: historyFormat)
            try data.write(to: url, options: .atomic)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    errorMessage = nil
                }
            }
        )
    }
}
