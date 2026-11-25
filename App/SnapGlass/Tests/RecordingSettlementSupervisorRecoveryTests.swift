import CaptureCore
import Foundation
import Testing

extension RecordingSettlementSupervisorTests {
    /// S4: progress that only reflects checkpoint coverage (elapsed time, age,
    /// saved segments, loud levels) must never be mistaken for a captured sample.
    @Test("Checkpoint coverage never starts media")
    func checkpointCoverageNeverStartsMedia() async {
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
            readiness: .audioProgress(stream),
            stop: {
                await counter.record()
                return .audio(settlementAudioResult(sessionID))
            }
        )

        for _ in 0..<20 {
            continuation.yield(
                RecordingProgress(
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
        let stopGate = SettlementStopGate()
        let harness = SettlementSupervisorHarness(sleep: { _ in })
        defer { harness.stop() }
        let counter = SettlementStopCounter()
        let sessionID = UUID()
        let ticket = await harness.supervisor.arm(
            generation: UUID(),
            kind: .audio,
            deadline: .seconds(15),
            readiness: .audioProgress(settlementNeverYieldingProgress()),
            stop: {
                await counter.record()
                await stopGate.waitForRelease()
                return .audio(settlementAudioResult(sessionID))
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
        let gate = SettlementSleepGate()
        let harness = SettlementSupervisorHarness(sleep: { _ in await gate.wait() })
        defer { harness.stop() }
        let counter = SettlementStopCounter()
        _ = await harness.supervisor.arm(
            generation: UUID(),
            kind: .audio,
            deadline: .seconds(15),
            readiness: .audioProgress(settlementNeverYieldingProgress()),
            stop: {
                await counter.record()
                return .audio(settlementAudioResult(UUID()))
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
        let harness = SettlementSupervisorHarness(sleep: { _ in })
        defer { harness.stop() }
        let ticket = await harness.supervisor.arm(
            generation: UUID(),
            kind: .screen,
            deadline: .seconds(15),
            readiness: .audioProgress(settlementNeverYieldingProgress()),
            stop: { throw SettlementStopFailure() }
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
        let counter = SettlementStopCounter()
        let sessionID = UUID()
        let ticket = await supervisor.arm(
            generation: UUID(),
            kind: .audio,
            deadline: .seconds(15),
            readiness: .audioProgress(settlementNeverYieldingProgress()),
            stop: {
                await counter.record()
                return .audio(settlementAudioResult(sessionID, segmentCount: 1))
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
        let gate = SettlementSleepGate()
        let harness = SettlementSupervisorHarness(sleep: { _ in await gate.wait() })
        defer { harness.stop() }
        let counter = SettlementStopCounter()
        let ticket = await harness.supervisor.arm(
            generation: UUID(),
            kind: .audio,
            deadline: .seconds(15),
            readiness: .audioProgress(settlementNeverYieldingProgress()),
            stop: {
                await counter.record()
                return .audio(settlementAudioResult(UUID()))
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
        let gate = SettlementSleepGate()
        let harness = SettlementSupervisorHarness(sleep: { _ in await gate.wait() })
        defer { harness.stop() }
        let counter = SettlementStopCounter()
        let firstGeneration = UUID()

        let first = await harness.supervisor.arm(
            generation: firstGeneration,
            kind: .audio,
            deadline: .seconds(15),
            readiness: .audioProgress(settlementNeverYieldingProgress()),
            stop: {
                await counter.record(firstGeneration)
                return .audio(settlementAudioResult(UUID()))
            }
        )
        let secondGeneration = UUID()
        let second = await harness.supervisor.arm(
            generation: secondGeneration,
            kind: .audio,
            deadline: .seconds(15),
            readiness: .audioProgress(settlementNeverYieldingProgress()),
            stop: {
                await counter.record(secondGeneration)
                return .audio(settlementAudioResult(UUID()))
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
        let gate = SettlementSleepGate()
        let harness = SettlementSupervisorHarness(sleep: { _ in await gate.wait() })
        defer { harness.stop() }
        let counter = SettlementStopCounter()
        let sessionID = UUID()
        _ = await harness.supervisor.arm(
            generation: UUID(),
            kind: .screen,
            deadline: .seconds(15),
            readiness: .poll { .failed("The writer was not ready.") },
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
        let gate = SettlementSleepGate()
        let harness = SettlementSupervisorHarness(sleep: { _ in await gate.wait() })
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
