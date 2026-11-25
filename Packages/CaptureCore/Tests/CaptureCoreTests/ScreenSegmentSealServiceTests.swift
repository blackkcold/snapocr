import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

struct ScreenSegmentSealServiceTests {
    @Test func sealsARealChunkIntoOnePlayableSegment() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenSegmentSealReal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let dimensions = CGSize(width: 320, height: 240)
        let chunkURL = directory.appendingPathComponent("chunk-00000000.mp4")
        let bridge = try ScreenVideoWriterBridge(
            destinationURL: chunkURL,
            configuration: RecordingConfiguration(resolutionLimit: dimensions),
            dimensions: dimensions
        )
        try bridge.append(video: makeVideoSample(dimensions: dimensions, index: 0))
        try bridge.append(video: makeVideoSample(dimensions: dimensions, index: 1))
        let chunk = try await bridge.finish()
        #expect(chunk.frames.count == 2)

        let record = ScreenCheckpointRecord(
            segmentIndex: 0,
            chunkIndex: 0,
            videoURL: chunkURL,
            videoRange: RecordingSampleRange(startSample: 0, sampleCount: 48_000),
            audioCheckpoint: nil,
            coverage: RecordingSegmentCoverage(
                segmentIndex: 0,
                segmentStartSample: 0,
                segmentEndSample: 48_000,
                tracks: []
            ),
            contentHashes: [:]
        )
        let context = RecordingSealContext(
            sessionID: UUID(),
            kind: .screen,
            layout: .separateTracks,
            sampleRate: 48_000,
            outputStem: "sealed-segment",
            destinationDirectory: directory
        )

        let sealed = try await ScreenSegmentSealService().seal(
            [record],
            audio: nil,
            segmentID: UUID(),
            context: context
        )

