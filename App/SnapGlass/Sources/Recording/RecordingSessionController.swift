import AppKit
import CaptureCore
import Foundation
import OSLog
@preconcurrency import ScreenCaptureKit
import SharedKit

typealias AudioPipelineFactory =
    @Sendable (
        AudioRecordingConfiguration,
        RecordingPipelineRoots,
        String?
    ) async throws -> RecordingSessionPipeline

/// Replaces the screen audio engine factory in agent runs.
///
/// Production never sets it; the agent channel uses it to prove that a failed
/// audio track leaves the video intact.
typealias ScreenAudioEngineFactoryOverride =
    @Sendable (
        AudioRecordingConfiguration,
        any AudioCheckpointSink & Sendable,
        AudioSampleClock
    ) throws -> any AudioRecordingControlling & Sendable

struct RecordingPreferenceSnapshot: Sendable {
    let codec: RecordingVideoCodec
    let resolutionProfile: String
    let frameRate: Int
    let averageVideoBitrate: Int
    let capturesSystemAudio: Bool
    let screenAudioMode: AudioSourceMode
    let screenAudioBitRate: Int
    let destinationDirectory: URL?
    let hasCustomDestination: Bool
    let customVolumeUUID: String?

    init(defaults: UserDefaults) {
        let storedCodec =
            defaults.string(forKey: PreferenceKeys.recordingVideoCodec)
            ?? PreferenceDefaults.recordingVideoCodec
        codec = RecordingVideoCodec(rawValue: storedCodec) ?? .h264
        resolutionProfile =
            defaults.string(forKey: PreferenceKeys.recordingResolution)
            ?? PreferenceDefaults.recordingResolution

        let storedFrameRate =
            (defaults.object(forKey: PreferenceKeys.recordingFrameRate) as? NSNumber)?.intValue
            ?? PreferenceDefaults.recordingFrameRate
        frameRate = [24, 30, 60].contains(storedFrameRate) ? storedFrameRate : PreferenceDefaults.recordingFrameRate

        let storedBitrate =
            (defaults.object(forKey: PreferenceKeys.recordingAverageVideoBitrate) as? NSNumber)?.intValue
            ?? PreferenceDefaults.recordingAverageVideoBitrate
        averageVideoBitrate =
            [2, 4, 8, 12, 16, 20].contains(storedBitrate / 1_000_000)
            ? storedBitrate
            : PreferenceDefaults.recordingAverageVideoBitrate

        capturesSystemAudio =
            defaults.object(forKey: PreferenceKeys.recordingSystemAudio) == nil
            ? PreferenceDefaults.recordingSystemAudio
            : defaults.bool(forKey: PreferenceKeys.recordingSystemAudio)
        screenAudioMode = RecordingAudioPreferenceStore.mode(for: .screen, in: defaults)
        screenAudioBitRate = RecordingAudioPreferenceStore.bitRate(for: .screen, in: defaults)
        destinationDirectory = RecordingDestinationPreferences.directory(for: .screen, in: defaults)
        hasCustomDestination = RecordingDestinationPreferences.customDirectory(for: .screen, in: defaults) != nil
        customVolumeUUID = RecordingDestinationPreferences.customDirectoryVolumeUUID(
            for: .screen,
            in: defaults
        )
    }

    func configuration(for selection: RecordingSourceSelection) -> RecordingConfiguration {
        let sourceDimensions = Self.pixelDimensions(for: selection)
        let resolutionLimit: CGSize
        switch resolutionProfile {
        case "720p":
            resolutionLimit = CGSize(width: 1_280, height: 720)
        case "1440p":
            resolutionLimit = CGSize(width: 2_560, height: 1_440)
        case "2160p":
            resolutionLimit = CGSize(width: 3_840, height: 2_160)
        case "source":
            resolutionLimit = sourceDimensions
        default:
            resolutionLimit = CGSize(width: 1_920, height: 1_080)
        }

        return RecordingConfiguration(
            codec: codec,
            resolutionLimit: resolutionLimit,
            frameRateLimit: frameRate,
            averageVideoBitrate: averageVideoBitrate,
            capturesSystemAudio: capturesSystemAudio
        )
    }

