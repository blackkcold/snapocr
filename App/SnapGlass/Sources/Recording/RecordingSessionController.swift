// The controller now carries audio/screen lifecycle, bounded settlement, and
// recovery quarantine in one type; splitting it is a deferred refactor. This
// matches the existing file_length suppression used by the CaptureCore audio
// engines and keeps the Swift compiler gate fully active.
// swiftlint:disable file_length

import AppKit
import CaptureCore
import Foundation
import SharedKit

@preconcurrency import ScreenCaptureKit

typealias AudioPipelineFactory = @Sendable (
    AudioRecordingConfiguration,
    RecordingPipelineRoots,
    String?
) async throws -> RecordingSessionPipeline

/// Replaces the screen audio engine factory in agent runs.
///
/// Production never sets it; the agent channel uses it to prove that a failed
/// audio track leaves the video intact.
typealias ScreenAudioEngineFactoryOverride = @Sendable (
    AudioRecordingConfiguration,
    any AudioCheckpointSink & Sendable,
    AudioSampleClock
) throws -> any AudioRecordingControlling & Sendable

private struct RecordingPreferenceSnapshot: Sendable {
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
        let storedCodec = defaults.string(forKey: PreferenceKeys.recordingVideoCodec)
            ?? PreferenceDefaults.recordingVideoCodec
        codec = RecordingVideoCodec(rawValue: storedCodec) ?? .h264
        resolutionProfile = defaults.string(forKey: PreferenceKeys.recordingResolution)
            ?? PreferenceDefaults.recordingResolution

        let storedFrameRate = (defaults.object(forKey: PreferenceKeys.recordingFrameRate) as? NSNumber)?.intValue
            ?? PreferenceDefaults.recordingFrameRate
        frameRate = [24, 30, 60].contains(storedFrameRate) ? storedFrameRate : PreferenceDefaults.recordingFrameRate

        let storedBitrate =
            (defaults.object(forKey: PreferenceKeys.recordingAverageVideoBitrate) as? NSNumber)?.intValue
            ?? PreferenceDefaults.recordingAverageVideoBitrate
        averageVideoBitrate = [2, 4, 8, 12, 16, 20].contains(storedBitrate / 1_000_000)
            ? storedBitrate
            : PreferenceDefaults.recordingAverageVideoBitrate

        capturesSystemAudio = defaults.object(forKey: PreferenceKeys.recordingSystemAudio) == nil
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

private struct RecordingSessionSnapshot: Sendable {
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
    private let captureOrchestrator: CaptureOrchestrator
    let defaults: UserDefaults
    private let audioPipelineFactory: AudioPipelineFactory
    private(set) var status: RecordingSessionStatus = .idle
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

    private var activeSession: RecordingSessionSnapshot?
    var sessionScreen: NSScreen?
    var engine: ScreenRecordingEngine?
    private var screenPipelineAdapter: ScreenRecordingPipelineAdapter?
    var controlPanel: RecordingControlPanel?
    var captureFramePanel: RecordingCaptureFramePanel?
    var recordingStartedAt: Date?
    var panelHiddenByUser = false
    var watchdogReported = false
    var retainedFailure: (engine: ScreenRecordingEngine, payload: RecordingControlPanelFailure)?
    private var countdownTask: Task<Void, Never>?
    private var monitoringTask: Task<Void, Never>?
    private var notificationObservers: [NSObjectProtocol] = []
    private var stopWhenStarted = false
    private var pendingStopReason: String?
    private var stopWaiters: [CheckedContinuation<Bool, Never>] = []
    private var outcomeWaiters: [CheckedContinuation<RecordingSessionTerminalOutcome, Never>] = []
    /// The request identity that owns the current preparation/start/session.
    private var currentRequest: RecordingRequestIdentity?
    var sessionGeneration = UUID()
    private var activeRecordingKind: RecordingKind?
    private var announcedPhase: RecordingPhase?
    var isResolvingQuit = false
    private var cancelRequested = false
    var preparationPhase: RecordingPreparationPhase = .checkingPermission
    /// The truthful sub-stage while `status == .starting`.
    var startPhase: RecordingStartPhase = .startingScreenWriter
    /// The single clock used for phase durations and privacy-safe signposts.
    let clock: RecordingPhaseClock
    /// Duration anchor for the current phase; used only for privacy-safe signposts.
    private var phaseStartedAt: ContinuousClock.Instant?
    /// Who owns the current screen start and its one stop.
    private(set) var screenStartOwnership = RecordingStartOwnership()
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
    private(set) var didAwaitFirstVideoFrame = false
    /// One in-flight screen stop, so a bounded UI wait never starts a second one.
    private var screenStopTask: Task<ScreenRecordingOutcome, Error>?
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
    private var audioStartTask: Task<Void, any Error>?
    private var audioStopJoinTask: Task<AudioRecordingResult, Never>?
    var audioStopRequested = false
    private var audioPipelineStarted = false
    private var pendingRecoverySessionIDs: Set<UUID> = []
    private var recoveryMaterialURLs: [UUID: [URL]] = [:]
    private var audioStartWatchdogTask: Task<Void, Never>?
    private var audioStartReservation: UUID?
    private var audioResourceOwner: UUID?
    private var audioRetireTask: Task<Void, Never>?
    private var screenStartWatchdogTask: Task<Void, Never>?
    private var screenCleanupTask: Task<Void, Never>?
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
    private(set) var lastScreenWriterDiagnostics: ScreenWriterDiagnostics?
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

    func cancelPendingStart() {
        switch status {
        case .selectingSource:
            screenPreparationTask?.cancel()
            screenPreparationTask = nil
            finishSession(success: false, errorClass: .cancelled)
            RecordingSourcePickerPanel.cancelActivePanel()
            AreaSelectionPanel.cancelRecordingRegionSelection()
        case .countdown:
            countdownTask?.cancel()
            finishSession(success: false, errorClass: .cancelled)
        case .starting:
            cancelStartingSession()
        case .idle, .recording, .saving:
            break
        }
    }

    @discardableResult
    func stopAndSave(reason: String? = nil) async -> Bool {
        if isAudioSessionActive || hasPendingBackgroundFinalization {
            let result = await stopAudio()
            return Self.audioResultWasSaved(result)
        }

        switch status {
        case .idle:
            return false
        case .selectingSource, .countdown:
            cancelPendingStart()
            return false
        case .starting:
            stopWhenStarted = true
            if let reason { pendingStopReason = reason }
            let generation = sessionGeneration
            let completed = await RecordingReadiness.awaitBounded(RecordingReadiness.uiSettleDeadline) {
                await self.waitForStopCompletion()
            }
            guard let completed else {
                guard generation == sessionGeneration else { return false }
                cancelStartingSession()
                return false
            }
            return completed
        case .recording:
            return await finalizeRecording(reason: reason)
        case .saving:
            let generation = sessionGeneration
            let completed = await RecordingReadiness.awaitBounded(RecordingReadiness.uiSettleDeadline) {
                await self.waitForStopCompletion()
            }
            guard let completed else {
                guard generation == sessionGeneration else { return false }
                return false
            }
            return completed
        }
    }

    func stopAndResolveForQuit(reason: String) async -> RecordingSessionTerminalOutcome {
        let generation = sessionGeneration
        let kind = currentRecordingKind
        if let kind { RecordingSignposts.emit(.saving, kind: kind) }
        isResolvingQuit = true
        if status == .saving {
            updateStatus(.saving)
        }
        defer { isResolvingQuit = false }

        let resolved = await RecordingReadiness.awaitBounded(RecordingReadiness.uiSettleDeadline) {
            await self.resolveQuitOutcome(reason: reason)
        }
        guard let outcome = resolved else {
            guard generation == sessionGeneration else {
                return outcomeState.terminalOutcome ?? .failed
            }
            // Do not claim saved, and do not settle or drop references for a save
            // that is still live. Keep it represented as saving and return an
            // actionable result; a later quit request joins the same save.
            onMessage?(
                AppLocalization.string(
                    "The recording is still finishing in the background. Try quitting again after it finishes."
                ),
                .info
            )
            if let kind { RecordingSignposts.emit(.quitResolved, kind: kind) }
            return .failed
        }
        if outcome.allowsApplicationQuit { await closeAudioPreview() }
        if let kind { RecordingSignposts.emit(.quitResolved, kind: kind) }
        return outcome
    }

    private func resolveQuitOutcome(reason: String) async -> RecordingSessionTerminalOutcome {
        let outcome: RecordingSessionTerminalOutcome
        if isAudioSessionActive || hasPendingBackgroundFinalization {
            _ = await stopAudio()
            outcome = await waitForBackgroundFinalization()
        } else {
            switch status {
            case .idle:
                outcome = outcomeState.terminalOutcome ?? .noActiveSession
            case .selectingSource, .countdown:
                cancelPendingStart()
                outcome = outcomeState.terminalOutcome ?? .noActiveSession
            case .starting:
                stopWhenStarted = true
                pendingStopReason = reason
                outcome = await waitForTerminalOutcome()
            case .recording:
                _ = await finalizeRecording(reason: reason)
                outcome = outcomeState.terminalOutcome ?? .failed
            case .saving:
                outcome = await waitForTerminalOutcome()
            }
        }
        return outcome
    }

    private func cancelStartingSession() {
        let kind = currentRecordingKind ?? .screen
        cancelRequested = true
        RecordingSignposts.emit(.cancelled, kind: kind)
        if isAudioSessionActive || kind == .audio {
            let generation = sessionGeneration
            audioStopRequested = true
            audioStateMachine.apply(.stopRequested)
            updateStatus(audioStateMachine.legacyStatus)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let result = await RecordingReadiness.awaitBounded(RecordingReadiness.uiSettleDeadline) {
                    await self.stopAudio()
                }
                guard generation == self.sessionGeneration else { return }
                if result == nil { self.forceAudioStartCancellation(generation: generation) }
            }
            return
        }

        guard let request = currentRequest, request.kind == .screen else {
            // No request identity owns this start; settle honestly rather than
            // touching a newer request.
            outcomeState.beginSession()
            finishSession(success: false, errorClass: .cancelled)
            return
        }
        let route = screenStartOwnership.requestCancel(generation: request.generation)
        switch route {
        case .stopWhenStartReturns:
            // The platform start call may never cooperate. Settle the UI now; the
            // late success path performs at most one cleanup when it arrives.
            stopWhenStarted = true
            pendingStopReason = AppLocalization.string("Cancelled")
            outcomeState.beginSession()
            finishSession(success: false, errorClass: .cancelled)
            presentScreenReleaseCapsuleIfNeeded()
        case .cancelFirstFrameWait:
            // The start already returned, so the adapter is live right now. The
            // supervisor owns its single stop; cancelling the first-frame wait here
            // only means "settle the UI now and let that same stop finish".
            stopWhenStarted = false
            pendingStopReason = AppLocalization.string("Cancelled")
            outcomeState.beginSession()
            screenStopIntent = .startCleanup
            screenSettlingGeneration = request.generation
            if let ticket = screenSettlementTicket {
                screenSettlementTicket = nil
                Task { [weak self] in
                    _ = await self?.settlementSupervisor.settle(ticket: ticket, reason: .requested)
                }
            } else if let adapter = screenPipelineAdapter {
                // No ticket owns this start (defensive); its one initial stop is the
                // cleanup latch.
                runScreenCleanup(adapter: adapter, generation: request.generation)
            }
            finishSession(success: false, errorClass: .cancelled)
            presentScreenReleaseCapsuleIfNeeded()
        case .alreadyStopping:
            // A stop is already in flight; settle once and let its real result
            // release (or retain) the gate.
            stopWhenStarted = false
            outcomeState.beginSession()
            finishSession(success: false, errorClass: .cancelled)
            presentScreenReleaseCapsuleIfNeeded()
        case .notStarting:
            break
        case .notOwner:
            // Defensive: the request exists but owns no start. Settle once.
            outcomeState.beginSession()
            finishSession(success: false, errorClass: .cancelled)
        }
    }

