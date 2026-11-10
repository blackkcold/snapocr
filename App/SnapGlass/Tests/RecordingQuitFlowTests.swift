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
