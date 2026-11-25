import CaptureCore
import Foundation
import LibraryCore
import OSLog

public struct RecordingDeletionReport: Sendable {
    public let deletedSessionCount: Int
    public let trashedURLs: [URL]
    public let failures: [String]

    public var succeeded: Bool { failures.isEmpty }
}

/// Moves published recordings and their hidden session folders to the Trash.
///
/// The journal/index is treated as a cache after deletion: removing the index
/// file forces the next scan to rebuild it from the surviving session folders.
public actor RecordingDeletionService {
    private let metadataStore: RecordingLibraryStore
    private let fileManager: FileManager
    private let logger = Logger(subsystem: "com.snapglass.app", category: "LibraryDeletion")

    public init(metadataStore: RecordingLibraryStore, fileManager: FileManager = .default) {
        self.metadataStore = metadataStore
        self.fileManager = fileManager
    }

    public func delete(_ group: LibraryRecordingGroup) async -> RecordingDeletionReport {
        var candidates = Set<URL>()

        for root in group.roots {
            let sessionFolder = root
                .appendingPathComponent(".SnapGlassSessions", isDirectory: true)
                .appendingPathComponent(group.sessionID.uuidString.lowercased(), isDirectory: true)
            if fileManager.fileExists(atPath: sessionFolder.path) {
                candidates.insert(sessionFolder.standardizedFileURL)
            }
        }

        for segment in group.segments {
            for url in segment.mediaURLs {
                let standardized = url.standardizedFileURL
                guard group.roots.contains(where: { isContained(standardized, in: $0) }) else {
                    continue
                }
                candidates.insert(standardized)
            }
        }

        let topLevel = candidates
            .sorted { $0.path.count < $1.path.count }
            .reduce(into: [URL]()) { result, url in
                if result.contains(where: { isContained(url, in: $0) }) { return }
                result.append(url)
            }

        guard !topLevel.isEmpty else {
            return RecordingDeletionReport(
                deletedSessionCount: 0,
                trashedURLs: [],
                failures: [LibraryLocalization.string("No recording files were found; the item was left untouched.")]
            )
        }

        var trashed: [URL] = []
        var failures: [String] = []
        for url in topLevel {
            do {
                try fileManager.trashItem(at: url, resultingItemURL: nil)
                trashed.append(url)
            } catch {
                let message = LibraryLocalization.string(
                    "Could not move %@ to the Trash: %@",
                    url.lastPathComponent,
                    error.localizedDescription
                )
                failures.append(message)
                logger.error("Trash failed for \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        if !trashed.isEmpty {
            await metadataStore.markDeleted(sessionID: group.sessionID)
            invalidateIndexes(for: group.roots)
        }

        return RecordingDeletionReport(
            deletedSessionCount: trashed.isEmpty ? 0 : 1,
            trashedURLs: trashed,
            failures: failures
        )
    }

    private func invalidateIndexes(for roots: [URL]) {
        for root in roots {
            let indexURL = root
                .appendingPathComponent(".SnapGlassSessions", isDirectory: true)
                .appendingPathComponent("recording-index.json")
            try? fileManager.removeItem(at: indexURL)
        }
    }

    private func isContained(_ url: URL, in directory: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let base = directory.standardizedFileURL.path
        return path == base || path.hasPrefix(base + "/")
    }
}
