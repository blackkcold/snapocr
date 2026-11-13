import AVFoundation
import AudioToolbox
import CoreGraphics
import CoreMedia
import Foundation

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
    /// Frames dropped by bounded video backpressure.
    public let droppedFrameCount: Int64
    /// A failure summary when finalization was incomplete.
    public let failure: String?

    /// Creates a screen-recording outcome.
    public init(
        sessionID: UUID,
        segmentURLs: [URL],
        droppedFrameCount: Int64,
        failure: String?
    ) {
        self.sessionID = sessionID
        self.segmentURLs = segmentURLs
        self.droppedFrameCount = droppedFrameCount
        self.failure = failure
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
        }
    }
}

private struct ScreenVideoFrameEvent: @unchecked Sendable {
    let sampleBuffer: CMSampleBuffer
    let hostTime: UInt64
}

/// Coordinates one SCK video stream, its screen segments, and T6 audio capture.
public actor ScreenRecordingSessionCoordinator {
    private let engine: ScreenRecordingEngine
    private let segmentCompositionFactory: @Sendable (ScreenRecordingStartConfiguration) throws -> ScreenSegmentComposition
    private let audioEngineFactory: @Sendable (
        AudioRecordingConfiguration,
        any AudioCheckpointSink & Sendable,
        AudioSampleClock
    ) throws -> any AudioRecordingControlling & Sendable
    private let audio: ScreenAudioBridge

    private var configuration: ScreenRecordingStartConfiguration?
    private var composition: ScreenSegmentComposition?
    private var audioEngine: (any AudioRecordingControlling & Sendable)?
    private var frameContinuation: AsyncStream<ScreenVideoFrameEvent>.Continuation?
    private var frameTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var onFailure: (@Sendable (String) -> Void)?
    private var processingFailure: String?
    private var lastOutcome: ScreenRecordingOutcome?
    private var isStopping = false

    /// Creates a coordinator around the existing screen stream engine.
    public init(
        engine: ScreenRecordingEngine,
        segmentCompositionFactory: @escaping @Sendable (ScreenRecordingStartConfiguration) throws -> ScreenSegmentComposition,
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
    public static func makeProduction(
        engine: ScreenRecordingEngine,
        roots: RecordingPipelineRoots
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
            audioEngineFactory: audioFactory,
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
        guard configuration.audio.kind == .screen,
              configuration.audio.layout == .separateTracks,
              configuration.audio.sampleRate == 48_000,
              configuration.video.frameRateLimit > 0,
              configuration.destinationDirectory.isFileURL
        else { throw ScreenRecordingSessionCoordinatorError.invalidConfiguration }

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

        let reuseAudio = configuration.audio.mode == .system
            || configuration.audio.mode == .systemAndMicrophone
            ? ScreenAudioOutputReuse(bridge: audio)
            : nil
        do {
            try await engine.startSegmented(
                configuration,
                audioOutputReuse: reuseAudio,
                onVideoFrame: { sampleBuffer, hostTime in
                    switch queue.continuation.yield(ScreenVideoFrameEvent(sampleBuffer: sampleBuffer, hostTime: hostTime)) {
                    case .enqueued:
                        true
                    case .dropped, .terminated:
                        false
                    @unknown default:
                        false
                    }
                },
                onFailure: onFailure
            )
        } catch {
            queue.continuation.finish()
            await frameTask?.value
            frameTask = nil
            frameContinuation = nil
            self.configuration = nil
            self.composition = nil
            self.onFailure = nil
            await engine.installSegmentedRetryHandler(nil)
            throw error
        }
        startBoundaryTicks()
    }

    /// Stops the shared stream, drains audio, seals the final segment, and returns published URLs.
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
        let streamDroppedFrames = await engine.stopSegmentedCapture()
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
            let outcome = ScreenRecordingOutcome(
                sessionID: composition.coordinator.sessionID,
                segmentURLs: urls,
                droppedFrameCount: streamDroppedFrames + (await composition.coordinator.droppedVideoFrameCount()),
                failure: failure
            )
            lastOutcome = outcome
            if failure == nil {
                try await engine.finishSegmentedSession()
                await engine.installSegmentedRetryHandler(nil)
            } else {
                await engine.failSegmentedSession()
            }
            return outcome
        } catch {
            await engine.failSegmentedSession()
            throw error
        }
    }

    /// Retries a pending screen seal or returns the latest already-published segment.
    public func retryPublish() async throws -> URL {
        if let lastOutcome {
            guard let url = lastOutcome.latestPublishedURL else {
                throw ScreenRecordingSessionCoordinatorError.audioFinalizationFailed(
                    lastOutcome.failure ?? ScreenRecordingSessionCoordinatorError.noPublishedSegments.localizedDescription
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
        lastOutcome = ScreenRecordingOutcome(
            sessionID: composition.coordinator.sessionID,
            segmentURLs: urls,
            droppedFrameCount: await composition.coordinator.droppedVideoFrameCount(),
            failure: nil
        )
        try await engine.finishSegmentedSession()
        await engine.installSegmentedRetryHandler(nil)
        return url
    }

    private func consume(_ event: ScreenVideoFrameEvent) async {
        guard let configuration, let composition, processingFailure == nil else { return }
        do {
            try await composition.coordinator.append(video: event.sampleBuffer, at: event.hostTime)
            guard audioEngine == nil, configuration.audio.mode != .none,
                  let epoch = await composition.coordinator.recordingEpochHostTime() else { return }
            let clock = AudioSampleClock(
                epochHostTime: epoch,
                hostTicksPerSecond: AudioSourceTimestampMapper.nativeHostTicksPerSecond(),
                sampleRate: configuration.audio.sampleRate
            )
            let engine = try audioEngineFactory(configuration.audio, composition.audioSink, clock)
            try await engine.start(configuration.audio)
            audioEngine = engine
        } catch {
            recordFailure(error.localizedDescription)
        }
    }

    private func startBoundaryTicks() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            let clock = ContinuousClock()
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.advanceBoundaryTick()
            }
        }
    }

    private func advanceBoundaryTick() async {
        guard !isStopping, processingFailure == nil, let composition else { return }
        do {
            try await composition.coordinator.tick(hostTime: AudioGetCurrentHostTime())
        } catch {
            recordFailure(error.localizedDescription)
        }
    }

    private func recordFailure(_ reason: String) {
        guard processingFailure == nil else { return }
        processingFailure = reason
        onFailure?(reason)
    }

    private static func makeComposition(
        configuration: ScreenRecordingStartConfiguration,
        roots: RecordingPipelineRoots
    ) throws -> ScreenSegmentComposition {
        let sessionID = UUID()
        let recordingRoot = try RecordingLedgerFileSystem.canonicalDirectory(roots.sessionRoot, create: true)
        let sessionsRoot = try RecordingLedgerFileSystem.canonicalDirectory(
            recordingRoot.appendingPathComponent(".SnapGlassSessions", isDirectory: true),
            create: true
        )
        let sessionRoot = sessionsRoot.appendingPathComponent(sessionID.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: sessionRoot, withIntermediateDirectories: false)
        let ledger = try RecordingSessionLedger(
            sessionRoot: sessionRoot,
            indexURL: roots.indexURL,
            sessionID: sessionID
        )
        let planner = try VideoSegmentPlanner(frameRate: configuration.video.frameRateLimit)
        let plannerReference = ScreenSegmentPlannerReference(planner: planner)
        let roles = Set(configuration.audio.channelCountByRole.keys.filter {
            $0 == .system || $0 == .microphone
        })
        let videoDimensions = configuration.video.validatedEvenOutputDimensions(
            for: configuration.sourceDimensions ?? configuration.video.resolutionLimit
        ) ?? configuration.video.resolutionLimit

        let videoFactory: @Sendable (ScreenBoundary) throws -> ScreenVideoWriterBridge = { boundary in
            let segmentRoot = sessionRoot.appendingPathComponent(
                String(format: "segment-%08d", boundary.segmentIndex),
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: segmentRoot, withIntermediateDirectories: true)
            let url = segmentRoot.appendingPathComponent(
                String(format: "chunk-%08d.mp4", boundary.chunkIndex)
            )
            return try ScreenVideoWriterBridge(
                destinationURL: url,
                configuration: configuration.video,
                dimensions: videoDimensions
            )
        }
        let audioFactory: @Sendable (ScreenBoundary) throws -> any SegmentCheckpointSink = { boundary in
            let startSample: Int64
            if let epoch = plannerReference.recordingEpoch {
                let delta = CMTimeSubtract(boundary.startTime, epoch)
                let value = CMTimeConvertScale(delta, timescale: 48_000, method: .roundTowardZero)
                guard value.isValid, value.isNumeric, value.value >= 0 else {
                    throw ScreenRecordingSessionCoordinatorError.invalidConfiguration
                }
                startSample = value.value
            } else {
                startSample = 0
            }
            let (endSample, overflow) = startSample.addingReportingOverflow(3_540 * 48_000)
            guard !overflow else { throw ScreenRecordingSessionCoordinatorError.invalidConfiguration }
            let segmentBoundary = SegmentBoundary(
                index: boundary.segmentIndex,
                startSample: startSample,
                endSample: endSample
            )
            guard !roles.isEmpty else { return ScreenNoAudioSegmentSink(segmentBoundary: segmentBoundary) }
            let segmentRoot = sessionRoot.appendingPathComponent(
                String(format: "segment-%08d", boundary.segmentIndex),
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: segmentRoot, withIntermediateDirectories: true)
            return try RecordingCheckpointWriter(
                directory: segmentRoot,
                sessionRoot: sessionRoot,
                segment: segmentBoundary,
                sampleRate: configuration.audio.sampleRate,
                roles: roles
            )
        }
        let seal = ScreenSegmentSealService(
            publicationHooks: [LedgerPublicationHook(ledger: ledger)]
        )
        let coordinator = ScreenSegmentCoordinator(
            planner: planner,
            videoWriterFactory: videoFactory,
            audioSinkFactory: audioFactory,
            ledger: ledger,
            seal: seal
        )
        return ScreenSegmentComposition(coordinator: coordinator, audioSink: coordinator)
    }

    private static func makeAudioEngine(
        configuration: AudioRecordingConfiguration,
        sink: any AudioCheckpointSink & Sendable,
        clock: AudioSampleClock,
        systemRing: AudioSourceRingBuffer,
        hostTicksPerSecond: UInt64
    ) throws -> any AudioRecordingControlling & Sendable {
        guard configuration.kind == .screen,
              configuration.mode != .none,
              configuration.layout == .separateTracks,
              configuration.sampleRate == 48_000
        else { throw ScreenRecordingSessionCoordinatorError.invalidConfiguration }

        let system = ScreenRingAudioFrameSource(ring: systemRing, hostTicksPerSecond: hostTicksPerSecond)
        var sources: [RecordingTrackRole: any AudioFrameSource] = [.system: system]
        if configuration.mode == .microphone || configuration.mode == .systemAndMicrophone {
            let authorizer = AVMicrophoneAuthorizer()
            let capture = AVAudioEngineMicrophoneCaptureEngine()
            guard let format = capture.currentFormat,
                  format.commonFormat == .pcmFormatFloat32,
                  (format.channelCount == 1 || format.channelCount == 2),
                  format.sampleRate.isFinite,
                  format.sampleRate > 0 else {
                throw AudioSourceError.invalidFormat
            }
            let sourceFormat = AudioSourceFormat(
                sampleRate: Int(format.sampleRate.rounded()),
                channelCount: Int(format.channelCount)
            )
            let microphoneRing = try AudioSourceRingBuffer(
                role: .microphone,
                sampleRate: sourceFormat.sampleRate,
                channelCount: sourceFormat.channelCount,
                hostTicksPerSecond: hostTicksPerSecond
            )
            sources[.microphone] = MicrophoneSource(
                ringBuffer: microphoneRing,
                authorizer: authorizer,
                engine: capture,
                deviceMonitor: CoreAudioDeviceChangeMonitor(),
                format: sourceFormat,
                hostTicksPerSecond: hostTicksPerSecond
            )
        }
        let authorizer = AVMicrophoneAuthorizer()
        let routeController = AudioRouteController(authorizer: authorizer, sources: sources)
        let pump = AudioMixPump(
            clock: clock,
            policy: AudioMixPolicy(sampleRate: configuration.sampleRate),
            layout: configuration.layout,
            blockFrames: 480,
            channelCountByRole: configuration.channelCountByRole
        )
        return AudioRecordingEngine(
            sink: sink,
            clock: clock,
            sources: sources,
            routeController: routeController,
            pump: pump
        )
    }
}

