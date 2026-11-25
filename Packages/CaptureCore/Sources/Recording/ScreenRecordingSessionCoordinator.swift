import AVFoundation
import AudioToolbox
import CoreGraphics
import CoreMedia
import Foundation
import SharedKit

/// Immutable settings selected for one screen-recording session.
public struct ScreenRecordingStartConfiguration: Sendable, Hashable {
    /// The display, window, or region being recorded.
    public let source: RecordingSource
    /// Video encoding and stream settings.
    public let video: RecordingConfiguration
    /// Screen-session audio sources and track settings.
    public let audio: AudioRecordingConfiguration
    /// Source dimensions used to resolve the even output dimensions.
    public let sourceDimensions: CGSize?
    /// Existing directory that receives sealed MP4 segments.
    public let destinationDirectory: URL
    /// Window IDs excluded from display and region capture.
    public let excludedWindowIDs: Set<CGWindowID>

    /// Creates an immutable screen-recording configuration.
    public init(
        source: RecordingSource,
        video: RecordingConfiguration,
        audio: AudioRecordingConfiguration,
        destinationDirectory: URL,
        excludedWindowIDs: Set<CGWindowID>,
        sourceDimensions: CGSize? = nil
    ) {
        self.source = source
        self.video = video
        self.audio = audio
        self.destinationDirectory = destinationDirectory
        self.excludedWindowIDs = excludedWindowIDs
        self.sourceDimensions = sourceDimensions
    }

    public static func == (
        lhs: ScreenRecordingStartConfiguration,
        rhs: ScreenRecordingStartConfiguration
    ) -> Bool {
        lhs.source == rhs.source
            && lhs.video == rhs.video
            && lhs.audio == rhs.audio
            && lhs.destinationDirectory == rhs.destinationDirectory
            && lhs.excludedWindowIDs == rhs.excludedWindowIDs
            && lhs.sourceDimensions == rhs.sourceDimensions
    }

    public func hash(into hasher: inout Hasher) {
        switch source {
        case .display(let displayID):
            hasher.combine(0)
            hasher.combine(displayID)
        case .window(let windowID):
            hasher.combine(1)
            hasher.combine(windowID)
        case .region(let displayID, let sourceRect):
            hasher.combine(2)
            hasher.combine(displayID)
            hasher.combine(sourceRect.origin.x)
            hasher.combine(sourceRect.origin.y)
            hasher.combine(sourceRect.width)
            hasher.combine(sourceRect.height)
        }
        hasher.combine(video.codec.rawValue)
        hasher.combine(video.resolutionLimit.width)
        hasher.combine(video.resolutionLimit.height)
        hasher.combine(video.frameRateLimit)
        hasher.combine(video.averageVideoBitrate)
        hasher.combine(video.maximumKeyFrameIntervalSeconds)
        hasher.combine(video.capturesSystemAudio)
        hasher.combine(audio)
        hasher.combine(destinationDirectory)
        hasher.combine(excludedWindowIDs)
        if let sourceDimensions {
            hasher.combine(true)
            hasher.combine(sourceDimensions.width)
            hasher.combine(sourceDimensions.height)
        } else {
            hasher.combine(false)
        }
    }
}

/// A screen segment coordinator and its stable audio-checkpoint facade.
public struct ScreenSegmentComposition: Sendable {
    /// Coordinates screen-video boundaries and sealing.
    public let coordinator: ScreenSegmentCoordinator
    /// Sink retained by the audio engine across visible-segment rotations.
    public let audioSink: any AudioCheckpointSink & Sendable

    /// Creates a screen composition.
    public init(
        coordinator: ScreenSegmentCoordinator,
        audioSink: any AudioCheckpointSink & Sendable
    ) {
        self.coordinator = coordinator
        self.audioSink = audioSink
    }
}

/// The outcome of stopping and publishing a screen-recording session.
public struct ScreenRecordingOutcome: Sendable, Hashable {
    /// Identity of the screen-recording session.
    public let sessionID: UUID
    /// Published MP4 URLs in segment order.
    public let segmentURLs: [URL]
    /// Total frames dropped by bounded video backpressure and writer rejection.
    public let droppedFrameCount: Int64
    /// A failure summary when finalization was incomplete.
    public let failure: String?
    /// Why the audio track could not start, when it could not.
    ///
    /// Non-fatal: the video is published normally and the app shows a warning.
    public let audioFailure: String?
    /// Per-stage drop counts; `total` always equals ``droppedFrameCount``.
    public let dropAccounting: ScreenRecordingDropAccounting

