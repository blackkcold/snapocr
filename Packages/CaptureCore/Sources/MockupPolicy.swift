import Foundation

/// Pure rules that decide whether a capture gets a share-ready treatment.
///
/// Keeping this out of the App layer lets the capture pipeline, shelf badge,
/// and tests agree on one answer instead of duplicating the predicate.
public enum MockupPolicy {
    public static func applies(
        captureMode: CaptureMode,
        isPinning: Bool,
        isEnabled: Bool
    ) -> Bool {
        guard !isPinning, isEnabled else { return false }
        switch captureMode {
        case .area, .fullscreen:
            return true
        case .window, .scroll:
            return false
        }
    }

    public static func preset(for presetID: String) -> MockupPreset {
        MockupPreset(rawValue: presetID) ?? .light
    }

    public static func style(for presetID: String) -> MockupStyle {
        preset(for: presetID).style
    }
}
