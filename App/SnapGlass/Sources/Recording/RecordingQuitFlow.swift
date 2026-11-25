import CaptureCore
import Foundation

enum RecordingSessionTerminalOutcome: Equatable, Sendable {
    case saved
    case noActiveSession
    case failed

    var allowsApplicationQuit: Bool {
        switch self {
        case .saved, .noActiveSession:
            true
        case .failed:
            false
        }
    }
}

enum RecordingAudioSessionState: Equatable, Sendable {
    case idle
    case starting
    case recording
    case stopping
    case finalizing
    case finished
    case failedRecoverable
}

enum RecordingAudioSessionTransition: Equatable, Sendable {
    case begin
    case started
    case stopRequested
    case stopCompleted(saved: Bool)
    case failedRecoverable
}

struct RecordingAudioSessionStateMachine {
    private(set) var state: RecordingAudioSessionState

    init(state: RecordingAudioSessionState = .idle) {
        self.state = state
    }

    mutating func apply(_ transition: RecordingAudioSessionTransition) {
        switch transition {
        case .begin:
            guard state == .idle || state == .finished || state == .failedRecoverable else { return }
            state = .starting
        case .started:
            guard state == .starting else { return }
            state = .recording
        case .stopRequested:
            guard state == .starting || state == .recording else { return }
            state = .stopping
        case .stopCompleted(saved: true):
            guard state == .finalizing else { return }
            state = .finished
        case .stopCompleted(saved: false):
            guard state == .stopping || state == .finalizing else { return }
            state = .failedRecoverable
        case .failedRecoverable:
            guard state != .idle && state != .finished else { return }
            state = .failedRecoverable
        }
    }

    mutating func beginFinalization() {
        guard state == .stopping else { return }
        state = .finalizing
    }

    var legacyStatus: RecordingSessionStatus {
        switch state {
        case .starting: .starting
        case .recording: .recording
        case .stopping, .finalizing: .saving
        case .idle, .finished, .failedRecoverable: .idle
        }
    }
}

struct RecordingSessionOutcomeState {
    private(set) var terminalOutcome: RecordingSessionTerminalOutcome?
    private var recordingDidStart = false
    private var captureAttempted = false

    mutating func beginSession() {
        terminalOutcome = nil
        recordingDidStart = false
        captureAttempted = false
    }

    mutating func markRecordingStarted() {
        recordingDidStart = true
    }

    /// Records that capture resources were started, even if no media arrived.
    mutating func markCaptureAttempted() {
        captureAttempted = true
    }

    mutating func finishSession(wasSaved: Bool) {
        guard terminalOutcome == nil else { return }
        if wasSaved {
            terminalOutcome = .saved
        } else {
            terminalOutcome = (recordingDidStart || captureAttempted) ? .failed : .noActiveSession
        }
        recordingDidStart = false
        captureAttempted = false
    }
}

struct RecordingQuitFlow {
    enum Request: Equatable {
        case terminateNow
        case terminateCancel
        case confirm
        case waitForRecording
    }

    private(set) var isHandlingRequest = false

    mutating func request(needsConfirmation: Bool, isSaving: Bool) -> Request {
        guard !isHandlingRequest else { return .terminateCancel }
        if isSaving {
            isHandlingRequest = true
            return .waitForRecording
        }
        guard needsConfirmation else { return .terminateNow }
        isHandlingRequest = true
        return .confirm
    }

    mutating func cancel() {
        isHandlingRequest = false
    }

    mutating func complete(with outcome: RecordingSessionTerminalOutcome?) -> Bool {
        guard isHandlingRequest else { return false }
        isHandlingRequest = false
        return outcome?.allowsApplicationQuit ?? false
    }
}

/// The immutable identity of one recording request.
///
/// The identity is created synchronously at the request entry point, before the
/// first suspension point. It deliberately carries only request-level facts:
/// permission resolution and source selection may finish later, so the session
/// snapshot (selection, resolved configuration, destination) is frozen separately
/// once the user has actually chosen a source.
///
/// `generation` reuses the controller's existing `sessionGeneration`; there is no
/// second attempt identifier. A late completion belongs to this request only when
/// its generation still matches.
public struct RecordingRequestIdentity: Equatable, Sendable {
    /// The request generation; the same value the controller keeps as `sessionGeneration`.
    public let generation: UUID
    /// The capture kind the request asked for.
    public let kind: RecordingKind

