import Foundation
import Testing

@testable import CaptureCore

struct RecordingPreviewServiceTests {
    @Test func checkpointLeaseBlocksCollectionUntilReleased() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let ledger = try RecordingSessionLedger(
            sessionRoot: paths.sessionRoot,
            indexURL: paths.indexURL,
            sessionID: paths.sessionID
        )
        try await ledger.register(RecordingSessionRecord(
            id: paths.sessionID, kind: .audio, layout: .mixed, startedAt: Date(), segments: []
        ))

        let segmentRoot = paths.sessionRoot.appendingPathComponent("segment-000000")
        try FileManager.default.createDirectory(at: segmentRoot, withIntermediateDirectories: true)
        let caf = segmentRoot.appendingPathComponent("checkpoint.caf")
        try Data([0x43, 0x41, 0x46]).write(to: caf, options: .withoutOverwriting)
        let checkpointID = UUID()
        let commit = CheckpointCommit(
            checkpointID: checkpointID, segmentIndex: 0,
            range: SampleRange(startSample: 0, sampleCount: 2),
            trackURLs: [.mixed: caf], committedAt: Date()
        )
        try await ledger.commit(commit)
        let coverage = makeCoverage()
        try await ledger.recordClosedSegment(RecordingSegmentCheckpointBundle(
            checkpoints: SegmentCheckpointSet(segmentIndex: 0, checkpoints: [commit]),
            coverage: coverage
        ))

        let segmentID = await ledger.segmentID(for: 0)
        let outputRoot = paths.root.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        let staging = outputRoot.appendingPathComponent(".pending.m4a")
        let final = outputRoot.appendingPathComponent("segment.m4a")
        let bytes = Data([0x4d, 0x34, 0x41])
        try bytes.write(to: staging, options: .withoutOverwriting)
        let digest = try RecordingLedgerFileSystem.sha256(of: staging)
        let intent = RecordingPublishIntent(
            segmentID: segmentID, segmentIndex: 0,
            reservedFinalURL: final, stagingURL: staging, isDirectory: false,
            contentHashes: [final.lastPathComponent: digest],
            effectiveRange: RecordingSampleRange(startSample: 0, sampleCount: 2),
            coverage: coverage
        )
        try await ledger.recordPublishIntent(intent)
        try FileManager.default.moveItem(at: staging, to: final)
        try await ledger.markPublished(PublishedSegment(
            id: segmentID, index: 0,
            files: ["mixed": final.lastPathComponent],
            startSample: 0, sampleCount: 2,
            trackMap: ["mixed": 0], missingRanges: [], state: .published
        ))

        let preview = await ledger.makePreviewService()
        let lease = try await preview.leasePreview(for: .checkpoint(checkpointID))
        let whileLeased = try await preview.collectGarbage()
        await preview.release(lease)
        let afterRelease = try await preview.collectGarbage()

        #expect(lease.mediaURLs == [caf])
        #expect(whileLeased.isEmpty)
        #expect(afterRelease.contains(caf))
        #expect(!FileManager.default.fileExists(atPath: caf.path))
    }

    @Test func openCheckpointCannotBeLeasedForPreview() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let ledger = try RecordingSessionLedger(
            sessionRoot: paths.sessionRoot,
            indexURL: paths.indexURL,
            sessionID: paths.sessionID
        )
        try await ledger.register(RecordingSessionRecord(
            id: paths.sessionID, kind: .audio, layout: .mixed, startedAt: Date(), segments: []
        ))
        let segmentRoot = paths.sessionRoot.appendingPathComponent("segment-000000")
        try FileManager.default.createDirectory(at: segmentRoot, withIntermediateDirectories: true)
        let caf = segmentRoot.appendingPathComponent("checkpoint.caf")
        try Data([0x43]).write(to: caf)
        let checkpointID = UUID()
        try await ledger.commit(CheckpointCommit(
            checkpointID: checkpointID, segmentIndex: 0,
            range: SampleRange(startSample: 0, sampleCount: 1),
            trackURLs: [.mixed: caf], committedAt: Date()
        ))
        let preview = await ledger.makePreviewService()

        await #expect(throws: RecordingPreviewError.self) {
            _ = try await preview.leasePreview(for: .checkpoint(checkpointID))
        }
    }

    private func makeCoverage() -> RecordingSegmentCoverage {
        RecordingSegmentCoverage(
            segmentIndex: 0,
            segmentStartSample: 0,
            segmentEndSample: 2,
            tracks: [RecordingTrackCoverage(
                role: "mixed", sampleRate: 48_000, channelCount: 1, wasActive: true,
                firstSample: 0, lastSample: 2, missingRanges: [], writerSynthesizedSilenceFrames: 0
            )]
        )
    }

    private func makePaths() throws -> (root: URL, sessionRoot: URL, indexURL: URL, sessionID: UUID) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Task09-Preview-\(UUID().uuidString)", isDirectory: true)
        let sessionID = UUID()
        let sessionRoot = root.appendingPathComponent(".SnapGlassSessions", isDirectory: true)
            .appendingPathComponent(sessionID.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
        return (root, sessionRoot, root.appendingPathComponent("recording-index.json"), sessionID)
    }
}