    private static func pixelDimensions(for selection: RecordingSourceSelection) -> CGSize {
        if case .display = selection.source {
            return selection.displayPixelSize
        }

        guard selection.displayFrame.width > 0, selection.displayFrame.height > 0 else { return .zero }
        let scaleX = selection.displayPixelSize.width / selection.displayFrame.width
        let scaleY = selection.displayPixelSize.height / selection.displayFrame.height
        return CGSize(
            width: selection.sourceFrame.width * scaleX,
            height: selection.sourceFrame.height * scaleY
        )
    }
}

struct RecordingSessionSnapshot: Sendable {
    let request: RecordingRequestIdentity
    let selection: RecordingSourceSelection
    let configuration: RecordingConfiguration
    let screenAudioMode: AudioSourceMode
    let screenAudioBitRate: Int
    let destinationDirectory: URL
    let hasCustomDestination: Bool
    let customVolumeUUID: String?
}

/// A first-frame gate failure that came from the writer itself.
///
/// Kept separate from ``RecordingReadinessError`` so the panel can show the
/// writer's own reason instead of a generic timeout.
enum ScreenStartFailureReason: LocalizedError, Equatable {
    /// `startWriting()` failed, or the engine reported a writer failure.
    case writerFailed(String)
    /// The writer input stayed busy past its bounded sync-frame wait.
    case writerNotReady(String)

    var errorDescription: String? {
        switch self {
        case let .writerFailed(reason):
            AppLocalization.string(
                "The video writer failed before the recording started: %@",
                reason
            )
        case let .writerNotReady(reason):
            AppLocalization.string(
                "The video writer was not ready to accept video frames: %@",
                reason
            )
        }
    }
}

/// Why new screen capture is blocked by an unconfirmed capture release.
///
/// This is the "stream release not confirmed" axis; "file not sealed yet" is the
/// separate `.saving` state and must never be merged into it.
enum ScreenReleasePhase: Equatable {
    /// Capture start was requested and has not returned; it may or may not run.
    case startUnconfirmed
    /// A stop was requested; its confirmation has not returned.
    case stopUnconfirmed
    /// `stopCapture()` reported a failure; an explicit retry may try again.
    case stopRejected
}

@MainActor
final class RecordingSessionController {
    let captureOrchestrator: CaptureOrchestrator
    let defaults: UserDefaults
    let audioPipelineFactory: AudioPipelineFactory
    var status: RecordingSessionStatus = .idle
    var outcomeState = RecordingSessionOutcomeState()
    var audioStateMachine = RecordingAudioSessionStateMachine()

    var onStatusChange: ((RecordingSessionStatus) -> Void)?
    var onScreenshotShelfRecordingChange: ((Bool) -> Void)?
    var onMessage: ((String, ToastType) -> Void)?
    var onOpenPermissionGuide: (() -> Void)?
    var onOpenRecordings: (() -> Void)?
    var onFailureChange: ((RecordingControlPanelFailure?) -> Void)?
    /// Resolves microphone access for a screen source that includes the microphone.
    var onRequestScreenMicrophoneAccess: (() async -> Bool)?

    /// Persisted diagnosis for a status that never reached the control panel.
    ///
    /// The panel's own log only records what it accepted. A status dropped before
    /// the panel sees it is invisible there, so the controller records it here.
    let logger = Logger(subsystem: "com.snapglass", category: "recording.hud")

