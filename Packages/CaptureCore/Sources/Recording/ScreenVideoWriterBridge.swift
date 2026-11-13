import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// Timing and sync metadata for one accepted source video frame.
public struct VideoFrameSample: Sendable, Hashable {
    /// Source-frame ordinal; dropped input frames leave gaps in this sequence.
    public let index: Int64
    /// Presentation timestamp supplied by the capture source.
    public let presentationTime: CMTime
    /// Decode timestamp supplied by the capture source, or invalid when absent.
    public let decodeTime: CMTime
    /// Sample duration supplied by the capture source or the configured frame interval.
    public let duration: CMTime
    /// Whether the source sample is a sync frame.
    public let isSync: Bool

    /// Creates frame timing metadata.
    ///
    /// - Parameters:
    ///   - index: Source-frame ordinal.
    ///   - presentationTime: Presentation timestamp.
    ///   - decodeTime: Decode timestamp, or `.invalid` when absent.
    ///   - duration: Positive sample duration.
    ///   - isSync: Whether the sample is a sync frame.
    public init(
        index: Int64,
        presentationTime: CMTime,
        decodeTime: CMTime,
        duration: CMTime,
        isSync: Bool
    ) {
        self.index = index
        self.presentationTime = presentationTime
        self.decodeTime = decodeTime
        self.duration = duration
        self.isSync = isSync
    }
}

/// Result of finishing one encoded, video-only chunk.
public struct VideoChunkResult: Sendable, Hashable {
    /// URL of the finalized MP4 chunk.
    public let url: URL
    /// Accepted source-frame timing records in append order.
    public let frames: [VideoFrameSample]
    /// Number of source frames dropped because the writer input was not ready.
    public let droppedFrameCount: Int64

    /// Creates a finalized video chunk result.
    ///
    /// - Parameters:
    ///   - url: Finalized MP4 URL.
    ///   - frames: Accepted source-frame timing records.
    ///   - droppedFrameCount: Count of backpressure drops.
    public init(url: URL, frames: [VideoFrameSample], droppedFrameCount: Int64) {
        self.url = url
        self.frames = frames
        self.droppedFrameCount = droppedFrameCount
    }
}

/// Failures raised while writing one screen-video chunk.
public enum ScreenVideoWriterBridgeError: LocalizedError, Equatable, Sendable {
    /// The requested destination already exists or is not a file URL.
    case invalidDestination
    /// The configuration or output dimensions cannot produce a valid MP4 track.
    case invalidConfiguration
    /// The source sample is invalid, not ready, or has no image buffer.
    case invalidVideoSample
    /// The first usable frame was not a sync frame.
    case firstFrameNotSync
    /// The selected encoder cannot accept the requested video settings.
    case unsupportedVideoFormat
    /// The writer input cannot be added.
    case writerInputUnavailable
    /// The writer failed to start, append, or finish.
    case writerFailed(String)
    /// The chunk has no accepted video frame.
    case noVideoFrames
    /// Append was attempted after finalization began.
    case alreadyFinished

    /// English fallback description.
    public var errorDescription: String? {
        switch self {
        case .invalidDestination:
            "The video chunk destination is invalid or already exists."
        case .invalidConfiguration:
            "The video chunk configuration or dimensions are invalid."
        case .invalidVideoSample:
            "The capture source did not provide a valid video sample."
        case .firstFrameNotSync:
            "The first video frame in a chunk must be a sync frame."
        case .unsupportedVideoFormat:
            "The selected encoder cannot write the requested video format."
        case .writerInputUnavailable:
            "The media writer cannot add a video input."
        case let .writerFailed(reason):
            reason
        case .noVideoFrames:
            "The video chunk contains no accepted video frames."
        case .alreadyFinished:
            "The video chunk writer has already finished."
        }
    }
}

/// Encodes video samples into one MP4 chunk without creating per-frame tasks.
///
/// Calls are serialized by a lock; backpressure drops the incoming frame and
/// increments a counter. No pixel buffer is retained after `append` returns.
public final class ScreenVideoWriterBridge: @unchecked Sendable {
    private let lock = NSLock()
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let destinationURL: URL
    private let frameRate: Int
    private var hasStartedWriting = false
    private var hasStartedSession = false
    private var isFinishing = false
    private var nextFrameIndex: Int64 = 0
    private var acceptedFrames: [VideoFrameSample] = []
    private var droppedFrames: Int64 = 0

