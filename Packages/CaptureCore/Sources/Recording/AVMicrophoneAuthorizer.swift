import AVFoundation

/// Reads and requests microphone authorization through AVFoundation.
///
/// Initialization performs no system calls and never prompts. Access is requested only when
/// `requestAccess()` is invoked from an explicit user action.
public struct AVMicrophoneAuthorizer: MicrophoneAuthorizing {
    /// Creates an authorizer without reading device state or prompting.
    public init() {}

    /// Returns the current microphone authorization state without prompting.
    ///
    /// - Returns: The current microphone authorization state.
    public func currentState() -> MicrophoneAuthorizationState {
        Self.map(AVCaptureDevice.authorizationStatus(for: .audio))
    }

    /// Requests microphone access, prompting the user when the state is undetermined.
    ///
    /// - Returns: The authorization state after the request completes.
    public func requestAccess() async -> MicrophoneAuthorizationState {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else {
            return Self.map(AVCaptureDevice.authorizationStatus(for: .audio))
        }
        return .authorized
    }

    /// Maps an AVFoundation authorization status to the recording domain state.
    ///
    /// - Parameter status: The AVFoundation status to map.
    /// - Returns: The matching microphone authorization state.
    private static func map(_ status: AVAuthorizationStatus) -> MicrophoneAuthorizationState {
        switch status {
        case .notDetermined:
            return .unknown
        case .restricted:
            return .restricted
        case .denied:
            return .denied
        case .authorized:
            return .authorized
        @unknown default:
            return .denied
        }
    }
}