    private func forceAudioStartCancellation(generation: UUID) {
        guard generation == sessionGeneration, lastAudioResult == nil else { return }
        switch audioStateMachine.state {
        case .starting, .stopping, .finalizing:
            completeAudioSession(with: failedAudioResult(RecordingReadinessError.cancelledWhileStarting))
        case .idle, .recording, .finished, .failedRecoverable:
            break
        }
    }

    /// Starts the audio pipeline after the app has resolved the required system permission.
    /// This method never requests microphone permission itself.
    ///
    /// - Parameters:
    ///   - configuration: The source, layout, and bitrate snapshot taken at invocation.
    ///   - roots: The destination snapshot taken at invocation.
    ///   - isCustomDestination: Whether the user picked the destination. A custom
    ///     external folder is validated at its exact path and never falls back.
    ///   - request: The identity created by ``beginAudioRequest(requiresMicrophonePermission:)`` before the
    ///     permission prompt. `nil` creates a fresh identity for legacy callers.
    func startAudio(
        _ configuration: AudioRecordingConfiguration,
        roots: RecordingPipelineRoots,
        isCustomDestination: Bool,
        expectedVolumeUUID: String? = nil,
        request: RecordingRequestIdentity? = nil
    ) async throws {
        // All state checks happen before any mutation, so a rejected start leaves
        // the current request and UI untouched.
        guard !isAudioSessionActive, !hasPendingBackgroundFinalization else {
            throw RecordingPipelineError.alreadyStarted
        }
        guard !screenStartOwnership.blocksNewStart, screenCleanupTask == nil else {
            throw RecordingPipelineError.alreadyStarted
        }
        // Reserve the start slot synchronously, before any suspension point, so a
        // second start cannot pass the same idle-state checks. The resource owner
        // is separate from the UI terminal state: it outlives an early UI settle
        // until the real setup/start/stop operation has drained.
        guard audioResourceOwner == nil, audioStartReservation == nil else {
            throw RecordingPipelineError.alreadyStarted
        }

        let identity: RecordingRequestIdentity
        if let request {
            // The permission prompt may return after a cancel or a newer request.
            // Only a request that still owns the UI may create a pipeline.
            guard request.kind == .audio,
                  currentRequest == request,
                  request.disposition(generation: sessionGeneration, holdsResource: false) == .apply,
                  status == .selectingSource
            else { throw RecordingReadinessError.supersededStart }
            identity = request
        } else {
            guard status == .idle else { throw RecordingPipelineError.alreadyStarted }
            identity = RecordingRequestIdentity(kind: .audio)
            sessionGeneration = identity.generation
            currentRequest = identity
            activeRecordingKind = .audio
            announcedPhase = nil
            cancelRequested = false
            outcomeState.beginSession()
            preparationPhase = .checkingPermission
            phaseStartedAt = clock.now
            RecordingSignposts.emit(.preparing, kind: .audio)
        }
        let owner = UUID()
        audioResourceOwner = owner
        audioStartReservation = owner

        let generation = identity.generation
        currentRequest = identity
        activeRecordingKind = .audio
        announcedPhase = nil
        cancelRequested = false
        outcomeState.beginSession()
        audioStateMachine = RecordingAudioSessionStateMachine()
        audioStateMachine.apply(.begin)
        audioConfiguration = configuration
        audioSessionID = UUID()
        audioPipeline = nil
        audioPipelineStarted = false
        audioStopRequested = false
        lastAudioResult = nil
        audioProgress = nil
        audioCurrentMode = configuration.mode
        latestAudioOutputURL = nil
        audioHUDExpanded = false
        audioSilenceStartedAt = nil
        audioSilenceWarningShown = false
        audioSilenceWarningVisible = false
        panelHiddenByUser = false
        // The destination check is a visible preparation step, not part of the
        // "starting" spinner. Report it before the probe and only enter
        // `.starting` once the pipeline factory is about to run.
        preparationPhase = .verifyingDestination
        updatePreparationPhase(.verifyingDestination)
        startAudioStartupWatchdog(generation: generation, owner: owner)

        await closeAudioPreview()
        guard generation == sessionGeneration, audioResourceOwner == owner else {
            releaseAudioResourceOwner(owner)
            throw RecordingReadinessError.supersededStart
        }
        audioProgressTask?.cancel()
        audioProgressTask = nil
        previewReadinessTask?.cancel()
        previewReadinessTask = nil

        let pipeline: RecordingSessionPipeline
        do {
            // Location only: no capacity read here. The pipeline's preflight is
            // the single capacity decision for this start.
            try await RecordingDestinationProbe.validateLocation(
                directory: roots.outputDirectory,
                isCustom: isCustomDestination,
                expectedVolumeUUID: expectedVolumeUUID
            )
            guard identity.disposition(generation: sessionGeneration, holdsResource: false) == .apply else {
                throw RecordingReadinessError.supersededStart
            }
            startPhase = .startingAudioPipeline
            phaseStartedAt = clock.now
            updateStatus(.starting)
            RecordingSignposts.emit(.starting, kind: .audio)
            emitStartPhaseSignpost(kind: .audio)
            pipeline = try await audioPipelineFactory(
                configuration,
                roots,
                expectedVolumeUUID
            )
        } catch {
            audioStartWatchdogTask?.cancel()
            audioStartWatchdogTask = nil
            audioStartReservation = nil
            guard identity.disposition(generation: sessionGeneration, holdsResource: false) == .apply,
                  lastAudioResult == nil
            else {
                releaseAudioResourceOwner(owner)
                throw RecordingReadinessError.supersededStart
            }
            completeAudioSession(with: failedAudioResult(error))
            releaseAudioResourceOwner(owner)
            throw error
        }
        guard identity.disposition(generation: sessionGeneration, holdsResource: false) == .apply,
              lastAudioResult == nil,
              audioResourceOwner == owner else {
            // The factory ran on its worker; a cancel, watchdog, or replacement
            // settled while it did. Never adopt or start a pipeline for a session
            // that has already settled.
            audioStartWatchdogTask?.cancel()
            audioStartWatchdogTask = nil
            audioStartReservation = nil
            releaseAudioResourceOwner(owner)
            throw RecordingReadinessError.supersededStart
        }

        audioPipeline = pipeline
        audioSessionID = pipeline.ledger.sessionID
        let task = Task { try await pipeline.start(configuration) }
        audioStartTask = task
        do {
            try await task.value
        } catch {
            audioStartWatchdogTask?.cancel()
            audioStartWatchdogTask = nil
            audioStartReservation = nil
            audioStartTask = nil
            guard identity.disposition(generation: sessionGeneration, holdsResource: false) == .apply,
                  lastAudioResult == nil else {
                // The UI already settled (cancel, watchdog, bounded stop). The
                // failed start owns no live resources, so release the owner and
                // suppress a second visible failure.
                releaseAudioResourceOwner(owner)
                throw RecordingReadinessError.supersededStart
            }
            // A failed start never keeps a half-created pipeline reference.
            if !audioPipelineStarted { audioPipeline = nil }
            completeAudioSession(with: failedAudioResult(error))
            releaseAudioResourceOwner(owner)
            throw error
        }

        audioStartWatchdogTask?.cancel()
        audioStartWatchdogTask = nil
        audioStartReservation = nil
        audioStartTask = nil
        guard identity.disposition(generation: sessionGeneration, holdsResource: true) == .apply,
              lastAudioResult == nil,
              audioResourceOwner == owner else {
            // A genuine late success must stop its own pipeline exactly once; the
            // owner stays reserved until that retirement drains.
            scheduleAudioRetirement(pipeline, owner: owner)
            throw RecordingReadinessError.supersededStart
        }
        // Arm before presenting: the first-sample deadline must already exist when
        // the HUD shows `.starting`, so a stalled main thread cannot skip it.
        let deadline = firstSampleDeadlineOverride ?? RecordingReadiness.firstAudioSampleDeadline
        let readiness: RecordingSettlementSupervisor.Readiness =
            suppressFirstSampleReadiness
            ? .poll { .waiting }
            : .audioProgress(pipeline.makeProgressStream())
        screenSettlementTicket = nil
        audioSettlementTicket = await settlementSupervisor.arm(
            generation: generation,
            kind: .audio,
            deadline: deadline,
            readiness: readiness,
            stop: { [pipeline] in
                // `RecordingSessionPipeline.stop()` is idempotent and actor-isolated;
                // this closure never touches the main actor.
                .audio(await pipeline.stop())
            }
        )
        markAudioPipelineStarted()
        startAudioProgressMonitoring(for: pipeline, generation: generation)
        if audioStopRequested {
            _ = await stopAudio()
        }
    }