    /// Creates a video-only MP4 chunk writer.
    ///
    /// - Parameters:
    ///   - destinationURL: A new, not-yet-existing MP4 URL in the owned staging directory.
    ///   - configuration: Immutable video encoding configuration.
    ///   - dimensions: Even output dimensions in pixels.
    /// - Throws: `ScreenVideoWriterBridgeError` when the destination, encoder,
    ///   configuration, or dimensions cannot be used.
    public init(destinationURL: URL, configuration: RecordingConfiguration, dimensions: CGSize) throws {
        guard destinationURL.isFileURL,
              destinationURL.pathExtension.lowercased() == "mp4",
              !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw ScreenVideoWriterBridgeError.invalidDestination
        }
        guard dimensions.width.isFinite,
              dimensions.height.isFinite,
              dimensions.width >= 2,
              dimensions.height >= 2,
              dimensions.width.rounded(.towardZero) == dimensions.width,
              dimensions.height.rounded(.towardZero) == dimensions.height,
              Int(dimensions.width).isMultiple(of: 2),
              Int(dimensions.height).isMultiple(of: 2) else {
            throw ScreenVideoWriterBridgeError.invalidConfiguration
        }
        do {
            try configuration.validate()
        } catch {
            throw ScreenVideoWriterBridgeError.invalidConfiguration
        }

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: destinationURL, fileType: .mp4)
        } catch {
            throw ScreenVideoWriterBridgeError.writerFailed(error.localizedDescription)
        }
        let supportedCodecs = RecordingWriterSettings.supportedVideoCodecs(
            configuration: configuration,
            dimensions: dimensions
        ) { settings in
            writer.canApply(outputSettings: settings, forMediaType: .video)
        }
        guard supportedCodecs.contains(configuration.codec) else {
            throw ScreenVideoWriterBridgeError.unsupportedVideoFormat
        }

        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: RecordingWriterSettings.videoOutputSettings(
                configuration: configuration,
                dimensions: dimensions
            )
        )
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw ScreenVideoWriterBridgeError.writerInputUnavailable
        }
        writer.add(input)
        self.writer = writer
        videoInput = input
        self.destinationURL = destinationURL
        frameRate = configuration.frameRateLimit
    }

    /// Number of input frames dropped because AVAssetWriter applied backpressure.
    public var droppedFrameCount: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return droppedFrames
    }

    /// Appends a video sample synchronously on the caller's capture queue.
    ///
    /// Invalid/non-video samples throw. When the writer input is not ready, the
    /// sample is dropped immediately and the bounded drop counter is incremented.
    ///
    /// - Parameter sampleBuffer: A ready sample buffer containing a pixel buffer.
    /// - Throws: `ScreenVideoWriterBridgeError` for invalid input or writer failure.
    public func append(video sampleBuffer: CMSampleBuffer) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinishing else { throw ScreenVideoWriterBridgeError.alreadyFinished }
        guard CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferDataIsReady(sampleBuffer),
              CMSampleBufferGetImageBuffer(sampleBuffer) != nil else {
            throw ScreenVideoWriterBridgeError.invalidVideoSample
        }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTime.isValid, presentationTime.isNumeric else {
            throw ScreenVideoWriterBridgeError.invalidVideoSample
        }
        let isSync = Self.isSyncSample(sampleBuffer)
        if !hasStartedSession, !isSync {
            throw ScreenVideoWriterBridgeError.firstFrameNotSync
        }

        if !hasStartedWriting {
            guard writer.startWriting() else {
                throw ScreenVideoWriterBridgeError.writerFailed(
                    writer.error?.localizedDescription ?? "The media writer could not start."
                )
            }
            hasStartedWriting = true
        }
        if !hasStartedSession {
            writer.startSession(atSourceTime: presentationTime)
            hasStartedSession = true
        }

        let frameIndex = nextFrameIndex
        try advanceFrameIndex()
        guard videoInput.isReadyForMoreMediaData else {
            droppedFrames += 1
            return
        }
        guard videoInput.append(sampleBuffer) else {
            throw ScreenVideoWriterBridgeError.writerFailed(
                writer.error?.localizedDescription ?? "The media writer rejected a video sample."
            )
        }

        let sourceDuration = CMSampleBufferGetDuration(sampleBuffer)
        let duration: CMTime
        if sourceDuration.isValid, sourceDuration.isNumeric, CMTimeCompare(sourceDuration, .zero) > 0 {
            duration = sourceDuration
        } else {
            duration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        }
        acceptedFrames.append(VideoFrameSample(
            index: frameIndex,
            presentationTime: presentationTime,
            decodeTime: CMSampleBufferGetDecodeTimeStamp(sampleBuffer),
            duration: duration,
            isSync: isSync
        ))
    }

    /// Finishes and returns the finalized video-only MP4 chunk.
    ///
    /// - Returns: The chunk URL, accepted frame table, and backpressure-drop count.
    /// - Throws: `ScreenVideoWriterBridgeError` when no video was accepted or
    ///   finalization did not complete successfully.
    public func finish() async throws -> VideoChunkResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<VideoChunkResult, any Error>) in
            lock.lock()
            guard !isFinishing else {
                lock.unlock()
                continuation.resume(throwing: ScreenVideoWriterBridgeError.alreadyFinished)
                return
            }
            isFinishing = true
            guard !acceptedFrames.isEmpty, hasStartedWriting, hasStartedSession else {
                writer.cancelWriting()
                lock.unlock()
                continuation.resume(throwing: ScreenVideoWriterBridgeError.noVideoFrames)
                return
            }
            videoInput.markAsFinished()
            lock.unlock()
            writer.finishWriting { [weak self] in
                guard let self else {
                    continuation.resume(throwing: ScreenVideoWriterBridgeError.writerFailed("The video writer was released while finishing."))
                    return
                }
                self.lock.lock()
                let result = VideoChunkResult(
                    url: self.destinationURL,
                    frames: self.acceptedFrames,
                    droppedFrameCount: self.droppedFrames
                )
                let writerStatus = self.writer.status
                let writerError = self.writer.error?.localizedDescription
                self.lock.unlock()

                guard writerStatus == .completed,
                      let attributes = try? FileManager.default.attributesOfItem(atPath: self.destinationURL.path),
                      ((attributes[.size] as? NSNumber)?.int64Value ?? 0) > 0 else {
                    continuation.resume(throwing: ScreenVideoWriterBridgeError.writerFailed(
                        writerError ?? "The video chunk could not be finalized."
                    ))
                    return
                }
                continuation.resume(returning: result)
            }
        }
    }

    private func advanceFrameIndex() throws {
        let (next, overflow) = nextFrameIndex.addingReportingOverflow(1)
        guard !overflow else { throw ScreenVideoWriterBridgeError.invalidConfiguration }
        nextFrameIndex = next
    }

    private static func isSyncSample(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[CFString: Any]],
        let first = attachments.first,
        let notSync = first[kCMSampleAttachmentKey_NotSync] as? NSNumber else {
            return true
        }
        return !notSync.boolValue
    }
}
