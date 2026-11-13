import Foundation
import Testing

@testable import CaptureCore

struct RecordingSessionLedgerTests {
    @Test func explicitEnumDTOAndJournalReplayAreIdempotent() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let ledger = try RecordingSessionLedger(
            sessionRoot: paths.sessionRoot,
            indexURL: paths.indexURL,
            sessionID: paths.sessionID
        )
        let initial = RecordingSessionRecord(
            id: paths.sessionID, kind: .audio, layout: .separateTracks,
            startedAt: Date(timeIntervalSince1970: 1_800_000_000), segments: []
        )
        try await ledger.register(initial)

        let chunkDirectory = paths.sessionRoot.appendingPathComponent("segment-000000")
        try FileManager.default.createDirectory(at: chunkDirectory, withIntermediateDirectories: true)
        let caf = chunkDirectory.appendingPathComponent("checkpoint.caf")
        try Data([0x43, 0x41, 0x46]).write(to: caf, options: .withoutOverwriting)
        let commit = CheckpointCommit(
            checkpointID: UUID(), segmentIndex: 0,
            range: SampleRange(startSample: 0, sampleCount: 480),
            trackURLs: [.system: caf], committedAt: Date(timeIntervalSince1970: 1_800_000_001)
        )
        try await ledger.commit(commit)
        try await ledger.commit(commit)

        let journalBeforeOpen = try Data(contentsOf: paths.sessionRoot.appendingPathComponent("journal.ndjson"))
        let reopened = try await RecordingSessionLedger.openExisting(
            sessionID: paths.sessionID, recordingRoot: paths.root, indexURL: paths.indexURL
        )
        let snapshot = try await reopened.snapshot()
        let journalAfterOpen = try Data(contentsOf: paths.sessionRoot.appendingPathComponent("journal.ndjson"))

        #expect(snapshot.id == paths.sessionID)
        #expect(snapshot.kind == .audio)
        #expect(snapshot.layout == .separateTracks)
        #expect(snapshot.segments.count == 1)
        #expect(snapshot.segments.first?.state == .recording)
        #expect(journalAfterOpen == journalBeforeOpen)
    }

    @Test func checkpointPathsOutsideSessionRootAreRejected() async throws {
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
        let outside = paths.root.appendingPathComponent("outside.caf")
        try Data([0x01]).write(to: outside)
        let commit = CheckpointCommit(
            checkpointID: UUID(), segmentIndex: 0,
            range: SampleRange(startSample: 0, sampleCount: 1),
            trackURLs: [.mixed: outside], committedAt: Date()
        )

        await #expect(throws: RecordingSessionLedgerError.self) {
            try await ledger.commit(commit)
        }
    }

    private func makePaths() throws -> (root: URL, sessionRoot: URL, indexURL: URL, sessionID: UUID) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Task09-Ledger-\(UUID().uuidString)", isDirectory: true)
        let sessionID = UUID()
        let sessionRoot = root.appendingPathComponent(".SnapGlassSessions", isDirectory: true)
            .appendingPathComponent(sessionID.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
        return (root, sessionRoot, root.appendingPathComponent("recording-index.json"), sessionID)
    }
}