    /// Creates a request identity.
    ///
    /// - Parameters:
    ///   - generation: The request/session generation. Defaults to a fresh UUID.
    ///   - kind: The requested capture kind.
    public init(generation: UUID = UUID(), kind: RecordingKind) {
        self.generation = generation
        self.kind = kind
    }

    /// Whether a completion still belongs to the current request generation.
    public func isCurrent(generation: UUID) -> Bool {
        self.generation == generation
    }

    /// Classifies a completion that may arrive after the request was settled.
    ///
    /// A stale result must never write UI or session state. It still has one
    /// obligation when it owns live resources: the resource must be cleaned up
    /// exactly once. A stale result with no live resource is simply discarded.
    ///
    /// - Parameters:
    ///   - generation: The generation the controller currently considers current.
    ///   - holdsResource: Whether the late result still owns a pipeline, adapter,
    ///     or capture stream that must be stopped.
    public func disposition(
        generation: UUID,
        holdsResource: Bool
    ) -> RecordingLateResultDisposition {
        guard isCurrent(generation: generation) else {
            return holdsResource ? .cleanupOnly : .discard
        }
        return .apply
    }
}

/// What the controller may do with a completion for a recording request.
public enum RecordingLateResultDisposition: Equatable, Sendable {
    /// The completion still belongs to the current request; state may be written.
    case apply
    /// The completion is stale but owns resources; clean up once, never touch UI.
    case cleanupOnly
    /// The completion is stale and owns nothing; discard it silently.
    case discard
}

/// The single injectable clock used for phase durations and diagnostics.
///
/// Readiness deadlines keep using their own real clock in `RecordingReadiness`;
/// this type exists so phase-length assertions do not need to sleep.
struct RecordingPhaseClock: Sendable {
    private let nowProvider: @Sendable () -> ContinuousClock.Instant

    /// Creates a phase clock.
    ///
    /// - Parameter now: The instant provider. Defaults to `ContinuousClock.now`.
    init(now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        nowProvider = now
    }

    /// The current instant from the injected provider.
    var now: ContinuousClock.Instant { nowProvider() }

    /// Whole milliseconds between `start` and the current instant.
    ///
    /// - Parameter start: The instant the phase started.
    /// - Returns: Non-negative elapsed milliseconds.
    func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let duration = start.duration(to: now)
        let components = duration.components
        let seconds = max(0, components.seconds)
        let attoseconds = max(0, components.attoseconds)
        return Int(clamping: seconds * 1_000 + attoseconds / 1_000_000_000_000_000)
    }
}

/// The truthful sub-stage of a start that has not become a recording yet.
///
/// These four stages are what the HUD may show. They map onto the existing
/// `RecordingSessionStatus.starting`; no parallel status machine is added.
enum RecordingStartPhase: Equatable, Sendable {
    /// The audio pipeline is being validated and started.
    case startingAudioPipeline
    /// The audio start returned; no real captured sample has arrived yet.
    case awaitingFirstAudioSample
    /// The screen stream/writer is being created and started.
    case startingScreenWriter
    /// The screen start returned; no writer-accepted frame has arrived yet.
    case awaitingFirstVideoFrame

    /// The capture kind represented by this stage.
    var kind: RecordingKind {
        switch self {
        case .startingAudioPipeline, .awaitingFirstAudioSample: .audio
        case .startingScreenWriter, .awaitingFirstVideoFrame: .screen
        }
    }

    /// A stable numeric code for privacy-safe signposts.
    var diagnosticCode: Int {
        switch self {
        case .startingAudioPipeline: 1
        case .awaitingFirstAudioSample: 2
        case .startingScreenWriter: 3
        case .awaitingFirstVideoFrame: 4
        }
    }
}

