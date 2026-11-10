import Testing

@testable import CaptureCore

struct RecordingSessionStateTests {
    @Test func rejectsDuplicateStartAndStopTransitions() throws {
        var state = RecordingSessionState()

        try state.beginStart()
        #expect(state.phase == .starting)
        #expect(throws: RecordingSessionStateError.self) {
            try state.beginStart()
        }

        try state.recordingDidStart()
        try state.beginStop()
        #expect(state.phase == .stopping)
        #expect(throws: RecordingSessionStateError.self) {
            try state.beginStop()
        }
    }

    @Test func permitsWriterFinalizationAfterARecordingStops() throws {
        var state = RecordingSessionState()

        try state.beginStart()
        try state.recordingDidStart()
        try state.beginStop()
        try state.beginSaving()
        try state.finish()

        #expect(state.phase == .finished)
    }

    @Test func cannotStopBeforeRecordingStarts() {
        var state = RecordingSessionState()

        #expect(throws: RecordingSessionStateError.self) {
            try state.beginStop()
        }
        #expect(state.phase == .idle)
    }

    @Test func failureIsTerminalAndCannotBeRestarted() throws {
        var state = RecordingSessionState()
        try state.beginStart()

        state.fail()

        #expect(state.phase == .failed)
        #expect(throws: RecordingSessionStateError.self) {
            try state.beginStart()
        }
    }
}