    /// Creates a screen-recording outcome.
    ///
    /// - Parameters:
    ///   - sessionID: Identity of the screen-recording session.
    ///   - segmentURLs: Published MP4 URLs in segment order.
    ///   - droppedFrameCount: Total dropped frames.
    ///   - failure: A failure summary when finalization was incomplete.
    ///   - audioFailure: Why the audio track could not start, when it could not.
    ///   - dropAccounting: Per-stage counts. When omitted, the legacy total is
    ///     treated as capture-callback drops so old call sites keep their meaning.
    public init(
        sessionID: UUID,
        segmentURLs: [URL],
        droppedFrameCount: Int64,
        failure: String?,
        audioFailure: String? = nil,
        dropAccounting: ScreenRecordingDropAccounting? = nil
    ) {
        let accounting = dropAccounting
            ?? ScreenRecordingDropAccounting(
                captureCallbackDrops: droppedFrameCount,
                frameStreamDrops: 0,
                writerDrops: 0
            )
        self.sessionID = sessionID
        self.segmentURLs = segmentURLs
        self.droppedFrameCount = accounting.total
        self.failure = failure
        self.audioFailure = audioFailure
        self.dropAccounting = accounting
    }

    /// The most recently published segment, when one exists.
    public var latestPublishedURL: URL? { segmentURLs.last }

    /// Whether at least one segment was published without a reported failure.
    public var isSaved: Bool { failure == nil && !segmentURLs.isEmpty }
}

/// Errors raised while coordinating a screen-recording session.
public enum ScreenRecordingSessionCoordinatorError: LocalizedError, Equatable, Sendable {
    /// A screen session is already active or awaiting finalization.
    case alreadyStarted
    /// No screen session has been started.
    case notStarted
    /// No video segment was published.
    case noPublishedSegments
    /// The selected configuration cannot be composed.
    case invalidConfiguration
    /// Audio finalization failed after capture stopped.
    case audioFinalizationFailed(String)
    /// The capture stream could not be confirmed stopped, so files were left unfinalized.
    case streamStopUnconfirmed

    public var errorDescription: String? {
        switch self {
        case .alreadyStarted:
            "A screen-recording session is already active."
        case .notStarted:
            "The screen-recording session is unavailable."
        case .noPublishedSegments:
            "The screen recording did not publish a video segment."
        case .invalidConfiguration:
            "The screen-recording configuration is invalid."
        case .audioFinalizationFailed(let reason):
            "Screen-recording audio could not be finalized: \(reason)"
        case .streamStopUnconfirmed:
            "The capture stream did not confirm it stopped; the recording files were kept as they are."
        }
    }
}

struct ScreenVideoFrameEvent: @unchecked Sendable {
    let sampleBuffer: CMSampleBuffer
    let hostTime: UInt64
}

