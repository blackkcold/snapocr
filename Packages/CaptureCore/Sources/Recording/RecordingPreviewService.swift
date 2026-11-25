import Foundation

/// Failures a preview request can report.
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

    /// Creates a preview service over one ledger.
    ///
    /// - Parameters:
    ///   - ledger: The session journal that resolves preview targets.
    ///   - fileManager: File manager used to confirm media is readable.
    ///   - now: Clock used to stamp lease expiry.
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

    /// Issues a read-only lease for a segment or checkpoint preview.
    ///
    /// The lease is capped at 24 hours and recorded in the ledger, which keeps
    /// garbage collection away from the media until it expires or is released.
    ///
    /// - Parameters:
    ///   - target: The segment or checkpoint to preview.
    ///   - duration: Requested lease length in seconds; must be finite and positive.
    /// - Returns: The recorded lease and its media URLs.
    /// - Throws: `RecordingPreviewError.invalidDuration` for a non-positive or
    ///   non-finite duration, `.notPreviewable` when the target has no media,
    ///   `.materialUnavailable` when a media file is missing, and ledger errors
    ///   when the target cannot be resolved.
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

    /// Issues a read-only lease for a published or adopted segment.
    ///
    /// - Parameters:
    ///   - segmentID: Identity of the segment to preview.
    ///   - duration: Requested lease length in seconds; must be finite and positive.
    /// - Returns: The recorded lease and its media URLs.
    /// - Throws: The same errors as `leasePreview(for:duration:)` when the target
    ///   is `PreviewTarget.segment(segmentID)`.
    public func leasePreview(
        for segmentID: UUID,
        duration: TimeInterval = 300
    ) async throws -> PreviewLease {
        try await leasePreview(for: .segment(segmentID), duration: duration)
    }

    /// Releases a lease so its media becomes collectable again.
    ///
    /// - Parameter lease: The lease returned when the preview started.
    public func release(_ lease: PreviewLease) async {
        await ledger.removeLease(lease)
    }

    /// Deletes checkpoint media that published segments no longer need.
    ///
    /// Expired leases are pruned first; files still covered by an unexpired lease
    /// are skipped. A checkpoint is collected only when its segment is published
    /// and its media still matches the journaled hash, together with its sidecar.
    ///
    /// - Parameter now: The time used to decide which leases are still active.
    /// - Returns: Every file and sidecar that was removed.
    /// - Throws: A ledger error when a path cannot be resolved or a file cannot be
    ///   removed and synced.
    public func collectGarbage(now: Date = Date()) async throws -> [URL] {
        try await ledger.collectableCheckpointFiles(now: now)
    }
}
