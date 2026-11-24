import CaptureCore
import Testing

@Suite("Recording audio session state")
struct RecordingAudioSessionStateTests {
    @Test("A saved audio session moves through finalization")
    func savedSessionLifecycle() {
        var state = RecordingAudioSessionStateMachine()

        state.apply(.begin)
        #expect(state.state == .starting)
        state.apply(.started)
        #expect(state.state == .recording)
        state.apply(.stopRequested)
        #expect(state.state == .stopping)
        state.beginFinalization()
        #expect(state.state == .finalizing)
        state.apply(.stopCompleted(saved: true))
        #expect(state.state == .finished)
    }

    @Test("A failed finalization remains recoverable")
    func failedFinalizationIsRecoverable() {
        var state = RecordingAudioSessionStateMachine()
        state.apply(.begin)
        state.apply(.started)
        state.apply(.stopRequested)
        state.beginFinalization()

        state.apply(.stopCompleted(saved: false))

        #expect(state.state == .failedRecoverable)
    }

    @Test("Audio state maps to the frozen screen-recording status")
    func legacyStatusMapping() {
        var state = RecordingAudioSessionStateMachine()
        #expect(state.legacyStatus == .idle)

        state.apply(.begin)
        #expect(state.legacyStatus == .starting)
        state.apply(.started)
        #expect(state.legacyStatus == .recording)
        state.apply(.stopRequested)
        #expect(state.legacyStatus == .saving)
        state.beginFinalization()
        #expect(state.legacyStatus == .saving)
        state.apply(.stopCompleted(saved: true))
        #expect(state.legacyStatus == .idle)

        state.apply(.begin)
        state.apply(.failedRecoverable)
        #expect(state.legacyStatus == .idle)
    }

    @Test("Repeated transitions are idempotent")
    func repeatedTransitionsAreIdempotent() {
        var state = RecordingAudioSessionStateMachine()

        state.apply(.begin)
        state.apply(.begin)
        #expect(state.state == .starting)
        state.apply(.started)
        state.apply(.started)
        #expect(state.state == .recording)
        state.apply(.stopRequested)
        state.apply(.stopRequested)
        #expect(state.state == .stopping)
        state.beginFinalization()
        state.apply(.stopCompleted(saved: true))
        state.apply(.stopCompleted(saved: true))
        #expect(state.state == .finished)
    }

    /// A promotion-stall stop can arrive after the session already reached
    /// `.recording`: the main actor presented the promoted state, then stopped
    /// responding. Finishing must still be possible for that live state, or the
    /// app refuses every later recording until relaunch.
    @Test("A stop after the promoted state still finalizes")
    func promotedSessionStillFinalizes() {
        var state = RecordingAudioSessionStateMachine()
        state.apply(.begin)
        state.apply(.started)
        #expect(state.state == .recording)

        state.apply(.stopRequested)
        state.beginFinalization()
        state.apply(.stopCompleted(saved: true))

        #expect(state.state == .finished)
        #expect(state.legacyStatus == .idle)
    }
}
