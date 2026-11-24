import CaptureCore
import Foundation

/// How a settlement was initiated.
enum RecordingSettlementReason: String, Sendable {
    /// A person or the app asked to stop.
    case requested
    /// The readiness deadline expired before any real media arrived.
    case deadline
    /// Real media arrived, but the main actor never confirmed that it presented
    /// the recording state. The interface is unresponsive; the session is stopped
    /// and saved from the supervisor so capture cannot run unbounded.
    case promotionStalled
}

/// The durable result of one stop.
///
/// Produced by the stop closure, which runs outside the main actor. The main
/// actor only presents this value: it never performs the stop itself.
enum RecordingSettlement: Sendable {
    /// An audio session stopped and returned its real pipeline result.
    case audio(AudioRecordingResult)
    /// A screen session stopped and returned its published segments.
    case screen(ScreenRecordingOutcome)
    /// No capture result exists; the message is user-facing and already localized.
    case failed(kind: RecordingKind, message: String)

    /// The recording kind this settlement belongs to.
    var kind: RecordingKind {
        switch self {
        case .audio: .audio
        case .screen: .screen
        case let .failed(kind, _): kind
        }
    }
}

/// Carries a screen stop's error class from the supervisor's stop closure to the UI.
///
/// The closure runs off the main actor, while the release capsule and the start
/// gate are main-actor state. This one-slot relay carries the single fact the UI
/// cannot infer from a message: whether the capture stream confirmed it stopped.
actor ScreenStopFailureRelay {
    private var error: (any Error)?

    /// Records the first failure; later reports cannot overwrite it.
    func record(_ error: any Error) {
        if self.error == nil { self.error = error }
    }

    /// Whether the recorded failure was an unconfirmed stream stop.
    func wasUnconfirmedStreamStop() -> Bool {
        guard let error = error as? ScreenRecordingSessionCoordinatorError else { return false }
        return error == .streamStopUnconfirmed
    }
}

