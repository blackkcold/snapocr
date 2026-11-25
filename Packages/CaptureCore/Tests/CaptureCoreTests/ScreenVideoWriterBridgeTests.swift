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

    @Test func syncFrameNotReadyThrowsAfterBoundedWait() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dimensions = CGSize(width: 320, height: 240)
        let destination = directory.appendingPathComponent("busy.mp4")
        let bridge = try ScreenVideoWriterBridge(
            destinationURL: destination,
            configuration: RecordingConfiguration(resolutionLimit: dimensions),
            dimensions: dimensions
        )
        bridge.faultInjection.inputReady = { false }
        let clock = ContinuousClock()
        let start = clock.now

        #expect(throws: ScreenVideoWriterBridgeError.writerNotReady) {
            try bridge.append(video: self.makeVideoSample(dimensions: dimensions, index: 0))
        }

        // The sync frame was waited for, not silently dropped.
        #expect(clock.now - start >= .milliseconds(150))
        #expect(bridge.diagnostics.syncDropCount == 1)
        #expect(bridge.diagnostics.nonSyncDropCount == 0)
        #expect(bridge.diagnostics.lastErrorDescription != nil)
        // No zero-byte chunk is left behind.
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func syncFrameAcceptedAfterTheWriterBecomesReady() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dimensions = CGSize(width: 320, height: 240)
        let destination = directory.appendingPathComponent("late-ready.mp4")
        let bridge = try ScreenVideoWriterBridge(
            destinationURL: destination,
            configuration: RecordingConfiguration(resolutionLimit: dimensions),
            dimensions: dimensions
        )
        let counter = WriterProbeCounter()
        bridge.faultInjection.inputReady = { counter.next() > 2 }

        let accepted = try bridge.append(video: makeVideoSample(dimensions: dimensions, index: 0))

        #expect(accepted)
        #expect(bridge.diagnostics.syncDropCount == 0)
        let result = try await bridge.finish()
        #expect(result.frames.count == 1)
    }

    @Test func startWritingFailureReportsAndRemovesTheChunk() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dimensions = CGSize(width: 320, height: 240)
        let destination = directory.appendingPathComponent("start-failed.mp4")
        let bridge = try ScreenVideoWriterBridge(
            destinationURL: destination,
            configuration: RecordingConfiguration(resolutionLimit: dimensions),
            dimensions: dimensions
        )
        bridge.faultInjection.startWriting = { false }

        #expect(throws: ScreenVideoWriterBridgeError.self) {
            try bridge.append(video: self.makeVideoSample(dimensions: dimensions, index: 0))
        }

        #expect(bridge.diagnostics.startWritingResult == .failed)
        #expect(bridge.diagnostics.lastErrorDescription != nil)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func appendRejectionDiscardsTheChunk() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dimensions = CGSize(width: 320, height: 240)
        let destination = directory.appendingPathComponent("append-failed.mp4")
        let bridge = try ScreenVideoWriterBridge(
            destinationURL: destination,
            configuration: RecordingConfiguration(resolutionLimit: dimensions),
            dimensions: dimensions
        )
        bridge.faultInjection.append = { _ in false }

        #expect(throws: ScreenVideoWriterBridgeError.self) {
            try bridge.append(video: self.makeVideoSample(dimensions: dimensions, index: 0))
        }

        #expect(bridge.diagnostics.appendFailureCount == 1)
        #expect(bridge.diagnostics.lastErrorDescription != nil)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func nonSyncFrameIsDroppedAndCounted() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dimensions = CGSize(width: 320, height: 240)
        let destination = directory.appendingPathComponent("drop.mp4")
        let bridge = try ScreenVideoWriterBridge(
            destinationURL: destination,
            configuration: RecordingConfiguration(resolutionLimit: dimensions),
            dimensions: dimensions
        )
        try bridge.append(video: makeVideoSample(dimensions: dimensions, index: 0))
        bridge.faultInjection.inputReady = { false }

        let accepted = try bridge.append(
            video: makeVideoSample(dimensions: dimensions, index: 1, notSync: true)
        )

        #expect(!accepted)
        #expect(bridge.diagnostics.nonSyncDropCount == 1)
        #expect(bridge.diagnostics.syncDropCount == 0)
        let result = try await bridge.finish()
        #expect(result.frames.count == 1)
    }

    @Test func finishWithoutAcceptedFramesLeavesNoFile() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dimensions = CGSize(width: 320, height: 240)
        let destination = directory.appendingPathComponent("no-frames.mp4")
        let bridge = try ScreenVideoWriterBridge(
            destinationURL: destination,
            configuration: RecordingConfiguration(resolutionLimit: dimensions),
            dimensions: dimensions
        )

        await #expect(throws: ScreenVideoWriterBridgeError.noVideoFrames) {
            try await bridge.finish()
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
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

    private func makeVideoSample(
        dimensions: CGSize,
        index: Int,
        notSync: Bool = false
    ) throws -> CMSampleBuffer {
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
        if notSync {
            guard
                let attachments = CMSampleBufferGetSampleAttachmentsArray(
                    sampleBuffer,
                    createIfNecessary: true
                ), CFArrayGetCount(attachments) > 0
            else {
                throw ScreenVideoWriterBridgeTestError.sampleBufferFailed(bufferStatus)
            }
            let entry = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                entry,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
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

/// Thread-safe call counter for the injected writer-readiness probe.
private final class WriterProbeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
