import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import SharedKit

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

/// How one chunk writer's `startWriting()` attempt ended.
public enum ScreenWriterStartResult: String, Codable, Sendable, Hashable {
    /// No frame reached the writer, so writing was never attempted.
    case notAttempted
    /// `AVAssetWriter.startWriting()` returned true.
    case started
    /// `AVAssetWriter.startWriting()` returned false.
    case failed
}

/// Privacy-safe counters describing how a chunk writer behaved.
///
/// Every field is a count or a short error string. No frame content, window
/// title, or application name is ever recorded here.
public struct ScreenWriterDiagnostics: Codable, Sendable, Hashable {
    /// Whether `startWriting()` was attempted and what it returned.
    public var startWritingResult: ScreenWriterStartResult
    /// Sync frames the writer could not accept. A healthy run keeps this at zero.
    public var syncDropCount: Int64
    /// Non-sync frames dropped because the writer applied backpressure.
    public var nonSyncDropCount: Int64
    /// `AVAssetWriterInput.append` rejections and the writer errors behind them.
    public var appendFailureCount: Int64
    /// The last writer error description, when one was reported.
    public var lastErrorDescription: String?
    /// Why the session's audio track could not start, when it could not.
    ///
    /// This is a session-level fact carried here so every diagnostics consumer sees
    /// it next to the writer counters. The video keeps recording when this is set.
    public var audioFailureReason: String?

    /// A writer that has not run yet.
    public static let idle = ScreenWriterDiagnostics(
        startWritingResult: .notAttempted,
        syncDropCount: 0,
        nonSyncDropCount: 0,
        appendFailureCount: 0,
        lastErrorDescription: nil
    )

    /// Creates a diagnostics snapshot.
    public init(
        startWritingResult: ScreenWriterStartResult,
        syncDropCount: Int64,
        nonSyncDropCount: Int64,
        appendFailureCount: Int64,
        lastErrorDescription: String?,
        audioFailureReason: String? = nil
    ) {
        self.startWritingResult = startWritingResult
        self.syncDropCount = syncDropCount
        self.nonSyncDropCount = nonSyncDropCount
        self.appendFailureCount = appendFailureCount
        self.lastErrorDescription = lastErrorDescription
        self.audioFailureReason = audioFailureReason
    }

    /// Whether the writer started writing successfully.
    public var writerStart: Bool { startWritingResult == .started }

    /// Adds another writer's counters to this snapshot.
    ///
    /// - Parameter other: The later writer's counters.
    /// - Returns: Summed counts with the newest error and the furthest start result.
    public func combined(with other: ScreenWriterDiagnostics) -> ScreenWriterDiagnostics {
        ScreenWriterDiagnostics(
            startWritingResult: Self.stronger(startWritingResult, other.startWritingResult),
            syncDropCount: syncDropCount + other.syncDropCount,
            nonSyncDropCount: nonSyncDropCount + other.nonSyncDropCount,
            appendFailureCount: appendFailureCount + other.appendFailureCount,
            lastErrorDescription: other.lastErrorDescription ?? lastErrorDescription,
            audioFailureReason: other.audioFailureReason ?? audioFailureReason
        )
    }

    private static func stronger(
        _ lhs: ScreenWriterStartResult,
        _ rhs: ScreenWriterStartResult
    ) -> ScreenWriterStartResult {
        if lhs == .failed || rhs == .failed { return .failed }
        if lhs == .started || rhs == .started { return .started }
        return .notAttempted
    }
}

/// Test-only fault injection for the writer's failure branches.
///
/// Production never sets these; the unit tests use them to reach branches an
/// encoder will not produce on demand (a refusing `startWriting`, an always-busy
/// input, a rejected append).
struct ScreenWriterFaultInjection: Sendable {
    /// Replaces `AVAssetWriter.startWriting()`.
    var startWriting: (@Sendable () -> Bool)?
    /// Replaces `AVAssetWriterInput.isReadyForMoreMediaData`.
    var inputReady: (@Sendable () -> Bool)?
    /// Replaces `AVAssetWriterInput.append(_:)`.
    var append: (@Sendable (CMSampleBuffer) -> Bool)?

