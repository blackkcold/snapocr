/// Pure guards that prevent screenshot and screen-recording sessions from overlapping.
public enum RecordingCaptureAvailability {
    /// Returns whether a recording may start while the app's capture state is idle.
    ///
    /// - Parameters:
    ///   - isCapturing: Whether a screenshot capture is in progress.
    ///   - isScrollCaptureActive: Whether a scrolling-capture session is active.
    /// - Returns: `true` only when neither capture mode is active.
    public static func canBeginRecording(isCapturing: Bool, isScrollCaptureActive: Bool) -> Bool {
        !isCapturing && !isScrollCaptureActive
    }

    /// Returns whether a screenshot or scrolling capture may start.
    ///
    /// - Parameter isRecordingBusy: Whether recording is selecting, starting, recording, or saving.
    /// - Returns: `true` when no recording session is busy.
    public static func canBeginCapture(isRecordingBusy: Bool) -> Bool {
        !isRecordingBusy
    }
}
