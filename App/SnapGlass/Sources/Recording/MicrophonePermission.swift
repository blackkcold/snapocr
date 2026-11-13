import CaptureCore

/// The user-facing action indicated by the current microphone authorization state.
enum MicrophonePermissionGuidance: Equatable {
    /// Ask the user for microphone access with a system prompt.
    case requestAccess
    /// Send the user to System Settings to grant access.
    case openSystemSettings
    /// Continue with system audio when microphone access is unavailable.
    case useSystemAudioFallback
    /// Microphone access is granted; recording may proceed.
    case ready
    /// The request no longer belongs to the current recording attempt.
    case ignore
}

/// Maps microphone authorization state to the guidance shown by recording UI.
enum MicrophonePermission {
    /// Returns the guidance for a microphone authorization state.
    ///
    /// - Parameter state: The current authorization state.
    /// - Returns: The action the UI should offer.
    static func guidance(for state: MicrophoneAuthorizationState) -> MicrophonePermissionGuidance {
        switch state {
        case .authorized:
            return .ready
        case .unknown:
            return .requestAccess
        case .denied, .restricted:
            return .openSystemSettings
        }
    }
}
