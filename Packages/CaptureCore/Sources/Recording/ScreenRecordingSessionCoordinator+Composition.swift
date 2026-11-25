import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation

extension ScreenRecordingSessionCoordinator {
    static func makeComposition(
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

        let videoFactory = makeVideoWriterFactory(
            sessionRoot: sessionRoot,
            configuration: configuration,
            dimensions: videoDimensions
        )
        let audioFactory = makeAudioSinkFactory(
            sessionRoot: sessionRoot,
            audio: configuration.audio,
            roles: roles,
            plannerReference: plannerReference
        )
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

    static func makeAudioEngine(
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
                  format.channelCount == 1 || format.channelCount == 2,
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

    /// Builds the per-boundary video chunk writer factory for one session root.
    private static func makeVideoWriterFactory(
        sessionRoot: URL,
        configuration: ScreenRecordingStartConfiguration,
        dimensions: CGSize
    ) -> @Sendable (ScreenBoundary) throws -> ScreenVideoWriterBridge {
        { boundary in
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
                dimensions: dimensions
            )
        }
    }

    /// Builds the per-boundary checkpoint sink factory for one session root.
    private static func makeAudioSinkFactory(
        sessionRoot: URL,
        audio: AudioRecordingConfiguration,
        roles: Set<RecordingTrackRole>,
        plannerReference: ScreenSegmentPlannerReference
    ) -> @Sendable (ScreenBoundary) throws -> any SegmentCheckpointSink {
        { boundary in
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
                sampleRate: audio.sampleRate,
                roles: roles
            )
        }
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