/// Coordinates one SCK video stream, its screen segments, and T6 audio capture.
public actor ScreenRecordingSessionCoordinator {
    private let engine: ScreenRecordingEngine
    private let segmentCompositionFactory:
        @Sendable (ScreenRecordingStartConfiguration) throws -> ScreenSegmentComposition
    // Session state below is `internal` because the frame pipeline and its failure
    // bookkeeping live in `ScreenRecordingSessionCoordinator+FramePipeline.swift`.
    let audioEngineFactory: @Sendable (
        AudioRecordingConfiguration,
        any AudioCheckpointSink & Sendable,
        AudioSampleClock
    ) throws -> any AudioRecordingControlling & Sendable
    private let audio: ScreenAudioBridge

    var configuration: ScreenRecordingStartConfiguration?
    var composition: ScreenSegmentComposition?
    var audioEngine: (any AudioRecordingControlling & Sendable)?
    private var frameContinuation: AsyncStream<ScreenVideoFrameEvent>.Continuation?
    private var frameTask: Task<Void, Never>?
    var tickTask: Task<Void, Never>?
    var onFailure: (@Sendable (String) -> Void)?
    var processingFailure: String?
    /// The first audio failure for this session, when the audio track could not start.
    ///
    /// Audio is optional for a screen recording: the video keeps recording and the
    /// user is told the audio was not captured instead of losing the whole take.
    var audioFailureReason: String?
    private var lastOutcome: ScreenRecordingOutcome?
    var isStopping = false
    let frameStreamDropCounter = ScreenRecordingDropCounter()
    let logger = Logger(subsystem: "com.snapglass", category: "screen.session")

    /// Creates a coordinator around the existing screen stream engine.
    public init(
        engine: ScreenRecordingEngine,
        segmentCompositionFactory:
            @escaping @Sendable (ScreenRecordingStartConfiguration) throws -> ScreenSegmentComposition,
        audioEngineFactory: @escaping @Sendable (
            AudioRecordingConfiguration,
            any AudioCheckpointSink & Sendable,
            AudioSampleClock
        ) throws -> any AudioRecordingControlling & Sendable,
        audio: ScreenAudioBridge
    ) {
        self.engine = engine
        self.segmentCompositionFactory = segmentCompositionFactory
        self.audioEngineFactory = audioEngineFactory
        self.audio = audio
    }

    /// Creates the production screen composition using the shared capture roots.
    ///
    /// - Parameters:
    ///   - engine: The ScreenCaptureKit engine for this session.
    ///   - roots: Ledger and destination roots.
    ///   - audioEngineFactoryOverride: Test/agent-only seam that replaces the real
    ///     audio engine factory. Production passes `nil`; the agent channel uses it
    ///     to prove that an audio-start failure never truncates the video.
    /// - Returns: A coordinator wired for one screen session.
    /// - Throws: ``RecordingPipelineError`` or a file-system error while creating the roots.
    public static func makeProduction(
        engine: ScreenRecordingEngine,
        roots: RecordingPipelineRoots,
        audioEngineFactoryOverride: (@Sendable (
            AudioRecordingConfiguration,
            any AudioCheckpointSink & Sendable,
            AudioSampleClock
        ) throws -> any AudioRecordingControlling & Sendable)? = nil
    ) throws -> ScreenRecordingSessionCoordinator {
        let ticksPerSecond = AudioSourceTimestampMapper.nativeHostTicksPerSecond()
        let systemRing = try AudioSourceRingBuffer(
            role: .system,
            sampleRate: 48_000,
            channelCount: 2,
            hostTicksPerSecond: ticksPerSecond
        )
        let bridge = ScreenAudioBridge(
            systemRing: systemRing,
            microphoneRing: nil,
            hostTicksPerSecond: ticksPerSecond
        )
        let compositionFactory: @Sendable (ScreenRecordingStartConfiguration) throws -> ScreenSegmentComposition = {
            try makeComposition(configuration: $0, roots: roots)
        }
        let audioFactory: @Sendable (
            AudioRecordingConfiguration,
            any AudioCheckpointSink & Sendable,
            AudioSampleClock
        ) throws -> any AudioRecordingControlling & Sendable = { configuration, sink, clock in
            try makeAudioEngine(
                configuration: configuration,
                sink: sink,
                clock: clock,
                systemRing: systemRing,
                hostTicksPerSecond: ticksPerSecond
            )
        }
        return ScreenRecordingSessionCoordinator(
            engine: engine,
            segmentCompositionFactory: compositionFactory,
            audioEngineFactory: audioEngineFactoryOverride ?? audioFactory,
            audio: bridge
        )
    }

    /// Creates the segment journal, stable audio sink, and first video stream.
    public func start(
        _ configuration: ScreenRecordingStartConfiguration,
        onFailure: @escaping @Sendable (String) -> Void
    ) async throws {
        guard self.configuration == nil, !isStopping else {
            throw ScreenRecordingSessionCoordinatorError.alreadyStarted
        }
        try validateStartConfiguration(configuration)
        let composition = try await makeRegisteredComposition(configuration)

        let queue = AsyncStream.makeStream(
            of: ScreenVideoFrameEvent.self,
            bufferingPolicy: .bufferingNewest(3)
        )
        self.configuration = configuration
        self.composition = composition
        self.onFailure = onFailure
        frameContinuation = queue.continuation
        frameTask = Task { [weak self] in
            for await event in queue.stream {
                guard let self else { return }
                await self.consume(event)
            }
        }
        await engine.installSegmentedRetryHandler { [weak self] in
            guard let self else { throw ScreenRecordingSessionCoordinatorError.notStarted }
            return try await self.retryPublish()
        }

        try await startVideoCapture(
            configuration: configuration,
            continuation: queue.continuation,
            onFailure: onFailure
        )
        startBoundaryTicks()
    }

    /// Checks the audio and video fields the segment and audio writers require.
    private func validateStartConfiguration(
        _ configuration: ScreenRecordingStartConfiguration
    ) throws {
        guard configuration.audio.kind == .screen,
              configuration.audio.layout == .separateTracks,
              configuration.audio.sampleRate == 48_000,
              configuration.video.frameRateLimit > 0,
              configuration.destinationDirectory.isFileURL
        else { throw ScreenRecordingSessionCoordinatorError.invalidConfiguration }
    }

    /// Builds the first composition and registers it with the session journal.
    private func makeRegisteredComposition(
        _ configuration: ScreenRecordingStartConfiguration
    ) async throws -> ScreenSegmentComposition {
        let composition = try segmentCompositionFactory(configuration)
        try await composition.coordinator.registerSession(
            kind: .screen,
            layout: .separateTracks
        )
        await composition.coordinator.configureSealContext(RecordingSealContext(
            sessionID: composition.coordinator.sessionID,
            kind: .screen,
            layout: .separateTracks,
            sampleRate: configuration.audio.sampleRate,
            outputStem: "Recording-\(composition.coordinator.sessionID.uuidString.lowercased())",
            destinationDirectory: configuration.destinationDirectory,
            bitRate: configuration.audio.bitRate
        ))
        return composition
    }

    /// Starts the shared capture stream and unwinds the stream state on a failed start.
    private func startVideoCapture(
        configuration: ScreenRecordingStartConfiguration,
        continuation: AsyncStream<ScreenVideoFrameEvent>.Continuation,
        onFailure: @escaping @Sendable (String) -> Void
    ) async throws {
        let reuseAudio = configuration.audio.mode == .system
            || configuration.audio.mode == .systemAndMicrophone
            ? ScreenAudioOutputReuse(bridge: audio)
            : nil
        do {
            try await engine.startSegmented(
                configuration,
                audioOutputReuse: reuseAudio,
                onVideoFrame: { sampleBuffer, hostTime in
                    switch continuation.yield(
                        ScreenVideoFrameEvent(sampleBuffer: sampleBuffer, hostTime: hostTime)
                    ) {
                    case .enqueued:
                        .accepted
                    case .dropped:
                        // The capture callback owns this eviction count exactly once.
                        .streamDrop
                    case .terminated:
                        // Normal stream shutdown is not backpressure.
                        .ignored
                    @unknown default:
                        .ignored
                    }
                },
                onFailure: { [logger] reason in
                    logger.error("screen.session capture failure: \(reason)")
                    onFailure(reason)
                }
            )
        } catch {
            continuation.finish()
            await frameTask?.value
            frameTask = nil
            frameContinuation = nil
            await engine.installSegmentedRetryHandler(nil)
            // A failed start that could not confirm its stream stopped is reported
            // as such: the caller must keep this adapter and confirm the stop
            // before any new stream is allowed. The journal and composition are
            // kept so that confirmation can still finalize what was written.
            if await engine.hasUnconfirmedStream {
                throw ScreenRecordingSessionCoordinatorError.streamStopUnconfirmed
            }
            self.configuration = nil
            self.composition = nil
            self.onFailure = nil
            throw error
        }
    }

    /// Whether the active video writer has accepted at least one frame.
    ///
    /// Forwards the segment coordinator's writer-level signal. Queue acceptance
    /// in the capture engine is not enough because frames can still be dropped
    /// before they reach `AVAssetWriterInput`.
    public func hasWrittenVideoFrame() async -> Bool {
        guard let composition else { return false }
        return await composition.coordinator.hasWrittenVideoFrame
    }

    /// Whether the capture callback ever accepted a video sample for this session.
    ///
    /// This is the queue-level fact used only to classify a failed first-frame
    /// gate into "no frames arrived" versus "the writer never accepted a frame".
    public func hasAcceptedCaptureFrame() async -> Bool {
        await engine.hasAcceptedVideoFrame
    }

    /// The first capture or writer failure reported for this session, if any.
    public func failureDescription() async -> String? {
        if let processingFailure { return processingFailure }
        return await engine.segmentedFailureDescription()
    }

    /// The session's material directory, used for an actionable recovery hint.
    ///
    /// Read-only: the coordinator never moves or deletes these files.
    public func materialRoot() -> URL? {
        composition?.coordinator.materialRoot
    }

    /// Why the writer could not accept its first frame, when it reported a failure.
    ///
    /// Used by the first-frame readiness poll so a real writer failure ends the wait
    /// immediately with its own reason instead of a generic five-second timeout.
    public func writerFailureDescription() async -> String? {
        if let processingFailure { return processingFailure }
        guard let composition else { return nil }
        let diagnostics = await composition.coordinator.writerDiagnostics()
        let failed = diagnostics.startWritingResult == .failed
            || diagnostics.syncDropCount > 0
            || diagnostics.appendFailureCount > 0
        guard failed else { return nil }
        return diagnostics.lastErrorDescription
            ?? "The video writer failed before the recording started."
    }

    /// Privacy-safe writer counters for this session, or `nil` before it starts.
    public func writerDiagnostics() async -> ScreenWriterDiagnostics? {
        guard let composition else { return nil }
        var diagnostics = await composition.coordinator.writerDiagnostics()
        // Session-level facts travel with the writer counters so every consumer
        // (failure copy, agent report) sees them together.
        diagnostics.audioFailureReason = audioFailureReason
        return diagnostics
    }

    /// Why the screen audio track could not start, when it could not.
    public func audioFailureDescription() -> String? { audioFailureReason }

    /// Frames the frame task consumed but could not append to a segment writer.
    ///
    /// This is the consumer stage only; evictions observed at `yield` belong to
    /// the capture callback's count and are never added here again.
    public nonisolated func frameStreamDroppedCount() -> Int64 {
        frameStreamDropCounter.value
    }

    /// Stops the shared stream, drains audio, seals the final segment, and returns published URLs.
    ///
    /// The order is fixed: the stream stop must be confirmed before any file is
    /// finalized. An unconfirmed stop throws ``ScreenRecordingSessionCoordinatorError/streamStopUnconfirmed``
    /// and deliberately leaves the journal, frame stream, and composition in place
    /// so a later attempt can confirm the stop first.
    public func stopAndSave() async throws -> ScreenRecordingOutcome {
        if let lastOutcome { return lastOutcome }
        guard configuration != nil, let composition else {
            throw ScreenRecordingSessionCoordinatorError.notStarted
        }
        guard !isStopping else { throw ScreenRecordingSessionCoordinatorError.alreadyStarted }
        isStopping = true
        defer { isStopping = false }

        tickTask?.cancel()
        await tickTask?.value
        tickTask = nil
        let stop = await engine.stopSegmentedCapture()
        guard stop.confirmed else {
            recordFailure(
                ScreenRecordingSessionCoordinatorError.streamStopUnconfirmed.localizedDescription
            )
            throw ScreenRecordingSessionCoordinatorError.streamStopUnconfirmed
        }
        let streamDroppedFrames = stop.droppedFrames
        frameContinuation?.finish()
        frameContinuation = nil
        await frameTask?.value
        frameTask = nil

        let audioResult = await audioEngine?.stop()
        audioEngine = nil
        do {
            _ = try await composition.coordinator.closeSegment()
            let urls = try await composition.coordinator.publishedVideoURLs()
            guard !urls.isEmpty else { throw ScreenRecordingSessionCoordinatorError.noPublishedSegments }
            let engineFailure = await engine.segmentedFailureDescription()
            let failure = processingFailure
                ?? audioResult?.failure
                ?? engineFailure
            let dropAccounting = ScreenRecordingDropAccounting(
                captureCallbackDrops: streamDroppedFrames,
                frameStreamDrops: frameStreamDroppedCount(),
                writerDrops: await composition.coordinator.droppedVideoFrameCount()
            )
            let outcome = ScreenRecordingOutcome(
                sessionID: composition.coordinator.sessionID,
                segmentURLs: urls,
                droppedFrameCount: dropAccounting.total,
                failure: failure,
                audioFailure: audioFailureReason,
                dropAccounting: dropAccounting
            )
            lastOutcome = outcome
            logger.info("screen.session stop published=\(urls.count) writerDrops=\(dropAccounting.writerDrops)")
            if failure == nil {
                try await engine.finishSegmentedSession()
                await engine.installSegmentedRetryHandler(nil)
            } else {
                await engine.failSegmentedSession()
            }
            return outcome
        } catch {
            logger.error("screen.session stop failed: \(error.localizedDescription)")
            await engine.failSegmentedSession()
            throw error
        }
    }

    /// Retries a pending screen seal or returns the latest already-published segment.
    public func retryPublish() async throws -> URL {
        if let lastOutcome {
            guard let url = lastOutcome.latestPublishedURL else {
                throw ScreenRecordingSessionCoordinatorError.audioFinalizationFailed(
                    lastOutcome.failure
                        ?? ScreenRecordingSessionCoordinatorError.noPublishedSegments.localizedDescription
                )
            }
            try await engine.finishSegmentedSession()
            await engine.installSegmentedRetryHandler(nil)
            return url
        }
        guard let composition else { throw ScreenRecordingSessionCoordinatorError.notStarted }
        _ = try await composition.coordinator.closeSegment()
        guard let url = try await composition.coordinator.publishedVideoURLs().last else {
            throw ScreenRecordingSessionCoordinatorError.noPublishedSegments
        }
        let urls = try await composition.coordinator.publishedVideoURLs()
        let dropAccounting = ScreenRecordingDropAccounting(
            captureCallbackDrops: await engine.captureCallbackDroppedCount(),
            frameStreamDrops: frameStreamDroppedCount(),
            writerDrops: await composition.coordinator.droppedVideoFrameCount()
        )
        lastOutcome = ScreenRecordingOutcome(
            sessionID: composition.coordinator.sessionID,
            segmentURLs: urls,
            droppedFrameCount: dropAccounting.total,
            failure: nil,
            audioFailure: audioFailureReason,
            dropAccounting: dropAccounting
        )
        try await engine.finishSegmentedSession()
        await engine.installSegmentedRetryHandler(nil)
        return url
    }
}