/// Who owns one screen start, and who must stop it.
///
/// This type is the single source of truth for the two races:
/// 1. Cancel before the platform start returned vs. after it returned while the
///    first writer-accepted frame is still pending.
/// 2. A late start/frame that no longer owns the UI but may still own a stream,
///    plus the release gate that must outlive the settled session.
///
/// Every transition is synchronous and value-based, so tests can drive the exact
/// event order without sleeping.
struct RecordingStartOwnership: Equatable, Sendable {
    /// The lifecycle stage of the owned start.
    enum Stage: Equatable, Sendable {
        /// No start or stop is owned.
        case idle
        /// `start` was called but has not returned.
        case platformStartOutstanding
        /// `start` returned; no writer-accepted frame yet.
        case awaitingFirstFrame
        /// A writer-accepted frame arrived and the session is recording.
        case recording
        /// One initial stop is in flight.
        case stopping
        /// The stop could not be confirmed; the gate stays closed until a retry.
        case stopUnconfirmed
    }

    /// What a cancel request must do for this screen start.
    enum CancelRoute: Equatable, Sendable {
        /// The caller does not own this start.
        case notOwner
        /// The session already records; use the normal stop path.
        case notStarting
        /// `start` has not returned. Settle the UI and clean up the late adapter once.
        case stopWhenStartReturns
        /// `start` returned and the first frame is still pending. Stop the live adapter now.
        case cancelFirstFrameWait
        /// A stop (initial or retry) is already in flight.
        case alreadyStopping
    }

    private(set) var stage: Stage = .idle
    private(set) var ownerGeneration: UUID?
    private(set) var cancelRequested = false
    private(set) var didRequestInitialStop = false

    /// Whether new capture must stay blocked for this start.
    var blocksNewStart: Bool { stage != .idle }

    /// Whether the platform start call is still outstanding.
    var isPlatformStartOutstanding: Bool { stage == .platformStartOutstanding }

    /// Whether the start returned and no writer-accepted frame has arrived.
    var isAwaitingFirstFrame: Bool { stage == .awaitingFirstFrame }

    /// Whether an initial stop is currently in flight.
    var isStopping: Bool { stage == .stopping }

    /// Whether the stop must be retried before new capture is allowed.
    var needsReleaseConfirmation: Bool { stage == .stopUnconfirmed }

    /// Reserves the ownership slot before any suspension point.
    ///
    /// - Parameter generation: The request generation that will own the start.
    /// - Returns: `false` when another start or an unconfirmed release still owns the slot.
    mutating func beginStart(generation: UUID) -> Bool {
        guard stage == .idle else { return false }
        stage = .platformStartOutstanding
        ownerGeneration = generation
        cancelRequested = false
        didRequestInitialStop = false
        return true
    }

    /// Records that the platform start call returned.
    ///
    /// - Parameter generation: The generation whose start returned.
    /// - Returns: `true` when the caller may promote the UI to "awaiting first frame";
    ///   `false` when a cancel already won (the caller must still clean up the adapter).
    mutating func platformStartReturned(generation: UUID) -> Bool {
        guard ownerGeneration == generation, stage == .platformStartOutstanding else { return false }
        stage = .awaitingFirstFrame
        return !cancelRequested
    }

    /// Promotes the start to recording after a writer-accepted frame.
    ///
    /// - Parameter generation: The generation whose frame arrived.
    /// - Returns: `true` only for the first accepted frame of a still-current, uncancelled start.
    mutating func firstFrameAccepted(generation: UUID) -> Bool {
        guard ownerGeneration == generation,
            stage == .awaitingFirstFrame,
            !cancelRequested,
            !didRequestInitialStop
        else { return false }
        stage = .recording
        return true
    }

    /// Classifies a cancel while this start has not become a recording.
    ///
    /// - Parameter generation: The generation the cancel targets.
    mutating func requestCancel(generation: UUID) -> CancelRoute {
        guard ownerGeneration == generation else { return .notOwner }
        guard !didRequestInitialStop else { return .alreadyStopping }
        switch stage {
        case .platformStartOutstanding:
            cancelRequested = true
            return .stopWhenStartReturns
        case .awaitingFirstFrame:
            cancelRequested = true
            return .cancelFirstFrameWait
        case .recording:
            return .notStarting
        case .stopping, .stopUnconfirmed:
            return .alreadyStopping
        case .idle:
            return .notOwner
        }
    }