    /// No injection.
    static let none = ScreenWriterFaultInjection()
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
    /// The writer input stayed busy past the bounded sync-frame wait.
    case writerNotReady
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
        case .writerNotReady:
            "The media writer was not ready to accept a video sample."
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
    private var diagnosticsState = ScreenWriterDiagnostics.idle
    private let logger = Logger(subsystem: "com.snapglass", category: "screen.writer")
    /// Test-only fault injection; production never sets it.
    var faultInjection = ScreenWriterFaultInjection.none

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
            !FileManager.default.fileExists(atPath: destinationURL.path)
        else {
            throw ScreenVideoWriterBridgeError.invalidDestination
        }
        guard dimensions.width.isFinite,
            dimensions.height.isFinite,
            dimensions.width >= 2,
            dimensions.height >= 2,
            dimensions.width.rounded(.towardZero) == dimensions.width,
            dimensions.height.rounded(.towardZero) == dimensions.height,
            Int(dimensions.width).isMultiple(of: 2),
            Int(dimensions.height).isMultiple(of: 2)
        else {
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

    /// Privacy-safe counters for this writer.
    public var diagnostics: ScreenWriterDiagnostics {
        lock.lock()
        defer { lock.unlock() }
        return diagnosticsState
    }

    /// Bounded wait for a sync frame when the writer input is busy.
    static let syncReadinessBudget: Duration = .milliseconds(250)
    /// Slice length used while polling the writer input.
    private static let readinessPollSlice: TimeInterval = 0.005

    /// Appends a video sample synchronously on the caller's capture queue.
    ///
    /// A sync frame is never dropped silently: while the writer input is busy the
    /// call waits in bounded slices, and if it is still busy after
    /// ``syncReadinessBudget`` the chunk fails with
    /// ``ScreenVideoWriterBridgeError/writerNotReady`` after cancelling the writer
    /// and removing the unusable chunk. Non-sync frames may be dropped under
    /// backpressure and are counted.
    ///
    /// - Parameter sampleBuffer: A ready sample buffer containing a pixel buffer.
    /// - Returns: `true` only when `AVAssetWriterInput.append` accepted the sample.
    /// - Throws: `ScreenVideoWriterBridgeError` for invalid input or writer failure.
    @discardableResult
    public func append(video sampleBuffer: CMSampleBuffer) throws -> Bool {
        guard CMSampleBufferIsValid(sampleBuffer),
            CMSampleBufferDataIsReady(sampleBuffer),
            CMSampleBufferGetImageBuffer(sampleBuffer) != nil
        else {
            throw ScreenVideoWriterBridgeError.invalidVideoSample
        }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTime.isValid, presentationTime.isNumeric else {
            throw ScreenVideoWriterBridgeError.invalidVideoSample
        }
        let isSync = Self.isSyncSample(sampleBuffer)
        let frameIndex = try beginAppend(presentationTime: presentationTime, isSync: isSync)
        guard try awaitInputReady(isSync: isSync) else {
            recordNonSyncDrop()
            return false
        }
        return try commit(
            sampleBuffer,
            frameIndex: frameIndex,
            presentationTime: presentationTime,
            isSync: isSync
        )
    }

    /// Validates state and starts the writer/session for one frame.
    ///
    /// - Parameters:
    ///   - presentationTime: The frame's presentation timestamp.
    ///   - isSync: Whether the frame is a sync frame.
    /// - Returns: The source-frame ordinal this attempt owns.
    /// - Throws: A ``ScreenVideoWriterBridgeError`` when the writer cannot start.
    private func beginAppend(presentationTime: CMTime, isSync: Bool) throws -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinishing else { throw ScreenVideoWriterBridgeError.alreadyFinished }
        if !hasStartedSession, !isSync {
            throw ScreenVideoWriterBridgeError.firstFrameNotSync
        }
        if !hasStartedWriting {
            let started = faultInjection.startWriting?() ?? writer.startWriting()
            guard started else {
                let reason =
                    writer.error?.localizedDescription
                    ?? "The media writer could not start."
                diagnosticsState.startWritingResult = .failed
                diagnosticsState.lastErrorDescription = reason
                writer.cancelWriting()
                discardDestinationIfEmpty()
                logger.error("screen.writer start failed")
                throw ScreenVideoWriterBridgeError.writerFailed(reason)
            }
            hasStartedWriting = true
            diagnosticsState.startWritingResult = .started
        }
        if !hasStartedSession {
            writer.startSession(atSourceTime: presentationTime)
            hasStartedSession = true
        }
        let frameIndex = nextFrameIndex
        try advanceFrameIndex()
        return frameIndex
    }

    /// Waits for writer-input readiness without holding the state lock.
    ///
    /// - Parameter isSync: Whether a drop is allowed when the wait expires.
    /// - Returns: `true` when the input is ready; `false` only for a dropped non-sync frame.
    /// - Throws: ``ScreenVideoWriterBridgeError/writerNotReady`` for a sync frame.
    private func awaitInputReady(isSync: Bool) throws -> Bool {
        if isInputReady() { return true }
        guard isSync else { return false }
        let deadline = ContinuousClock.now.advanced(by: Self.syncReadinessBudget)
        while true {
            if isInputReady() { return true }
            if ContinuousClock.now >= deadline {
                let reason = "The media writer was not ready to accept a video sample."
                lock.lock()
                diagnosticsState.syncDropCount += 1
                diagnosticsState.lastErrorDescription = reason
                droppedFrames += 1
                writer.cancelWriting()
                discardDestinationIfEmpty()
                lock.unlock()
                logger.error("screen.writer sync frame was still not ready after the bounded wait")
                throw ScreenVideoWriterBridgeError.writerNotReady
            }
            Thread.sleep(forTimeInterval: Self.readinessPollSlice)
        }
    }

