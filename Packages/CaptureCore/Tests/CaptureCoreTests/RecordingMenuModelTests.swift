import CaptureCore
import Testing

@Suite("Recording menu model")
struct RecordingMenuModelTests {
    @Test("default and current source markers are independent")
    func modeItemsKeepDefaultAndCurrentSeparate() {
        let items = RecordingMenuModel.modeItems(defaultMode: .system, currentMode: .microphone)

        #expect(items.first(where: { $0.mode == .system })?.isDefault == true)
        #expect(items.first(where: { $0.mode == .system })?.isCurrent == false)
        #expect(items.first(where: { $0.mode == .microphone })?.isDefault == false)
        #expect(items.first(where: { $0.mode == .microphone })?.isCurrent == true)
        #expect(items.count == 4)
    }

    @Test("stop title includes short, long, and empty elapsed durations")
    func stopTitleFormatsElapsedTime() {
        #expect(RecordingMenuModel.stopTitle(kind: .audio, duration: 8) == "Stop Audio Recording (0:08)")
        #expect(RecordingMenuModel.stopTitle(kind: .screen, duration: 3_661) == "Stop and Save (1:01:01)")
        #expect(RecordingMenuModel.stopTitle(kind: .audio, duration: -.infinity) == "Stop Audio Recording (0:00)")
    }

    @Test("stop command is enabled only for the matching active recording")
    func stopCommandEnabledState() {
        #expect(RecordingMenuModel.isEnabled(kind: .audio, isRecording: true, isSaving: false))
        #expect(!RecordingMenuModel.isEnabled(kind: .screen, isRecording: false, isSaving: false))
        #expect(!RecordingMenuModel.isEnabled(kind: .audio, isRecording: true, isSaving: true))
    }
}