        guard let videoURL = sealed.videoURL else {
            Issue.record("the seal produced no video URL")
            return
        }
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        #expect(CMTimeGetSeconds(duration) > 0)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        #expect(tracks.count == 1)
    }

    @Test func sealsVideoAndAudioTracksTogether() async throws {
        let sessionRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenSealAudio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sessionRoot) }

        let segmentRoot = sessionRoot.appendingPathComponent("segment-00000000", isDirectory: true)
        try FileManager.default.createDirectory(at: segmentRoot, withIntermediateDirectories: true)
        let dimensions = CGSize(width: 320, height: 240)
        let chunkURL = segmentRoot.appendingPathComponent("chunk-00000000.mp4")
        let bridge = try ScreenVideoWriterBridge(
            destinationURL: chunkURL,
            configuration: RecordingConfiguration(resolutionLimit: dimensions),
            dimensions: dimensions
        )
        // Ten frames of video keep the video input busy while audio is fed.
        for index in 0..<10 {
            try bridge.append(video: makeVideoSample(dimensions: dimensions, index: index))
        }
        _ = try await bridge.finish()
        let audioBundle = try await makeAudioBundle(
            sessionRoot: sessionRoot,
            segmentRoot: segmentRoot
        )

        let record = ScreenCheckpointRecord(
            segmentIndex: 0,
            chunkIndex: 0,
            videoURL: chunkURL,
            videoRange: RecordingSampleRange(startSample: 0, sampleCount: 48_000),
            audioCheckpoint: nil,
            coverage: RecordingSegmentCoverage(
                segmentIndex: 0,
                segmentStartSample: 0,
                segmentEndSample: 48_000,
                tracks: []
            ),
            contentHashes: [:]
        )
        let context = RecordingSealContext(
            sessionID: UUID(),
            kind: .screen,
            layout: .separateTracks,
            sampleRate: 48_000,
            outputStem: "sealed-with-audio",
            destinationDirectory: sessionRoot
        )

        let sealed = try await ScreenSegmentSealService().seal(
            [record],
            audio: audioBundle,
            segmentID: UUID(),
            context: context
        )

        guard let videoURL = sealed.videoURL else {
            Issue.record("the seal produced no video URL")
            return
        }
        let asset = AVURLAsset(url: videoURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        #expect(videoTracks.count == 1)
        #expect(audioTracks.count == 1)
    }

    /// The audio source can stop delivering samples a few milliseconds before the
    /// final video frame closes. The sealer pads that tail with silence, so the
    /// published coverage must span the video range; otherwise the ledger rejects
    /// the publication with `invalidPublication` and the whole recording is lost.
    @Test func aShortAudioTailPublishesCoverageAtTheVideoEnd() async throws {
        let sessionRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenSealShortTail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sessionRoot) }

        let segmentRoot = sessionRoot.appendingPathComponent("segment-00000000", isDirectory: true)
        try FileManager.default.createDirectory(at: segmentRoot, withIntermediateDirectories: true)
        let dimensions = CGSize(width: 320, height: 240)
        let chunkURL = segmentRoot.appendingPathComponent("chunk-00000000.mp4")
        let bridge = try ScreenVideoWriterBridge(
            destinationURL: chunkURL,
            configuration: RecordingConfiguration(resolutionLimit: dimensions),
            dimensions: dimensions
        )
        for index in 0..<10 {
            try bridge.append(video: makeVideoSample(dimensions: dimensions, index: index))
        }
        _ = try await bridge.finish()
        // 47_040 of the 48_000 samples the video range expects: the last 20 ms are
        // silence the sealer must add.
        let audioBundle = try await makeAudioBundle(
            sessionRoot: sessionRoot,
            segmentRoot: segmentRoot,
            totalFrames: 47_040
        )

        let record = ScreenCheckpointRecord(
            segmentIndex: 0,
            chunkIndex: 0,
            videoURL: chunkURL,
            videoRange: RecordingSampleRange(startSample: 0, sampleCount: 48_000),
            audioCheckpoint: nil,
            coverage: RecordingSegmentCoverage(
                segmentIndex: 0,
                segmentStartSample: 0,
                segmentEndSample: 48_000,
                tracks: []
            ),
            contentHashes: [:]
        )
        let context = RecordingSealContext(
            sessionID: UUID(),
            kind: .screen,
            layout: .separateTracks,
            sampleRate: 48_000,
            outputStem: "sealed-short-tail",
            destinationDirectory: sessionRoot
        )
        let hook = PublicationCoverageCapture()

        _ = try await ScreenSegmentSealService(publicationHooks: [hook]).seal(
            [record],
            audio: audioBundle,
            segmentID: UUID(),
            context: context
        )

        let coverage = try #require(await hook.capturedCoverage())
        #expect(coverage.segmentStartSample == 0)
        #expect(coverage.segmentEndSample == 48_000)
        let track = try #require(coverage.tracks.first { $0.role == "system" })
        #expect(track.lastSample == 47_040)
        #expect(
            track.missingRanges == [
                RecordingSampleRange(startSample: 47_040, sampleCount: 960)
            ])
    }

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

    /// Writes a real audio checkpoint into the segment and returns its bundle.
    private func makeAudioBundle(
        sessionRoot: URL,
        segmentRoot: URL,
        totalFrames: Int64 = 4_800
    ) async throws -> RecordingSegmentCheckpointBundle {
        let audioWriter = try RecordingCheckpointWriter(
            directory: segmentRoot,
            sessionRoot: sessionRoot,
            segment: SegmentBoundary(index: 0, startSample: 0, endSample: 48_000 * 10),
            sampleRate: 48_000,
            roles: [.system]
        )
        var written: Int64 = 0
        while written < totalFrames {
            let count = Int(min(480, totalFrames - written))
            let start = written
            try await audioWriter.append(
                AudioPCMBlock(
                    role: .system,
                    range: SampleRange(startSample: start, sampleCount: Int64(count)),
                    sampleRate: 48_000,
                    channelCount: 2,
                    frameCount: count,
                    hostTime: UInt64(written) * 10_000,
                    channels: [
                        [Float](repeating: 0.1, count: count),
                        [Float](repeating: 0.1, count: count),
                    ],
                    isSilence: false
                ))
            written += Int64(count)
        }
        return try await audioWriter.finishSegmentBundle()
    }

    private func makeVideoSample(dimensions: CGSize, index: Int) throws -> CMSampleBuffer {
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]()
        ]
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(dimensions.width),
            Int(dimensions.height),
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw ScreenSealTestError.pixelBufferFailed(status)
        }
        var formatDescription: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDescription else {
            throw ScreenSealTestError.formatDescriptionFailed(formatStatus)
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
            throw ScreenSealTestError.sampleBufferFailed(bufferStatus)
        }
        return sampleBuffer
    }
}

private actor PublicationCoverageCapture: SegmentPublicationHooking {
    private var coverage: RecordingSegmentCoverage?

    func beforePublish(_ candidate: SegmentPublicationCandidate) async throws {
        if coverage == nil {
            coverage = candidate.coverage
        }
    }

    func capturedCoverage() -> RecordingSegmentCoverage? {
        coverage
    }
}

private enum ScreenSealTestError: Error {
    case pixelBufferFailed(CVReturn)
    case formatDescriptionFailed(OSStatus)
    case sampleBufferFailed(OSStatus)
}
