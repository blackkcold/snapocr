import CaptureCore
import Foundation
import Testing

@Suite("Recording quit flow")
struct RecordingQuitFlowTests {
    @Test("A save that completes while confirmation is open allows quit")
    func savedRecordingDuringConfirmationAllowsQuit() {
        var outcomeState = RecordingSessionOutcomeState()
        outcomeState.beginSession()
        outcomeState.markRecordingStarted()
        var flow = RecordingQuitFlow()

        #expect(flow.request(needsConfirmation: true, isSaving: false) == .confirm)
        outcomeState.finishSession(wasSaved: true)

        let shouldQuit = flow.complete(with: outcomeState.terminalOutcome)
        #expect(shouldQuit)
    }

    @Test("A finalization failure cancels quit")
    func finalizationFailureCancelsQuit() {
        var outcomeState = activeRecordingOutcomeState()
        var flow = confirmationFlow()
        outcomeState.finishSession(wasSaved: false)

        #expect(outcomeState.terminalOutcome == .failed)
        let shouldQuit = flow.complete(with: outcomeState.terminalOutcome)
        #expect(!shouldQuit)
    }

    @Test("A source picker failure before recording allows quit")
    func pickerFailureBeforeRecordingAllowsQuit() {
        var outcomeState = newSessionOutcomeState()
        var flow = confirmationFlow()
        outcomeState.finishSession(wasSaved: false)

        #expect(outcomeState.terminalOutcome == .noActiveSession)
        let shouldQuit = flow.complete(with: outcomeState.terminalOutcome)
        #expect(shouldQuit)
    }

    @Test("A recording start failure before activation allows quit")
    func startFailureBeforeActivationAllowsQuit() {
        var outcomeState = newSessionOutcomeState()
        var flow = confirmationFlow()
        outcomeState.finishSession(wasSaved: false)

        #expect(outcomeState.terminalOutcome == .noActiveSession)
        let shouldQuit = flow.complete(with: outcomeState.terminalOutcome)
        #expect(shouldQuit)
    }

    @Test("Cancelling during countdown is a no-active-session outcome")
    func countdownCancellationAllowsQuit() {
        var outcomeState = newSessionOutcomeState()
        var flow = confirmationFlow()
        outcomeState.finishSession(wasSaved: false)

        #expect(outcomeState.terminalOutcome == .noActiveSession)
        let shouldQuit = flow.complete(with: outcomeState.terminalOutcome)
        #expect(shouldQuit)
    }

    @Test("An already-running save skips confirmation and waits for its outcome")
    func alreadyRunningSaveWaitsWithoutConfirmation() {
        var outcomeState = activeRecordingOutcomeState()
        var flow = RecordingQuitFlow()

        #expect(flow.request(needsConfirmation: true, isSaving: true) == .waitForRecording)
        outcomeState.finishSession(wasSaved: true)

        let shouldQuit = flow.complete(with: outcomeState.terminalOutcome)
        #expect(shouldQuit)
    }

    @Test("A failed background finalization keeps the application open")
    func failedBackgroundFinalizationKeepsApplicationOpen() {
        var flow = RecordingQuitFlow()

        #expect(flow.request(needsConfirmation: true, isSaving: true) == .waitForRecording)
        let shouldQuit = flow.complete(with: .failed)
        #expect(!shouldQuit)
    }

    @Test("A duplicate quit request is cancelled while confirmation is open")
    func duplicateQuitIsCancelled() {
        var flow = RecordingQuitFlow()

        #expect(flow.request(needsConfirmation: true, isSaving: false) == .confirm)
        #expect(flow.request(needsConfirmation: true, isSaving: false) == .terminateCancel)

        flow.cancel()
        #expect(!flow.isHandlingRequest)
    }

    @Test("A post-start no-frame or stream failure cancels quit")
    func postStartFailureCancelsQuit() {
        var outcomeState = activeRecordingOutcomeState()
        var flow = confirmationFlow()
        outcomeState.finishSession(wasSaved: false)

        #expect(outcomeState.terminalOutcome == .failed)
        let shouldQuit = flow.complete(with: outcomeState.terminalOutcome)
        #expect(!shouldQuit)
    }

