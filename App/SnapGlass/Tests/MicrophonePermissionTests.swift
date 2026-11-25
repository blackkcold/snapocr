import CaptureCore
import Testing

@Suite("Microphone permission guidance")
struct MicrophonePermissionTests {
    @Test("Authorized microphone access is ready")
    func authorizedIsReady() {
        let guidance = MicrophonePermission.guidance(for: .authorized)

        #expect(guidance == .ready)
    }

    @Test("Undetermined microphone access requests permission")
    func unknownRequestsAccess() {
        let guidance = MicrophonePermission.guidance(for: .unknown)

        #expect(guidance == .requestAccess)
    }

    @Test("Denied microphone access opens System Settings")
    func deniedOpensSystemSettings() {
        let guidance = MicrophonePermission.guidance(for: .denied)

        #expect(guidance == .openSystemSettings)
    }

    @Test("Restricted microphone access opens System Settings")
    func restrictedOpensSystemSettings() {
        let guidance = MicrophonePermission.guidance(for: .restricted)

        #expect(guidance == .openSystemSettings)
    }
}