    /// Bounds the platform startup (factory plus `pipeline.start`) independently of
    /// the first-sample readiness timer.
    ///
    /// If it fires, the UI receives a visible failure but the start keeps running;
    /// a later success stops its own pipeline through `scheduleAudioRetirement`.
    private func startAudioStartupWatchdog(generation: UUID, owner: UUID) {
        audioStartWatchdogTask?.cancel()
        audioStartWatchdogTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: RecordingReadiness.platformStartDeadline)
            } catch {
                return
            }
            guard let self, !Task.isCancelled,
                  generation == self.sessionGeneration,
                  self.audioResourceOwner == owner,
                  self.audioStartReservation == owner,
                  self.lastAudioResult == nil,
                  self.audioStateMachine.state == .starting
            else { return }
            self.outcomeState.markCaptureAttempted()
            self.completeAudioSession(
                with: self.failedAudioResult(RecordingReadinessError.startTimedOut)
            )
        }
    }

    /// Stops resources for an operation whose UI has already settled.
    ///
    /// At most one retirement runs at a time. The resource owner is released only
    /// after the pipeline has drained, so no new capture can overlap it.
    private func scheduleAudioRetirement(_ pipeline: RecordingSessionPipeline, owner: UUID) {
        guard audioRetireTask == nil else { return }
        audioRetireTask = Task { @MainActor [weak self] in
            let result = await pipeline.stop()
            guard let self else { return }
            if Self.audioResultWasSaved(result) {
                self.registerRecoveryMaterials(sessionID: result.sessionID, pipeline: pipeline)
            }
            self.releaseAudioResourceOwner(owner)
        }
    }

    private func releaseAudioResourceOwner(_ owner: UUID) {
        guard audioResourceOwner == owner else { return }
        audioResourceOwner = nil
        audioStartReservation = nil
        audioRetireTask = nil
    }

    /// Stops capture idempotently and returns only after T9 has drained tail and seal work.
    ///
    /// Concurrent callers join one in-flight stop. A hanging pipeline start is
    /// bounded so a cancel or stop can still produce a UI result. The tail/seal
    /// save itself is not bounded: a legitimately long save keeps running and is
    /// reported by its real result.
    func stopAudio() async -> AudioRecordingResult {
        if let audioStopJoinTask { return await audioStopJoinTask.value }
        let task = Task { @MainActor [weak self] in
            guard let self else {
                return AudioRecordingResult(
                    sessionID: UUID(),
                    kind: .audio,
                    layout: .mixed,
                    segmentCount: 0,
                    droppedRanges: [],
                    checkpointAge: 0,
                    failure: "recording session was released"
                )
            }
            return await self.performAudioStop()
        }
        audioStopJoinTask = task
        let result = await task.value
        audioStopJoinTask = nil
        return result
    }

    private func performAudioStop() async -> AudioRecordingResult {
        // A settled session that is still retiring its own pipeline owns the
        // resources; do not start a second stop against it.
        if audioRetireTask != nil {
            return lastAudioResult ?? makeAudioResult(failure: "recording is still stopping")
        }
        if pendingRecoverySessionIDs.contains(audioSessionID ?? UUID()), let lastAudioResult {
            return lastAudioResult
        }
        if !isAudioSessionActive && !hasPendingBackgroundFinalization {
            return lastAudioResult ?? makeAudioResult(failure: "recording pipeline is not active")
        }

        let generation = sessionGeneration
        let sessionID = audioSessionID
        let owner = audioResourceOwner
        if let audioStartTask {
            audioStopRequested = true
            audioStateMachine.apply(.stopRequested)
            updateStatus(audioStateMachine.legacyStatus)
            let started = await RecordingReadiness.awaitBounded(RecordingReadiness.uiSettleDeadline) {
                do {
                    try await audioStartTask.value
                    return true
                } catch {
                    return false
                }
            }
            guard generation == sessionGeneration, sessionID == audioSessionID else {
                return lastAudioResult ?? makeAudioResult(failure: "recording pipeline was replaced")
            }
            guard let started else {
                let result = failedAudioResult(RecordingReadinessError.uiWaitTimedOut)
                completeAudioSession(with: result)
                return result
            }
            guard started else {
                if let lastAudioResult { return lastAudioResult }
                let result = failedAudioResult(
                    RecordingReadinessError.cancelledWhileStarting
                )
                completeAudioSession(with: result)
                return result
            }
            if let lastAudioResult { return lastAudioResult }
            markAudioPipelineStarted()
        }

        guard let pipeline = audioPipeline else {
            let result = lastAudioResult ?? makeAudioResult(failure: "recording pipeline is unavailable")
            completeAudioSession(with: result)
            return result
        }

        audioStopRequested = true
        audioStateMachine.apply(.stopRequested)
        audioStateMachine.beginFinalization()
        updateStatus(audioStateMachine.legacyStatus)
        if let kind = currentRecordingKind { RecordingSignposts.emit(.saving, kind: kind) }

        await beginPreviewReadinessMonitoring(for: pipeline)

        // The supervisor owns the single stop. A deadline that already started it
        // returns the same settlement instead of stopping twice, and the reason it
        // reports is the one that actually started the stop.
        var settlement: RecordingSettlement?
        var settledReason: RecordingSettlementReason = .requested
        if let ticket = audioSettlementTicket {
            settlement = await settlementSupervisor.settle(ticket: ticket, reason: .requested)
            if let actual = await settlementSupervisor.settledReason(for: ticket) {
                settledReason = actual
            }
            audioSettlementTicket = nil
        }
        if settlement == nil {
            // No ticket owns this generation; the pipeline's own idempotent stop is
            // the only remaining stop for it.
            settlement = .audio(await pipeline.stop())
        }
        guard let settlement else {
            return lastAudioResult ?? makeAudioResult(failure: "recording pipeline is unavailable")
        }
        await applyAudioSettlement(
            settlement,
            generation: generation,
            reason: settledReason,
            owner: owner,
            pipeline: pipeline
        )
        return lastAudioResult ?? makeAudioResult(failure: "recording pipeline is unavailable")
    }

    func applyRoute(_ event: RouteEvent) async -> RouteCommitResult {
        guard let audioPipeline else {
            return .unchanged(reason: "recording pipeline is not active")
        }
        let result = await audioPipeline.applyRoute(event)
        if case .committed = result { audioCurrentMode = event.mode }
        return result
    }

    func makeAudioProgressStream() -> AsyncStream<RecordingProgress> {
        guard let audioPipeline else {
            return AsyncStream { continuation in continuation.finish() }
        }
        return audioPipeline.makeProgressStream()
    }

    func waitForBackgroundFinalization() async -> RecordingSessionTerminalOutcome {
        if let audioStopJoinTask {
            _ = await audioStopJoinTask.value
            return outcomeState.terminalOutcome ?? .failed
        }
        if let audioRetireTask {
            // The settled session is still stopping its own late-started pipeline.
            _ = await audioRetireTask.value
            return outcomeState.terminalOutcome ?? .failed
        }
        if audioStopRequested {
            _ = await stopAudio()
            return outcomeState.terminalOutcome ?? .failed
        }
        if isAudioSessionActive { return .failed }
        return outcomeState.terminalOutcome ?? .noActiveSession
    }

    private func pipelineRoots(for directory: URL) -> RecordingPipelineRoots {
        let outputDirectory = directory.standardizedFileURL
        let sessionsDirectory = outputDirectory.appendingPathComponent(".SnapGlassSessions", isDirectory: true)
        return RecordingPipelineRoots(
            sessionRoot: outputDirectory,
            indexURL: sessionsDirectory.appendingPathComponent("recording-index.json"),
            outputDirectory: outputDirectory
        )
    }

    private func markAudioPipelineStarted() {
        guard !audioPipelineStarted else { return }
        audioPipelineStarted = true
        outcomeState.markCaptureAttempted()
        guard !audioStopRequested else { return }
        startPhase = .awaitingFirstAudioSample
        phaseStartedAt = clock.now
        emitStartPhaseSignpost(kind: .audio)
        // `updateStatus` is the only entry point that presents: the audio branch of
        // `.starting` creates and shows the panel, so a second present here would
        // enqueue the same state again in the same turn.
        updateStatus(.starting)
    }

    /// Applies one audio settlement on the main actor.
    ///
    /// Called both by the awaiting stop path (which needs its return value) and by
    /// the event consumer (which covers a deadline stop nobody awaited). The first
    /// call applies it; every later report of the same generation is a no-op.
    ///
    /// - Parameters:
    ///   - settlement: The settled stop result.
    ///   - generation: The session generation the settlement belongs to.
    ///   - reason: Whether a request or the deadline produced it.
    ///   - owner: The resource owner to release once the pipeline has drained.
    ///   - pipeline: The pipeline the settlement came from, for the output URL.
    func applyAudioSettlement(
        _ settlement: RecordingSettlement,
        generation: UUID,
        reason: RecordingSettlementReason,
        owner: UUID?,
        pipeline explicitPipeline: RecordingSessionPipeline?
    ) async {
        guard markSettlementApplied(generation) else { return }
        let pipeline = explicitPipeline ?? audioPipeline
        let outputURL = await pipeline?.latestPublishedFileURL()
        // The pipeline drained; release the resource owner even when a newer
        // generation already settled this session's UI. A deadline stop has no
        // awaiting caller, so it releases the owner the session still holds.
        if let owner {
            releaseAudioResourceOwner(owner)
        } else if generation == sessionGeneration, let currentOwner = audioResourceOwner {
            releaseAudioResourceOwner(currentOwner)
        }
        await previewReadinessTask?.value

        guard generation == sessionGeneration, lastAudioResult == nil else {
            // The UI already settled this session (cancel, replacement, or a stop
            // that ran twice). Keep any real material reachable for recovery and
            // never touch the newer session.
            if case let .audio(result) = settlement, Self.audioResultWasSaved(result),
               let pipeline {
                registerRecoveryMaterials(sessionID: result.sessionID, pipeline: pipeline)
            }
            return
        }

        // A deadline stop never passed through the requested-stop path, so move the
        // state machine to finalizing here. Without this the session would stay
        // `.starting` and the next recording would be refused.
        if reason == .deadline, audioStateMachine.state == .starting {
            audioStateMachine.apply(.stopRequested)
            audioStateMachine.beginFinalization()
        }

        switch settlement {
        case let .audio(result):
            if reason == .deadline, !Self.audioResultWasSaved(result) {
                completeAudioSession(
                    with: Self.audioResult(
                        result,
                        failure: AppLocalization.recordingErrorDescription(
                            RecordingReadinessError.noAudioSamples
                        )
                    )
                )
                return
            }
            completeAudioSession(with: result, outputURL: outputURL)
        case let .failed(_, message):
            completeAudioSession(with: makeAudioResult(failure: message))
        case .screen:
            completeAudioSession(
                with: makeAudioResult(failure: "the audio session returned a screen result")
            )
        }
    }

    /// Returns `result` with a failure summary, keeping every real measurement.
    private static func audioResult(_ result: AudioRecordingResult, failure: String) -> AudioRecordingResult {
        AudioRecordingResult(
            sessionID: result.sessionID,
            kind: result.kind,
            layout: result.layout,
            segmentCount: result.segmentCount,
            droppedRanges: result.droppedRanges,
            checkpointAge: result.checkpointAge,
            failure: failure
        )
    }

    /// Monotonic-clock supervisor facts, used by the agent test report.
    func settlementDiagnostics() async -> RecordingSettlementSupervisor.Diagnostics {
        await settlementSupervisor.diagnostics()
    }

    /// Marks one generation's settlement as applied, exactly once.
    ///
    /// - Parameter generation: The generation whose settlement is being applied.
    /// - Returns: `true` for the first call only.
    private func markSettlementApplied(_ generation: UUID) -> Bool {
        guard !appliedSettlementGenerations.contains(generation) else { return false }
        appliedSettlementGenerations.append(generation)
        if appliedSettlementGenerations.count > 8 {
            appliedSettlementGenerations.removeFirst(appliedSettlementGenerations.count - 8)
        }
        return true
    }

    /// Consumes one supervisor event on the main actor.
    private func handleSettlementEvent(_ event: RecordingSettlementSupervisor.Event) async {
        switch event {
        case let .mediaStarted(generation, kind):
            switch kind {
            case .audio:
                handleAudioReadiness(generation: generation)
            case .screen:
                await handleScreenFirstFrame(generation: generation)
            }
        case let .settled(generation, kind, settlement, reason):
            switch kind {
            case .audio:
                await applyAudioSettlement(
                    settlement,
                    generation: generation,
                    reason: reason,
                    owner: nil,
                    pipeline: nil
                )
            case .screen:
                let engine = self.engine
                let materialRoot = await screenPipelineAdapter?.materialRoot()
                await applyScreenSettlement(
                    settlement,
                    generation: generation,
                    reason: reason,
                    materialRoot: materialRoot,
                    engine: engine
                )
            }
        }
    }

    private func failedAudioResult(_ error: Error) -> AudioRecordingResult {
        makeAudioResult(failure: AppLocalization.recordingErrorDescription(error))
    }

    private func makeAudioResult(failure: String?) -> AudioRecordingResult {
        AudioRecordingResult(
            sessionID: audioSessionID ?? UUID(),
            kind: .audio,
            layout: audioConfiguration?.layout ?? .mixed,
            segmentCount: 0,
            droppedRanges: [],
            checkpointAge: 0,
            failure: failure
        )
    }

    private func completeAudioSession(with result: AudioRecordingResult, outputURL: URL? = nil) {
        guard lastAudioResult == nil else { return }
        lastAudioResult = result
        latestAudioOutputURL = outputURL
        audioProgressTask?.cancel()
        audioProgressTask = nil
        audioStartWatchdogTask?.cancel()
        audioStartWatchdogTask = nil
        audioStartTask = nil
        audioStopRequested = false
        let saved = Self.audioResultWasSaved(result)
        if saved {
            audioStateMachine.apply(.stopCompleted(saved: true))
        } else {
            audioStateMachine.apply(.stopCompleted(saved: false))
            audioStateMachine.apply(.failedRecoverable)
            registerRecoveryMaterials(sessionID: result.sessionID)
            if cancelRequested { outcomeState.beginSession() }
        }
        settleTerminal(wasSaved: saved)
        updateStatus(audioStateMachine.legacyStatus)
        if saved, result.segmentCount > 0, !panelHiddenByUser, !RecordingHUDPreferences.isHidden(in: defaults) {
            if controlPanel == nil { controlPanel = makeControlPanel(on: NSScreen.main) }
            controlPanel?.present(state: .audioFinished(
                savedSegments: result.segmentCount,
                outputURL: outputURL,
                previewReady: previewLease != nil,
                previewPlaying: previewPlayer?.isPlaying ?? false
            ))
        } else if !saved {
            presentAudioFailure(reason: result.failure ?? AppLocalization.string("Recording failed"))
        }
        sessionGeneration = UUID()
        activeRecordingKind = nil
        announcedPhase = nil
    }

    /// Registers recoverable material references without copying, moving, or deleting them.
    ///
    /// The URLs come from the existing pipeline ledger (`sessionRoot`) or its latest
    /// published file. Keeping the registration per session avoids a second global
    /// inventory beside the ledger.
    private func registerRecoveryMaterials(
        sessionID: UUID,
        pipeline explicitPipeline: RecordingSessionPipeline? = nil
    ) {
        guard audioPipelineStarted || explicitPipeline != nil else { return }
        var urls: [URL] = []
        if let pipeline = explicitPipeline ?? audioPipeline {
            urls.append(pipeline.ledger.sessionRoot.standardizedFileURL)
        }
        registerRecoveryMaterials(sessionID: sessionID, urls: urls)
    }

    /// Registers recoverable material URLs without copying, moving, or deleting them.
    ///
    /// Used by both audio retirement and a cancelled screen start whose late stop
    /// published a segment. The URLs come from the existing pipeline ledger or the
    /// screen outcome; no second inventory is created.
    private func registerRecoveryMaterials(sessionID: UUID, urls: [URL]) {
        guard !urls.isEmpty else { return }
        var existing = recoveryMaterialURLs[sessionID] ?? []
        for url in urls where !existing.contains(url) {
            existing.append(url)
        }
        recoveryMaterialURLs[sessionID] = existing
        pendingRecoverySessionIDs.insert(sessionID)
    }

    private func presentAudioFailure(reason: String) {
        let partialURL = audioSessionID.flatMap { recoveryMaterialURLs[$0]?.first }
        let payload = RecordingControlPanelFailure(
            reason: reason,
            canRetry: false,
            partialURL: partialURL
        )
        onFailureChange?(payload)
        presentFailurePanel(payload)
        if panelHiddenByUser || RecordingHUDPreferences.isHidden(in: defaults) {
            onMessage?(AppLocalization.string("Recording failed: %@", reason), .error)
        }
    }

    /// The single idempotent terminal settlement shared by audio and screen paths.
    ///
    /// - Parameters:
    ///   - wasSaved: Whether published media is durable.
    ///   - errorClass: Optional privacy-safe failure class for the signpost only.
    /// - Returns: `true` only for the call that wrote the outcome.
    @discardableResult
    private func settleTerminal(
        wasSaved: Bool,
        errorClass: RecordingDiagnosticErrorClass? = nil
    ) -> Bool {
        guard outcomeState.terminalOutcome == nil else { return false }
        let kind = activeRecordingKind
        outcomeState.finishSession(wasSaved: wasSaved)
        guard let kind, let outcome = outcomeState.terminalOutcome else { return true }
        let elapsed = phaseElapsedMilliseconds()
        let phase: RecordingPhase
        switch outcome {
        case .saved:
            phase = .finished
        case .failed:
            phase = .failed
        case .noActiveSession:
            phase = .cancelled
        }
        RecordingSignposts.emit(
            phase,
            kind: kind,
            elapsedMilliseconds: elapsed,
            errorClass: errorClass
        )
        announcePhase(phase, kind: kind)
        return true
    }

    /// Milliseconds since the current phase started, or `nil` when unknown.
    private func phaseElapsedMilliseconds() -> Int? {
        guard let phaseStartedAt else { return nil }
        return clock.milliseconds(since: phaseStartedAt)
    }

    /// Emits one numeric start-stage signpost for the current phase.
    private func emitStartPhaseSignpost(kind: RecordingKind) {
        RecordingSignposts.emitStartStage(
            startPhase.diagnosticCode,
            kind: kind,
            elapsedMilliseconds: phaseElapsedMilliseconds()
        )
    }

    /// Maps an error to the numeric signpost class. Never carries error text.
    static func diagnosticClass(for error: Error) -> RecordingDiagnosticErrorClass {
        if let readiness = error as? RecordingReadinessError {
            switch readiness {
            case .videoWriterFailed, .videoWriterWaitTimedOut:
                return .writer
            case .noVideoFrames, .noAudioSamples:
                return .source
            case .sourceListTimedOut, .startTimedOut, .uiWaitTimedOut:
                return .timeout
            case .cancelledWhileStarting, .supersededStart:
                return .cancelled
            }
        }
        if let engineError = error as? ScreenRecordingEngineError {
            switch engineError {
            case .sourceUnavailable, .invalidRegion, .invalidSourceDimensions, .invalidOutputDimensions:
                return .source
            case .writerInputUnavailable, .recordingFailed, .finalizationFailed, .previousStreamNotStopped:
                return .writer
            }
        }
        if let coordinatorError = error as? ScreenRecordingSessionCoordinatorError {
            switch coordinatorError {
            case .streamStopUnconfirmed, .noPublishedSegments, .audioFinalizationFailed:
                return .writer
            case .alreadyStarted, .notStarted, .invalidConfiguration:
                return .unknown
            }
        }
        if error is ScreenStartFailureReason { return .writer }
        return .unknown
    }

    /// Posts one kind-aware VoiceOver announcement per phase transition.
    func announcePhase(_ phase: RecordingPhase, kind: RecordingKind) {
        guard announcedPhase != phase else { return }
        let message: String?
        switch phase {
        case .preparing:
            message = AppLocalization.string(
                kind == .audio ? "Preparing audio recording" : "Preparing screen recording"
            )
        case .starting:
            message = nil
        case .recording:
            message = AppLocalization.string(kind == .audio ? "Recording audio" : "Recording screen")
        case .saving:
            message = AppLocalization.string(
                isResolvingQuit
                    ? "Saving recording before quitting"
                    : (kind == .audio ? "Saving audio recording" : "Saving screen recording")
            )
        case .finished:
            message = AppLocalization.string(
                kind == .audio ? "Audio recording saved" : "Screen recording saved"
            )
        case .failed:
            message = AppLocalization.string("Recording failed")
        case .cancelled, .quitResolved:
            message = nil
        }
        announcedPhase = phase
        guard let message else { return }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    private static func audioResultWasSaved(_ result: AudioRecordingResult) -> Bool {
        result.failure == nil && result.segmentCount > 0
    }

    private func sourcePickerCompleted(
        _ selection: RecordingSourceSelection?,
        preferences: RecordingPreferenceSnapshot,
        request: RecordingRequestIdentity
    ) async {
        guard isCurrentRequest(request), status == .selectingSource else { return }
        guard let selection else {
            finishSession(success: false)
            return
        }
        let screenMode = preferences.screenAudioMode
        if screenMode == .microphone || screenMode == .systemAndMicrophone {
            updatePreparationPhase(.checkingPermission)
            let permitted = await onRequestScreenMicrophoneAccess?() ?? true
            guard isCurrentRequest(request), status == .selectingSource else { return }
            guard permitted else {
                onMessage?(
                    AppLocalization.string(
                        "Microphone access is needed for the selected screen-audio source. Enable it in System Settings, or choose a source without the microphone."
                    ),
                    .error
                )
                onOpenPermissionGuide?()
                finishSession(success: false)
                return
            }
        }
        guard let destination = preferences.destinationDirectory else {
            onMessage?(
                AppLocalization.string("The Movies recording folder is unavailable."),
                .error
            )
            finishSession(success: false)
            return
        }

        let configuration = preferences.configuration(for: selection)
        do {
            try configuration.validate()
            updatePreparationPhase(.verifyingDestination)
            try await RecordingDestinationProbe.prepare(
                directory: destination,
                isCustom: preferences.hasCustomDestination,
                expectedVolumeUUID: preferences.customVolumeUUID
            )
        } catch {
            // The probe runs off the main actor; a cancel or a new attempt may win.
            guard isCurrentRequest(request), status == .selectingSource else { return }
            let message = AppLocalization.string(
                "Unable to start recording: %@",
                AppLocalization.recordingErrorDescription(error)
            )
            onMessage?(message, .error)
            finishSession(success: false)
            return
        }
        guard isCurrentRequest(request), status == .selectingSource else { return }

        // Freeze the session snapshot only now: the identity existed before the
        // permission wait, but the selection is real only after the picker returned.
        activeSession = RecordingSessionSnapshot(
            request: request,
            selection: selection,
            configuration: configuration,
            screenAudioMode: screenAudioModeOverride ?? preferences.screenAudioMode,
            screenAudioBitRate: preferences.screenAudioBitRate,
            destinationDirectory: destination,
            hasCustomDestination: preferences.hasCustomDestination,
            customVolumeUUID: preferences.customVolumeUUID
        )
        beginCountdown(for: selection)
    }

    /// Whether `request` still owns the preparation UI.
    private func isCurrentRequest(_ request: RecordingRequestIdentity) -> Bool {
        currentRequest == request && request.isCurrent(generation: sessionGeneration)
    }

    private func beginCountdown(for selection: RecordingSourceSelection) {
        let screen = screen(for: selection.displayID)
        sessionScreen = screen
        let panel = makeControlPanel(on: screen)
        controlPanel = panel
        if !RecordingHUDPreferences.isHidden(in: defaults) {
            panel.present(state: .countdown(3))
        }
        showCaptureFrame(for: selection)
        updateStatus(.countdown(3))

        countdownTask = Task { @MainActor [weak self] in
            for seconds in stride(from: 3, through: 1, by: -1) {
                guard let self, !Task.isCancelled, self.isCountingDown else { return }
                self.updateStatus(.countdown(seconds))
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
            guard let self, !Task.isCancelled, self.isCountingDown else { return }
            self.countdownTask = nil
            await self.startCapture()
        }
    }

    private func startCapture() async {
        guard status.isBusy, let activeSession, isCurrentRequest(activeSession.request) else { return }
        guard !screenStartOwnership.blocksNewStart else { return }
        guard audioResourceOwner == nil, !isAudioSessionActive, !hasPendingBackgroundFinalization else {
            // A previous audio operation still owns capture resources.
            onMessage?(
                AppLocalization.string(
                    "The previous recording is still stopping. Try again when it finishes."
                ),
                .info
            )
            finishSession(success: false)
            return
        }
        let request = activeSession.request
        let session = activeSession

        // The countdown has finished, but the post-countdown destination check may
        // still be suspended (e.g., a slow external volume). Do not leave the last
        // countdown digit on screen: show the real, cancellable verification step.
        preparationPhase = .verifyingDestination
        startPhase = .startingScreenWriter
        phaseStartedAt = clock.now
        updateStatus(.selectingSource)
        RecordingSignposts.emitStartStage(
            preparationDiagnosticCode(for: .verifyingDestination),
            kind: .screen
        )

        let recheck = RecordingDestinationRecheck(
            request: request,
            verify: {
                try await RecordingDestinationProbe.validateLocation(
                    directory: session.destinationDirectory,
                    isCustom: session.hasCustomDestination,
                    expectedVolumeUUID: session.customVolumeUUID
                )
            },
            isCurrent: { [weak self] request in
                self?.isCurrentRequest(request) ?? false
            },
            onVerified: { [weak self] in
                guard let self else { return }
                await self.beginScreenCapture(session: session, request: request)
            },
            onFailure: { [weak self] error in
                guard let self, self.isCurrentRequest(request) else { return }
                self.onMessage?(
                    AppLocalization.string(
                        "Unable to start recording: %@",
                        AppLocalization.recordingErrorDescription(error)
                    ),
                    .error
                )
                self.finishSession(success: false)
            }
        )
        await recheck.run()
    }

    /// Starts the screen writer after the destination recheck confirmed it is
    /// still the current request.
    private func beginScreenCapture(
        session: RecordingSessionSnapshot,
        request: RecordingRequestIdentity
    ) async {
        guard isCurrentRequest(request),
              let activeSession,
              activeSession.request == request
        else { return }
        let generation = request.generation
        // Access is decided before any writer, journal, or deadline exists. A denial
        // must be visible immediately and must not look like a first-frame timeout.
        guard screenPermissionGate.decide() == .granted else {
            presentScreenPermissionDenied()
            finishSession(success: false, errorClass: .permission)
            return
        }
        guard screenStartOwnership.beginStart(generation: generation) else { return }
        screenReleaseDestination = session.destinationDirectory
        didAnnounceScreenRelease = false
        lastScreenWriterDiagnostics = nil
        startPhase = .startingScreenWriter
        phaseStartedAt = clock.now
        updateStatus(.starting)
        RecordingSignposts.emit(.starting, kind: .screen)
        emitStartPhaseSignpost(kind: .screen)
        startScreenStartupWatchdog(generation: generation)

        let engine = ScreenRecordingEngine()
        self.engine = engine
        screenPipelineAdapter = nil
        RecordingWindowExclusionRegistry.shared.onChange = { [weak engine] windowIDs in
            guard let engine else { return }
            Task { await engine.updateExcludedWindowIDs(windowIDs) }
        }
        do {
            let audioFactoryOverride: ScreenAudioEngineFactoryOverride? = screenAudioFailureInjection
                ? Self.injectedFailingAudioFactory()
                : nil
            let coordinator = try ScreenRecordingSessionCoordinator.makeProduction(
                engine: engine,
                roots: pipelineRoots(for: session.destinationDirectory),
                audioEngineFactoryOverride: audioFactoryOverride
            )
            let adapter = ScreenRecordingPipelineAdapter(coordinator: coordinator)
            let screenMode = session.screenAudioMode
            let audioBitRate = session.screenAudioBitRate
            let startConfiguration = ScreenRecordingPipelineAdapter.makeStartConfiguration(
                source: session.selection.source,
                video: session.configuration,
                audioMode: screenMode,
                audioBitRate: audioBitRate,
                destinationDirectory: session.destinationDirectory,
                excludedWindowIDs: excludedWindowIDs,
                sourceDimensions: screenSourceDimensions(for: session.selection)
            )
            screenPipelineAdapter = adapter
            try await adapter.start(
                startConfiguration,
                onFailure: { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self,
                              generation == self.sessionGeneration,
                              self.screenPipelineAdapter != nil
                        else { return }
                        _ = await self.stopAndSave()
                    }
                }
            )
            screenStartWatchdogTask?.cancel()
            screenStartWatchdogTask = nil
            let mayPromote = screenStartOwnership.platformStartReturned(generation: generation)
            guard mayPromote, isCurrentRequest(request) else {
                // A cancel won while the start call was returning. The adapter is
                // live, so it must be stopped exactly once, but the settled UI and
                // any newer request must not be touched.
                runScreenCleanup(adapter: adapter, generation: generation)
                return
            }
            outcomeState.markCaptureAttempted()
            // The platform stream is up; from here the only readiness fact left is
            // a frame the writer actually accepted.
            startPhase = .awaitingFirstVideoFrame
            didAwaitFirstVideoFrame = true
            phaseStartedAt = clock.now
            emitStartPhaseSignpost(kind: .screen)
            // Arm before presenting: a stalled main thread must not be able to skip
            // the first-frame deadline. The stop closure talks to the capture actor
            // directly, so it never depends on the main actor either.
            let relay = ScreenStopFailureRelay()
            screenStopRelay = relay
            screenStopIntent = .startCleanup
            audioSettlementTicket = nil
            screenSettlementTicket = await settlementSupervisor.arm(
                generation: generation,
                kind: .screen,
                deadline: RecordingReadiness.firstVideoFrameDeadline,
                readiness: .poll {
                    if await coordinator.hasWrittenVideoFrame() { return .ready }
                    if let reason = await coordinator.writerFailureDescription() {
                        return .failed(reason)
                    }
                    return .waiting
                },
                stop: { [coordinator] in
                    do {
                        return .screen(try await coordinator.stopAndSave())
                    } catch {
                        await relay.record(error)
                        return .failed(
                            kind: .screen,
                            message: AppLocalization.recordingErrorDescription(error)
                        )
                    }
                }
            )
            // A cancel can win while arming. The cleanup latch then owns the only
            // stop, so the ticket must go away before it can fire a second one. A
            // frame that arrived meanwhile is kept: it already promoted the session.
            guard isCurrentRequest(request),
                  screenStartOwnership.ownerGeneration == generation,
                  !screenStartOwnership.isStopping
            else {
                if let ticket = screenSettlementTicket {
                    await settlementSupervisor.disarm(ticket: ticket)
                }
                screenSettlementTicket = nil
                screenStopRelay = nil
                runScreenCleanup(adapter: adapter, generation: generation)
                return
            }
            // Present only if readiness did not already move the session on.
            if status == .starting {
                updateStatus(.starting)
            }
        } catch {
            screenStartWatchdogTask?.cancel()
            screenStartWatchdogTask = nil
            if let coordinatorError = error as? ScreenRecordingSessionCoordinatorError,
               coordinatorError == .streamStopUnconfirmed,
               let adapter = screenPipelineAdapter {
                // The start tore down a stream that never confirmed it stopped.
                // Keep the adapter so the recovery action can confirm it, and keep
                // the ownership gate so no second stream can start meanwhile.
                guard screenStartOwnership.stopUnconfirmed(generation: generation) else { return }
                unconfirmedScreenStop = (adapter, await adapter.materialRoot())
                screenPipelineAdapter = nil
                guard isCurrentRequest(request) else {
                    presentScreenReleaseCapsule()
                    return
                }
                finishSession(success: false, errorClass: .source)
                presentScreenReleaseCapsule()
                return
            }
            // An ordinary failed start retained no stream. Release only the gate
            // this request owns, even if a newer request already replaced the UI.
            let released = screenStartOwnership.startFailed(generation: generation)
            if released { screenReleaseDestination = nil }
            guard isCurrentRequest(request) else {
                if released {
                    unconfirmedScreenStop = nil
                    clearScreenReleaseCapsule()
                }
                return
            }
            guard released else {
                // A stop already owns this start. Settle honestly and keep the
                // release state visible instead of claiming the failure alone.
                finishSession(success: false, errorClass: Self.diagnosticClass(for: error))
                presentScreenReleaseCapsule()
                return
            }
            screenPipelineAdapter = nil
            screenReleaseDestination = nil
            let message = AppLocalization.string(
                "Unable to start recording: %@",
                AppLocalization.recordingErrorDescription(error)
            )
            onMessage?(message, .error)
            finishSession(success: false, errorClass: Self.diagnosticClass(for: error))
        }
    }

    /// Bounds the platform screen start independently of first-frame readiness.
    ///
    /// On expiry the UI settles honestly; the late start performs at most one
    /// cleanup and the ownership gate stays closed until that cleanup drains.
    private func startScreenStartupWatchdog(generation: UUID) {
        screenStartWatchdogTask?.cancel()
        screenStartWatchdogTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: RecordingReadiness.platformStartDeadline)
            } catch {
                return
            }
            guard let self, !Task.isCancelled,
                  generation == self.sessionGeneration,
                  self.screenStartOwnership.isPlatformStartOutstanding,
                  self.status == .starting
            else { return }
            self.outcomeState.markCaptureAttempted()
            // The platform start never returned. The stream may exist and may be
            // capturing, so this is a release-pending state, not a finished
            // session: keep the gate, keep any written material, and leave a
            // persistent, reopenable explanation instead of a one-shot toast.
            self.finishSession(success: false, errorClass: .timeout)
            self.presentScreenReleaseCapsule()
        }
    }

    /// Promotes a screen session after the writer accepted its first frame.
    ///
    /// Driven only by the supervisor's `.mediaStarted` event; there is no
    /// main-actor polling task behind it.
    private func handleScreenFirstFrame(generation: UUID) async {
        guard generation == sessionGeneration,
              let request = currentRequest,
              request.generation == generation,
              isCurrentRequest(request)
        else { return }
        // A cancelled first-frame wait must never promote the settled session.
        guard screenStartOwnership.firstFrameAccepted(generation: generation) else { return }
        screenReleaseDestination = nil
        outcomeState.markRecordingStarted()
        recordingStartedAt = Date()
        updateStatus(.recording)
        RecordingSignposts.emit(.recording, kind: .screen)
        announcePhase(.recording, kind: .screen)
        if stopWhenStarted {
            // Readiness already made the session real, so the pending stop goes
            // through the normal recorded path (one stop, one settle).
            _ = await stopAndSave(reason: pendingStopReason)
        } else {
            startMonitoring()
        }
    }

    /// Ends a start whose first-frame gate closed without accepted media.
    ///
    /// The three failure modes stay apart: the writer reported a failure, the
    /// source never delivered a frame, or frames arrived but the writer never
    /// accepted one. The stop already ran in the supervisor; this only presents
    /// the failure and keeps any written material reachable.
    private func finishScreenStartWithoutFrames(
        failure: any Error,
        materialRoot: URL?,
        generation: UUID
    ) async {
        guard generation == sessionGeneration else { return }
        screenPipelineAdapter = nil
        if let engine {
            await handleRecordingFailure(
                failure,
                engine: engine,
                materialRoot: materialRoot,
                errorClass: Self.diagnosticClass(for: failure)
            )
        } else {
            finishSession(success: false, errorClass: Self.diagnosticClass(for: failure))
        }
    }

    /// Classifies a first-frame gate timeout without trusting any single signal.
    ///
    /// The three outcomes stay apart: the writer's own start failure, frames that
    /// never reached the capture callback, and frames that arrived but were never
    /// accepted by the writer.
    private func classifyScreenStartFailure(
        adapter: ScreenRecordingPipelineAdapter
    ) async -> Error {
        // The supervisor keeps the reason a readiness poll failed with, so a real
        // writer failure is never reported as a plain timeout.
        if let reason = await settlementSupervisor.diagnostics().readinessFailure {
            return ScreenStartFailureReason.writerFailed(reason)
        }
        if let diagnostics = await adapter.writerDiagnostics() {
            if diagnostics.startWritingResult == .failed {
                return ScreenStartFailureReason.writerFailed(
                    diagnostics.lastErrorDescription
                        ?? AppLocalization.string("The media writer could not start.")
                )
            }
            if diagnostics.syncDropCount > 0 {
                return ScreenStartFailureReason.writerNotReady(
                    diagnostics.lastErrorDescription
                        ?? AppLocalization.string(
                            "The media writer was not ready to accept a video sample."
                        )
                )
            }
        }
        if let description = await adapter.failureDescription(), !description.isEmpty {
            return ScreenStartFailureReason.writerFailed(description)
        }
        if !(await adapter.hasAcceptedCaptureFrame()) {
            return RecordingReadinessError.noVideoFrames
        }
        return RecordingReadinessError.videoWriterWaitTimedOut
    }

    /// Performs at most one initial stop for a start that never became a recording.
    ///
    /// The cleanup only releases the ownership gate once the stream stop is
    /// confirmed. An unconfirmed stop keeps the gate closed and raises an
    /// actionable recovery panel instead of spinning.
    private func runScreenCleanup(adapter: ScreenRecordingPipelineAdapter, generation: UUID) {
        guard screenCleanupTask == nil else { return }
        guard screenStartOwnership.beginInitialStop(generation: generation) else { return }
        // The gate now means "stop in flight", not "start unknown".
        refreshScreenReleaseCapsule()
        screenCleanupTask = Task { @MainActor [weak self] in
            var stopConfirmed = true
            var outcome: ScreenRecordingOutcome?
            do {
                outcome = try await adapter.stopAndSave()
            } catch {
                if let coordinatorError = error as? ScreenRecordingSessionCoordinatorError,
                   coordinatorError == .streamStopUnconfirmed {
                    stopConfirmed = false
                    if let self, self.screenStartOwnership.ownerGeneration == generation {
                        self.unconfirmedScreenStop = (adapter, await adapter.materialRoot())
                    }
                }
            }
            guard let self else { return }
            self.screenCleanupTask = nil
            if stopConfirmed {
                // Release the gate and remove the old notice in one synchronous
                // step: a new session cannot start in between, so this can never
                // touch a newer session's panel.
                guard self.screenStartOwnership.stopConfirmed(generation: generation) else { return }
                self.unconfirmedScreenStop = nil
                self.screenReleaseDestination = nil
                self.clearScreenReleaseCapsule()
                if let outcome, outcome.isSaved {
                    // This start never became a recording, so it must not reappear as
                    // a saved recording. A late frame may still have written a real
                    // file: keep its URL in the existing recovery registry and never
                    // toast or update the UI for it.
                    self.registerRecoveryMaterials(
                        sessionID: outcome.sessionID,
                        urls: outcome.segmentURLs
                    )
                }
            } else {
                guard self.screenStartOwnership.stopUnconfirmed(generation: generation) else { return }
                self.presentScreenReleaseCapsule()
            }
            if generation != self.sessionGeneration {
                RecordingSignposts.emit(.cancelled, kind: .screen)
            }
        }
    }

    private func finalizeRecording(reason: String?) async -> Bool {
        guard status == .recording, let engine else { return false }
        let generation = sessionGeneration
        guard screenStartOwnership.beginInitialStop(generation: generation) else { return false }
        monitoringTask?.cancel()
        monitoringTask = nil
        phaseStartedAt = clock.now
        updateStatus(.saving)
        if let kind = currentRecordingKind { RecordingSignposts.emit(.saving, kind: kind) }

        guard let adapter = screenPipelineAdapter else {
            return await finalizeLegacyRecording(reason: reason, engine: engine, generation: generation)
        }

        let materialRoot = await adapter.materialRoot()
        screenStopIntent = .recordingStop
        screenStopReason = reason
        screenSettlingGeneration = generation
        let ticket = screenSettlementTicket
        screenSettlementTicket = nil
        guard let ticket else {
            // Defensive: no supervisor ticket owns this start; seal the files with
            // the adapter's own single stop.
            return await finalizeLegacyScreenStop(
                adapter: adapter,
                engine: engine,
                reason: reason,
                generation: generation,
                materialRoot: materialRoot
            )
        }
        let bounded = await RecordingReadiness.awaitBounded(RecordingReadiness.uiSettleDeadline) {
            await self.settlementSupervisor.settle(ticket: ticket, reason: .requested)
        }
        guard let settled = bounded else {
            // The UI must not spin forever. Keep the real stop running, keep the
            // files untouched, and show what the user can act on now. The
            // settlement event converges the panel when the stop finishes.
            guard generation == sessionGeneration else { return false }
            presentScreenStopRecovery(
                materialRoot: materialRoot,
                reason: AppLocalization.string("The recording is still being saved in the background."),
                canRetry: false
            )
            return false
        }
        guard let settlement = settled else {
            // The ticket no longer owns the supervisor (defensive); seal the files
            // with the adapter's own single stop instead of waiting for an event.
            return await finalizeLegacyScreenStop(
                adapter: adapter,
                engine: engine,
                reason: reason,
                generation: generation,
                materialRoot: materialRoot
            )
        }
        _ = await applyScreenSettlement(
            settlement,
            generation: generation,
            reason: .requested,
            materialRoot: materialRoot,
            engine: engine
        )
        return outcomeState.terminalOutcome == .saved
    }

    /// Publishes a confirmed stop as the session's single saved outcome.
    ///
    /// - Parameters:
    ///   - finalURL: The published MP4.
    ///   - reason: Why the recording stopped, when the user gave one.
    ///   - generation: The session generation this result belongs to.
    ///   - audioFailure: Why the audio track is missing, when it could not start.
    /// - Returns: `true` after the saved outcome is presented.
    private func finishScreenRecording(
        finalURL: URL,
        reason: String?,
        generation: UUID,
        audioFailure: String? = nil
    ) -> Bool {
        _ = screenStartOwnership.stopConfirmed(generation: generation)
        screenReleaseDestination = nil
        let message: String
        if audioFailure != nil {
            // The video is complete; say plainly that only the audio is missing.
            message = AppLocalization.string(
                "The system audio could not be recorded. The video was saved: %@",
                finalURL.lastPathComponent
            )
        } else if let reason {
            message = AppLocalization.string(
                "Recording stopped and saved (%@): %@",
                reason,
                finalURL.lastPathComponent
            )
        } else {
            message = AppLocalization.string("Recording saved: %@", finalURL.lastPathComponent)
        }
        onMessage?(message, .success)
        finishSession(success: true)
        if RecordingHUDPreferences.revealsOnFinish(in: defaults) {
            revealInFinder(finalURL)
        }
        return true
    }

    /// Legacy single-file finalization kept for the non-segmented path.
    private func finalizeLegacyRecording(
        reason: String?,
        engine: ScreenRecordingEngine,
        generation: UUID
    ) async -> Bool {
        do {
            let finalURL = try await engine.stopAndSave()
            _ = screenStartOwnership.stopConfirmed(generation: generation)
            guard generation == sessionGeneration else { return true }
            return finishScreenRecording(finalURL: finalURL, reason: reason, generation: generation)
        } catch {
            _ = screenStartOwnership.stopConfirmed(generation: generation)
            guard generation == sessionGeneration else { return false }
            await handleRecordingFailure(
                error,
                engine: engine,
                materialRoot: nil,
                errorClass: Self.diagnosticClass(for: error)
            )
            return false
        }
    }

    /// Seals a screen session with the adapter's own single stop.
    ///
    /// Only used when no supervisor ticket owns the start (defensive), so this
    /// path cannot double-stop a supervised session.
    private func finalizeLegacyScreenStop(
        adapter: ScreenRecordingPipelineAdapter,
        engine: ScreenRecordingEngine,
        reason: String?,
        generation: UUID,
        materialRoot: URL?
    ) async -> Bool {
        do {
            let outcome = try await adapter.stopAndSave()
            _ = screenStartOwnership.stopConfirmed(generation: generation)
            guard generation == sessionGeneration else { return outcome.isSaved }
            guard outcome.isSaved, let url = outcome.latestPublishedURL else {
                let failure = ScreenRecordingEngineError.finalizationFailed(
                    outcome.failure ?? "The screen recording did not publish a video segment.",
                    partialURL: materialRoot
                )
                screenPipelineAdapter = nil
                await handleRecordingFailure(
                    failure,
                    engine: engine,
                    materialRoot: materialRoot,
                    errorClass: .writer
                )
                return false
            }
            screenPipelineAdapter = nil
            return finishScreenRecording(
                finalURL: url,
                reason: reason,
                generation: generation,
                audioFailure: outcome.audioFailure
            )
        } catch {
            if let coordinatorError = error as? ScreenRecordingSessionCoordinatorError,
               coordinatorError == .streamStopUnconfirmed {
                _ = screenStartOwnership.stopUnconfirmed(generation: generation)
                unconfirmedScreenStop = (adapter, materialRoot)
                guard generation == sessionGeneration else { return false }
                finishSession(success: false, errorClass: .writer)
                presentScreenReleaseCapsule()
                return false
            }
            _ = screenStartOwnership.stopConfirmed(generation: generation)
            guard generation == sessionGeneration else { return false }
            screenPipelineAdapter = nil
            finishSession(success: false, errorClass: .writer)
            onMessage?(
                AppLocalization.string(
                    "The screen recording could not be finalized. The written files were kept."
                ),
                .error
            )
            return false
        }
    }

    /// Applies one screen settlement on the main actor.
    ///
    /// This is the only place a screen stop's outcome reaches the UI: it releases
    /// the start gate even when a newer generation owns the screen, and it never
    /// claims a save without a published segment.
    ///
    /// - Parameters:
    ///   - settlement: The settled stop result.
    ///   - generation: The session generation the settlement belongs to.
    ///   - reason: Whether a request or the deadline produced it.
    ///   - materialRoot: Read-only material directory for a recoverable failure.
    ///   - engine: The engine that may still hold retryable material.
    /// - Returns: `true` only when this call published the saved session.
    @discardableResult
    func applyScreenSettlement(
        _ settlement: RecordingSettlement,
        generation: UUID,
        reason: RecordingSettlementReason,
        materialRoot: URL?,
        engine: ScreenRecordingEngine?
    ) async -> Bool {
        guard markSettlementApplied(generation) else {
            // The event consumer already applied this stop (or the awaiting caller
            // did). Report the real terminal outcome instead of presenting twice.
            return outcomeState.terminalOutcome == .saved
        }
        if let adapter = screenPipelineAdapter {
            lastScreenWriterDiagnostics = await adapter.writerDiagnostics()
        }
        let relay = screenStopRelay
        let unconfirmed = await relay?.wasUnconfirmedStreamStop() ?? false
        let intent = reason == .deadline ? .startCleanup : (screenStopIntent ?? .startCleanup)
        let stopReason = screenStopReason
        screenStopIntent = nil
        screenStopReason = nil
        screenStopRelay = nil
        if screenSettlingGeneration == generation { screenSettlingGeneration = nil }

        if unconfirmed {
            // Do not finalize files. Keep the adapter and the start gate so no
            // second stream can start, and give the user an actionable retry.
            _ = screenStartOwnership.stopUnconfirmed(generation: generation)
            if let adapter = screenPipelineAdapter {
                unconfirmedScreenStop = (adapter, materialRoot)
            }
            guard generation == sessionGeneration else { return false }
            finishSession(success: false, errorClass: .writer)
            presentScreenReleaseCapsule()
            return false
        }

        // The stream confirmed it stopped, so its gate is released even when a
        // newer session already owns the UI.
        _ = screenStartOwnership.stopConfirmed(generation: generation)
        guard generation == sessionGeneration else {
            if case let .screen(outcome) = settlement, outcome.isSaved {
                registerRecoveryMaterials(sessionID: outcome.sessionID, urls: outcome.segmentURLs)
            }
            return false
        }

        if intent == .startCleanup {
            // The session never became a recording: any written material is
            // recoverable only, and the failure explains why it never started.
            if case let .screen(outcome) = settlement, outcome.isSaved {
                registerRecoveryMaterials(sessionID: outcome.sessionID, urls: outcome.segmentURLs)
            }
            let failure: any Error
            if case let .failed(_, message) = settlement {
                failure = ScreenStartFailureReason.writerFailed(message)
            } else if let adapter = screenPipelineAdapter {
                failure = await classifyScreenStartFailure(adapter: adapter)
            } else {
                failure = reason == .deadline
                    ? RecordingReadinessError.noVideoFrames
                    : RecordingReadinessError.videoWriterFailed
            }
            await finishScreenStartWithoutFrames(
                failure: failure,
                materialRoot: materialRoot,
                generation: generation
            )
            return false
        }

        switch settlement {
        case let .screen(outcome):
            guard outcome.isSaved, let url = outcome.latestPublishedURL else {
                let failure = ScreenRecordingEngineError.finalizationFailed(
                    outcome.failure ?? "The screen recording did not publish a video segment.",
                    partialURL: materialRoot
                )
                screenPipelineAdapter = nil
                if let engine {
                    await handleRecordingFailure(
                        failure,
                        engine: engine,
                        materialRoot: materialRoot,
                        errorClass: .writer
                    )
                } else {
                    finishSession(success: false, errorClass: .writer)
                }
                return false
            }
            screenPipelineAdapter = nil
            return finishScreenRecording(
                finalURL: url,
                reason: stopReason,
                generation: generation,
                audioFailure: outcome.audioFailure
            )
        case let .failed(_, message):
            screenPipelineAdapter = nil
            finishSession(success: false, errorClass: .writer)
            onMessage?(message, .error)
            return false
        case .audio:
            screenPipelineAdapter = nil
            finishSession(success: false, errorClass: .writer)
            return false
        }
    }

    /// The screen writer's privacy-safe counters for this session, when one is live.
    ///
    /// Exposed for the failure classifier and the agent report; it never carries
    /// frame content, window titles, or application names.
    func screenWriterDiagnostics() async -> ScreenWriterDiagnostics? {
        if let adapter = screenPipelineAdapter, let diagnostics = await adapter.writerDiagnostics() {
            lastScreenWriterDiagnostics = diagnostics
            return diagnostics
        }
        return lastScreenWriterDiagnostics
    }

    /// An audio engine factory that always fails, for the agent's degraded scenario.
    ///
    /// Production never calls it; it exists so the harness can prove that a failed
    /// audio track still produces a complete video.
    ///
    /// - Returns: A factory that throws on every call.
    private static func injectedFailingAudioFactory() -> ScreenAudioEngineFactoryOverride {
        { _, _, _ in
            throw AudioRecordingEngineError.startFailed("injected screen audio failure")
        }
    }

    /// Shows the actionable screen-permission denial.
    ///
    /// The copy names the exact System Settings pane; the guide is opened as well
    /// so the user lands on the switch instead of guessing where it is.
    func presentScreenPermissionDenied() {
        onMessage?(AppLocalization.string(ScreenCapturePermissionCopy.deniedKey), .error)
        onOpenPermissionGuide?()
    }

    /// Builds the capsule payload for a stop that has not confirmed yet.
    func screenStopRecoveryPayload(
        materialRoot: URL? = nil,
        reason: String? = nil,
        canRetry: Bool = true
    ) -> RecordingControlPanelFailure {
        RecordingControlPanelFailure(
            reason: reason ?? AppLocalization.string(
                "The capture stream did not confirm it stopped. Your recording was kept; wait for it to stop before starting another one."
            ),
            canRetry: canRetry,
            partialURL: materialRoot ?? unconfirmedScreenStop?.materialRoot
        )
    }

    /// Shows an actionable capsule for a stop that has not confirmed yet.
    ///
    /// Retry re-enters the same stop (never a second stream); Show in Finder opens
    /// the retained material directory. Nothing is deleted.
    func presentScreenStopRecovery(
        materialRoot: URL? = nil,
        reason: String? = nil,
        canRetry: Bool = true
    ) {
        let payload = screenStopRecoveryPayload(
            materialRoot: materialRoot,
            reason: reason,
            canRetry: canRetry
        )
        onFailureChange?(payload)
        presentFailurePanel(payload)
        if panelHiddenByUser || RecordingHUDPreferences.isHidden(in: defaults) {
            onMessage?(payload.reason, .error)
        }
    }

    /// Retries an unconfirmed screen stop, then reports its real result.
    ///
    /// A real start cleanup or stop that is still running is never joined by a
    /// second stop: the retry refuses while one is in flight, and when it does run
    /// it reuses the single `screenStopTask` slot.
    @discardableResult
    func retryUnconfirmedScreenStop() async -> Bool {
        guard let pending = unconfirmedScreenStop,
              !isScreenStopInFlight,
              let generation = screenStartOwnership.ownerGeneration,
              screenStartOwnership.beginStopRetry(generation: generation)
        else { return false }
        let task = Task { try await pending.adapter.stopAndSave() }
        screenStopTask = task
        // Reflect the in-flight retry immediately: Retry disables, no spinner.
        refreshScreenReleaseCapsule()
        do {
            let outcome = try await task.value
            screenStopTask = nil
            _ = screenStartOwnership.stopConfirmed(generation: generation)
            unconfirmedScreenStop = nil
            screenReleaseDestination = nil
            screenPipelineAdapter = nil
            retainedFailure = nil
            clearScreenReleaseCapsule()
            controlPanel?.dismiss()
            controlPanel = nil
            onFailureChange?(nil)
            if outcome.isSaved, let url = outcome.latestPublishedURL {
                let message = outcome.audioFailure == nil
                    ? AppLocalization.string("Recording saved: %@", url.lastPathComponent)
                    : AppLocalization.string(
                        "The system audio could not be recorded. The video was saved: %@",
                        url.lastPathComponent
                    )
                onMessage?(message, .success)
                if RecordingHUDPreferences.revealsOnFinish(in: defaults) { revealInFinder(url) }
                return true
            }
            onMessage?(
                AppLocalization.string(
                    "The screen recording could not be finalized. The written files were kept."
                ),
                .error
            )
            return false
        } catch {
            screenStopTask = nil
            _ = screenStartOwnership.stopUnconfirmed(generation: generation)
            presentScreenReleaseCapsule()
            return false
        }
    }

    private func screenSourceDimensions(for selection: RecordingSourceSelection) -> CGSize {
        if case .display = selection.source { return selection.displayPixelSize }
        guard selection.displayFrame.width > 0, selection.displayFrame.height > 0 else {
            return selection.displayPixelSize
        }
        let scaleX = selection.displayPixelSize.width / selection.displayFrame.width
        let scaleY = selection.displayPixelSize.height / selection.displayFrame.height
        return CGSize(
            width: selection.sourceFrame.width * scaleX,
            height: selection.sourceFrame.height * scaleY
        )
    }

    private func startMonitoring() {
        monitoringTask?.cancel()
        let generation = sessionGeneration
        monitoringTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                guard let self,
                      generation == self.sessionGeneration,
                      self.status == .recording
                else { return }
                await self.reportMissingFramesIfNeeded()
                guard generation == self.sessionGeneration, self.status == .recording else { return }
                if let reason = await self.recordingInterruptionReason() {
                    guard generation == self.sessionGeneration, self.status == .recording else { return }
                    _ = await self.stopAndSave(reason: reason)
                    return
                }
            }
        }
    }

    private func recordingInterruptionReason() async -> String? {
        guard let activeSession else { return nil }
        switch await RecordingDestinationProbe.capacity(
            at: activeSession.destinationDirectory,
            expectedVolumeUUID: activeSession.customVolumeUUID
        ) {
        case .capacityUnreadable:
            // A slow or unreadable volume is not a confirmed failure; skip this poll.
            return nil
        case .locationUnavailable:
            return AppLocalization.string("The recording destination is no longer available.")
        case let .available(availableBytes, _, _):
            guard availableBytes >= RecordingStorage.minimumContinueFreeSpace else {
                return AppLocalization.string("Free space fell below 512 MB; the recording is being finalized.")
            }
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            // Rare failure path: this poll ends the recording anyway, so fall
            // back to the existing check to keep both messages (permission lost
            // vs. source unavailable) and the permission guide exactly as today.
            guard await captureOrchestrator.checkPermissionStatus() else {
                onOpenPermissionGuide?()
                return AppLocalization.string(
                    "Screen recording permission was lost; the recording is being finalized."
                )
            }
            return AppLocalization.string(
                "Recording sources are no longer available; the recording is being finalized."
            )
        }

        // Steady state: one enumeration answers both permission and source changes.
        guard await captureOrchestrator.checkPermissionStatus(displayCount: content.displays.count) else {
            onOpenPermissionGuide?()
            return AppLocalization.string(
                "Screen recording permission was lost; the recording is being finalized."
            )
        }
        return Self.sourceChangeReason(for: activeSession.selection, in: content)
    }

    private static func sourceChangeReason(
        for selection: RecordingSourceSelection,
        in content: SCShareableContent
    ) -> String? {
        guard let display = content.displays.first(where: { $0.displayID == selection.displayID }) else {
            return AppLocalization.string("The selected display was disconnected; the recording is being finalized.")
        }
        guard display.width == Int(selection.displayPixelSize.width),
              display.height == Int(selection.displayPixelSize.height),
              display.frame.size == selection.displayFrame.size else {
            return AppLocalization.string("The selected display changed size; the recording is being finalized.")
        }

        switch selection.source {
        case .display, .region:
            return nil
        case .window(let windowID):
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                return AppLocalization.string(
                    "The selected window is no longer available; the recording is being finalized."
                )
            }
            guard window.frame.size == selection.sourceFrame.size,
                  display.frame.contains(window.frame) else {
                return AppLocalization.string(
                    "The selected window changed size or display; the recording is being finalized."
                )
            }
            return nil
        }
    }

    private func handleInterruption(_ reason: String) async {
        switch status {
        case .idle:
            return
        case .selectingSource, .countdown:
            cancelPendingStart()
            onMessage?(reason, .info)
        case .starting, .recording, .saving:
            _ = await stopAndSave(reason: reason)
        }
    }

    private func installLifecycleObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        notificationObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.handleInterruption(AppLocalization.string("The Mac is going to sleep."))
            }
        })

        notificationObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.hasPendingBackgroundFinalization {
                    _ = await self.waitForBackgroundFinalization()
                } else if self.isAudioSessionActive {
                    // If sleep suspended the notification task before it requested a stop, resume
                    // through the same pipeline/ledger finalizer instead of claiming the session saved.
                    _ = await self.stopAudio()
                }
            }
        })

        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.status == .recording || self.status == .starting else { return }
                await self.handleInterruptionIfSourceChanged()
            }
        })

        let distributedCenter = DistributedNotificationCenter.default()
        notificationObservers.append(distributedCenter.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                // Audio capture is allowed to continue through a lock; sleep still requests a
                // durable stop above. Preserve the existing screen-recording interruption path.
                guard let self, !self.isAudioSessionActive, !self.hasPendingBackgroundFinalization else {
                    return
                }
                await self.handleInterruption(AppLocalization.string("The screen was locked."))
            }
        })
    }

    private func handleInterruptionIfSourceChanged() async {
        guard let activeSession else { return }
        do {
            let content = try await SCShareableContent.current
            if let reason = Self.sourceChangeReason(for: activeSession.selection, in: content) {
                await handleInterruption(reason)
            }
        } catch {
            await handleInterruption(
                AppLocalization.string("Recording sources are no longer available; the recording is being finalized.")
            )
        }
    }

    func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
                == displayID
        }
    }

    private var isCountingDown: Bool {
        if case .countdown = status { return true }
        return false
    }

    func updateStatus(_ status: RecordingSessionStatus) {
        self.status = status
        onStatusChange?(status)
        guard !panelHiddenByUser else { return }
        switch status {
        case .countdown(let seconds):
            controlPanel?.update(state: .countdown(seconds))
        case .starting:
            let kind = currentRecordingKind ?? .screen
            let state = RecordingControlPanelState.starting(kind: kind, phase: startPhase)
            if audioStateMachine.state == .starting {
                if controlPanel == nil { controlPanel = makeControlPanel(on: NSScreen.main) }
                controlPanel?.present(state: state)
                return
            }
            controlPanel?.update(state: state)
        case .recording:
            if audioStateMachine.state == .recording {
                presentAudioRecordingHUD()
                return
            }
            let startedAt = recordingStartedAt ?? Date()
            recordingStartedAt = startedAt
            controlPanel?.update(state: .recording(startedAt: startedAt))
        case .saving:
            if audioStateMachine.state == .stopping || audioStateMachine.state == .finalizing {
                updateAudioHUD()
                return
            }
            controlPanel?.update(state: .saving(
                kind: currentRecordingKind ?? .screen,
                fileName: nil,
                isBeforeQuit: isResolvingQuit
            ))
        case .idle, .selectingSource:
            if status == .selectingSource {
                if controlPanel == nil { controlPanel = makeControlPanel(on: NSScreen.main) }
                controlPanel?.present(
                    state: .preparing(
                        kind: currentRecordingKind ?? .screen,
                        phase: preparationPhase
                    )
                )
            }
        }
    }

    func finishSession(success: Bool, errorClass: RecordingDiagnosticErrorClass? = nil) {
        Task { @MainActor [weak self] in await self?.closeAudioPreview() }
        settleTerminal(wasSaved: success, errorClass: errorClass)
        countdownTask?.cancel()
        countdownTask = nil
        monitoringTask?.cancel()
        monitoringTask = nil
        screenStartWatchdogTask?.cancel()
        screenStartWatchdogTask = nil
        // Never release the screen ownership gate here: a late start or an
        // unconfirmed stream stop must keep it closed until its own path confirms.
        isPresentingScreenRelease = false
        didAnnounceScreenRelease = false
        controlPanel?.dismiss()
        controlPanel = nil
        captureFramePanel?.dismiss()
        captureFramePanel = nil
        recordingStartedAt = nil
        panelHiddenByUser = false
        watchdogReported = false
        engine = nil
        activeSession = nil
        RecordingWindowExclusionRegistry.shared.onChange = { _ in }
        stopWhenStarted = false
        pendingStopReason = nil
        currentRequest = nil
        screenPreparationTask?.cancel()
        screenPreparationTask = nil
        preparationPhase = .checkingPermission
        startPhase = .startingScreenWriter
        onScreenshotShelfRecordingChange?(false)
        updateStatus(.idle)
        sessionGeneration = UUID()
        activeRecordingKind = nil
        announcedPhase = nil
        cancelRequested = false

        let waiters = stopWaiters
        stopWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: outcomeState.terminalOutcome == .saved)
        }

        let terminalOutcome = outcomeState.terminalOutcome ?? .failed
        let outcomeWaiters = outcomeWaiters
        self.outcomeWaiters.removeAll()
        for waiter in outcomeWaiters {
            waiter.resume(returning: terminalOutcome)
        }
    }

    private func waitForStopCompletion() async -> Bool {
        await withCheckedContinuation { continuation in
            stopWaiters.append(continuation)
        }
    }

    private func waitForTerminalOutcome() async -> RecordingSessionTerminalOutcome {
        await withCheckedContinuation { continuation in
            outcomeWaiters.append(continuation)
        }
    }
}

