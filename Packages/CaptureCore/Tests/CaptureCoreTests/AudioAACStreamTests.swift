import AVFoundation
import Foundation
import Testing

@testable import CaptureCore

struct AudioAACStreamTests {
    @Test func aacStreamRejectsInvalidFormat() throws {
        let (directory, writer) = try makeWriter()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: AudioAACStreamSinkError.self) {
            try AudioAACStreamSink(
                writer: writer,
                role: .system,
                sampleRate: 0,
                channelCount: 1,
                bitRate: 96_000
            )
        }
    }

    @Test func aacStreamUsesOneMP4WriterWithoutTemporaryM4A() throws {
        let (directory, writer) = try makeWriter()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = try AudioAACStreamSink(
            writer: writer,
            role: .system,
            sampleRate: 48_000,
            channelCount: 1,
            bitRate: 96_000
        )

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files.allSatisfy { !$0.lowercased().hasSuffix(".m4a") })
        try sink.finish()
        #expect(throws: AudioAACStreamSinkError.self) { try sink.finish() }
    }

    private func makeWriter() throws -> (URL, AVAssetWriter) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioAACStreamTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outputURL = directory.appendingPathComponent("segment.mp4")
        return (directory, try AVAssetWriter(outputURL: outputURL, fileType: .mp4))
    }
}