    @Test("Beginning a new session clears a prior terminal outcome")
    func newSessionClearsPriorOutcome() {
        var outcomeState = activeRecordingOutcomeState()
        outcomeState.finishSession(wasSaved: true)

        outcomeState.beginSession()

        #expect(outcomeState.terminalOutcome == nil)
    }

    private func activeRecordingOutcomeState() -> RecordingSessionOutcomeState {
        var outcomeState = newSessionOutcomeState()
        outcomeState.markRecordingStarted()
        return outcomeState
    }

    private func newSessionOutcomeState() -> RecordingSessionOutcomeState {
        var outcomeState = RecordingSessionOutcomeState()
        outcomeState.beginSession()
        return outcomeState
    }

    private func confirmationFlow() -> RecordingQuitFlow {
        var flow = RecordingQuitFlow()
        _ = flow.request(needsConfirmation: true, isSaving: false)
        return flow
    }
}

@Suite("Recording start ownership")
struct RecordingStartOwnershipTests {
    @Test("Cancel before the start returns cleans the late adapter once")
    func cancelBeforeStartReturns() {
        var ownership = RecordingStartOwnership()
        let generation = UUID()

        let beginStartResult144 = ownership.beginStart(generation: generation)
        #expect(beginStartResult144)
        #expect(ownership.blocksNewStart)
        #expect(ownership.isPlatformStartOutstanding)
        #expect(ownership.requestCancel(generation: generation) == .stopWhenStartReturns)

        // The start returns after the UI settled: it may not promote the session.
        let platformStartReturnedResult150 = ownership.platformStartReturned(generation: generation)
        #expect(!platformStartReturnedResult150)
        #expect(ownership.isAwaitingFirstFrame)
        let beginInitialStopResult152 = ownership.beginInitialStop(generation: generation)
        #expect(beginInitialStopResult152)
        #expect(ownership.isStopping)
        let beginInitialStopResult154 = ownership.beginInitialStop(generation: generation)
        #expect(!beginInitialStopResult154)
        let firstFrameAcceptedResult155 = ownership.firstFrameAccepted(generation: generation)
        #expect(!firstFrameAcceptedResult155)
    }

    @Test("A late start that fails releases only the gate it owns")
    func lateStartFailureReleasesOwnGate() {
        var ownership = RecordingStartOwnership()
        let generation = UUID()

        let beginStartResult163 = ownership.beginStart(generation: generation)
        #expect(beginStartResult163)
        #expect(ownership.requestCancel(generation: generation) == .stopWhenStartReturns)
        let startFailedResult165 = ownership.startFailed(generation: generation)
        #expect(startFailedResult165)
        #expect(!ownership.blocksNewStart)
        let startFailedResult167 = ownership.startFailed(generation: generation)
        #expect(!startFailedResult167)
    }

    @Test("Cancel after the start returned stops the live adapter immediately")
    func cancelWhileAwaitingFirstFrame() {
        var ownership = RecordingStartOwnership()
        let generation = UUID()

        let beginStartResult175 = ownership.beginStart(generation: generation)
        #expect(beginStartResult175)
        let platformStartReturnedResult176 = ownership.platformStartReturned(generation: generation)
        #expect(platformStartReturnedResult176)
        #expect(ownership.isAwaitingFirstFrame)
        #expect(ownership.requestCancel(generation: generation) == .cancelFirstFrameWait)
        let beginInitialStopResult179 = ownership.beginInitialStop(generation: generation)
        #expect(beginInitialStopResult179)
        let beginInitialStopResult180 = ownership.beginInitialStop(generation: generation)
        #expect(!beginInitialStopResult180)
        let startFailedResult181 = ownership.startFailed(generation: generation)
        #expect(!startFailedResult181)
        let firstFrameAcceptedResult182 = ownership.firstFrameAccepted(generation: generation)
        #expect(!firstFrameAcceptedResult182)
        let stopConfirmedResult183 = ownership.stopConfirmed(generation: generation)
        #expect(stopConfirmedResult183)
        #expect(!ownership.blocksNewStart)
        let beginStartResult185 = ownership.beginStart(generation: UUID())
        #expect(beginStartResult185)
    }

