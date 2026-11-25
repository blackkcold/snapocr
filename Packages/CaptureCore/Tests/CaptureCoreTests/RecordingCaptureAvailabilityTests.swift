import Testing

@testable import CaptureCore

struct RecordingCaptureAvailabilityTests {
    @Test func recordingCannotStartDuringScreenshotOrScrollCapture() {
        #expect(RecordingCaptureAvailability.canBeginRecording(isCapturing: false, isScrollCaptureActive: false))
        #expect(!RecordingCaptureAvailability.canBeginRecording(isCapturing: true, isScrollCaptureActive: false))
        #expect(!RecordingCaptureAvailability.canBeginRecording(isCapturing: false, isScrollCaptureActive: true))
    }

}
