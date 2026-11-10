enum RecordingPermissionDecision: Equatable {
    case showPicker
    case openPermissionGuide
    case showPickerFailure
    case ignore

    static func beforePicker(
        accessAvailable: Bool,
        isCurrentAttempt: Bool,
        isSelectingSource: Bool
    ) -> Self {
        guard isCurrentAttempt, isSelectingSource else { return .ignore }
        return accessAvailable ? .showPicker : .openPermissionGuide
    }

    static func afterPickerFailure(
        accessAvailable: Bool,
        isCurrentAttempt: Bool
    ) -> Self {
        guard isCurrentAttempt else { return .ignore }
        return accessAvailable ? .showPickerFailure : .openPermissionGuide
    }
}