    /// Latches the one initial stop for this generation.
    ///
    /// - Parameter generation: The generation whose adapter must be stopped.
    /// - Returns: `true` for the first stop request only.
    mutating func beginInitialStop(generation: UUID) -> Bool {
        guard ownerGeneration == generation, !didRequestInitialStop else { return false }
        switch stage {
        case .platformStartOutstanding, .awaitingFirstFrame, .recording:
            didRequestInitialStop = true
            stage = .stopping
            return true
        case .idle, .stopping, .stopUnconfirmed:
            return false
        }
    }

    /// Records a confirmed stop and releases the gate.
    ///
    /// - Parameter generation: The generation whose stop was confirmed.
    /// - Returns: `true` when this call owned the gate.
    mutating func stopConfirmed(generation: UUID) -> Bool {
        guard ownerGeneration == generation else { return false }
        stage = .idle
        ownerGeneration = nil
        cancelRequested = false
        didRequestInitialStop = false
        return true
    }

    /// Records a stop that the underlying stream did not confirm.
    ///
    /// - Parameter generation: The generation whose stop is unconfirmed.
    /// - Returns: `true` when the ownership slot was updated.
    mutating func stopUnconfirmed(generation: UUID) -> Bool {
        guard ownerGeneration == generation else { return false }
        stage = .stopUnconfirmed
        return true
    }

    /// Starts an explicit retry for an unconfirmed stop.
    ///
    /// - Parameter generation: The generation whose stop must be retried.
    /// - Returns: `true` only while the stop is unconfirmed.
    mutating func beginStopRetry(generation: UUID) -> Bool {
        guard ownerGeneration == generation, stage == .stopUnconfirmed else { return false }
        stage = .stopping
        return true
    }

    /// Resolves a failed start that has no retained stream.
    ///
    /// A plain failure releases only the gate this request owns. If a cancel
    /// already latched a stop, the stop path owns the release instead.
    ///
    /// - Parameter generation: The generation whose start failed.
    /// - Returns: `true` when this call released the gate.
    mutating func startFailed(generation: UUID) -> Bool {
        guard ownerGeneration == generation else { return false }
        switch stage {
        case .platformStartOutstanding, .awaitingFirstFrame:
            guard !didRequestInitialStop else { return false }
            stage = .idle
            ownerGeneration = nil
            cancelRequested = false
            return true
        case .idle, .recording, .stopping, .stopUnconfirmed:
            return false
        }
    }
}

/// The post-countdown destination recheck for one recording request.
///
/// The verification may suspend (for example, on a slow external volume) and may
/// complete after the request was cancelled and another request started. This
/// type owns the exact post-await handoff: only a request that is still current
/// may produce a success or failure. A superseded result returns without calling
/// either handler, so it cannot start capture, show an error, or settle a newer
/// request.
@MainActor
final class RecordingDestinationRecheck {
    typealias Verification = @MainActor () async throws -> Void
    typealias CurrentCheck = @MainActor (RecordingRequestIdentity) -> Bool
    typealias VerifiedHandler = @MainActor () async -> Void
    typealias FailureHandler = @MainActor (any Error) async -> Void

    /// The request whose destination is being verified.
    let request: RecordingRequestIdentity

    private let verify: Verification
    private let isCurrent: CurrentCheck
    private let onVerified: VerifiedHandler
    private let onFailure: FailureHandler

    /// Creates one destination recheck.
    ///
    /// - Parameters:
    ///   - request: The request that owns the recheck.
    ///   - verify: The real, suspending destination validation.
    ///   - isCurrent: Evaluated only after `verify` returns; decides whether the
    ///     request still owns the UI and generation.
    ///   - onVerified: Called only for a current request whose verification succeeded.
    ///   - onFailure: Called only for a current request whose verification failed.
    init(
        request: RecordingRequestIdentity,
        verify: @escaping Verification,
        isCurrent: @escaping CurrentCheck,
        onVerified: @escaping VerifiedHandler,
        onFailure: @escaping FailureHandler
    ) {
        self.request = request
        self.verify = verify
        self.isCurrent = isCurrent
        self.onVerified = onVerified
        self.onFailure = onFailure
    }

    /// Runs the verification and delivers it only to the still-current request.
    func run() async {
        do {
            try await verify()
        } catch {
            guard isCurrent(request) else { return }
            await onFailure(error)
            return
        }
        guard isCurrent(request) else { return }
        await onVerified()
    }
}
