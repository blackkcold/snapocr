import CaptureCore
import Foundation
import Testing

/// One test's supervisor plus the facts it produced.
struct SettlementSupervisorHarness {
    let supervisor: RecordingSettlementSupervisor
    let log: SettlementEventLog
    let consumer: Task<Void, Never>

    init(sleep: @escaping @Sendable (Duration) async throws -> Void) {
        supervisor = RecordingSettlementSupervisor(sleep: sleep)
        let log = SettlementEventLog()
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
actor SettlementEventLog {
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
actor SettlementSleepGate {
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

/// A sleep the test releases explicitly, per duration, so a lease is asserted
/// without racing a wall-clock timer.
///
/// Every duration starts shut: no deadline, promotion watchdog, or liveness lease
/// can expire on its own. The test opens exactly one duration to make that
/// deadline fire. A liveness assertion therefore holds no matter how loaded the
/// machine is, which a real `Task.sleep` cannot promise: a 200 ms lease renewed
/// every 50 ms has only a 4× margin, and a busy main actor can miss it.
actor SettlementLeaseGate {
    private var openDurations: Set<Duration> = []
    private var waiters: [(duration: Duration, continuation: CheckedContinuation<Void, Never>)] = []
    private var sleepCounts: [Duration: Int] = [:]

    /// Sleeps until the test opens this duration, or forever for the rest.
    func sleep(_ duration: Duration) async {
        sleepCounts[duration, default: 0] += 1
        if openDurations.contains(duration) { return }
        await withCheckedContinuation { continuation in
            waiters.append((duration, continuation))
        }
    }

    /// Releases every sleep waiting on this duration.
    func open(_ duration: Duration) {
        openDurations.insert(duration)
        var parked: [(duration: Duration, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in waiters {
            if waiter.duration == duration {
                waiter.continuation.resume()
            } else {
                parked.append(waiter)
            }
        }
        waiters = parked
    }

    /// Releases whatever is still parked, so a test leaves no continuation behind.
    func openAll() {
        for waiter in waiters { waiter.continuation.resume() }
        waiters.removeAll()
    }

    /// How many sleeps this duration was asked for, including ones still parked.
    func sleepCount(_ duration: Duration) -> Int { sleepCounts[duration] ?? 0 }

    /// Waits until this duration was slept on at least `minimum` times.
    ///
    /// A beat re-arms the lease by starting a new sleep, so this is how a test
    /// proves the lease was actually renewed instead of inferring it from timing.
    func waitForSleepCount(
        _ duration: Duration,
        atLeast minimum: Int,
        timeout: Duration = .seconds(5)
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while sleepCount(duration) < minimum {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }
}

/// A stop the test releases explicitly, to keep one stop in flight while a second
/// caller and the deadline arrive.
actor SettlementStopGate {
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
actor SettlementStopCounter {
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
func settlementNeverYieldingProgress() -> AsyncStream<RecordingProgress> {
    AsyncStream { _ in }
}

func settlementProgress(_ sessionID: UUID, capturedSamples: Int64) -> RecordingProgress {
    RecordingProgress(
        sessionID: sessionID,
        elapsedSeconds: 0.1,
        savedSegments: 0,
        checkpointAgeSeconds: 0,
        droppedSamples: 0,
        capturedSamples: capturedSamples
    )
}

func settlementAudioResult(_ sessionID: UUID, segmentCount: Int = 0) -> AudioRecordingResult {
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
struct SettlementStopFailure: LocalizedError {
    var errorDescription: String? { "stop failed" }
}

@Suite("Recording settlement supervisor")
struct RecordingSettlementSupervisorTests {
    @Test("The deadline runs the stop exactly once and reports it")
    func deadlineStopsExactlyOnce() async {
        let harness = SettlementSupervisorHarness(sleep: { _ in })
        defer { harness.stop() }
        let counter = SettlementStopCounter()
        let generation = UUID()
        let sessionID = UUID()
        let ticket = await harness.supervisor.arm(
            generation: generation,
            kind: .audio,
            deadline: .seconds(15),
            readiness: .audioProgress(settlementNeverYieldingProgress()),
            stop: {
                await counter.record()
                return .audio(settlementAudioResult(sessionID))
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
        let gate = SettlementSleepGate()
        let harness = SettlementSupervisorHarness(sleep: { _ in await gate.wait() })
        defer { harness.stop() }
        let counter = SettlementStopCounter()
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
                return .audio(settlementAudioResult(sessionID))
            }
        )

        continuation.yield(settlementProgress(sessionID, capturedSamples: 1))
        let started = await harness.log.waitForMediaStarted()
        #expect(started)
        // The presentation watchdog only stays quiet when the UI confirms that it
        // presented the promoted state; an alive main actor always does this.
        await harness.supervisor.acknowledgePresentation(generation: generation)
        continuation.yield(settlementProgress(sessionID, capturedSamples: 2))

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
        let gate = SettlementSleepGate()
        let harness = SettlementSupervisorHarness(sleep: { _ in await gate.wait() })
        defer { harness.stop() }
        let counter = SettlementStopCounter()
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
                return .audio(settlementAudioResult(sessionID, segmentCount: 1))
            }
        )

        continuation.yield(settlementProgress(sessionID, capturedSamples: 1))
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
        let harness = SettlementSupervisorHarness(sleep: { try await Task.sleep(for: $0) })
        defer { harness.stop() }
        let counter = SettlementStopCounter()
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
                return .screen(
                    ScreenRecordingOutcome(
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
        let harness = SettlementSupervisorHarness(sleep: { try await Task.sleep(for: $0) })
        defer { harness.stop() }
        let counter = SettlementStopCounter()
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
                return .screen(
                    ScreenRecordingOutcome(
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
    ///
    /// The lease is asserted through the injected sleep, not by racing a wall-clock
    /// timer: a 200 ms lease renewed every 50 ms leaves only a 4× margin, which a
    /// loaded CI runner can miss. Each beat re-arms the lease by starting a fresh
    /// sleep, so "the beat renewed it" is exactly "another sleep was requested".
    @Test("Screen liveness stops when the main actor stops heartbeating")
    func screenLivenessStopsWhenHeartbeatsStop() async {
        let lease = Duration.milliseconds(200)
        let gate = SettlementLeaseGate()
        let harness = SettlementSupervisorHarness(sleep: { await gate.sleep($0) })
        defer { harness.stop() }
        let counter = SettlementStopCounter()
        let sessionID = UUID()
        let generation = UUID()
        _ = await harness.supervisor.arm(
            generation: generation,
            kind: .screen,
            deadline: .seconds(60),
            promotionDeadline: .milliseconds(400),
            livenessDeadline: lease,
            readiness: .poll { .ready },
            stop: {
                await counter.record()
                return .screen(
                    ScreenRecordingOutcome(
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

        // Ten beats, each of which must re-arm the lease: one sleep for the lease
        // itself, then one more per beat.
        for beat in 0..<10 {
            await harness.supervisor.heartbeat(generation: generation)
            let armed = await gate.waitForSleepCount(lease, atLeast: beat + 2)
            #expect(armed, "beat \(beat) did not re-arm the liveness lease")
            if !armed { break }
        }

        // A renewed lease never expires, so nothing may settle while beats continue.
        let settledWhileHealthy = await harness.log.settledCount
        #expect(settledWhileHealthy == 0)

        // Stop beating: the lease expires and the single stop runs.
        await gate.open(lease)
        let settled = await harness.log.waitForSettled()
        #expect(settled)
        let reasons = await harness.log.settledReasons
        #expect(reasons == [.promotionStalled])
        let calls = await counter.calls
        #expect(calls == 1)
        await gate.openAll()
    }

    /// Audio recordings use the same lease as screen recordings, renewed by the
    /// progress consumer. A frozen main actor stops the beats and the session is
    /// stopped and saved from the supervisor.
    ///
    /// Renewal is proven the same way as the screen case, through the injected
    /// sleep count, so the assertion cannot flake on a busy runner.
    @Test("Audio liveness stops when the progress consumer stops heartbeating")
    func audioLivenessStopsWhenHeartbeatsStop() async {
        let lease = Duration.milliseconds(200)
        let gate = SettlementLeaseGate()
        let harness = SettlementSupervisorHarness(sleep: { await gate.sleep($0) })
        defer { harness.stop() }
        let counter = SettlementStopCounter()
        let sessionID = UUID()
        let generation = UUID()
        let (stream, continuation) = AsyncStream<RecordingProgress>.makeStream()
        _ = await harness.supervisor.arm(
            generation: generation,
            kind: .audio,
            deadline: .seconds(60),
            promotionDeadline: .milliseconds(400),
            livenessDeadline: lease,
            readiness: .audioProgress(stream),
            stop: {
                await counter.record()
                return .audio(settlementAudioResult(sessionID, segmentCount: 1))
            }
        )

        continuation.yield(settlementProgress(sessionID, capturedSamples: 1))
        let started = await harness.log.waitForMediaStarted()
        #expect(started)
        await harness.supervisor.acknowledgePresentation(generation: generation)

        for beat in 0..<10 {
            await harness.supervisor.heartbeat(generation: generation)
            let armed = await gate.waitForSleepCount(lease, atLeast: beat + 2)
            #expect(armed, "beat \(beat) did not re-arm the liveness lease")
        }

        let settledWhileHealthy = await harness.log.settledCount
        #expect(settledWhileHealthy == 0)

        await gate.open(lease)
        let settled = await harness.log.waitForSettled()
        #expect(settled)
        let reasons = await harness.log.settledReasons
        #expect(reasons == [.promotionStalled])
        let calls = await counter.calls
        #expect(calls == 1)
        await gate.openAll()
    }

    /// The watchdog is identity-bound: an acknowledgement for another session must
    /// not silence this one.
    @Test("An acknowledgement for another generation does not cancel the watchdog")
    func acknowledgementForAnotherGenerationIsIgnored() async {
        let gate = SettlementSleepGate()
        let harness = SettlementSupervisorHarness(sleep: { _ in await gate.wait() })
        defer { harness.stop() }
        let counter = SettlementStopCounter()
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
                return .audio(settlementAudioResult(sessionID))
            }
        )

        continuation.yield(settlementProgress(sessionID, capturedSamples: 1))
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
        let gate = SettlementSleepGate()
        let harness = SettlementSupervisorHarness(sleep: { _ in await gate.wait() })
        defer { harness.stop() }
        let counter = SettlementStopCounter()
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
                return .audio(settlementAudioResult(sessionID))
            }
        )

        continuation.yield(settlementProgress(sessionID, capturedSamples: 1))
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

}
