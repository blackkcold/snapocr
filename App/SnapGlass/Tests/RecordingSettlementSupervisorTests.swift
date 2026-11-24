import CaptureCore
import Foundation
import Testing

/// One test's supervisor plus the facts it produced.
private struct SupervisorHarness {
    let supervisor: RecordingSettlementSupervisor
    let log: EventLog
    let consumer: Task<Void, Never>

    init(sleep: @escaping @Sendable (Duration) async throws -> Void) {
        supervisor = RecordingSettlementSupervisor(sleep: sleep)
        let log = EventLog()
        self.log = log
        let stream = supervisor.events
        consumer = Task {
            for await event in stream {
                await log.append(event)
            }
        }
    }

    func stop() {
        consumer.cancel()
    }
}

/// Thread-safe record of every supervisor event, so a test never has to consume
/// the stream itself and the production "no consumer" case stays testable.
private actor EventLog {
    private var events: [RecordingSettlementSupervisor.Event] = []

    func append(_ event: RecordingSettlementSupervisor.Event) {
        events.append(event)
    }

    var count: Int { events.count }

    var mediaStartedCount: Int {
        events.reduce(0) { count, event in
            if case .mediaStarted = event { return count + 1 }
            return count
        }
    }

    var settledCount: Int {
        events.reduce(0) { count, event in
            if case .settled = event { return count + 1 }
            return count
        }
    }

    var settledReasons: [RecordingSettlementReason] {
        events.compactMap { event in
            guard case let .settled(_, _, _, reason) = event else { return nil }
            return reason
        }
    }

    var settlements: [RecordingSettlement] {
        events.compactMap { event in
            guard case let .settled(_, _, settlement, _) = event else { return nil }
            return settlement
        }
    }

    var settledGenerations: [UUID] {
        events.compactMap { event in
            guard case let .settled(generation, _, _, _) = event else { return nil }
            return generation
        }
    }

    /// Waits until at least `minimum` settled events exist, or the timeout expires.
    func waitForSettled(_ minimum: Int = 1, timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while settledCount < minimum {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    /// Waits until at least `minimum` media-started events exist, or the timeout expires.
    func waitForMediaStarted(_ minimum: Int = 1, timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while mediaStartedCount < minimum {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }
}

/// A gate the test opens explicitly, so a deadline is only ever raced on purpose.
private actor SleepGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

/// A stop the test releases explicitly, to keep one stop in flight while a second
/// caller and the deadline arrive.
private actor StopGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    func waitForRelease() async {
        if isReleased { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

/// Counts real stop-closure invocations, optionally per generation.
private actor StopCounter {
    private var value = 0
    private var generations: [UUID] = []

    func record(_ generation: UUID? = nil) {
        value += 1
        if let generation { generations.append(generation) }
    }

    var calls: Int { value }

    func calls(for generation: UUID) -> Int {
        generations.filter { $0 == generation }.count
    }
}

/// A readiness stream that never yields, so only the deadline can settle.
private func neverYieldingProgress() -> AsyncStream<RecordingProgress> {
    AsyncStream { _ in }
}

private func progress(_ sessionID: UUID, capturedSamples: Int64) -> RecordingProgress {
    RecordingProgress(
        sessionID: sessionID,
        elapsedSeconds: 0.1,
        savedSegments: 0,
        checkpointAgeSeconds: 0,
        droppedSamples: 0,
        capturedSamples: capturedSamples
    )
}

private func audioResult(_ sessionID: UUID, segmentCount: Int = 0) -> AudioRecordingResult {
    AudioRecordingResult(
        sessionID: sessionID,
        kind: .audio,
        layout: .mixed,
        segmentCount: segmentCount,
        droppedRanges: [],
        checkpointAge: 0,
        failure: nil
    )
}

/// A stop failure that localizes itself, like the app's real errors do.
private struct StopFailure: LocalizedError {
    var errorDescription: String? { "stop failed" }
}

@Suite("Recording settlement supervisor")
struct RecordingSettlementSupervisorTests {
    @Test("The deadline runs the stop exactly once and reports it")
    func deadlineStopsExactlyOnce() async {
        let harness = SupervisorHarness(sleep: { _ in })
        defer { harness.stop() }
        let counter = StopCounter()
        let generation = UUID()
        let sessionID = UUID()
        let ticket = await harness.supervisor.arm(
            generation: generation,
            kind: .audio,
            deadline: .seconds(15),
            readiness: .audioProgress(neverYieldingProgress()),
            stop: {
                await counter.record()
                return .audio(audioResult(sessionID))
            }
        )

        let settled = await harness.log.waitForSettled()
        #expect(settled)
        let calls = await counter.calls
        #expect(calls == 1)
        let generations = await harness.log.settledGenerations
        #expect(generations == [generation])
        let reasons = await harness.log.settledReasons
        #expect(reasons == [.deadline])
        let diagnostics = await harness.supervisor.diagnostics()
        #expect(diagnostics.stopCalls == 1)
        #expect(diagnostics.settledAt != nil)

        // A late requested stop joins the settled result instead of stopping twice.
        let joined = await harness.supervisor.settle(ticket: ticket, reason: .requested)
        #expect(joined != nil)
        let callsAfterJoin = await counter.calls
        #expect(callsAfterJoin == 1)
        let settledAfterJoin = await harness.log.settledCount
        #expect(settledAfterJoin == 1)
    }

    @Test("A real sample cancels the deadline and keeps the session open")
    func mediaStartedCancelsDeadline() async {
        let gate = SleepGate()
        let harness = SupervisorHarness(sleep: { _ in await gate.wait() })
        defer { harness.stop() }
        let counter = StopCounter()
        let sessionID = UUID()
        let generation = UUID()
        let (stream, continuation) = AsyncStream<RecordingProgress>.makeStream()
        let ticket = await harness.supervisor.arm(
            generation: generation,
            kind: .audio,
            deadline: .seconds(15),
            readiness: .audioProgress(stream),
            stop: {
                await counter.record()
                return .audio(audioResult(sessionID))
            }
        )

        continuation.yield(progress(sessionID, capturedSamples: 1))
        let started = await harness.log.waitForMediaStarted()
        #expect(started)
        // The presentation watchdog only stays quiet when the UI confirms that it
        // presented the promoted state; an alive main actor always does this.
        await harness.supervisor.acknowledgePresentation(generation: generation)
        continuation.yield(progress(sessionID, capturedSamples: 2))

        // Let the deadline sleep finish; it must not stop anything now.
        await gate.open()
        try? await Task.sleep(for: .milliseconds(100))
        let settledCount = await harness.log.settledCount
        #expect(settledCount == 0)
        let calls = await counter.calls
        #expect(calls == 0)
        let mediaStartedCount = await harness.log.mediaStartedCount
        #expect(mediaStartedCount == 1)

        // A real stop still runs once, and it is reported as requested.
        let settlement = await harness.supervisor.settle(ticket: ticket, reason: .requested)
        #expect(settlement != nil)
        let callsAfterStop = await counter.calls
        #expect(callsAfterStop == 1)
        let reasons = await harness.log.settledReasons
        #expect(reasons == [.requested])
    }

    /// The freeze this supervisor guards against: real media arrived, the readiness
    /// deadline was therefore cancelled, but the main actor never confirmed that it
    /// presented the recording state. Capture must be stopped and saved anyway.
    @Test("A promoted recording without a UI acknowledgement stops as a promotion stall")
    func promotionStallStopsWithoutAcknowledgement() async {
        let gate = SleepGate()
        let harness = SupervisorHarness(sleep: { _ in await gate.wait() })
        defer { harness.stop() }
        let counter = StopCounter()
        let sessionID = UUID()
        let generation = UUID()
        let (stream, continuation) = AsyncStream<RecordingProgress>.makeStream()
        _ = await harness.supervisor.arm(
            generation: generation,
            kind: .audio,
            deadline: .seconds(15),
            promotionDeadline: .seconds(8),
            readiness: .audioProgress(stream),
            stop: {
                await counter.record()
                return .audio(audioResult(sessionID, segmentCount: 1))
            }
        )

        continuation.yield(progress(sessionID, capturedSamples: 1))
        let started = await harness.log.waitForMediaStarted()
        #expect(started)

        // The UI never acknowledges: the app is wedged. The promotion deadline is
        // the only remaining stop, and it must run the single stop once.
        await gate.open()
        let settled = await harness.log.waitForSettled()
        #expect(settled)
        let reasons = await harness.log.settledReasons
        #expect(reasons == [.promotionStalled])
        let calls = await counter.calls
        #expect(calls == 1)

        // A late acknowledgement cannot undo the saved settlement or stop twice.
        await harness.supervisor.acknowledgePresentation(generation: generation)
        let settledAfter = await harness.log.settledCount
        #expect(settledAfter == 1)
        let callsAfter = await counter.calls
        #expect(callsAfter == 1)
    }

    /// The presentation watchdog covers both kinds. Screen readiness used to be
    /// exempt, which left a recording with real frames and a frozen interface with
    /// no bounded stop at all.
    @Test("Screen promotion without a UI acknowledgement stops as a promotion stall")
    func screenPromotionStallStopsWithoutAcknowledgement() async {
        let harness = SupervisorHarness(sleep: { try await Task.sleep(for: $0) })
        defer { harness.stop() }
        let counter = StopCounter()
        let sessionID = UUID()
        let generation = UUID()
        _ = await harness.supervisor.arm(
            generation: generation,
            kind: .screen,
            deadline: .seconds(60),
            promotionDeadline: .milliseconds(60),
            readiness: .poll { .ready },
            stop: {
                await counter.record()
                return .screen(ScreenRecordingOutcome(
                    sessionID: sessionID,
                    segmentURLs: [],
                    droppedFrameCount: 0,
                    failure: nil
                ))
            }
        )

        let started = await harness.log.waitForMediaStarted()
        #expect(started)
        // The interface never confirms the promotion.
        let settled = await harness.log.waitForSettled()
        #expect(settled)
        let reasons = await harness.log.settledReasons
        #expect(reasons == [.promotionStalled])
        let calls = await counter.calls
        #expect(calls == 1)
    }

    /// A healthy screen promotion confirms on the next main-actor turn and must
    /// not be stopped by the watchdog.
    @Test("A screen promotion acknowledgement disarms the watchdog")
    func screenAcknowledgementDisarmsPromotionWatchdog() async {
        let harness = SupervisorHarness(sleep: { try await Task.sleep(for: $0) })
        defer { harness.stop() }
        let counter = StopCounter()
        let sessionID = UUID()
        let generation = UUID()
        _ = await harness.supervisor.arm(
            generation: generation,
            kind: .screen,
            deadline: .seconds(60),
            promotionDeadline: .milliseconds(400),
            readiness: .poll { .ready },
            stop: {
                await counter.record()
                return .screen(ScreenRecordingOutcome(
                    sessionID: sessionID,
                    segmentURLs: [],
                    droppedFrameCount: 0,
                    failure: nil
                ))
            }
        )

        let started = await harness.log.waitForMediaStarted()
        #expect(started)
        await harness.supervisor.acknowledgePresentation(generation: generation)
        try? await Task.sleep(for: .milliseconds(700))
        let settledCount = await harness.log.settledCount
        #expect(settledCount == 0)
        let calls = await counter.calls
        #expect(calls == 0)
    }

    /// After the promotion, the screen monitoring loop renews a liveness lease.
    /// If the main actor stops renewing it, the supervisor must stop and save the
    /// recording instead of capturing forever behind a frozen interface.
    @Test("Screen liveness stops when the main actor stops heartbeating")
    func screenLivenessStopsWhenHeartbeatsStop() async {
        let harness = SupervisorHarness(sleep: { try await Task.sleep(for: $0) })
        defer { harness.stop() }
        let counter = StopCounter()
        let sessionID = UUID()
        let generation = UUID()
        _ = await harness.supervisor.arm(
            generation: generation,
            kind: .screen,
            deadline: .seconds(60),
            promotionDeadline: .milliseconds(400),
            livenessDeadline: .milliseconds(200),
            readiness: .poll { .ready },
            stop: {
                await counter.record()
                return .screen(ScreenRecordingOutcome(
                    sessionID: sessionID,
                    segmentURLs: [],
                    droppedFrameCount: 0,
                    failure: nil
                ))
            }
        )

        let started = await harness.log.waitForMediaStarted()
        #expect(started)
        await harness.supervisor.acknowledgePresentation(generation: generation)

        // Ten beats at 50 ms keep the 200 ms lease alive.
        for _ in 0..<10 {
            await harness.supervisor.heartbeat(generation: generation)
            try? await Task.sleep(for: .milliseconds(50))
        }
        let settledWhileHealthy = await harness.log.settledCount
        #expect(settledWhileHealthy == 0)

        // Stop beating: the lease expires and the single stop runs.
        let settled = await harness.log.waitForSettled()
        #expect(settled)
        let reasons = await harness.log.settledReasons
        #expect(reasons == [.promotionStalled])
        let calls = await counter.calls
        #expect(calls == 1)
    }

    /// Audio recordings use the same lease as screen recordings, renewed by the
    /// progress consumer. A frozen main actor stops the beats and the session is
    /// stopped and saved from the supervisor.
    @Test("Audio liveness stops when the progress consumer stops heartbeating")
    func audioLivenessStopsWhenHeartbeatsStop() async {
        let harness = SupervisorHarness(sleep: { try await Task.sleep(for: $0) })
        defer { harness.stop() }
        let counter = StopCounter()
        let sessionID = UUID()
        let generation = UUID()
        let (stream, continuation) = AsyncStream<RecordingProgress>.makeStream()
        _ = await harness.supervisor.arm(
            generation: generation,
            kind: .audio,
            deadline: .seconds(60),
            promotionDeadline: .milliseconds(400),
            livenessDeadline: .milliseconds(200),
            readiness: .audioProgress(stream),
            stop: {
                await counter.record()
                return .audio(audioResult(sessionID, segmentCount: 1))
            }
        )

        continuation.yield(progress(sessionID, capturedSamples: 1))
        let started = await harness.log.waitForMediaStarted()
        #expect(started)
        await harness.supervisor.acknowledgePresentation(generation: generation)

        // Progress beats at 50 ms keep the 200 ms lease alive.
        for _ in 0..<10 {
            await harness.supervisor.heartbeat(generation: generation)
            try? await Task.sleep(for: .milliseconds(50))
        }
        let settledWhileHealthy = await harness.log.settledCount
        #expect(settledWhileHealthy == 0)

        let settled = await harness.log.waitForSettled()
        #expect(settled)
        let reasons = await harness.log.settledReasons
        #expect(reasons == [.promotionStalled])
        let calls = await counter.calls
        #expect(calls == 1)
    }

    /// The watchdog is identity-bound: an acknowledgement for another session must
    /// not silence this one.
    @Test("An acknowledgement for another generation does not cancel the watchdog")
    func acknowledgementForAnotherGenerationIsIgnored() async {
        let gate = SleepGate()
        let harness = SupervisorHarness(sleep: { _ in await gate.wait() })
        defer { harness.stop() }
        let counter = StopCounter()
        let sessionID = UUID()
        let (stream, continuation) = AsyncStream<RecordingProgress>.makeStream()
        _ = await harness.supervisor.arm(
            generation: UUID(),
            kind: .audio,
            deadline: .seconds(15),
            promotionDeadline: .seconds(8),
            readiness: .audioProgress(stream),
            stop: {
                await counter.record()
                return .audio(audioResult(sessionID))
            }
        )

        continuation.yield(progress(sessionID, capturedSamples: 1))
        let started = await harness.log.waitForMediaStarted()
        #expect(started)
        await harness.supervisor.acknowledgePresentation(generation: UUID())
        await gate.open()
        let settled = await harness.log.waitForSettled()
        #expect(settled)
        let reasons = await harness.log.settledReasons
        #expect(reasons == [.promotionStalled])
    }

    /// Disarming replaces the session; the promotion watchdog must not survive it.
    @Test("Disarming after readiness cancels the promotion watchdog")
    func disarmCancelsPromotionWatchdog() async {
        let gate = SleepGate()
        let harness = SupervisorHarness(sleep: { _ in await gate.wait() })
        defer { harness.stop() }
        let counter = StopCounter()
        let sessionID = UUID()
        let (stream, continuation) = AsyncStream<RecordingProgress>.makeStream()
        let ticket = await harness.supervisor.arm(
            generation: UUID(),
            kind: .audio,
            deadline: .seconds(15),
            promotionDeadline: .seconds(8),
            readiness: .audioProgress(stream),
            stop: {
                await counter.record()
                return .audio(audioResult(sessionID))
            }
        )

        continuation.yield(progress(sessionID, capturedSamples: 1))
        let started = await harness.log.waitForMediaStarted()
        #expect(started)
        await harness.supervisor.disarm(ticket: ticket)
        await gate.open()
        try? await Task.sleep(for: .milliseconds(100))
        let settled = await harness.log.settledCount
        #expect(settled == 0)
        let calls = await counter.calls
        #expect(calls == 0)
    }

    /// S4: progress that only reflects checkpoint coverage (elapsed time, age,
    /// saved segments, loud levels) must never be mistaken for a captured sample.
    @Test("Checkpoint coverage never starts media")
    func checkpointCoverageNeverStartsMedia() async {
        let gate = SleepGate()
        let harness = SupervisorHarness(sleep: { _ in await gate.wait() })
        defer { harness.stop() }
        let counter = StopCounter()
        let sessionID = UUID()
        let (stream, continuation) = AsyncStream<RecordingProgress>.makeStream()
        _ = await harness.supervisor.arm(
            generation: UUID(),
            kind: .audio,
            deadline: .seconds(15),
            readiness: .audioProgress(stream),
            stop: {
                await counter.record()
                return .audio(audioResult(sessionID))
            }
        )

        for _ in 0..<20 {
            continuation.yield(RecordingProgress(
                sessionID: sessionID,
                elapsedSeconds: 5,
                savedSegments: 1,
                checkpointAgeSeconds: 3,
                droppedSamples: 0,
                systemLevel: 0.9,
                micLevel: 0.9,
                capturedSamples: 0
            ))
            try? await Task.sleep(for: .milliseconds(5))
        }

        let startedWithoutSamples = await harness.log.mediaStartedCount
        let settledWithoutSamples = await harness.log.settledCount
        #expect(startedWithoutSamples == 0)
        #expect(settledWithoutSamples == 0)

        // The deadline still stops the session exactly once, reported as a deadline.
        await gate.open()
        let settled = await harness.log.waitForSettled()
        #expect(settled)
        let reasons = await harness.log.settledReasons
        #expect(reasons == [.deadline])
        let startedAfterDeadline = await harness.log.mediaStartedCount
        #expect(startedAfterDeadline == 0)
        let calls = await counter.calls
        #expect(calls == 1)
    }

    @Test("A requested stop racing the deadline produces one terminal result")
    func settleAndDeadlineRaceProduceOneTerminal() async {
        let stopGate = StopGate()
        let harness = SupervisorHarness(sleep: { _ in })
        defer { harness.stop() }
        let counter = StopCounter()
        let sessionID = UUID()
        let ticket = await harness.supervisor.arm(
            generation: UUID(),
            kind: .audio,
            deadline: .seconds(15),
            readiness: .audioProgress(neverYieldingProgress()),
            stop: {
                await counter.record()
                await stopGate.waitForRelease()
                return .audio(audioResult(sessionID))
            }
        )

        async let first = harness.supervisor.settle(ticket: ticket, reason: .requested)
        async let second = harness.supervisor.settle(ticket: ticket, reason: .requested)
        await stopGate.release()
        let firstResult = await first
        let secondResult = await second

        #expect(firstResult != nil)
        #expect(secondResult != nil)
        let calls = await counter.calls
        #expect(calls == 1)
        let settledCount = await harness.log.settledCount
        #expect(settledCount == 1)
        let reasons = await harness.log.settledReasons
        #expect(reasons.count == 1)
    }

    @Test("A stale ticket never runs a stop")
    func staleTicketDoesNotStop() async {
        let gate = SleepGate()
        let harness = SupervisorHarness(sleep: { _ in await gate.wait() })
        defer { harness.stop() }
        let counter = StopCounter()
        _ = await harness.supervisor.arm(
            generation: UUID(),
            kind: .audio,
            deadline: .seconds(15),
            readiness: .audioProgress(neverYieldingProgress()),
            stop: {
                await counter.record()
                return .audio(audioResult(UUID()))
            }
        )

        let stale = RecordingSettlementSupervisor.Ticket(id: UUID(), generation: UUID())
        let result = await harness.supervisor.settle(ticket: stale, reason: .requested)
        #expect(result == nil)
        let calls = await counter.calls
        #expect(calls == 0)
        await gate.open()
    }

    @Test("A throwing stop maps to a failed settlement")
    func throwingStopMapsToFailed() async {
        let harness = SupervisorHarness(sleep: { _ in })
        defer { harness.stop() }
        let ticket = await harness.supervisor.arm(
            generation: UUID(),
            kind: .screen,
            deadline: .seconds(15),
            readiness: .audioProgress(neverYieldingProgress()),
            stop: { throw StopFailure() }
        )

        let settlement = await harness.supervisor.settle(ticket: ticket, reason: .requested)
        let failed = await harness.log.waitForSettled()
        #expect(failed)
        guard case let .failed(kind, message) = settlement else {
            Issue.record("expected a failed settlement, got \(String(describing: settlement))")
            return
        }
        #expect(kind == .screen)
        #expect(message == "stop failed")
        let settlements = await harness.log.settlements
        #expect(settlements.count == 1)
    }

    @Test("A stop completes even when nobody consumes the event stream")
    func stopCompletesWithoutConsumer() async {
        let supervisor = RecordingSettlementSupervisor(sleep: { _ in })
        let counter = StopCounter()
        let sessionID = UUID()
        let ticket = await supervisor.arm(
            generation: UUID(),
            kind: .audio,
            deadline: .seconds(15),
            readiness: .audioProgress(neverYieldingProgress()),
            stop: {
                await counter.record()
                return .audio(audioResult(sessionID, segmentCount: 1))
            }
        )

        let settlement = await supervisor.settle(ticket: ticket, reason: .requested)
        #expect(settlement != nil)
        let calls = await counter.calls
        #expect(calls == 1)
        let diagnostics = await supervisor.diagnostics()
        #expect(diagnostics.isSettled)
        #expect(diagnostics.stopCalls == 1)
        #expect(diagnostics.reason == .requested)
    }

    @Test("Disarming cancels the deadline before it can stop")
    func disarmPreventsDeadline() async {
        let gate = SleepGate()
        let harness = SupervisorHarness(sleep: { _ in await gate.wait() })
        defer { harness.stop() }
        let counter = StopCounter()
        let ticket = await harness.supervisor.arm(
            generation: UUID(),
            kind: .audio,
            deadline: .seconds(15),
            readiness: .audioProgress(neverYieldingProgress()),
            stop: {
                await counter.record()
                return .audio(audioResult(UUID()))
            }
        )

        await harness.supervisor.disarm(ticket: ticket)
        await gate.open()
        try? await Task.sleep(for: .milliseconds(100))

        let calls = await counter.calls
        #expect(calls == 0)
        let settledCount = await harness.log.settledCount
        #expect(settledCount == 0)
        let settlement = await harness.supervisor.settle(ticket: ticket, reason: .requested)
        #expect(settlement == nil)
    }

    @Test("Arming a new session disarms the previous ticket")
    func armingNewSessionDisarmsPrevious() async {
        let gate = SleepGate()
        let harness = SupervisorHarness(sleep: { _ in await gate.wait() })
        defer { harness.stop() }
        let counter = StopCounter()
        let firstGeneration = UUID()

        let first = await harness.supervisor.arm(
            generation: firstGeneration,
            kind: .audio,
            deadline: .seconds(15),
            readiness: .audioProgress(neverYieldingProgress()),
            stop: {
                await counter.record(firstGeneration)
                return .audio(audioResult(UUID()))
            }
        )
        let secondGeneration = UUID()
        let second = await harness.supervisor.arm(
            generation: secondGeneration,
            kind: .audio,
            deadline: .seconds(15),
            readiness: .audioProgress(neverYieldingProgress()),
            stop: {
                await counter.record(secondGeneration)
                return .audio(audioResult(UUID()))
            }
        )

        // The first deadline was cancelled when the second session armed. Let both
        // sleeps finish: the old one must not stop anything.
        await gate.open()
        try? await Task.sleep(for: .milliseconds(100))
        let firstCalls = await counter.calls(for: firstGeneration)
        #expect(firstCalls == 0)
        let staleSettlement = await harness.supervisor.settle(ticket: first, reason: .requested)
        #expect(staleSettlement == nil)
        let diagnostics = await harness.supervisor.diagnostics()
        #expect(diagnostics.generation == secondGeneration)

        _ = await harness.supervisor.settle(ticket: second, reason: .requested)
        let secondCalls = await counter.calls(for: secondGeneration)
        #expect(secondCalls == 1)
    }

    /// S5: a readiness poll that reports a writer failure must end the wait with its
    /// own reason, run the single stop, and never claim the deadline expired as a
    /// plain timeout.
    @Test("A failing readiness poll stops at once and keeps its reason")
    func failingReadinessPollStopsWithReason() async {
        let gate = SleepGate()
        let harness = SupervisorHarness(sleep: { _ in await gate.wait() })
        defer { harness.stop() }
        let counter = StopCounter()
        let sessionID = UUID()
        _ = await harness.supervisor.arm(
            generation: UUID(),
            kind: .screen,
            deadline: .seconds(15),
            readiness: .poll { .failed("The writer was not ready.") },
            stop: {
                await counter.record()
                return .screen(ScreenRecordingOutcome(
                    sessionID: sessionID,
                    segmentURLs: [],
                    droppedFrameCount: 0,
                    failure: nil
                ))
            }
        )

        let settled = await harness.log.waitForSettled()
        #expect(settled)
        let calls = await counter.calls
        #expect(calls == 1)
        let mediaStartedCount = await harness.log.mediaStartedCount
        #expect(mediaStartedCount == 0)
        let diagnostics = await harness.supervisor.diagnostics()
        #expect(diagnostics.readinessFailure == "The writer was not ready.")
        #expect(diagnostics.reason == .deadline)
        #expect(diagnostics.stopCalls == 1)
        await gate.open()
    }

    @Test("A waiting poll never starts media")
    func waitingPollNeverStartsMedia() async {
        let gate = SleepGate()
        let harness = SupervisorHarness(sleep: { _ in await gate.wait() })
        defer { harness.stop() }
        _ = await harness.supervisor.arm(
            generation: UUID(),
            kind: .screen,
            deadline: .seconds(15),
            readiness: .poll { .waiting },
            stop: { .failed(kind: .screen, message: "stopped") }
        )

        await gate.open()
        let settled = await harness.log.waitForSettled()
        #expect(settled)
        let diagnostics = await harness.supervisor.diagnostics()
        #expect(diagnostics.mediaStarted == false)
        #expect(diagnostics.readinessFailure == nil)
    }
}
