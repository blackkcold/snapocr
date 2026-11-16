import Foundation
import Testing

@testable import CaptureCore

struct ScreenSegmentCoordinatorTests {
    @Test func audioAheadOfVideoIsBoundedToTwoSeconds() async throws {
        let root = TestTemporaryDirectory.root("ScreenSegmentCoordinatorTests")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = UUID()
        let sessionRoot = root.appendingPathComponent(".SnapGlassSessions", isDirectory: true)
            .appendingPathComponent(sessionID.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
        let ledger = try RecordingSessionLedger(
            sessionRoot: sessionRoot,
            indexURL: root.appendingPathComponent("recording-index.json"),
            sessionID: sessionID
        )
        let coordinator = ScreenSegmentCoordinator(
            planner: try VideoSegmentPlanner(frameRate: 30, hostTicksPerSecond: 48_000),
            videoWriterFactory: { _ in throw ScreenSegmentCoordinatorError.noVideoFrames },
            audioSinkFactory: { _ in throw ScreenSegmentCoordinatorError.noVideoFrames },
            ledger: ledger,
            seal: ScreenSegmentSealService()
        )

        try await coordinator.append(audioBlock(frameCount: 96_000, startSample: 0))
        await #expect(throws: ScreenSegmentCoordinatorError.self) {
            try await coordinator.append(audioBlock(frameCount: 1, startSample: 96_000))
        }
    }

    @Test func audioBlocksWithInvalidSampleGridAreRejected() async throws {
        let root = TestTemporaryDirectory.root("ScreenSegmentCoordinatorInvalidAudio")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = UUID()
        let ledger = try RecordingSessionLedger(
            sessionRoot: root.appendingPathComponent("session", isDirectory: true),
            indexURL: root.appendingPathComponent("recording-index.json"),
            sessionID: sessionID
        )
        let coordinator = ScreenSegmentCoordinator(
            planner: try VideoSegmentPlanner(frameRate: 30, hostTicksPerSecond: 48_000),
            videoWriterFactory: { _ in throw ScreenSegmentCoordinatorError.noVideoFrames },
            audioSinkFactory: { _ in throw ScreenSegmentCoordinatorError.noVideoFrames },
            ledger: ledger,
            seal: ScreenSegmentSealService()
        )
        let invalid = AudioPCMBlock(
            role: .system,
            range: SampleRange(startSample: 0, sampleCount: 2),
            sampleRate: 44_100,
            channelCount: 1,
            frameCount: 2,
            hostTime: 0,
            channels: [[0, 0]],
            isSilence: true
        )

        await #expect(throws: ScreenSegmentCoordinatorError.self) {
            try await coordinator.append(invalid)
        }
    }

    private func audioBlock(frameCount: Int, startSample: Int64) -> AudioPCMBlock {
        AudioPCMBlock(
            role: .system,
            range: SampleRange(startSample: startSample, sampleCount: Int64(frameCount)),
            sampleRate: 48_000,
            channelCount: 1,
            frameCount: frameCount,
            hostTime: 48_000,
            channels: [[Float](repeating: 0.1, count: frameCount)],
            isSilence: false
        )
    }
}
