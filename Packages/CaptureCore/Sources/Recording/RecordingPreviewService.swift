import Foundation

public enum RecordingPreviewError: Error, Equatable, Sendable {
    case notPreviewable
    case invalidDuration
    case materialUnavailable
}

/// Issues read-only leases for closed CAF checkpoints and published segments.
public actor RecordingPreviewService {
    private let ledger: RecordingSessionLedger
    private let fileManager: RecordingSendableFileManager
    private let now: @Sendable () -> Date

    public init(
        ledger: RecordingSessionLedger,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.ledger = ledger
        self.fileManager = RecordingSendableFileManager(fileManager)
        self.now = now
    }

    init(
        ledger: RecordingSessionLedger,
        fileManager: RecordingSendableFileManager,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.ledger = ledger
        self.fileManager = fileManager
        self.now = now
    }

    public func leasePreview(
        for target: PreviewTarget,
        duration: TimeInterval = 300
    ) async throws -> PreviewLease {
        guard duration.isFinite, duration > 0 else { throw RecordingPreviewError.invalidDuration }
        let (segmentID, urls) = try await ledger.previewURLs(for: target)
        guard !urls.isEmpty else { throw RecordingPreviewError.notPreviewable }
        for url in urls {
            guard RecordingLedgerFileSystem.isRegularFile(url) else {
                throw RecordingPreviewError.materialUnavailable
            }
        }
        let expiryDelta = min(duration, 24 * 60 * 60)
        let lease = PreviewLease(
            id: UUID(),
            segmentID: segmentID,
            mediaURLs: urls,
            expiresAt: now().addingTimeInterval(expiryDelta)
        )
        await ledger.addLease(lease)
        return lease
    }

    public func leasePreview(
        for segmentID: UUID,
        duration: TimeInterval = 300
    ) async throws -> PreviewLease {
        try await leasePreview(for: .segment(segmentID), duration: duration)
    }

    public func release(_ lease: PreviewLease) async {
        await ledger.removeLease(lease)
    }

    public func collectGarbage(now: Date = Date()) async throws -> [URL] {
        try await ledger.collectableCheckpointFiles(now: now)
    }
}
