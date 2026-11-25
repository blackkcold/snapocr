import Foundation

/// One source option in the recording menu, with next-session and active-session state kept apart.
public struct RecordingMenuModeItem: Sendable, Equatable {
    /// The source option this row represents.
    public let mode: AudioSourceMode
    /// Whether this source is selected as the next session's default.
    public let isDefault: Bool
    /// Whether this source is active in the current recording.
    public let isCurrent: Bool

    /// Creates a menu option with independent default and current-session markers.
    public init(mode: AudioSourceMode, isDefault: Bool, isCurrent: Bool) {
        self.mode = mode
        self.isDefault = isDefault
        self.isCurrent = isCurrent
    }
}

/// Pure presentation rules shared by the menu bar and its tests.
public enum RecordingMenuModel {
    /// Returns every source in stable menu order, marking the next-session default separately
    /// from the source currently active in a recording.
    public static func modeItems(
        defaultMode: AudioSourceMode,
        currentMode: AudioSourceMode
    ) -> [RecordingMenuModeItem] {
        [AudioSourceMode.system, .microphone, .systemAndMicrophone, .none].map { mode in
            RecordingMenuModeItem(
                mode: mode,
                isDefault: mode == defaultMode,
                isCurrent: mode == currentMode
            )
        }
    }

    /// Returns the English menu key text and an elapsed-time value in parentheses.
    /// The app localizes the matching format key before presenting it.
    public static func stopTitle(kind: RecordingKind, duration: TimeInterval) -> String {
        let safeDuration = duration.isFinite ? min(max(duration, 0), 35_999_999_999) : 0
        let totalSeconds = Int(safeDuration.rounded(.down))
        let seconds = totalSeconds % 60
        let totalMinutes = totalSeconds / 60
        let minutes = totalMinutes % 60
        let hours = totalMinutes / 60
        let elapsed =
            hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", totalMinutes, seconds)

        switch kind {
        case .audio:
            return "Stop Audio Recording (\(elapsed))"
        case .screen:
            return "Stop and Save (\(elapsed))"
        }
    }

    /// Whether the stop command for the requested kind may run.
    /// `isRecording` must already indicate that the active session matches `kind`.
    public static func isEnabled(
        kind: RecordingKind,
        isRecording: Bool,
        isSaving: Bool
    ) -> Bool {
        guard !isSaving else { return false }
        switch kind {
        case .audio, .screen:
            return isRecording
        }
    }
}