    @Test("A recording cancel is a normal stop, not a first-frame cancel")
    func recordingCancelUsesNormalStop() {
        var ownership = RecordingStartOwnership()
        let generation = UUID()

        let beginStartResult193 = ownership.beginStart(generation: generation)
        #expect(beginStartResult193)
        let platformStartReturnedResult194 = ownership.platformStartReturned(generation: generation)
        #expect(platformStartReturnedResult194)
        let firstFrameAcceptedResult195 = ownership.firstFrameAccepted(generation: generation)
        #expect(firstFrameAcceptedResult195)
        #expect(ownership.requestCancel(generation: generation) == .notStarting)
        let beginInitialStopResult197 = ownership.beginInitialStop(generation: generation)
        #expect(beginInitialStopResult197)
        let beginInitialStopResult198 = ownership.beginInitialStop(generation: generation)
        #expect(!beginInitialStopResult198)
    }

    @Test("An old generation cannot release or reuse a newer gate")
    func staleGenerationCannotTouchNewGate() {
        var ownership = RecordingStartOwnership()
        let first = UUID()
        let second = UUID()

        let beginStartResult207 = ownership.beginStart(generation: first)
        #expect(beginStartResult207)
        let platformStartReturnedResult208 = ownership.platformStartReturned(generation: second)
        #expect(!platformStartReturnedResult208)
        let startFailedResult209 = ownership.startFailed(generation: second)
        #expect(!startFailedResult209)
        let beginStartResult210 = ownership.beginStart(generation: second)
        #expect(!beginStartResult210)
        #expect(ownership.blocksNewStart)
        let startFailedResult212 = ownership.startFailed(generation: first)
        #expect(startFailedResult212)
        let beginStartResult213 = ownership.beginStart(generation: second)
        #expect(beginStartResult213)
    }

    @Test("An unconfirmed stop keeps occupancy until a retry confirms it")
    func unconfirmedStopRetainsOccupancy() {
        var ownership = RecordingStartOwnership()
        let generation = UUID()

        let beginStartResult221 = ownership.beginStart(generation: generation)
        #expect(beginStartResult221)
        let platformStartReturnedResult222 = ownership.platformStartReturned(generation: generation)
        #expect(platformStartReturnedResult222)
        let beginInitialStopResult223 = ownership.beginInitialStop(generation: generation)
        #expect(beginInitialStopResult223)
        let stopUnconfirmedResult224 = ownership.stopUnconfirmed(generation: generation)
        #expect(stopUnconfirmedResult224)
        #expect(ownership.needsReleaseConfirmation)
        #expect(ownership.blocksNewStart)
        let beginStartResult227 = ownership.beginStart(generation: UUID())
        #expect(!beginStartResult227)
        let beginStopRetryResult228 = ownership.beginStopRetry(generation: generation)
        #expect(beginStopRetryResult228)
        #expect(ownership.isStopping)
        let stopConfirmedResult230 = ownership.stopConfirmed(generation: generation)
        #expect(stopConfirmedResult230)
        #expect(!ownership.blocksNewStart)
        let beginStartResult232 = ownership.beginStart(generation: UUID())
        #expect(beginStartResult232)
    }

    @Test("A stale result without resources is discarded, with resources cleaned up")
    func staleResultDisposition() {
        let generation = UUID()
        let identity = RecordingRequestIdentity(generation: generation, kind: .screen)

        #expect(identity.isCurrent(generation: generation))
        #expect(identity.disposition(generation: generation, holdsResource: false) == .apply)
        #expect(
            identity.disposition(generation: UUID(), holdsResource: true) == .cleanupOnly
        )
        #expect(
            identity.disposition(generation: UUID(), holdsResource: false) == .discard
        )
    }

    @Test("The phase clock is injectable and needs no sleep")
    func phaseClockIsControllable() {
        let base = ContinuousClock.now
        let clock = RecordingPhaseClock(now: { base.advanced(by: .seconds(2)) })

        #expect(clock.milliseconds(since: base) == 2_000)
        #expect(clock.milliseconds(since: base.advanced(by: .milliseconds(1_250))) == 750)
    }

    @Test("The four start phases have distinct stable diagnostic codes")
    func startPhaseDiagnosticCodesAreDistinct() {
        let phases: [RecordingStartPhase] = [
            .startingAudioPipeline,
            .awaitingFirstAudioSample,
            .startingScreenWriter,
            .awaitingFirstVideoFrame,
        ]

        #expect(Set(phases.map(\.diagnosticCode)).count == 4)
        #expect(phases.map(\.diagnosticCode) == [1, 2, 3, 4])
        #expect(phases.map(\.kind) == [.audio, .audio, .screen, .screen])
    }
}