extension RecordingSessionController {
    /// Reserves the screen request identity without the picker (agent channel).
    ///
    /// Mirrors ``beginAudioRequest(requiresMicrophonePermission:)``: it takes the
    /// idle session and exposes a cancellable `.selectingSource` state, so the
    /// caller can drive a real start without clicking the source picker.
    ///
    /// - Returns: The frozen request identity, or `nil` when another session owns capture.
    @discardableResult
    func beginScreenRequest() -> RecordingRequestIdentity? {
        guard status == .idle, !hasLiveCaptureResources, !isAudioSessionActive,
              !hasPendingBackgroundFinalization, !screenStartOwnership.blocksNewStart
        else { return nil }
        let request = RecordingRequestIdentity(kind: .screen)
        dismissFailurePanel()
        sessionGeneration = request.generation
        currentRequest = request
        activeRecordingKind = .screen
        announcedPhase = nil
        cancelRequested = false
        outcomeState.beginSession()
        preparationPhase = .checkingPermission
        startPhase = .startingScreenWriter
        didAwaitFirstVideoFrame = false
        phaseStartedAt = clock.now
        updateStatus(.selectingSource)
        return request
    }

    /// Starts a screen session from an explicit selection, skipping picker and countdown.
    ///
    /// The agent channel uses this so a real screen session runs headless. It reuses
    /// the same snapshot, destination check, permission gate, and settlement path as
    /// the interactive start, so it cannot bypass production behavior.
    ///
    /// - Parameters:
    ///   - selection: The display/window/region the scenario records.
    ///   - request: The identity returned by ``beginScreenRequest()``.
    func startScreen(
        selection: RecordingSourceSelection,
        request: RecordingRequestIdentity
    ) async {
        guard isCurrentRequest(request), status == .selectingSource else { return }
        let preferences = RecordingPreferenceSnapshot(defaults: defaults)
        guard let destination = preferences.destinationDirectory else {
            onMessage?(
                AppLocalization.string("The Movies recording folder is unavailable."),
                .error
            )
            finishSession(success: false)
            return
        }
        let configuration = preferences.configuration(for: selection)
        do {
            try configuration.validate()
            updatePreparationPhase(.verifyingDestination)
            try await RecordingDestinationProbe.prepare(
                directory: destination,
                isCustom: preferences.hasCustomDestination,
                expectedVolumeUUID: preferences.customVolumeUUID
            )
        } catch {
            guard isCurrentRequest(request), status == .selectingSource else { return }
            onMessage?(
                AppLocalization.string(
                    "Unable to start recording: %@",
                    AppLocalization.recordingErrorDescription(error)
                ),
                .error
            )
            finishSession(success: false)
            return
        }
        guard isCurrentRequest(request), status == .selectingSource else { return }
        let session = RecordingSessionSnapshot(
            request: request,
            selection: selection,
            configuration: configuration,
            screenAudioMode: screenAudioModeOverride ?? preferences.screenAudioMode,
            screenAudioBitRate: preferences.screenAudioBitRate,
            destinationDirectory: destination,
            hasCustomDestination: preferences.hasCustomDestination,
            customVolumeUUID: preferences.customVolumeUUID
        )
        activeSession = session
        await beginScreenCapture(session: session, request: request)
    }