    /// Appends the frame and records any rejection.
    ///
    /// - Parameters:
    ///   - sampleBuffer: The frame to append.
    ///   - frameIndex: The source-frame ordinal owned by this attempt.
    ///   - presentationTime: The frame's presentation timestamp.
    ///   - isSync: Whether the frame is a sync frame.
    /// - Returns: Always `true`; a rejection throws.
    /// - Throws: ``ScreenVideoWriterBridgeError/writerFailed(_:)`` after cleanup.
    private func commit(
        _ sampleBuffer: CMSampleBuffer,
        frameIndex: Int64,
        presentationTime: CMTime,
        isSync: Bool
    ) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinishing else { throw ScreenVideoWriterBridgeError.alreadyFinished }
        let accepted = faultInjection.append?(sampleBuffer) ?? videoInput.append(sampleBuffer)
        guard accepted else {
            let reason =
                writer.error?.localizedDescription
                ?? "The media writer rejected a video sample."
            diagnosticsState.appendFailureCount += 1
            diagnosticsState.lastErrorDescription = reason
            writer.cancelWriting()
            discardDestinationIfEmpty(force: true)
            logger.error("screen.writer append rejected a sample; the chunk was discarded")
            throw ScreenVideoWriterBridgeError.writerFailed(reason)
        }

        let sourceDuration = CMSampleBufferGetDuration(sampleBuffer)
        let duration: CMTime
        if sourceDuration.isValid, sourceDuration.isNumeric, CMTimeCompare(sourceDuration, .zero) > 0 {
            duration = sourceDuration
        } else {
            duration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        }
        acceptedFrames.append(
            VideoFrameSample(
                index: frameIndex,
                presentationTime: presentationTime,
                decodeTime: CMSampleBufferGetDecodeTimeStamp(sampleBuffer),
                duration: duration,
                isSync: isSync
            ))
        return true
    }

    /// Whether the writer input can accept another sample right now.
    private func isInputReady() -> Bool {
        lock.lock()
        let override = faultInjection.inputReady
        lock.unlock()
        if let override { return override() }
        return videoInput.isReadyForMoreMediaData
    }

    /// Counts one non-sync frame dropped under backpressure.
    private func recordNonSyncDrop() {
        lock.lock()
        droppedFrames += 1
        diagnosticsState.nonSyncDropCount += 1
        lock.unlock()
    }

    /// Removes the chunk file when it holds no bytes and so cannot be recovered.
    ///
    /// - Parameter force: Remove the file whatever its size (an appended chunk is
    ///   unusable after `cancelWriting`).
    private func discardDestinationIfEmpty(force: Bool = false) {
        let path = destinationURL.path
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?
            .int64Value
        guard let size else { return }
        guard force || size == 0 else { return }
        try? FileManager.default.removeItem(at: destinationURL)
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
                discardDestinationIfEmpty()
                diagnosticsState.lastErrorDescription =
                    "The video chunk contains no accepted video frames."
                lock.unlock()
                logger.error("screen.writer finish had no accepted frames")
                continuation.resume(throwing: ScreenVideoWriterBridgeError.noVideoFrames)
                return
            }
            videoInput.markAsFinished()
            let frameCount = acceptedFrames.count
            lock.unlock()
            logger.info("screen.writer finish requested frames=\(frameCount)")
            writer.finishWriting { [weak self] in
                guard let self else {
                    continuation.resume(
                        throwing: ScreenVideoWriterBridgeError.writerFailed(
                            "The video writer was released while finishing."
                        )
                    )
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
                self.logger.info(
                    "screen.writer finish completed status=\(writerStatus.rawValue)"
                )

                guard writerStatus == .completed,
                    let attributes = try? FileManager.default.attributesOfItem(atPath: self.destinationURL.path),
                    ((attributes[.size] as? NSNumber)?.int64Value ?? 0) > 0
                else {
                    self.logger.error("screen.writer finish produced no usable file")
                    self.discardDestinationIfEmpty()
                    continuation.resume(
                        throwing: ScreenVideoWriterBridgeError.writerFailed(
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
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
            ) as? [[CFString: Any]],
            let first = attachments.first,
            let notSync = first[kCMSampleAttachmentKey_NotSync] as? NSNumber
        else {
            return true
        }
        return !notSync.boolValue
    }
}
