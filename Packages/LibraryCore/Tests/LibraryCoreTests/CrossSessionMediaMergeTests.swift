import AVFoundation
import CaptureCore
import Foundation
import Testing

@testable import LibraryCore

@Suite("Cross-session media merge")
struct CrossSessionMediaMergeTests {
    @Test("Two real sessions merge into one playable file")
    func mergesTwoSessions() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrossSessionMerge-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let output = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let firstCAF = try writeSilentCAF(at: root.appendingPathComponent("first.caf"))
        let secondCAF = try writeSilentCAF(at: root.appendingPathComponent("second.caf"))

        let firstPlan = try makePlan(caf: firstCAF, output: output, stem: "first")
        let secondPlan = try makePlan(caf: secondCAF, output: output, stem: "second")
        let merged = try RecordingPlanMerger.merge(
            [firstPlan, secondPlan],
            sessionID: firstPlan.sessionID,
            destination: ExportDestination(directory: output, stem: "merged"),
            outputSpec: firstPlan.outputSpec
        )

        let result = try await RecordingCompositionExporter().export(merged) { _ in }
        #expect(FileManager.default.fileExists(atPath: result.outputURL.path))

        let asset = AVURLAsset(url: result.outputURL)
        let seconds = CMTimeGetSeconds(asset.duration)
        #expect(seconds > 1.5)
    }

    private func makePlan(
        caf: URL,
        output: URL,
        stem: String
    ) throws -> ExportPlan {
        let segmentID = UUID()
        let sessionID = UUID()
        let segment = PublishedSegment(
            id: segmentID,
            index: 0,
            files: ["mixed": caf.lastPathComponent],
            startSample: 0,
            sampleCount: 48_000,
            trackMap: ["mixed": 0],
            missingRanges: [],
            state: .published,
            videoURL: nil,
            videoTrackIndex: nil,
            materialURL: caf
        )
        let session = RecordingSessionRecord(
            id: sessionID,
            kind: .audio,
            layout: .mixed,
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            segments: [segment]
        )
        let selection = ExportSelection(
            segmentIDs: [segmentID],
            includeVideo: false,
            destination: ExportDestination(directory: output, stem: stem)
        )
        return try RecordingExportPlanner.plan(
            session: session,
            selection: selection,
            audioSourcesBySegment: [segmentID: .recoveredMedia([caf])]
        )
    }

    private func writeSilentCAF(at url: URL) throws -> URL {
        guard
            let format = AVAudioFormat(
                standardFormatWithSampleRate: 48_000,
                channels: 2
            )
        else {
            throw FixtureError.format
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: 48_000
            )
        else {
            throw FixtureError.buffer
        }
        buffer.frameLength = 48_000
        try file.write(from: buffer)
        return url
    }

    private enum FixtureError: Error {
        case format
        case buffer
    }
}
