import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

struct RecordingWriterPipelineTests {
    @Test func writesAPlayableFileFromSyntheticFrames() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let dimensions = CGSize(width: 320, height: 240)
        let queue = DispatchQueue(label: "RecordingWriterPipelineTests.samples")
        let transaction = try RecordingOutputTransaction(destinationDirectory: root)
        let pipeline = try RecordingWriterPipeline(
            transaction: transaction,
            configuration: RecordingConfiguration(
                codec: .h264,
                resolutionLimit: dimensions,
                frameRateLimit: 30,
                averageVideoBitrate: 2_000_000,
                capturesSystemAudio: false
            ),
            dimensions: dimensions,
            sampleQueue: queue,
            onFailure: { _ in }
        )

        for index in 0 ..< 30 {
            let sample = try Self.makeVideoSample(dimensions: dimensions, index: index)
            queue.sync { pipeline.append(sample, type: .screen) }
            try await Task.sleep(for: .milliseconds(16))
        }

        let url = try await pipeline.finishAndPublish(stopError: nil)

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(url.pathExtension == "mp4")
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        #expect(duration.seconds > 0.7)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        #expect(videoTracks.count == 1)
    }

    @Test func sessionWithoutFramesThrowsAndLeavesNoFile() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let dimensions = CGSize(width: 320, height: 240)
        let queue = DispatchQueue(label: "RecordingWriterPipelineTests.empty")
        let transaction = try RecordingOutputTransaction(destinationDirectory: root)
        let pipeline = try RecordingWriterPipeline(
            transaction: transaction,
            configuration: RecordingConfiguration(
                codec: .h264,
                resolutionLimit: dimensions,
                frameRateLimit: 30,
                averageVideoBitrate: 2_000_000,
                capturesSystemAudio: false
            ),
            dimensions: dimensions,
            sampleQueue: queue,
            onFailure: { _ in }
        )

        await #expect(throws: ScreenRecordingEngineError.self) {
            _ = try await pipeline.finishAndPublish(stopError: nil)
        }

        let contents = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(contents.isEmpty)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingWriterPipelineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func makeVideoSample(dimensions: CGSize, index: Int) throws -> CMSampleBuffer {
        let width = Int(dimensions.width)
        let height = Int(dimensions.height)
        let pixelBuffer = try makePixelBuffer(width: width, height: height, seed: UInt8(truncatingIfNeeded: index * 8))

        var formatDescription: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDescription else {
            throw RecordingWriterPipelineTestError.formatDescriptionFailed(formatStatus)
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: 30),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let bufferStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard bufferStatus == noErr, let sampleBuffer else {
            throw RecordingWriterPipelineTestError.sampleBufferFailed(bufferStatus)
        }
        return sampleBuffer
    }

    private static func makePixelBuffer(width: Int, height: Int, seed: UInt8) throws -> CVPixelBuffer {
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw RecordingWriterPipelineTestError.pixelBufferFailed(status)
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(baseAddress, Int32(seed), CVPixelBufferGetBytesPerRow(pixelBuffer) * height)
        }
        return pixelBuffer
    }
}

private enum RecordingWriterPipelineTestError: Error {
    case pixelBufferFailed(CVReturn)
    case formatDescriptionFailed(OSStatus)
    case sampleBufferFailed(OSStatus)
}