    var activeSession: RecordingSessionSnapshot?
    var sessionScreen: NSScreen?
    var engine: ScreenRecordingEngine?
    var screenPipelineAdapter: ScreenRecordingPipelineAdapter?
    var controlPanel: RecordingControlPanel?
    var captureFramePanel: RecordingCaptureFramePanel?
    var recordingStartedAt: Date?
    var panelHiddenByUser = false
    var watchdogReported = false
    var retainedFailure: (engine: ScreenRecordingEngine, payload: RecordingControlPanelFailure)?
    var countdownTask: Task<Void, Never>?
    var monitoringTask: Task<Void, Never>?
    var notificationObservers: [NSObjectProtocol] = []
    var stopWhenStarted = false
    var pendingStopReason: String?
    var stopWaiters: [CheckedContinuation<Bool, Never>] = []
    var outcomeWaiters: [CheckedContinuation<RecordingSessionTerminalOutcome, Never>] = []
    /// The request identity that owns the current preparation/start/session.
    var currentRequest: RecordingRequestIdentity?
    var sessionGeneration = UUID()
    var activeRecordingKind: RecordingKind?
    var announcedPhase: RecordingPhase?
    var isResolvingQuit = false
    var cancelRequested = false
    var preparationPhase: RecordingPreparationPhase = .checkingPermission
    /// The truthful sub-stage while `status == .starting`.
    var startPhase: RecordingStartPhase = .startingScreenWriter
    /// The single clock used for phase durations and privacy-safe signposts.
    let clock: RecordingPhaseClock
    /// Duration anchor for the current phase; used only for privacy-safe signposts.
    var phaseStartedAt: ContinuousClock.Instant?
    /// Who owns the current screen start and its one stop.
    var screenStartOwnership = RecordingStartOwnership()
    /// Screen-recording access decided immediately before the writer starts.
    ///
    /// Injectable so the agent channel and tests can prove the denied path without
    /// changing the machine's TCC state. Production always uses the system gate.
    var screenPermissionGate = ScreenCapturePermissionGate.system
    /// Agent-only override for the screen session's audio mode.
    ///
    /// The production value still comes from the user's preferences; the agent
    /// channel sets this to isolate the video path (`none`) or exercise audio.
    var screenAudioModeOverride: AudioSourceMode?
    /// Agent-only injection that makes the screen audio engine factory fail.
    ///
    /// Used to prove that a failed audio track never truncates the video and that
    /// the user sees the "system audio was not recorded" copy. Production leaves
    /// this `false`.
    var screenAudioFailureInjection = false
    /// Whether this session ever armed the first-frame wait.
    ///
    /// A permission denial must leave this false: the session fails before any
    /// writer exists, instead of waiting five seconds for a frame that cannot come.
    var didAwaitFirstVideoFrame = false
    /// One in-flight screen stop, so a bounded UI wait never starts a second one.
    var screenStopTask: Task<ScreenRecordingOutcome, Error>?
    /// The permission/enumeration attempt; cancelled when the user cancels.
    var screenPreparationTask: Task<Void, Never>?
    /// A screen stream that could not be confirmed stopped; blocks new capture
    /// until the retry action confirms it.
    var unconfirmedScreenStop: (adapter: ScreenRecordingPipelineAdapter, materialRoot: URL?)?
    /// Destination cached for the release capsule's Finder action after the
    /// session snapshot has been cleared.
    var screenReleaseDestination: URL?
    /// Whether the visible panel is the capture-release capsule.
    var isPresentingScreenRelease = false
    /// Whether the release capsule has already been announced once.
    var didAnnounceScreenRelease = false
    var audioPipeline: RecordingSessionPipeline?
    var audioConfiguration: AudioRecordingConfiguration?
    var audioCurrentMode: AudioSourceMode?
    var audioSessionID: UUID?
    var audioStartTask: Task<Void, any Error>?
    var audioStopJoinTask: Task<AudioRecordingResult, Never>?
    var audioStopRequested = false
    var audioPipelineStarted = false
    var pendingRecoverySessionIDs: Set<UUID> = []
    var recoveryMaterialURLs: [UUID: [URL]] = [:]
    var audioStartWatchdogTask: Task<Void, Never>?
    var audioStartReservation: UUID?
    var audioResourceOwner: UUID?
    var audioRetireTask: Task<Void, Never>?
    var screenStartWatchdogTask: Task<Void, Never>?
    var screenCleanupTask: Task<Void, Never>?
    var lastAudioResult: AudioRecordingResult?
    var audioProgressTask: Task<Void, Never>?
    var previewReadinessTask: Task<Void, Never>?
    var previewLoadTask: Task<Void, Never>?
    var previewService: RecordingPreviewService?
    var previewLease: PreviewLease?
    var previewTarget: PreviewTarget?
    var previewPlayer: RecordingAudioPreviewPlayer?
    var previewReleaseTask: Task<Void, Never>?
    var previewReleaseGeneration = 0
    var previewLifecycleGeneration = 0
    var audioProgress: RecordingProgress?
    var latestAudioOutputURL: URL?
    /// Test-channel override for the first-sample deadline; `nil` in normal launches.
    ///
    /// Only the agent harness sets this, so production timing stays exactly as shipped.
    var firstSampleDeadlineOverride: Duration?
    /// Test-channel injection: treat readiness as never observed (the harness uses
    /// this to exercise the deadline without disabling capture). `false` in normal
    /// launches, where readiness comes only from real samples.
    var suppressFirstSampleReadiness = false
    /// Owns every readiness deadline and every stop; never runs on the main actor.
    let settlementSupervisor = RecordingSettlementSupervisor()
    /// The supervisor ticket of the armed audio session, if any.
    var audioSettlementTicket: RecordingSettlementSupervisor.Ticket?
    /// The supervisor ticket of the armed screen session, if any.
    var screenSettlementTicket: RecordingSettlementSupervisor.Ticket?
    /// The screen generation whose stop is running; set before `settle`.
    var screenSettlingGeneration: UUID?
    /// What the running screen settlement should be applied as.
    enum ScreenStopIntent {
        /// The session was recording; a published segment is the saved outcome.
        case recordingStop
        /// The start never became a recording; any material is recoverable only.
        case startCleanup
    }
    var screenStopIntent: ScreenStopIntent?
    /// The user-facing reason of the running screen stop, for its saved message.
    var screenStopReason: String?
    /// Classifies a screen stop that started off the main actor.
    var screenStopRelay: ScreenStopFailureRelay?
    /// Last known writer counters, kept after the adapter is released for diagnostics.
    var lastScreenWriterDiagnostics: ScreenWriterDiagnostics?
    /// Generations whose settlement the main actor already applied.
    ///
    /// A stop is reported twice (to the awaiting caller and to the event
    /// consumer); this makes the second report a no-op instead of a second
    /// presentation or a second gate release.
    private var appliedSettlementGenerations: [UUID] = []
    private var settlementEventTask: Task<Void, Never>?
    var audioHUDExpanded = false
    var audioSilenceStartedAt: ContinuousClock.Instant?
    var audioSilenceWarningShown = false
    var audioSilenceWarningVisible = false