/// Owns one recording session's readiness deadline and its single stop.
///
/// The supervisor exists so that the first-sample / first-frame deadline and the
/// stop that follows it never depend on the main actor. Every deadline sleep, the
/// readiness probe, and the stop closure run inside this actor (or in a task that
/// it owns); the main actor only receives ``Event`` values afterwards. A stalled
/// main thread therefore delays presentation, never the deadline or the save.
///
/// Guarantees:
/// - At most one stop per ticket: the first settlement creates the stop task and
///   every later caller joins it.
/// - `.mediaStarted` cancels the deadline before it can fire.
/// - A stale ticket (older generation, or disarmed) never runs a stop.
/// - Events are emitted without requiring a consumer; a stop finishes even when
///   nobody is listening, so persistence never waits on the UI.
actor RecordingSettlementSupervisor {
    /// Identity of one armed session, protected against reuse by `generation`.
    struct Ticket: Sendable, Hashable {
        let id: UUID
        let generation: UUID
    }

    /// The single readiness source the supervisor watches.
    enum Readiness: Sendable {
        /// Consumes the pipeline's own progress stream; a real captured sample
        /// (`capturedSamples > 0`) is the only readiness fact.
        case audioProgress(AsyncStream<RecordingProgress>)
        /// Polls a sendable probe (used for the writer-accepted first frame).
        case poll(@Sendable () async -> PollOutcome)
    }

    /// What one readiness poll concluded.
    enum PollOutcome: Sendable, Equatable {
        /// Media has not arrived yet; keep waiting until the deadline.
        case waiting
        /// Real media arrived; the deadline is cancelled.
        case ready
        /// The producer reported a failure, so waiting longer cannot succeed.
        ///
        /// The message is the producer's own description and only used to pick the
        /// failure copy; the supervisor still runs the same single stop.
        case failed(String)
    }

    /// What the main actor is told, always carrying the generation it belongs to.
    enum Event: Sendable {
        /// Real media arrived; the deadline has been cancelled.
        case mediaStarted(generation: UUID, kind: RecordingKind)
        /// The session stopped exactly once, for the stated reason.
        case settled(
            generation: UUID,
            kind: RecordingKind,
            settlement: RecordingSettlement,
            reason: RecordingSettlementReason
        )
    }

    /// Monotonic-clock facts for diagnostics and the agent test report.
    struct Diagnostics: Sendable {
        var generation: UUID?
        var kind: RecordingKind?
        var armedAt: ContinuousClock.Instant
        var mediaStartedAt: ContinuousClock.Instant?
        /// When the main actor confirmed it presented the recording state.
        var presentationAcknowledgedAt: ContinuousClock.Instant?
        var settleStartedAt: ContinuousClock.Instant?
        var settledAt: ContinuousClock.Instant?
        var reason: RecordingSettlementReason?
        /// Number of real invocations of the stop closure for this arming.
        var stopCalls: Int
        var mediaStarted: Bool
        var isSettled: Bool
        /// Why readiness failed before media arrived, when the producer said so.
        var readinessFailure: String?
    }

    /// One armed session. Mutated only inside the actor.
    private struct Armed {
        let ticket: Ticket
        let kind: RecordingKind
        let stop: @Sendable () async throws -> RecordingSettlement
        var deadlineTask: Task<Void, Never>?
        var readinessTask: Task<Void, Never>?
        var settleTask: Task<RecordingSettlement, Never>?
        var settlement: RecordingSettlement?
        var reason: RecordingSettlementReason?
        var mediaStarted = false
        var readinessFailure: String?
        /// How long the UI has to acknowledge the promoted recording state after
        /// real media arrived, before the supervisor stops the session itself.
        let promotionDeadline: Duration
        var promotionDeadlineTask: Task<Void, Never>?
        /// How long the main actor may go without a heartbeat once it acknowledged
        /// the promotion. `nil` for kinds that do not run a liveness lease.
        let livenessDeadline: Duration?
        var livenessTask: Task<Void, Never>?
        var presentationAcknowledged = false
    }

    /// Poll interval for ``Readiness/poll``.
    private static let pollInterval: Duration = .milliseconds(100)

    private let clock = ContinuousClock()
    private nonisolated let sleep: @Sendable (Duration) async throws -> Void
    private nonisolated let stream: AsyncStream<Event>
    private nonisolated let continuation: AsyncStream<Event>.Continuation

    private var active: Armed?
    private var armedAt = ContinuousClock().now
    private var mediaStartedAt: ContinuousClock.Instant?
    private var presentationAcknowledgedAt: ContinuousClock.Instant?
    private var settleStartedAt: ContinuousClock.Instant?
    private var settledAt: ContinuousClock.Instant?
    private var settledGeneration: UUID?
    private var settledKind: RecordingKind?
    private var lastReason: RecordingSettlementReason?
    private var lastSettlement: RecordingSettlement?
    private var lastSettledTicket: Ticket?
    private var stopCalls = 0
    /// The producer's failure reason for the last armed session, if it reported one.
    private var readinessFailure: String?

    /// Creates a supervisor.
    ///
    /// - Parameter sleep: The deadline/observation sleep. Tests inject an
    ///   immediate or gated implementation so no wall-clock time is spent.
    init(
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.sleep = sleep
        (stream, continuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingNewest(64))
    }

    /// The event stream the main actor consumes.
    ///
    /// Reading is optional: stops complete and results persist whether or not
    /// anyone consumes these events.
    nonisolated var events: AsyncStream<Event> { stream }

    /// Arms one session: starts the deadline and observes readiness.
    ///
    /// Any previously armed ticket is disarmed first, so an old deadline can
    /// never fire into a new session.
    ///
    /// - Parameters:
    ///   - generation: The request generation this session belongs to.
    ///   - kind: Audio or screen; decides the failure kind and the event kind.
    ///   - deadline: How long readiness may take before the stop runs.
    ///   - promotionDeadline: How long the main actor has to acknowledge that it
    ///     presented the recording state after readiness succeeded. When it never
    ///     acknowledges, the interface is unresponsive and the session is stopped
    ///     and saved here instead of running unbounded.
    ///   - readiness: The single readiness source to watch.
    ///   - stop: The one stop for this ticket. Runs off the main actor.
    /// - Returns: The ticket every later settle/disarm call must present.
    func arm(
        generation: UUID,
        kind: RecordingKind,
        deadline: Duration,
        promotionDeadline: Duration = .seconds(8),
        livenessDeadline: Duration? = nil,
        readiness: Readiness,
        stop: @escaping @Sendable () async throws -> RecordingSettlement
    ) -> Ticket {
        disarmActive()
        resetDiagnostics()
        let ticket = Ticket(id: UUID(), generation: generation)
        var slot = Armed(
            ticket: ticket,
            kind: kind,
            stop: stop,
            promotionDeadline: promotionDeadline,
            livenessDeadline: livenessDeadline
        )
        active = slot
        armedAt = clock.now

        let deadlineTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.sleep(deadline)
            } catch {
                return
            }
            await self.deadlineReached(ticket)
        }
        let readinessTask = Task { [weak self] in
            guard let self else { return }
            await self.observe(readiness, ticket: ticket)
        }
        slot.deadlineTask = deadlineTask
        slot.readinessTask = readinessTask
        active = slot
        return ticket
    }

    /// Stops the session exactly once and returns its real result.
    ///
    /// Concurrent callers, a deadline that already started, and a stop requested
    /// afterwards all join the same stop and receive the same settlement.
    ///
    /// - Parameters:
    ///   - ticket: The ticket returned by ``arm(generation:kind:deadline:readiness:stop:)``.
    ///   - reason: Why this stop is being requested.
    /// - Returns: The settlement, or `nil` when the ticket is stale and no stop
    ///   was run. A `nil` result must never be presented as a failure.
    func settle(ticket: Ticket, reason: RecordingSettlementReason) async -> RecordingSettlement? {
        guard let slot = active, slot.ticket == ticket else { return nil }
        if let settlement = slot.settlement { return settlement }
        guard let task = beginSettlement(ticket: ticket, reason: reason) else {
            return active?.settlement
        }
        return await task.value
    }

    /// Cancels a ticket's deadline and readiness observation without stopping.
    ///
    /// Used when a new session replaces an old one. A stop that already started
    /// keeps running (persistence must not be abandoned) and still returns to its
    /// caller, but its event is dropped because no armed ticket matches anymore.
    func disarm(ticket: Ticket) {
        guard let slot = active, slot.ticket == ticket else { return }
        slot.deadlineTask?.cancel()
        slot.readinessTask?.cancel()
        slot.promotionDeadlineTask?.cancel()
        active = nil
    }

    /// Monotonic-clock facts about the current (or last) arming.
    func diagnostics() -> Diagnostics {
        Diagnostics(
            generation: active?.ticket.generation ?? settledGeneration,
            kind: active?.kind ?? settledKind,
            armedAt: armedAt,
            mediaStartedAt: mediaStartedAt,
            presentationAcknowledgedAt: presentationAcknowledgedAt,
            settleStartedAt: settleStartedAt,
            settledAt: settledAt,
            reason: lastReason,
            stopCalls: stopCalls,
            mediaStarted: active?.mediaStarted ?? (mediaStartedAt != nil),
            isSettled: settledAt != nil,
            readinessFailure: active?.readinessFailure ?? readinessFailure
        )
    }

    /// The last completed settlement, for diagnostics and tests.
    func completedSettlement() -> RecordingSettlement? { lastSettlement }

    /// The reason that actually initiated the stop for this ticket, if known.
    ///
    /// A caller that joined a stop someone else started must present the real
    /// reason (a deadline and a request mean different UI), not its own intent.
    ///
    /// - Parameter ticket: The ticket the caller settled.
    /// - Returns: The reason the stop was started with, or `nil` for a stale ticket.
    func settledReason(for ticket: Ticket) -> RecordingSettlementReason? {
        if let slot = active, slot.ticket == ticket { return slot.reason }
        if lastSettledTicket == ticket { return lastReason }
        return nil
    }

    // MARK: - Readiness

    private func observe(_ readiness: Readiness, ticket: Ticket) async {
        switch readiness {
        case let .audioProgress(stream):
            for await progress in stream {
                guard !Task.isCancelled else { return }
                if progress.capturedSamples > 0 {
                    markMediaStarted(ticket)
                    return
                }
            }
        case let .poll(probe):
            while !Task.isCancelled {
                switch await probe() {
                case .ready:
                    markMediaStarted(ticket)
                    return
                case let .failed(reason):
                    readinessFailed(ticket, reason: reason)
                    return
                case .waiting:
                    break
                }
                do {
                    try await sleep(Self.pollInterval)
                } catch {
                    return
                }
            }
        }
    }

    /// Ends a readiness wait whose producer reported a failure.
    ///
    /// The stop is the same single settlement the deadline would run; the only
    /// difference is that the producer's reason is kept so the UI can name the
    /// real cause instead of a generic timeout. Nothing is stopped twice.
    ///
    /// - Parameters:
    ///   - ticket: The armed session this poll belongs to.
    ///   - reason: The producer's description of the failure.
    private func readinessFailed(_ ticket: Ticket, reason: String) {
        guard var slot = active, slot.ticket == ticket, !slot.mediaStarted,
              slot.settlement == nil, slot.settleTask == nil else { return }
        slot.readinessFailure = reason
        active = slot
        readinessFailure = reason
        _ = beginSettlement(ticket: ticket, reason: .deadline)
    }

    private func markMediaStarted(_ ticket: Ticket) {
        guard var slot = active, slot.ticket == ticket,
              slot.settlement == nil, !slot.mediaStarted else { return }
        slot.mediaStarted = true
        // Cancel the deadline before announcing: a readiness observation and the
        // deadline can complete in either order, and readiness always wins.
        slot.deadlineTask?.cancel()
        slot.deadlineTask = nil
        slot.readinessTask?.cancel()
        slot.readinessTask = nil
        slot.promotionDeadlineTask?.cancel()
        // Every kind arms the promotion watchdog: readiness success cancels the
        // only other deadline, so a main actor that never presents the promoted
        // state would otherwise leave capture running with nobody able to stop it.
        // The screen recording also arms a continuous liveness lease once the
        // promotion is acknowledged; the monitoring loop renews it.
        let promotionDeadline = slot.promotionDeadline
        slot.promotionDeadlineTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.sleep(promotionDeadline)
            } catch {
                return
            }
            await self.promotionDeadlineReached(ticket)
        }
        active = slot
        mediaStartedAt = clock.now
        continuation.yield(.mediaStarted(generation: ticket.generation, kind: slot.kind))
    }

    /// Records that the main actor presented the recording state for a session.
    ///
    /// The supervisor needs this confirmation only to know the interface is alive:
    /// readiness alone is not proof, because the promotion is delivered on the main
    /// actor. A session whose promotion is never acknowledged is stopped here and
    /// saved, instead of capturing forever behind a frozen interface.
    ///
    /// - Parameter generation: The session generation whose promotion was presented.
    func acknowledgePresentation(generation: UUID) {
        guard var slot = active, slot.ticket.generation == generation,
              slot.mediaStarted, slot.settlement == nil,
              slot.settleTask == nil,
              !slot.presentationAcknowledged else { return }
        slot.presentationAcknowledged = true
        slot.promotionDeadlineTask?.cancel()
        slot.promotionDeadlineTask = nil
        if let livenessDeadline = slot.livenessDeadline {
            let ticket = slot.ticket
            armLiveness(slot: &slot, deadline: livenessDeadline, ticket: ticket)
        }
        active = slot
        presentationAcknowledgedAt = clock.now
    }

    /// Proves the main actor is still alive after the promotion was presented.
    ///
    /// Each recording kind renews the same lease from the work that proves its
    /// interface is responsive: the screen monitoring loop for screen sessions and
    /// the progress consumer for audio sessions. A main actor that stops sending
    /// them is indistinguishable from a frozen interface, so the supervisor stops
    /// and saves the session instead of capturing forever behind a window the user
    /// cannot operate.
    ///
    /// - Parameter generation: The session whose main actor is still alive.
    func heartbeat(generation: UUID) {
        guard var slot = active,
              slot.ticket.generation == generation,
              slot.mediaStarted,
              slot.presentationAcknowledged,
              slot.settlement == nil,
              slot.settleTask == nil,
              let deadline = slot.livenessDeadline
        else { return }
        let ticket = slot.ticket
        armLiveness(slot: &slot, deadline: deadline, ticket: ticket)
        active = slot
    }

    // MARK: - Settlement

    private func deadlineReached(_ ticket: Ticket) {
        guard let slot = active, slot.ticket == ticket,
              !slot.mediaStarted, slot.settlement == nil, slot.settleTask == nil else { return }
        _ = beginSettlement(ticket: ticket, reason: .deadline)
    }

    /// Stops a session whose promoted state was never presented.
    ///
    /// The session had real media, so the readiness deadline was cancelled. If the
    /// main actor cannot confirm presentation, the interface is unresponsive and
    /// waiting longer would only accumulate audio nobody can stop.
    ///
    /// - Parameter ticket: The armed session whose promotion deadline expired.
    private func promotionDeadlineReached(_ ticket: Ticket) {
        guard let slot = active, slot.ticket == ticket,
              slot.mediaStarted, !slot.presentationAcknowledged,
              slot.settlement == nil, slot.settleTask == nil else { return }
        _ = beginSettlement(ticket: ticket, reason: .promotionStalled)
    }

    /// Arms one liveness lease for a recording whose promotion was presented.
    ///
    /// The lease is renewed by ``heartbeat(generation:)``; it is deliberately
    /// separate from the promotion deadline so a healthy recording is not stopped
    /// just because its interface was slow once.
    private func armLiveness(slot: inout Armed, deadline: Duration, ticket: Ticket) {
        slot.livenessTask?.cancel()
        slot.livenessTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.sleep(deadline)
            } catch {
                return
            }
            await self.livenessDeadlineReached(ticket)
        }
    }

    /// Stops a recording whose main actor stopped heartbeating.
    ///
    /// The interface was already presented, so this is a post-promotion stall: the
    /// capture is real but nobody can operate the stop control anymore.
    private func livenessDeadlineReached(_ ticket: Ticket) {
        guard let slot = active, slot.ticket == ticket,
              slot.mediaStarted, slot.presentationAcknowledged,
              slot.settlement == nil, slot.settleTask == nil else { return }
        _ = beginSettlement(ticket: ticket, reason: .promotionStalled)
    }

    @discardableResult
    private func beginSettlement(
        ticket: Ticket,
        reason: RecordingSettlementReason
    ) -> Task<RecordingSettlement, Never>? {
        guard var slot = active, slot.ticket == ticket else { return nil }
        if let task = slot.settleTask { return task }
        guard slot.settlement == nil else { return nil }

        slot.reason = reason
        slot.deadlineTask?.cancel()
        slot.deadlineTask = nil
        slot.readinessTask?.cancel()
        slot.readinessTask = nil
        slot.promotionDeadlineTask?.cancel()
        slot.promotionDeadlineTask = nil
        slot.livenessTask?.cancel()
        slot.livenessTask = nil
        settleStartedAt = clock.now
        lastReason = reason

        let stop = slot.stop
        let kind = slot.kind
        // Detached on purpose: the stop must not inherit this actor's executor, and
        // it must keep running even if every event consumer goes away.
        let task = Task.detached { [weak self] () -> RecordingSettlement in
            await self?.noteStopCall()
            let settlement: RecordingSettlement
            do {
                settlement = try await stop()
            } catch {
                settlement = .failed(kind: kind, message: Self.describe(error))
            }
            await self?.finish(ticket: ticket, settlement: settlement)
            return settlement
        }
        slot.settleTask = task
        active = slot
        return task
    }

    private func noteStopCall() {
        stopCalls += 1
    }

    private func finish(ticket: Ticket, settlement: RecordingSettlement) {
        settledAt = clock.now
        settledGeneration = ticket.generation
        lastSettlement = settlement
        settledKind = settlement.kind
        lastSettledTicket = ticket
        guard var slot = active, slot.ticket == ticket else { return }
        // Disarmed while the stop ran: the caller still receives the settlement;
        // the event is dropped so it cannot touch a newer session.
        slot.settlement = settlement
        slot.settleTask = nil
        slot.promotionDeadlineTask?.cancel()
        slot.promotionDeadlineTask = nil
        slot.livenessTask?.cancel()
        slot.livenessTask = nil
        active = slot
        continuation.yield(
            .settled(
                generation: ticket.generation,
                kind: slot.kind,
                settlement: settlement,
                reason: slot.reason ?? .requested
            )
        )
    }

    private func disarmActive() {
        guard let slot = active else { return }
        slot.deadlineTask?.cancel()
        slot.readinessTask?.cancel()
        slot.promotionDeadlineTask?.cancel()
        slot.livenessTask?.cancel()
        active = nil
    }

    private func resetDiagnostics() {
        mediaStartedAt = nil
        presentationAcknowledgedAt = nil
        settleStartedAt = nil
        settledAt = nil
        settledGeneration = nil
        settledKind = nil
        lastReason = nil
        lastSettlement = nil
        lastSettledTicket = nil
        stopCalls = 0
        readinessFailure = nil
    }

    /// A user-facing description for a stop that threw.
    ///
    /// Recording errors already localize themselves; this only adds a fallback for
    /// errors that do not.
    private nonisolated static func describe(_ error: any Error) -> String {
        if let localized = error as? any LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