/// Sendability bridge for the epoch read performed by a factory owned by `ScreenSegmentCoordinator`.
/// The closure is only invoked from that actor, which serializes all access with planner mutation.
private final class ScreenSegmentPlannerReference: @unchecked Sendable {
    private let planner: VideoSegmentPlanner

    init(planner: VideoSegmentPlanner) {
        self.planner = planner
    }

    var recordingEpoch: CMTime? { planner.recordingEpoch }
}

private struct ScreenNoAudioSegmentSink: SegmentCheckpointSink {
    let segmentBoundary: SegmentBoundary

    func append(_ block: AudioPCMBlock) async throws {
        throw RecordingCheckpointError.invalidConfiguration
    }

    func commitCheckpoint() async throws -> CheckpointCommit {
        throw RecordingCheckpointError.emptyCheckpoint
    }

    func finishSegment() async throws -> SegmentCheckpointSet {
        SegmentCheckpointSet(segmentIndex: segmentBoundary.index, checkpoints: [])
    }

    func finishSegmentBundle() async throws -> RecordingSegmentCheckpointBundle {
        RecordingSegmentCheckpointBundle(
            checkpoints: SegmentCheckpointSet(segmentIndex: segmentBoundary.index, checkpoints: []),
            coverage: RecordingSegmentCoverage(
                segmentIndex: segmentBoundary.index,
                segmentStartSample: segmentBoundary.startSample,
                segmentEndSample: segmentBoundary.endSample,
                tracks: []
            )
        )
    }
}

private final class ScreenRingAudioFrameSource: AudioFrameSource, @unchecked Sendable {
    let role: RecordingTrackRole = .system
    private let ring: AudioSourceRingBuffer
    private let generation: AudioSourceGeneration
    private let lock = NSLock()
    private var stopped = false

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
        .unchangedOnFailure(reason: "screen audio uses the active SCK stream")
    }

    func commitReconfiguration(_ generation: AudioSourceGeneration) async -> Bool { false }
}