    var isBusy: Bool { status.isBusy }
    var needsQuitConfirmation: Bool { status.needsQuitConfirmation }
    var isSaving: Bool {
        status == .saving || hasPendingBackgroundFinalization || screenCleanupTask != nil
    }
    var terminalOutcome: RecordingSessionTerminalOutcome? { outcomeState.terminalOutcome }
    var isAudioSessionActive: Bool {
        switch audioStateMachine.state {
        case .starting, .recording, .stopping, .finalizing: true
        case .idle, .finished, .failedRecoverable: false
        }
    }
    /// The kind of the session currently preparing, recording, saving, or resolving quit.
    var currentRecordingKind: RecordingKind? {
        activeRecordingKind
            ?? (isAudioSessionActive || hasPendingBackgroundFinalization ? .audio : nil)
            ?? (status.isBusy ? .screen : nil)
    }
    /// Active stop/finalization and retirement only; recoverable materials never count here.
    var hasPendingBackgroundFinalization: Bool {
        audioStopRequested || audioStopJoinTask != nil
            || audioRetireTask != nil
            || audioStateMachine.state == .finalizing
    }
    /// Live or retiring capture resources; a new capture waits for their release.
    var hasLiveCaptureResources: Bool {
        audioResourceOwner != nil || audioRetireTask != nil
            || screenStartOwnership.blocksNewStart
            || screenCleanupTask != nil
            || screenSettlingGeneration != nil
            || screenStopTask != nil || unconfirmedScreenStop != nil
    }

