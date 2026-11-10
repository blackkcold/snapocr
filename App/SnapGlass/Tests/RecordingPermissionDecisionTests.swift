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
}
