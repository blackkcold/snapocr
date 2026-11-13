/// Pure guards for starting screen recording while capture operations are active.
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

}
