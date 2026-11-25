import AVFoundation
import Foundation
import Testing
@testable import CaptureCore

@Suite("Recording merge export")
struct RecordingMergeExportTests {
    @Test("Two real recovered segments export as one playable file")
    func mergesTwoRecoveredSegments() async throws {
        let root = TestTemporaryDirectory.root("MergeExport")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outputDirectory = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let firstURL = try RecordingRecoveryFixtures.writeSilentCAF(
            at: root.appendingPathComponent("first.caf"),
            seconds: 1
        )
        let secondURL = try RecordingRecoveryFixtures.writeSilentCAF(
            at: root.appendingPathComponent("second.caf"),
            seconds: 1
        )

        let firstID = UUID()
        let secondID = UUID()
        let sessionID = UUID()
        let session = RecordingSessionRecord(
            id: sessionID,
            kind: .audio,
            layout: .mixed,
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            segments: [
                PublishedSegment(
                    id: firstID,
                    index: 0,
                    files: ["mixed": firstURL.lastPathComponent],
                    startSample: 0,
                    sampleCount: 48_000,
                    trackMap: ["mixed": 0],
                    missingRanges: [],
                    state: .published,
                    videoURL: nil,
                    videoTrackIndex: nil,
                    materialURL: firstURL
                ),
                PublishedSegment(
                    id: secondID,
                    index: 1,
                    files: ["mixed": secondURL.lastPathComponent],
                    startSample: 0,
                    sampleCount: 48_000,
                    trackMap: ["mixed": 0],
                    missingRanges: [],
                    state: .published,
                    videoURL: nil,
                    videoTrackIndex: nil,
                    materialURL: secondURL
                ),
            ]
        )

        let selection = ExportSelection(
            segmentIDs: [firstID, secondID],
            includeVideo: false,
            destination: ExportDestination(directory: outputDirectory, stem: "merged")
        )
        let plan = try RecordingExportPlanner.plan(
            session: session,
            selection: selection,
            audioSourcesBySegment: [
                firstID: .recoveredMedia([firstURL]),
                secondID: .recoveredMedia([secondURL]),
            ]
        )
        let result = try await RecordingCompositionExporter().export(plan) { _ in }

        #expect(FileManager.default.fileExists(atPath: result.outputURL.path))
        let asset = AVURLAsset(url: result.outputURL)
        let seconds = CMTimeGetSeconds(asset.duration)
        #expect(seconds > 1.5)
    }
}