@Suite("Recording destination recheck")
@MainActor
struct RecordingDestinationRecheckTests {
    private struct RecheckFailure: Error {}

    @Test("A success after A is cancelled and B starts never starts A or finishes B")
    func staleSuccessDoesNotAffectB() async {
        let requestA = RecordingRequestIdentity(kind: .screen)
        let requestB = RecordingRequestIdentity(kind: .screen)
        let harness = RecheckHarness(current: requestA)
        let aGate = SuspendedDestinationVerification()
        let bGate = SuspendedDestinationVerification()

        let aRecheck = RecordingDestinationRecheck(
            request: requestA,
            verify: { try await aGate.verify() },
            isCurrent: { harness.isCurrent($0) },
            onVerified: { harness.started.append(requestA) },
            onFailure: { _ in
                harness.reportedFailures.append(requestA)
                harness.finished.append(requestA)
            }
        )
        let aTask = Task { await aRecheck.run() }
        await aGate.waitUntilStarted()

        // A is cancelled and B starts while A's recheck is still suspended.
        harness.current = requestB
        let bRecheck = RecordingDestinationRecheck(
            request: requestB,
            verify: { try await bGate.verify() },
            isCurrent: { harness.isCurrent($0) },
            onVerified: { harness.started.append(requestB) },
            onFailure: { _ in
                harness.reportedFailures.append(requestB)
                harness.finished.append(requestB)
            }
        )
        let bTask = Task { await bRecheck.run() }
        await bGate.waitUntilStarted()

        aGate.succeed()
        await aTask.value
        #expect(harness.started.isEmpty)
        #expect(harness.reportedFailures.isEmpty)
        #expect(harness.finished.isEmpty)
        #expect(harness.current == requestB)

        bGate.succeed()
        await bTask.value
        #expect(harness.started == [requestB])
        #expect(harness.reportedFailures.isEmpty)
        #expect(harness.finished.isEmpty)
    }

    @Test("A failure after A is cancelled and B starts never reports or finishes B")
    func staleFailureDoesNotAffectB() async {
        let requestA = RecordingRequestIdentity(kind: .screen)
        let requestB = RecordingRequestIdentity(kind: .screen)
        let harness = RecheckHarness(current: requestA)
        let aGate = SuspendedDestinationVerification()
        let bGate = SuspendedDestinationVerification()

        let aRecheck = RecordingDestinationRecheck(
            request: requestA,
            verify: { try await aGate.verify() },
            isCurrent: { harness.isCurrent($0) },
            onVerified: { harness.started.append(requestA) },
            onFailure: { _ in
                harness.reportedFailures.append(requestA)
                harness.finished.append(requestA)
            }
        )
        let aTask = Task { await aRecheck.run() }
        await aGate.waitUntilStarted()

        harness.current = requestB
        let bRecheck = RecordingDestinationRecheck(
            request: requestB,
            verify: { try await bGate.verify() },
            isCurrent: { harness.isCurrent($0) },
            onVerified: { harness.started.append(requestB) },
            onFailure: { _ in
                harness.reportedFailures.append(requestB)
                harness.finished.append(requestB)
            }
        )
        let bTask = Task { await bRecheck.run() }
        await bGate.waitUntilStarted()

        aGate.fail(RecheckFailure())
        await aTask.value
        #expect(harness.started.isEmpty)
        #expect(harness.reportedFailures.isEmpty)
        #expect(harness.finished.isEmpty)
        #expect(harness.current == requestB)

        bGate.succeed()
        await bTask.value
        #expect(harness.started == [requestB])
        #expect(harness.reportedFailures.isEmpty)
        #expect(harness.finished.isEmpty)
    }

