import AppKit
import CaptureCore
import Foundation
import HistoryCore
import ImageIO
import LibraryCore
import UniformTypeIdentifiers

@MainActor
extension LibraryViewModel {
    // MARK: - Quick Look

    func quickLookURLs(for item: LibraryCore.LibraryItem) async -> [URL] {
        switch item {
        case .screenshot(let entry):
            guard let history = HistoryActor.shared,
                let data = try? await history.imageData(for: entry.id)
            else { return [] }
            let directory = LibraryPaths.metadataFileURL
                .deletingLastPathComponent()
                .appendingPathComponent("QuickLook", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let url = directory.appendingPathComponent(
                "\(entry.id.uuidString).\(imageExtension(for: data))"
            )
            do {
                try data.write(to: url, options: .atomic)
                return [url]
            } catch {
                return []
            }
        case .recording(let group):
            let urls = group.segments
                .flatMap(\.mediaURLs)
                .filter { url in
                    (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
                }
            if !urls.isEmpty { return urls }
            return group.mediaURL.map { [$0] } ?? []
        }
    }

    private func imageExtension(for data: Data) -> String {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let type = CGImageSourceGetType(source) as String?,
            let utType = UTType(type),
            let preferred = utType.preferredFilenameExtension
        else { return "png" }
        return preferred.lowercased() == "jpeg" ? "jpg" : preferred.lowercased()
    }

    // MARK: - Opening and revealing

    func openScreenshot(_ entry: HistoryEntry, using captureViewModel: CaptureViewModel) async {
        guard let history = HistoryActor.shared,
            let data = try? await history.imageData(for: entry.id),
            let image = NSImage(data: data),
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            showToast(AppLocalization.string("Could not open this screenshot."), type: .error)
            return
        }
        _ = captureViewModel.openEditor(
            with: cgImage,
            captureMode: entry.captureMode,
            sourceEntryID: entry.id,
            mockupStyle: HistoryMockupPresenter.style(from: entry)
        )
    }

    func openRecording(_ group: LibraryRecordingGroup) {
        guard let url = group.mediaURL else {
            showToast(AppLocalization.string("The recording file is unavailable."), type: .error)
            return
        }
        NSWorkspace.shared.open(url)
    }

    func revealInFinder(_ item: LibraryCore.LibraryItem) {
        switch item {
        case .screenshot:
            let folder = URL.appSupportDirectory
                .appendingPathComponent("History", isDirectory: true)
                .appendingPathComponent("v2", isDirectory: true)
            NSWorkspace.shared.open(folder)
        case .recording(let group):
            let urls = group.segments.flatMap(\.mediaURLs)
            if urls.isEmpty, let firstRoot = group.roots.first {
                NSWorkspace.shared.open(firstRoot)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            }
        }
    }

    // MARK: - Thumbnails

    func thumbnail(for item: LibraryCore.LibraryItem) async -> NSImage? {
        if let cached = thumbnails[item.id] { return cached }
        let image: NSImage?
        switch item {
        case .screenshot(let entry):
            guard let history = HistoryActor.shared,
                let data = try? await history.thumbnailData(for: entry.id)
            else { return nil }
            image = NSImage(data: data)
        case .recording(let group):
            guard let data = await thumbnailService.thumbnailData(for: group) else { return nil }
            image = NSImage(data: data)
        }
        if let image {
            thumbnails[item.id] = image
        }
        return image
    }

    // MARK: - Colors

    func loadColors() async {
        guard let store = ColorHistoryStore.shared else { return }
        let count = await store.count()
        colorEntries = await store.recent(limit: max(count, 1))
    }

    func copyColor(_ entry: ColorHistoryEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.hexString, forType: .string)
        showToast(AppLocalization.string("Color copied"))
    }

    func deleteColor(_ entry: ColorHistoryEntry) async {
        guard let store = ColorHistoryStore.shared else { return }
        try? await store.delete(id: entry.id)
        await loadColors()
    }

    // MARK: - Recoverable

    func recover(_ recording: RecoverableRecording) async {
        do {
            _ = try await RecordingRecoveryService.shared.recover(recording)
            recoverable.removeAll { $0.id == recording.id }
            await load()
            showToast(AppLocalization.string("Recovered recording added to your list."))
        } catch {
            showToast(error.localizedDescription, type: .error)
        }
    }

    func discard(_ recording: RecoverableRecording) async {
        do {
            try await RecordingRecoveryService.shared.discard(recording)
            recoverable.removeAll { $0.id == recording.id }
            showToast(AppLocalization.string("Recording moved to the Trash."))
        } catch {
            showToast(error.localizedDescription, type: .error)
        }
    }
}
