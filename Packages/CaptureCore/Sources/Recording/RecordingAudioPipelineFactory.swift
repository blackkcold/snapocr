import Foundation

/// Builds the audio-only recording pipeline used by system and microphone capture.
public enum RecordingAudioPipelineFactory {
    /// Creates a recording session with its ledger, checkpoint writer, seal service, and engine.
    ///
    /// The configuration must be audio-only at 48 kHz with at least one active
    /// role. Session and output directories are created when missing, and the
    /// resulting pipeline owns the native audio sources for the configured layout.
    ///
    /// - Parameters:
    ///   - configuration: Audio-only recording settings.
    ///   - roots: Session, index, and output locations.
    ///   - spaceGate: Optional free-space policy checked before and during capture.
    ///   - fileManager: File manager for session directories and ledger files.
    /// - Returns: A pipeline ready to start.
    /// - Throws: `RecordingPipelineError.invalidConfiguration` when the
    ///   configuration is unsupported or its directories cannot be prepared.
    public static func make(
        configuration: AudioRecordingConfiguration,
        roots: RecordingPipelineRoots,
        spaceGate: (any RecordingSpaceGating)? = nil,
        fileManager: FileManager = .default
    ) throws -> RecordingSessionPipeline {
        let recordingRoot: URL
        let outputDirectory: URL
        do {
            recordingRoot = try RecordingLedgerFileSystem.canonicalDirectory(roots.sessionRoot, create: true)
            outputDirectory = try RecordingLedgerFileSystem.canonicalDirectory(roots.outputDirectory, create: true)
        } catch { throw RecordingPipelineError.invalidConfiguration }
        guard configuration.kind == .audio, configuration.sampleRate == 48_000,
            !configuration.channelCountByRole.isEmpty,
            configuration.mode != .none,
            let roles = Self.roles(for: configuration)
        else { throw RecordingPipelineError.invalidConfiguration }

        let sessionID = UUID()
        let sendableFileManager = RecordingSendableFileManager(fileManager)
        let sessionsRoot = recordingRoot.appendingPathComponent(".SnapGlassSessions", isDirectory: true)
        let canonicalSessionsRoot: URL
        do {
            canonicalSessionsRoot = try RecordingLedgerFileSystem.canonicalDirectory(sessionsRoot, create: true)
        } catch { throw RecordingPipelineError.invalidConfiguration }
        let sessionRoot = canonicalSessionsRoot.appendingPathComponent(
            sessionID.uuidString.lowercased(), isDirectory: true
        )
        let ledger: RecordingSessionLedger
        do {
            ledger = try RecordingSessionLedger(
                sessionRoot: sessionRoot,
                indexURL: roots.indexURL,
                sessionID: sessionID,
                fileManager: sendableFileManager
            )
        } catch { throw RecordingPipelineError.invalidConfiguration }

        let coordinator = try makeCoordinator(
            sessionRoot: sessionRoot,
            configuration: configuration,
            roles: roles,
            fileManager: sendableFileManager
        )
        let sealService = RecordingSealService(
            publicationHooks: [LedgerPublicationHook(ledger: ledger)]
        )
        let pipelineRoots = RecordingPipelineRoots(
            sessionRoot: recordingRoot,
            indexURL: roots.indexURL,
            outputDirectory: outputDirectory
        )
        let engineFactory:
            @Sendable (
                AudioRecordingConfiguration,
                any AudioCheckpointSink & Sendable,
                AudioSampleClock
            ) throws -> any AudioRecordingControlling & Sendable = { config, sink, clock in
                try Self.makeNativeEngine(configuration: config, sink: sink, clock: clock)
            }
        return try RecordingSessionPipeline(
            roots: pipelineRoots,
            ledger: ledger,
            coordinator: coordinator,
            sealService: sealService,
            spaceGate: spaceGate,
            engineFactory: engineFactory,
            expectedConfiguration: configuration,
            fileManager: sendableFileManager
        )
    }

    private static func makeCoordinator(
        sessionRoot: URL,
        configuration: AudioRecordingConfiguration,
        roles: Set<RecordingTrackRole>,
        fileManager: RecordingSendableFileManager
    ) throws -> SegmentedWriterCoordinator {
        do {
            return try SegmentedWriterCoordinator(plan: AudioSegmentPlan()) { boundary in
                let segmentRoot = sessionRoot.appendingPathComponent(
                    String(format: "segment-%08d", boundary.index), isDirectory: true
                )
                try fileManager.value.createDirectory(
                    at: segmentRoot, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                return try RecordingCheckpointWriter(
                    directory: segmentRoot,
                    sessionRoot: sessionRoot,
                    segment: boundary,
                    sampleRate: configuration.sampleRate,
                    roles: roles
                )
            }
        } catch { throw RecordingPipelineError.invalidConfiguration }
    }

    private static func roles(for configuration: AudioRecordingConfiguration) -> Set<RecordingTrackRole>? {
        if configuration.layout == .mixed { return [.mixed] }
        switch configuration.mode {
        case .system: return [.system]
        case .microphone: return [.microphone]
        case .systemAndMicrophone: return [.system, .microphone]
        case .none: return nil
        }
    }

    private static func makeNativeEngine(
        configuration: AudioRecordingConfiguration,
        sink: any AudioCheckpointSink & Sendable,
        clock: AudioSampleClock
    ) throws -> any AudioRecordingControlling & Sendable {
        let ticksPerSecond = AudioSourceTimestampMapper.nativeHostTicksPerSecond()
        let system = try SystemAudioSource(
            format: AudioSourceFormat(sampleRate: 48_000, channelCount: 2),
            hostTicksPerSecond: ticksPerSecond,
            factory: SCKSystemAudioStreamFactory(),
            deviceMonitor: CoreAudioDeviceChangeMonitor()
        )
        let authorizer = SendableMicrophoneAuthorizer(AVMicrophoneAuthorizer())
        let microphone = try LazyMicrophoneSource(
            authorizer: authorizer,
            hostTicksPerSecond: ticksPerSecond,
            channelCount: configuration.channelCountByRole[.microphone] ?? 1
        )
        let routeController = AudioRouteController(
            authorizer: authorizer,
            sources: [.system: system, .microphone: microphone]
        )
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
            sources: [.system: system, .microphone: microphone],
            routeController: routeController,
            pump: pump
        )
    }
}