    @Test("The current request receives its success")
    func currentSuccessStarts() async {
        let requestA = RecordingRequestIdentity(kind: .screen)
        let harness = RecheckHarness(current: requestA)
        let gate = SuspendedDestinationVerification()

        let recheck = RecordingDestinationRecheck(
            request: requestA,
            verify: { try await gate.verify() },
            isCurrent: { harness.isCurrent($0) },
            onVerified: { harness.started.append(requestA) },
            onFailure: { _ in
                harness.reportedFailures.append(requestA)
                harness.finished.append(requestA)
            }
        )
        let task = Task { await recheck.run() }
        await gate.waitUntilStarted()
        gate.succeed()
        await task.value

        #expect(harness.started == [requestA])
        #expect(harness.reportedFailures.isEmpty)
        #expect(harness.finished.isEmpty)
    }

    @Test("The current request receives its failure")
    func currentFailureReports() async {
        let requestA = RecordingRequestIdentity(kind: .screen)
        let harness = RecheckHarness(current: requestA)
        let gate = SuspendedDestinationVerification()

        let recheck = RecordingDestinationRecheck(
            request: requestA,
            verify: { try await gate.verify() },
            isCurrent: { harness.isCurrent($0) },
            onVerified: { harness.started.append(requestA) },
            onFailure: { _ in
                harness.reportedFailures.append(requestA)
                harness.finished.append(requestA)
            }
        )
        let task = Task { await recheck.run() }
        await gate.waitUntilStarted()
        gate.fail(RecheckFailure())
        await task.value

        #expect(harness.started.isEmpty)
        #expect(harness.reportedFailures == [requestA])
        #expect(harness.finished == [requestA])
    }
}

/// A verification that suspends until the test resumes it, with no delay.
@MainActor
private final class SuspendedDestinationVerification {
    private var resumption: CheckedContinuation<Void, any Error>?
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var didStart = false

    func verify() async throws {
        didStart = true
        startWaiter?.resume()
        startWaiter = nil
        try await withCheckedThrowingContinuation { resumption = $0 }
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func succeed() {
        let resumption = resumption
        self.resumption = nil
        resumption?.resume()
    }

    func fail(_ error: any Error) {
        let resumption = resumption
        self.resumption = nil
        resumption?.resume(throwing: error)
    }
}

/// The controller-side state the recheck is allowed to touch.
@MainActor
private final class RecheckHarness {
    var current: RecordingRequestIdentity
    var started: [RecordingRequestIdentity] = []
    var reportedFailures: [RecordingRequestIdentity] = []
    var finished: [RecordingRequestIdentity] = []

    init(current: RecordingRequestIdentity) {
        self.current = current
    }

    func isCurrent(_ request: RecordingRequestIdentity) -> Bool {
        current == request
    }
}

@Suite("Recording screen stop execution")
@MainActor
struct RecordingScreenStopExecutionTests {
    @Test("A cancelled first-frame start stops the adapter once and can start again")
    func cancelledFirstFrameStopsAdapterOnce() async throws {
        var ownership = RecordingStartOwnership()
        let generation = UUID()
        let beginStartResult487 = ownership.beginStart(generation: generation)
        #expect(beginStartResult487)
        let platformStartReturnedResult488 = ownership.platformStartReturned(generation: generation)
        #expect(platformStartReturnedResult488)
        #expect(ownership.requestCancel(generation: generation) == .cancelFirstFrameWait)

        let counter = StopCounter()
        let adapter = ScreenRecordingPipelineAdapter(
            start: { _, _ in },
            stopAndSave: {
                await counter.increment()
                return ScreenRecordingOutcome(
                    sessionID: UUID(),
                    segmentURLs: [URL(fileURLWithPath: "/recordings/late-00.mp4")],
                    droppedFrameCount: 0,
                    failure: nil
                )
            },
            retryPublish: { throw CancellationError() }
        )

        // The production ownership latch is what allows this one stop. The adapter
        // is the same type and stop operation the controller uses.
        if ownership.beginInitialStop(generation: generation) {
            _ = try await adapter.stopAndSave()
            _ = ownership.stopConfirmed(generation: generation)
        }
        let stopCount = await counter.value
        #expect(stopCount == 1)
        let firstFrameAcceptedResult514 = ownership.firstFrameAccepted(generation: generation)
        #expect(!firstFrameAcceptedResult514)
        let beginInitialStopResult515 = ownership.beginInitialStop(generation: generation)
        #expect(!beginInitialStopResult515)
        let beginStartResult516 = ownership.beginStart(generation: UUID())
        #expect(beginStartResult516)
    }
}

private actor StopCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
