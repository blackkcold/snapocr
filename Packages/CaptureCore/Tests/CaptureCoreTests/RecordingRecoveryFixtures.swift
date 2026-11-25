import AVFoundation
import Foundation

@testable import CaptureCore

/// Builders shared by the recovery catalog and adoption tests.
enum RecordingRecoveryFixtures {
    /// Creates one isolated recording root with a `.SnapGlassSessions` folder.
    static func makeRoot(_ name: String) throws -> URL {
        let root = TestTemporaryDirectory.root(name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".SnapGlassSessions", isDirectory: true),
            withIntermediateDirectories: true
        )
        return root
    }

    /// Index cache location for a test root.
    static func indexURL(root: URL) -> URL {
        root.appendingPathComponent(".SnapGlassSessions/recording-index.json")
    }

    /// Creates the session directory for `sessionID` under `root`.
    static func makeSessionDirectory(root: URL, sessionID: UUID) throws -> URL {
        let directory = root
            .appendingPathComponent(".SnapGlassSessions", isDirectory: true)
            .appendingPathComponent(sessionID.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Writes a real, decodable 48 kHz / 2-channel CAF of `seconds` length.
    @discardableResult
    static func writeSilentCAF(at url: URL, seconds: Double = 1) throws -> URL {
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 2
        ) else {
            throw FixtureError.audioFormatUnavailable
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount((seconds * 48_000).rounded())
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw FixtureError.audioBufferUnavailable
        }
        buffer.frameLength = frames
        try file.write(from: buffer)
        return url
    }

    /// Fixture construction failures.
    enum FixtureError: Error {
        case audioFormatUnavailable
        case audioBufferUnavailable
    }

    /// Registers a session through the real ledger and returns its session root.
    @discardableResult
    static func makeRegisteredSession(
        root: URL,
        sessionID: UUID,
        kind: RecordingKind = .audio,
        layout: AudioOutputLayout = .mixed
    ) async throws -> URL {
        let sessionRoot = try makeSessionDirectory(root: root, sessionID: sessionID)
        let ledger = try RecordingSessionLedger(
            sessionRoot: sessionRoot,
            indexURL: indexURL(root: root),
            sessionID: sessionID
        )
        try await ledger.register(RecordingSessionRecord(
            id: sessionID,
            kind: kind,
            layout: layout,
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            segments: []
        ))
        return sessionRoot
    }

    /// Registers a session, writes a CAF, and journals one valid checkpoint for segment 0.
    static func makeCheckpointedSession(
        root: URL,
        sessionID: UUID,
        seconds: Double = 1
    ) async throws {
        let sessionRoot = try await makeRegisteredSession(root: root, sessionID: sessionID)
        let ledger = try RecordingSessionLedger(
            sessionRoot: sessionRoot,
            indexURL: indexURL(root: root),
            sessionID: sessionID
        )
        try await ledger.commit(
            checkpoint(in: sessionRoot, seconds: seconds)
        )
    }

    /// Writes a CAF inside `segment-*/` and returns the commit that journals it.
    static func checkpoint(in sessionRoot: URL, seconds: Double = 1) throws -> CheckpointCommit {
        let segmentDirectory = sessionRoot.appendingPathComponent("segment-00000000", isDirectory: true)
        try FileManager.default.createDirectory(at: segmentDirectory, withIntermediateDirectories: true)
        let caf = segmentDirectory.appendingPathComponent("mixed-0001.caf")
        try writeSilentCAF(at: caf, seconds: seconds)
        return CheckpointCommit(
            checkpointID: UUID(),
            segmentIndex: 0,
            range: SampleRange(startSample: 0, sampleCount: Int64((seconds * 48_000).rounded())),
            trackURLs: [.mixed: caf],
            committedAt: Date()
        )
    }

    /// Corrupts a session journal so replay must reject it.
    static func corruptJournal(sessionRoot: URL) throws {
        try Data("{\"core\":{\"payload\":".utf8).write(
            to: sessionRoot.appendingPathComponent("journal.ndjson")
        )
    }
}