    /// Whether the platform screen start call is still outstanding.
    var isScreenPlatformStartOutstanding: Bool {
        screenStartOwnership.isPlatformStartOutstanding
    }
    /// Non-nil while new screen capture is blocked by an unconfirmed stream release.
    ///
    /// Only meaningful once the session UI has settled (`status == .idle`). While
    /// `.starting` the truthful message is "starting"; while `.saving` the stream
    /// already stopped and only the files are open, so that case keeps its own
    /// "still saving" message instead of borrowing the release wording.
    var screenReleasePhase: ScreenReleasePhase? {
        guard status == .idle else { return nil }
        if unconfirmedScreenStop != nil || screenStartOwnership.needsReleaseConfirmation {
            return .stopRejected
        }
        switch screenStartOwnership.stage {
        case .idle:
            return isScreenStopInFlight ? .stopUnconfirmed : nil
        case .platformStartOutstanding, .awaitingFirstFrame:
            return .startUnconfirmed
        case .stopping:
            return .stopUnconfirmed
        case .recording:
            // A settled UI never coexists with recording; keep this defensive.
            return nil
        case .stopUnconfirmed:
            return .stopRejected
        }
    }

    /// Whether a real stop/cleanup operation is still running for the old stream.
    var isScreenStopInFlight: Bool {
        screenCleanupTask != nil || screenSettlingGeneration != nil || screenStopTask != nil
    }
    /// Recoverable session IDs whose materials are retained for an explicit recovery action.
    var pendingRecoveryIDs: Set<UUID> { pendingRecoverySessionIDs }
    /// URLs retained for a recoverable session; never deleted by this controller.
    func recoveryMaterials(for sessionID: UUID) -> [URL] {
        recoveryMaterialURLs[sessionID] ?? []
    }

    init(
        captureOrchestrator: CaptureOrchestrator,
        defaults: UserDefaults = .standard,
        clock: RecordingPhaseClock = RecordingPhaseClock(),
        audioPipelineFactory: @escaping AudioPipelineFactory
    ) {
        self.captureOrchestrator = captureOrchestrator
        self.defaults = defaults
        self.clock = clock
        self.audioPipelineFactory = audioPipelineFactory
        installLifecycleObservers()
        startSettlementEventConsumer()
    }

    /// Consumes supervisor events on the main actor.
    ///
    /// The stream is optional by design: stops and saves complete without it, so a
    /// stalled main thread can never hold up persistence. This consumer only
    /// presents what already happened.
    private func startSettlementEventConsumer() {
        settlementEventTask?.cancel()
        let events = settlementSupervisor.events
        settlementEventTask = Task { @MainActor [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                await self.handleSettlementEvent(event)
            }
        }
    }

    /// Marks one generation's settlement as applied, exactly once.
    ///
    /// - Parameter generation: The generation whose settlement is being applied.
    /// - Returns: `true` for the first call only.
    func markSettlementApplied(_ generation: UUID) -> Bool {
        guard !appliedSettlementGenerations.contains(generation) else { return false }
        appliedSettlementGenerations.append(generation)
        if appliedSettlementGenerations.count > 8 {
            appliedSettlementGenerations.removeFirst(appliedSettlementGenerations.count - 8)
        }
        return true
    }
}