    func startRecording() {
        guard status == .idle else { return }
        guard !hasLiveCaptureResources else {
            // A pending stream release is the blocking fact; show it again so it
            // can be found later instead of a one-shot toast.
            if presentScreenReleaseCapsuleIfNeeded() { return }
            onMessage?(
                AppLocalization.string(
                    "The previous recording is still stopping. Try again when it finishes."
                ),
                .info
            )
            return
        }
        dismissFailurePanel()
        let request = RecordingRequestIdentity(kind: .screen)
        sessionGeneration = request.generation
        currentRequest = request
        activeRecordingKind = .screen
        announcedPhase = nil
        cancelRequested = false
        outcomeState.beginSession()
        preparationPhase = .checkingPermission
        startPhase = .startingScreenWriter
        didAwaitFirstVideoFrame = false
        phaseStartedAt = clock.now
        let preferences = RecordingPreferenceSnapshot(defaults: defaults)
        onScreenshotShelfRecordingChange?(true)
        updateStatus(.selectingSource)
        RecordingSignposts.emit(.preparing, kind: .screen)
        announcePhase(.preparing, kind: .screen)

        screenPreparationTask?.cancel()
        screenPreparationTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, self.isCurrentRequest(request) else { return }
            self.updatePreparationPhase(.checkingPermission)
            // Preflight is synchronous and only decides whether the enumeration
            // below may be bounded. It never decides access by itself: macOS 15
            // ad-hoc builds can report false while access is really granted.
            let accessAlreadyGranted = CGPreflightScreenCaptureAccess()
            if !accessAlreadyGranted {
                guard self.isCurrentRequest(request), !Task.isCancelled else { return }
                self.updatePreparationPhase(.waitingForAuthorization)
            }
            let outcome = await ScreenSourceProbe.load()
            // A cancel or a newer attempt discards this late result entirely.
            guard self.isCurrentRequest(request), self.status == .selectingSource else { return }

            switch outcome {
            case let .ready(content):
                _ = await self.captureOrchestrator.checkPermissionStatus(
                    displayCount: content.displays.count
                )
                guard self.isCurrentRequest(request), self.status == .selectingSource else { return }
                self.updatePreparationPhase(.choosingSource)
                self.showSourcePicker(
                    for: request,
                    preferences: preferences,
                    content: content
                )
            case .denied:
                let decision = RecordingPermissionDecision.beforePicker(
                    accessAvailable: false,
                    isCurrentAttempt: self.isCurrentRequest(request),
                    isSelectingSource: self.status == .selectingSource
                )
                guard case .openPermissionGuide = decision else { return }
                self.finishSession(success: false, errorClass: .permission)
                self.onOpenPermissionGuide?()
            case .timedOut:
                self.onMessage?(
                    AppLocalization.string("Loading the recording sources took too long. Try again."),
                    .error
                )
                self.finishSession(success: false, errorClass: .timeout)
            case let .failed(message):
                self.onMessage?(
                    AppLocalization.string("Could not load recording sources: %@", message),
                    .error
                )
                self.finishSession(success: false, errorClass: .source)
            }
        }
    }

    /// Creates the audio request identity before the microphone permission prompt.
    ///
    /// The HUD can then show a real permission wait instead of a silent gap. The
    /// caller must pass this identity to ``startAudio(_:roots:isCustomDestination:expectedVolumeUUID:request:)``
    /// and call ``cancelAudioRequest(_:)`` if permission is denied.
    ///
    /// - Parameter requiresMicrophonePermission: Whether this request will ask for
    ///   microphone access. System-only requests go straight to the destination check.
    /// - Returns: The frozen request identity, or `nil` when another session owns capture.
    @discardableResult
    func beginAudioRequest(requiresMicrophonePermission: Bool = true) -> RecordingRequestIdentity? {
        guard status == .idle, !hasLiveCaptureResources, !isAudioSessionActive,
              !hasPendingBackgroundFinalization
        else { return nil }
        let request = RecordingRequestIdentity(kind: .audio)
        dismissFailurePanel()
        sessionGeneration = request.generation
        currentRequest = request
        activeRecordingKind = .audio
        announcedPhase = nil
        cancelRequested = false
        outcomeState.beginSession()
        preparationPhase = requiresMicrophonePermission ? .checkingPermission : .verifyingDestination
        startPhase = .startingAudioPipeline
        phaseStartedAt = clock.now
        updateStatus(.selectingSource)
        RecordingSignposts.emit(.preparing, kind: .audio)
        announcePhase(.preparing, kind: .audio)
        return request
    }

    /// Settles an audio request that never reached `startAudio`, but only if it
    /// still owns the UI. A late permission result must not cancel a newer request.
    func cancelAudioRequest(_ request: RecordingRequestIdentity) {
        guard isCurrentRequest(request), status == .selectingSource else { return }
        cancelPendingStart()
    }

    /// Presents one preparation step in the floating panel, with its Cancel action.
    func updatePreparationPhase(_ phase: RecordingPreparationPhase) {
        guard status == .selectingSource else { return }
        let elapsed = phaseElapsedMilliseconds()
        preparationPhase = phase
        phaseStartedAt = clock.now
        RecordingSignposts.emitStartStage(
            preparationDiagnosticCode(for: phase),
            kind: currentRecordingKind ?? .screen,
            elapsedMilliseconds: elapsed
        )
        guard !panelHiddenByUser, !RecordingHUDPreferences.isHidden(in: defaults) else { return }
        if controlPanel == nil { controlPanel = makeControlPanel(on: NSScreen.main) }
        controlPanel?.present(
            state: .preparing(kind: currentRecordingKind ?? .screen, phase: phase)
        )
    }

    func preparationDiagnosticCode(for phase: RecordingPreparationPhase) -> Int {
        switch phase {
        case .checkingPermission: 11
        case .waitingForAuthorization: 12
        case .loadingSources: 13
        case .choosingSource: 14
        case .verifyingDestination: 15
        }
    }

    private func showSourcePicker(
        for request: RecordingRequestIdentity,
        preferences: RecordingPreferenceSnapshot,
        content: SCShareableContent
    ) {
        RecordingSourcePickerPanel.show(
            content: content,
            onComplete: { [weak self] selection in
                Task { @MainActor [weak self] in
                    await self?.sourcePickerCompleted(
                        selection,
                        preferences: preferences,
                        request: request
                    )
                }
            },
            onFailure: { [weak self] message in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let accessAvailable = await self.captureOrchestrator.checkPermissionStatus()
                    let decision = RecordingPermissionDecision.afterPickerFailure(
                        accessAvailable: accessAvailable,
                        isCurrentAttempt: self.isCurrentRequest(request)
                    )
                    switch decision {
                    case .showPickerFailure:
                        self.onMessage?(message, .error)
                    case .openPermissionGuide:
                        self.onOpenPermissionGuide?()
                    case .showPicker, .ignore:
                        break
                    }
                }
            }
        )
    }
}
