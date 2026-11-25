import AVFoundation
import CaptureCore
import Foundation
import Testing

/// Exercises the App-side recovery service against a real isolated recording root.
struct RecordingRecoveryServiceTests {
    @Test func scanFindsInterruptedSessionsAndHidesZeroByteMedia() async throws {
        let root = try makeRoot("S3-Service-Scan")
        defer { try? FileManager.default.removeItem(at: root) }
        let audioID = UUID()
        try await makeOrphanSession(root: root, sessionID: audioID, seconds: 1.5)
        let screenID = UUID()
        try await makeZeroByteVideoSession(root: root, sessionID: screenID)

        let service = RecordingRecoveryService()
        let found = await service.scan(roots: [RecordingExportRoot(kind: .audio, root: root)])

        #expect(found.map(\.id) == [audioID])
        #expect(found.first?.kind == .audio)
        #expect(abs((found.first?.duration ?? 0) - 1.5) < 0.01)
    }

    @Test func recoverAdoptsInPlaceAndIsIdempotent() async throws {
        let root = try makeRoot("S3-Service-Recover")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let caf = try await makeOrphanSession(root: root, sessionID: sessionID, seconds: 2)
        let exportRoot = RecordingExportRoot(kind: .audio, root: root)
        let service = RecordingRecoveryService()
        let recording = try #require(await service.scan(roots: [exportRoot]).first)

        let first = try await service.recover(recording)
        let second = try await service.recover(recording)
        let published = try await RecordingSessionLedger.publishedSessions(
            in: root, indexURL: exportRoot.indexURL
        )
        let afterRecovery = await service.scan(roots: [exportRoot])

        #expect(first.id == sessionID)
        #expect(first.segments.count == 1)
        #expect(first.segments.first?.state == .published)
        #expect(second.segments == first.segments)
        #expect(published.count == 1)
        #expect(afterRecovery.isEmpty)
        // The original media is referenced, never copied.
        #expect(FileManager.default.fileExists(atPath: caf.path))
        #expect(first.segments.first?.materialURL == caf)
    }

    @Test func discardMovesTheSessionFolderToTheTrash() async throws {
        let root = try makeRoot("S3-Service-Discard")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let caf = try await makeOrphanSession(root: root, sessionID: sessionID, seconds: 1)
        let exportRoot = RecordingExportRoot(kind: .audio, root: root)
        let service = RecordingRecoveryService()
        let recording = try #require(await service.scan(roots: [exportRoot]).first)
        let sessionDirectory =
            root
            .appendingPathComponent(".SnapGlassSessions", isDirectory: true)
            .appendingPathComponent(sessionID.uuidString.lowercased(), isDirectory: true)

        try await service.discard(recording)

        #expect(!FileManager.default.fileExists(atPath: sessionDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: caf.path))
        let trashed = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash", isDirectory: true)
            .appendingPathComponent(sessionID.uuidString.lowercased(), isDirectory: true)
        // trashItem put the folder in the Trash, so the action stays reversible.
        if FileManager.default.fileExists(atPath: trashed.path) {
            try? FileManager.default.removeItem(at: trashed)
        }
    }

    @Test func recoverKeepsTheFolderWhenTheSessionDisappeared() async throws {
        let root = try makeRoot("S3-Service-Missing")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        _ = try await makeOrphanSession(root: root, sessionID: sessionID, seconds: 1)
        let exportRoot = RecordingExportRoot(kind: .audio, root: root)
        let service = RecordingRecoveryService()
        let recording = try #require(await service.scan(roots: [exportRoot]).first)
        let otherRoot = try makeRoot("S3-Service-Missing-Other")
        defer { try? FileManager.default.removeItem(at: otherRoot) }

        // The service falls back to the root implied by the media path, so a
        // recover after the configured list changed must still work.
        let recovered = try await RecordingRecoveryService().recover(recording)
        #expect(recovered.id == sessionID)

        let fresh = try await RecordingRecoveryService().recover(recording)
        #expect(fresh.segments == recovered.segments)
    }

    @Test func unknownSessionReportsUnavailableInsteadOfWriting() async throws {
        let root = try makeRoot("S3-Service-Unavailable")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RecordingRecoveryService()
        let missing = RecoverableRecording(
            id: UUID(),
            kind: .audio,
            condition: .unregistered,
            createdAt: Date(),
            duration: 1,
            materials: [root.appendingPathComponent("gone/mixed-0001.caf")],
            discardedByteCount: 0
        )

        await #expect(throws: RecordingRecoveryService.ServiceError.sessionUnavailable) {
            try await service.recover(missing)
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appendingPathComponent(".SnapGlassSessions").path
            ))
    }

    @Test func scanOfAnUnreadableRootReturnsNothing() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapglass-missing-\(UUID().uuidString)", isDirectory: true)
        let service = RecordingRecoveryService()
        let found = await service.scan(roots: [
            RecordingExportRoot(kind: .audio, root: missing)
        ])
        #expect(found.isEmpty)
    }

    // MARK: Fixtures

    private func makeRoot(_ name: String) throws -> URL {
        let base =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let root =
            base
            .appendingPathComponent("SnapGlassTests", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Registers a register-only session with a real CAF, like today's orphans.
    @discardableResult
    private func makeOrphanSession(
        root: URL,
        sessionID: UUID,
        seconds: Double
    ) async throws -> URL {
        let sessionRoot =
            root
            .appendingPathComponent(".SnapGlassSessions", isDirectory: true)
            .appendingPathComponent(sessionID.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
        let indexURL =
            root
            .appendingPathComponent(".SnapGlassSessions", isDirectory: true)
            .appendingPathComponent("recording-index.json")
        let ledger = try RecordingSessionLedger(
            sessionRoot: sessionRoot, indexURL: indexURL, sessionID: sessionID
        )
        try await ledger.register(
            RecordingSessionRecord(
                id: sessionID, kind: .audio, layout: .mixed,
                startedAt: Date(timeIntervalSince1970: 1_800_000_000), segments: []
            ))
        let segmentDirectory = sessionRoot.appendingPathComponent("segment-00000000", isDirectory: true)
        try FileManager.default.createDirectory(at: segmentDirectory, withIntermediateDirectories: true)
        let caf = segmentDirectory.appendingPathComponent("mixed-0001.caf")
        try writeSilentCAF(at: caf, seconds: seconds)
        return caf
    }

    private func makeZeroByteVideoSession(root: URL, sessionID: UUID) async throws {
        let sessionRoot =
            root
            .appendingPathComponent(".SnapGlassSessions", isDirectory: true)
            .appendingPathComponent(sessionID.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
        let indexURL =
            root
            .appendingPathComponent(".SnapGlassSessions", isDirectory: true)
            .appendingPathComponent("recording-index.json")
        let ledger = try RecordingSessionLedger(
            sessionRoot: sessionRoot, indexURL: indexURL, sessionID: sessionID
        )
        try await ledger.register(
            RecordingSessionRecord(
                id: sessionID, kind: .screen, layout: .separateTracks,
                startedAt: Date(timeIntervalSince1970: 1_800_000_000), segments: []
            ))
        let segmentDirectory = sessionRoot.appendingPathComponent("segment-00000000", isDirectory: true)
        try FileManager.default.createDirectory(at: segmentDirectory, withIntermediateDirectories: true)
        try Data().write(to: segmentDirectory.appendingPathComponent("chunk-00000000.mp4"))
    }

    private func writeSilentCAF(at url: URL, seconds: Double) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount((seconds * 48_000).rounded())
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        try file.write(from: buffer)
    }
}
