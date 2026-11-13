import Foundation
import Testing

@testable import CaptureCore

struct ScreenSegmentSealServiceTests {
    @Test func zeroVideoCheckpointsFailWithoutPublishingAnEmptyMP4() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenSegmentSealServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let context = RecordingSealContext(
            sessionID: UUID(),
            kind: .screen,
            layout: .separateTracks,
            sampleRate: 48_000,
            outputStem: "screen-recording",
            destinationDirectory: directory
        )
        let service = ScreenSegmentSealService()

        await #expect(throws: ScreenSegmentSealError.self) {
            try await service.seal([], audio: nil, segmentID: UUID(), context: context)
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files.allSatisfy { !$0.hasSuffix(".mp4") })
    }
}
