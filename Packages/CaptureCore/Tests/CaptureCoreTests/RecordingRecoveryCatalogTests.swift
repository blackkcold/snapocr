import Foundation
import Testing

@testable import CaptureCore

struct RecordingRecoveryCatalogTests {
    @Test func registerOnlySessionWithCAFIsDiscovered() async throws {
        let root = try RecordingRecoveryFixtures.makeRoot("S3-Catalog-RegisterOnly")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let sessionRoot = try await RecordingRecoveryFixtures.makeRegisteredSession(
            root: root, sessionID: sessionID
        )
        let segmentDirectory = sessionRoot.appendingPathComponent("segment-00000000", isDirectory: true)
        try FileManager.default.createDirectory(at: segmentDirectory, withIntermediateDirectories: true)
        let caf = segmentDirectory.appendingPathComponent("mixed-0001.caf")
        try RecordingRecoveryFixtures.writeSilentCAF(at: caf, seconds: 2)

        let recordings = await RecordingRecoveryCatalog.scan(recordingRoot: root)

        #expect(recordings.count == 1)
        let recording = try #require(recordings.first)
        #expect(recording.id == sessionID)
        #expect(recording.kind == .audio)
        #expect(recording.condition == .unregistered)
        #expect(recording.materials == [caf])
        #expect(abs(recording.duration - 2) < 0.01)
        #expect(recording.discardedByteCount == 0)
    }

    @Test func sessionWithCheckpointButNoPublishIsInterrupted() async throws {
        let root = try RecordingRecoveryFixtures.makeRoot("S3-Catalog-Checkpoint")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        try await RecordingRecoveryFixtures.makeCheckpointedSession(
            root: root, sessionID: sessionID, seconds: 1.5
        )

        let recordings = await RecordingRecoveryCatalog.scan(recordingRoot: root)

        let recording = try #require(recordings.first)
        #expect(recording.id == sessionID)
        #expect(recording.condition == .interrupted)
        #expect(abs(recording.duration - 1.5) < 0.01)
        #expect(recording.materials.count == 1)
    }

    @Test func zeroByteVideoIsNotRecoverable() async throws {
        let root = try RecordingRecoveryFixtures.makeRoot("S3-Catalog-ZeroByte")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let sessionRoot = try await RecordingRecoveryFixtures.makeRegisteredSession(
            root: root, sessionID: sessionID, kind: .screen, layout: .separateTracks
        )
        let segmentDirectory = sessionRoot.appendingPathComponent("segment-00000000", isDirectory: true)
        try FileManager.default.createDirectory(at: segmentDirectory, withIntermediateDirectories: true)
        try Data().write(to: segmentDirectory.appendingPathComponent("chunk-00000000.mp4"))

        let recordings = await RecordingRecoveryCatalog.scan(recordingRoot: root)

        #expect(recordings.isEmpty)
    }

    @Test func corruptJournalIsSkippedWithoutHidingOtherSessions() async throws {
        let root = try RecordingRecoveryFixtures.makeRoot("S3-Catalog-Corrupt")
        defer { try? FileManager.default.removeItem(at: root) }
        let healthyID = UUID()
        let sessionRoot = try await RecordingRecoveryFixtures.makeRegisteredSession(
            root: root, sessionID: healthyID
        )
        let segmentDirectory = sessionRoot.appendingPathComponent("segment-00000000", isDirectory: true)
        try FileManager.default.createDirectory(at: segmentDirectory, withIntermediateDirectories: true)
        try RecordingRecoveryFixtures.writeSilentCAF(
            at: segmentDirectory.appendingPathComponent("mixed-0001.caf"), seconds: 1
        )

        let corruptID = UUID()
        let corruptRoot = try await RecordingRecoveryFixtures.makeRegisteredSession(
            root: root, sessionID: corruptID
        )
        try RecordingRecoveryFixtures.corruptJournal(sessionRoot: corruptRoot)

        let recordings = await RecordingRecoveryCatalog.scan(recordingRoot: root)

        #expect(recordings.count == 1)
        #expect(recordings.first?.id == healthyID)
    }

    @Test func scanDoesNotModifyTheSessionDirectory() async throws {
        let root = try RecordingRecoveryFixtures.makeRoot("S3-Catalog-ReadOnly")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let sessionRoot = try await RecordingRecoveryFixtures.makeRegisteredSession(
            root: root, sessionID: sessionID
        )
        let segmentDirectory = sessionRoot.appendingPathComponent("segment-00000000", isDirectory: true)
        try FileManager.default.createDirectory(at: segmentDirectory, withIntermediateDirectories: true)
        let caf = try RecordingRecoveryFixtures.writeSilentCAF(
            at: segmentDirectory.appendingPathComponent("mixed-0001.caf"), seconds: 1
        )
        let journalURL = sessionRoot.appendingPathComponent("journal.ndjson")
        let journalBefore = try Data(contentsOf: journalURL)

        _ = await RecordingRecoveryCatalog.scan(recordingRoot: root)

        #expect(try Data(contentsOf: journalURL) == journalBefore)
        #expect(FileManager.default.fileExists(atPath: caf.path))
    }

    @Test func publishedSessionIsNotOfferedAgain() async throws {
        let root = try RecordingRecoveryFixtures.makeRoot("S3-Catalog-Published")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let sessionRoot = try await RecordingRecoveryFixtures.makeRegisteredSession(
            root: root, sessionID: sessionID
        )
        let segmentDirectory = sessionRoot.appendingPathComponent("segment-00000000", isDirectory: true)
        try FileManager.default.createDirectory(at: segmentDirectory, withIntermediateDirectories: true)
        try RecordingRecoveryFixtures.writeSilentCAF(
            at: segmentDirectory.appendingPathComponent("mixed-0001.caf"), seconds: 1
        )
        let initial = await RecordingRecoveryCatalog.scan(recordingRoot: root)
        let recording = try #require(initial.first)
        _ = try await RecordingRecoveryAdoption.adopt(
            recording,
            recordingRoot: root,
            indexURL: RecordingRecoveryFixtures.indexURL(root: root)
        )

        let afterAdoption = await RecordingRecoveryCatalog.scan(recordingRoot: root)

        #expect(afterAdoption.isEmpty)
    }

    @Test func missingRootReturnsEmptyList() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapglass-missing-\(UUID().uuidString)", isDirectory: true)
        let recordings = await RecordingRecoveryCatalog.scan(recordingRoot: missing)
        #expect(recordings.isEmpty)
    }
}
