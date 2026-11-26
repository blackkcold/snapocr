import CaptureCore
import Foundation
import OSLog

/// Resolves published segment files through the official preview/lease path.
///
/// The library's list projection may use a cheap filename heuristic for poster
/// frames, but export and merge must use the journal-backed resolver so a
/// recording is never silently dropped because its output root or conflict
/// suffix is unusual.
struct RecordingMediaLease: Sendable {
    let segmentID: UUID
    let urls: [URL]
    let isAdopted: Bool
    let previewLease: PreviewLease
}

actor RecordingMediaResolver {
    private let fileManager: FileManager
    private let logger = Logger(subsystem: "com.snapglass.app", category: "LibraryMediaResolver")

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func lease(
        sessionID: UUID,
        root: URL,
        indexURL: URL,
        segmentIDs: [UUID],
        duration: TimeInterval = 300
    ) async throws -> (service: RecordingPreviewService, leases: [RecordingMediaLease]) {
        let ledger = try await RecordingSessionLedger.openExisting(
            sessionID: sessionID,
            recordingRoot: root,
            indexURL: indexURL
        )
        let record = try await ledger.snapshot()
        let preview = await ledger.makePreviewService()
        let wanted = Set(segmentIDs)
        var leases: [RecordingMediaLease] = []

        for segment in record.segments where wanted.contains(segment.id) {
            let lease = try await preview.leasePreview(for: segment.id, duration: duration)
            leases.append(
                RecordingMediaLease(
                    segmentID: segment.id,
                    urls: lease.mediaURLs,
                    isAdopted: segment.materialURL != nil,
                    previewLease: lease
                )
            )
        }
        guard !leases.isEmpty else {
            throw RecordingMediaResolverError.noMedia
        }
        return (preview, leases)
    }

    func release(
        _ leases: [RecordingMediaLease],
        using service: RecordingPreviewService
    ) async {
        for lease in leases {
            await service.release(lease.previewLease)
        }
    }
}

enum RecordingMediaResolverError: Error, LocalizedError {
    case noMedia

    var errorDescription: String? {
        LibraryLocalization.string("No media was found for this recording.")
    }
}