final class ScreenRingAudioFrameSource: AudioFrameSource, @unchecked Sendable {
    let role: RecordingTrackRole = .system
    private let ring: AudioSourceRingBuffer
    private let generation: AudioSourceGeneration
    private let lock = NSLock()
    private var stopped = false
    private let logger = Logger(subsystem: "com.snapglass", category: "screen.audio")

    init(ring: AudioSourceRingBuffer, hostTicksPerSecond: UInt64) {
        self.ring = ring
        generation = AudioSourceGeneration(
            role: .system,
            format: AudioSourceFormat(sampleRate: 48_000, channelCount: 2),
            ringBuffer: ring
        )
        _ = hostTicksPerSecond
    }

    func currentGeneration() async -> AudioSourceGeneration { generation }
    func start() async throws {}

    func isRunning() async -> Bool {
        !isStopped()
    }

    private func isStopped() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func stop() async {
        guard markStopped() else { return }
        ring.requestClose()
        _ = ring.finishProducing()
    }

    private func markStopped() -> Bool {
        lock.lock()
        let shouldClose = !stopped
        stopped = true
        lock.unlock()
        return shouldClose
    }

    func isProducerJoined() async -> Bool { true }

    func prepareReconfiguration(_ event: AudioDeviceChangeEvent) async -> AudioSourcePreparation {
        // The shared SCK stream owns the format, so there is nothing to prepare.
        logger.info("screen.audio prepare reconfiguration unchanged: stream-owned format")
        return .unchangedOnFailure(reason: "screen audio uses the active SCK stream")
    }

    /// Commits the ring generation the route controller prepared.
    ///
    /// The screen source has exactly one generation, created with its ring buffer
    /// when the SCK stream was attached. `AudioRouteController` still calls this for
    /// the initial commit, so returning `false` here failed every screen recording
    /// with "initial route commit failed" before any audio was written.
    ///
    /// - Parameter generation: The generation returned by ``currentGeneration()``.
    /// - Returns: `true` when it is this source's own generation and the source is
    ///   still running.
    func commitReconfiguration(_ generation: AudioSourceGeneration) async -> Bool {
        let matches = generation.id == self.generation.id
        let running = !isStopped()
        logger.info("screen.audio commit generation matches=\(matches) running=\(running)")
        return matches && running
    }
}
