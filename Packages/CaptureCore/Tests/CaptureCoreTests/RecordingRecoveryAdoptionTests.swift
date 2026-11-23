import Foundation
import Testing

@testable import CaptureCore

struct RecordingRecoveryAdoptionTests {
    @Test func adoptMakesTheOrphanAnOrdinaryPublishedSession() async throws {
        let root = try RecordingRecoveryFixtures.makeRoot("S3-Adopt-RegisterOnly")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let sessionRoot = try await RecordingRecoveryFixtures.makeRegisteredSession(
            root: root, sessionID: sessionID
        )
        let segmentDirectory = sessionRoot.appendingPathComponent("segment-00000000", isDirectory: true)
        try FileManager.default.createDirectory(at: segmentDirectory, withIntermediateDirectories: true)
        let caf = try RecordingRecoveryFixtures.writeSilentCAF(
            at: segmentDirectory.appendingPathComponent("mixed-0001.caf"), seconds: 2
        )
        let indexURL = RecordingRecoveryFixtures.indexURL(root: root)
        let recording = try #require(await RecordingRecoveryCatalog.scan(recordingRoot: root).first)

        let record = try await RecordingRecoveryAdoption.adopt(
            recording, recordingRoot: root, indexURL: indexURL
        )

        #expect(record.id == sessionID)
        #expect(record.segments.count == 1)
        let segment = try #require(record.segments.first)
        #expect(segment.state == .published)
        #expect(segment.startSample == 0)
        #expect(segment.sampleCount == 96_000)
        #expect(segment.materialURL == caf)
        #expect(segment.files["mixed"] == "segment-00000000/mixed-0001.caf")

        let published = try await RecordingSessionLedger.publishedSessions(
            in: root, indexURL: indexURL
        )
        #expect(published.map(\.id) == [sessionID])

        // The media is referenced, never copied: the original file is untouched.
        #expect(FileManager.default.fileExists(atPath: caf.path))
        let index = try JSONDecoder().decode(
            RecordingIndexRecord.self, from: Data(contentsOf: indexURL)
        )
        #expect(index.entries.first(where: { $0.sessionID == sessionID })?
            .record.segments.first?.materialURL == caf)
    }

    @Test func adoptIsIdempotentAndKeepsOneIndexEntry() async throws {
        let root = try RecordingRecoveryFixtures.makeRoot("S3-Adopt-Idempotent")
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
        let indexURL = RecordingRecoveryFixtures.indexURL(root: root)

        let firstScan = await RecordingRecoveryCatalog.scan(recordingRoot: root)
        let recording = try #require(firstScan.first)
        let first = try await RecordingRecoveryAdoption.adopt(
            recording, recordingRoot: root, indexURL: indexURL
        )
        let journalAfterFirst = try Data(
            contentsOf: sessionRoot.appendingPathComponent("journal.ndjson")
        )

        // A second recovery of the same session must not add a second entry.
        let second = try await RecordingRecoveryAdoption.adopt(
            recording, recordingRoot: root, indexURL: indexURL
        )
        let journalAfterSecond = try Data(
            contentsOf: sessionRoot.appendingPathComponent("journal.ndjson")
        )
        let published = try await RecordingSessionLedger.publishedSessions(
            in: root, indexURL: indexURL
        )

        #expect(first.id == second.id)
        #expect(first.segments == second.segments)
        #expect(published.count == 1)
        #expect(published.first?.segments.count == 1)
        #expect(journalAfterSecond == journalAfterFirst)
    }

    @Test func adoptUsesTheCheckpointSegmentIdentity() async throws {
        let root = try RecordingRecoveryFixtures.makeRoot("S3-Adopt-Checkpoint")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        try await RecordingRecoveryFixtures.makeCheckpointedSession(
            root: root, sessionID: sessionID, seconds: 1
        )
        let indexURL = RecordingRecoveryFixtures.indexURL(root: root)
        let recording = try #require(await RecordingRecoveryCatalog.scan(recordingRoot: root).first)

        let record = try await RecordingRecoveryAdoption.adopt(
            recording, recordingRoot: root, indexURL: indexURL
        )
        let reopened = try await RecordingSessionLedger.openExisting(
            sessionID: sessionID, recordingRoot: root, indexURL: indexURL
        )
        let snapshot = try await reopened.snapshot()

        #expect(record.segments.first?.state == .published)
        #expect(snapshot.segments.first?.state == .published)
        #expect(record.segments.first?.id == snapshot.segments.first?.id)
        // The checkpoint CAF is still on disk; adoption references it in place.
        let caf = sessionRootURL(root: root, sessionID: sessionID)
            .appendingPathComponent("segment-00000000/mixed-0001.caf")
        #expect(FileManager.default.fileExists(atPath: caf.path))
        #expect(record.segments.first?.materialURL == caf)
    }

    @Test func adoptedSegmentDecodesWithoutTheOptionalField() async throws {
        let segment = PublishedSegment(
            id: UUID(), index: 0, files: ["mixed": "segment-00000000/mixed-0001.caf"],
            startSample: 0, sampleCount: 48_000, trackMap: ["mixed": 0],
            missingRanges: [], state: .published
        )
        let encoded = try JSONEncoder().encode(segment)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        // Older records never carried the field; nil is omitted on encode.
        #expect(object["materialURL"] == nil)

        let decoded = try JSONDecoder().decode(PublishedSegment.self, from: encoded)
        #expect(decoded.materialURL == nil)
    }

    private func sessionRootURL(root: URL, sessionID: UUID) -> URL {
        root.appendingPathComponent(".SnapGlassSessions", isDirectory: true)
            .appendingPathComponent(sessionID.uuidString.lowercased(), isDirectory: true)
    }
}
