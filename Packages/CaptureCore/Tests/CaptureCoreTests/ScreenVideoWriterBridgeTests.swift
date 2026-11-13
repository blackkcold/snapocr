import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

struct ScreenVideoWriterBridgeTests {
    @Test func videoBridgeFirstFrameStartsSyncSessionAndFinishesReadableChunk() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dimensions = CGSize(width: 320, height: 240)
        let destination = directory.appendingPathComponent("video-chunk.mp4")
        let bridge = try ScreenVideoWriterBridge(
            destinationURL: destination,
            configuration: RecordingConfiguration(
                resolutionLimit: dimensions,
                averageVideoBitrate: 1_000_000
            ),
            dimensions: dimensions
        )

        try bridge.append(video: makeVideoSample(dimensions: dimensions, index: 0))
        let result = try await bridge.finish()

        #expect(result.url == destination)
        #expect(result.frames.count == 1)
        #expect(result.frames.first?.index == 0)
        #expect(result.frames.first?.isSync == true)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        let asset = AVURLAsset(url: destination)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        #expect(tracks.count == 1)
    }

    @Test func videoBridgeRejectsNonVideoSample() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dimensions = CGSize(width: 320, height: 240)
        let bridge = try ScreenVideoWriterBridge(
            destinationURL: directory.appendingPathComponent("non-video.mp4"),
            configuration: RecordingConfiguration(resolutionLimit: dimensions),
            dimensions: dimensions
        )
        let pcm = try AudioSampleBufferFactory.makePCMBuffer(
            channels: [[Float](repeating: 0.1, count: 128)],
            sampleRate: 48_000
        )
        let audioSample = try AudioSampleBufferFactory.makeSampleBuffer(from: pcm, presentationTime: .zero)

        #expect(throws: ScreenVideoWriterBridgeError.self) {
            try bridge.append(video: audioSample)
        }
    }

    @Test func screenStreamConfigurationKeepsQueueDepthThree() throws {
        let configuration = try RecordingStreamSettings.make(
            configuration: RecordingConfiguration(),
            sourceDimensions: CGSize(width: 1_920, height: 1_080)
        )

        #expect(configuration.queueDepth == 3)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenVideoWriterBridgeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeVideoSample(dimensions: CGSize, index: Int) throws -> CMSampleBuffer {
        let pixelBuffer = try makePixelBuffer(
            width: Int(dimensions.width),
            height: Int(dimensions.height),
            seed: UInt8(truncatingIfNeeded: index * 8)
        )
        var formatDescription: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDescription else {
            throw ScreenVideoWriterBridgeTestError.formatDescriptionFailed(formatStatus)
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
            throw ScreenVideoWriterBridgeTestError.sampleBufferFailed(bufferStatus)
        }
        return sampleBuffer
    }

    private func makePixelBuffer(width: Int, height: Int, seed: UInt8) throws -> CVPixelBuffer {
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
            throw ScreenVideoWriterBridgeTestError.pixelBufferFailed(status)
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(baseAddress, Int32(seed), CVPixelBufferGetBytesPerRow(pixelBuffer) * height)
        }
        return pixelBuffer
    }
}

private enum ScreenVideoWriterBridgeTestError: Error {
    case pixelBufferFailed(CVReturn)
    case formatDescriptionFailed(OSStatus)
    case sampleBufferFailed(OSStatus)
}
