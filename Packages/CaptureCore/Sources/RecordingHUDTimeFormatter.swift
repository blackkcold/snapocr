import Foundation

/// Formats the elapsed time shown by the floating recording control panel.
public enum RecordingHUDTimeFormatter {
    /// Returns `mm:ss`, or `h:mm:ss` once the recording passes one hour.
    ///
    /// Invalid or negative intervals read as `00:00` so a clock glitch never renders `-1:-1`.
    public static func string(elapsed: TimeInterval) -> String {
        guard elapsed.isFinite, elapsed > 0 else { return "00:00" }
        let totalSeconds = Int(elapsed.rounded(.down))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

/// Converts a recording's captured rectangle into AppKit screen coordinates.
public enum RecordingCaptureFrameGeometry {
    /// Converts a display-local, top-left-origin capture rectangle into an AppKit global rectangle.
    ///
    /// - Parameters:
    ///   - localRect: Capture rectangle relative to the display's top-left corner.
    ///   - displayFrame: Display bounds in Quartz global points.
    ///   - appKitScreenFrame: The same display's `NSScreen.frame`.
    /// - Returns: The rectangle in AppKit global coordinates, or `nil` for invalid geometry.
    public static func appKitRect(
        localRect: CGRect,
        displayFrame: CGRect,
        appKitScreenFrame: CGRect
    ) -> CGRect? {
        guard displayFrame.width > 0,
              displayFrame.height > 0,
              appKitScreenFrame.width > 0,
              appKitScreenFrame.height > 0 else {
            return nil
        }
        let rect = localRect.standardized
        guard rect.width > 0, rect.height > 0 else { return nil }
        return CGRect(
            x: appKitScreenFrame.minX + rect.minX,
            y: appKitScreenFrame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}
