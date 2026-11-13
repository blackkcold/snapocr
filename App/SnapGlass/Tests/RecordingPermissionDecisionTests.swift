import CaptureCore
import Testing

@Suite("Recording permission decision")
struct RecordingPermissionDecisionTests {
    @Test("Available capture access allows the source picker")
    func availableAccessAllowsPicker() {
        let decision = RecordingPermissionDecision.beforePicker(
            accessAvailable: true,
            isCurrentAttempt: true,
            isSelectingSource: true
        )

        #expect(decision == .showPicker)
    }

    @Test("Unavailable capture access opens the shared permission guide")
    func unavailableAccessOpensGuide() {
        let decision = RecordingPermissionDecision.beforePicker(
            accessAvailable: false,
            isCurrentAttempt: true,
            isSelectingSource: true
        )

        #expect(decision == .openPermissionGuide)
    }

    @Test("Cancelling while the preflight is suspended does not open a picker")
    func cancelledPreflightIsIgnored() {
        let decision = RecordingPermissionDecision.beforePicker(
            accessAvailable: true,
            isCurrentAttempt: true,
            isSelectingSource: false
        )

        #expect(decision == .ignore)
    }

    @Test("A picker failure followed by an available access check stays a toast")
    func pickerFailureWithAvailableAccessShowsError() {
        let decision = RecordingPermissionDecision.afterPickerFailure(
            accessAvailable: true,
            isCurrentAttempt: true
        )

        #expect(decision == .showPickerFailure)
    }

    @Test("A picker failure followed by unavailable access opens the shared guide")
    func pickerFailureWithUnavailableAccessOpensGuide() {
        let decision = RecordingPermissionDecision.afterPickerFailure(
            accessAvailable: false,
            isCurrentAttempt: true
        )

        #expect(decision == .openPermissionGuide)
    }

    @Test("An old picker failure cannot affect a newer start attempt")
    func supersededPickerFailureIsIgnored() {
        let decision = RecordingPermissionDecision.afterPickerFailure(
            accessAvailable: false,
            isCurrentAttempt: false
        )

        #expect(decision == .ignore)
    }

    @Test("Authorized microphone access is ready before a request")
    func authorizedMicrophoneAccessIsReady() {
        let guidance = RecordingPermissionDecision.beforeMicrophoneRequest(
            authorization: .authorized,
            isCurrentAttempt: true
        )

        #expect(guidance == .ready)
    }

    @Test("Undetermined microphone access requests permission")
    func unknownMicrophoneAccessRequestsPermission() {
        let guidance = RecordingPermissionDecision.beforeMicrophoneRequest(
            authorization: .unknown,
            isCurrentAttempt: true
        )

        #expect(guidance == .requestAccess)
    }

    @Test("Denied microphone access opens System Settings")
    func deniedMicrophoneAccessOpensSystemSettings() {
        let guidance = RecordingPermissionDecision.beforeMicrophoneRequest(
            authorization: .denied,
            isCurrentAttempt: true
        )

        #expect(guidance == .openSystemSettings)
    }

    @Test("Restricted microphone access opens System Settings")
    func restrictedMicrophoneAccessOpensSystemSettings() {
        let guidance = RecordingPermissionDecision.beforeMicrophoneRequest(
            authorization: .restricted,
            isCurrentAttempt: true
        )

        #expect(guidance == .openSystemSettings)
    }

    @Test("A superseded microphone request is ignored")
    func supersededMicrophoneRequestIsIgnored() {
        let guidance = RecordingPermissionDecision.beforeMicrophoneRequest(
            authorization: .unknown,
            isCurrentAttempt: false
        )

        #expect(guidance == .ignore)
    }
}
