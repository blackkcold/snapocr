import CaptureCore
import Foundation
import LibraryCore
import OSLog

/// Outcome of moving a recording to the Trash.
public struct RecordingDeletionReport: Sendable {
    /// `1` when the recording was deleted, `0` when nothing was trashed.
    public let deletedSessionCount: Int
    /// Top-level files and session folders that were moved to the Trash.
    public let trashedURLs: [URL]
    /// Localized messages for items that could not be moved.
    public let failures: [String]

    /// Whether no failure was reported.
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

    /// Creates a deletion service.
    ///
    /// - Parameters:
    ///   - metadataStore: Store that receives the session tombstone after a
    ///     successful deletion.
    ///   - fileManager: File manager used to probe and trash files.
    public init(metadataStore: RecordingLibraryStore, fileManager: FileManager = .default) {
        self.metadataStore = metadataStore
        self.fileManager = fileManager
    }

    /// Moves a recording's session folder and media files to the Trash.
    ///
    /// Only files below one of the group's roots are considered. Nested
    /// candidates are dropped so each top-level file or folder is trashed once.
    /// When at least one item reaches the Trash, the session is tombstoned in the
    /// metadata store and the recording indexes of the group's roots are
    /// removed so the next scan rebuilds them from the surviving folders.
    ///
    /// - Parameter group: Recording group to delete.
    /// - Returns: The trashed URLs, per-item failure messages and whether a
    ///   session was deleted. When no files are found, nothing is touched and the
    ///   report carries a failure message instead.
    public func delete(_ group: LibraryRecordingGroup) async -> RecordingDeletionReport {
        var candidates = Set<URL>()

        for root in group.roots {
            let sessionFolder =
                root
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

        let topLevel =
            candidates
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
                logger.error(
                    "Trash failed for \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
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
            let indexURL =
                root
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
