import CryptoKit
import Foundation
import Testing

@testable import CaptureCore

struct ScreenCheckpointLedgerTests {
    @Test func screenCheckpointCodableReadbackSurvivesLedgerRecoveryWithoutAudio() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenCheckpointLedgerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = UUID()
        let sessionRoot = root.appendingPathComponent(".SnapGlassSessions", isDirectory: true)
            .appendingPathComponent(sessionID.uuidString.lowercased(), isDirectory: true)
        let indexURL = root.appendingPathComponent("recording-index.json")
        let ledger = try RecordingSessionLedger(
            sessionRoot: sessionRoot,
            indexURL: indexURL,
            sessionID: sessionID
        )
        try await ledger.register(RecordingSessionRecord(
            id: sessionID,
            kind: .screen,
            layout: .separateTracks,
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            segments: []
        ))

        let media = Data([0x53, 0x43, 0x4b])
        let videoURL = sessionRoot.appendingPathComponent("chunk-000000.mp4")
        try media.write(to: videoURL)
        let hash = SHA256.hash(data: media).map { String(format: "%02x", $0) }.joined()
        let record = ScreenCheckpointRecord(
            segmentIndex: 0,
            chunkIndex: 0,
            videoURL: videoURL,
            videoRange: RecordingSampleRange(startSample: 0, sampleCount: 480),
            audioCheckpoint: nil,
            coverage: RecordingSegmentCoverage(
                segmentIndex: 0,
                segmentStartSample: 0,
                segmentEndSample: 480,
                tracks: []
            ),
            contentHashes: ["chunk-000000.mp4": hash]
        )

        try await ledger.commitScreenCheckpoint(record)
        let decoded = try JSONDecoder().decode(ScreenCheckpointRecord.self, from: JSONEncoder().encode(record))
        let reopened = try await RecordingSessionLedger.openExisting(
            sessionID: sessionID,
            recordingRoot: root,
            indexURL: indexURL
        )
        let recovered = try await reopened.screenCheckpoints(sessionID: sessionID)

        #expect(decoded == record)
        #expect(recovered == [record])
        #expect(recovered.first?.audioCheckpoint == nil)
    }
}
