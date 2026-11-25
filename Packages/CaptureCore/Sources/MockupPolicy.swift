import Foundation

/// Pure rules that decide whether a capture gets a share-ready treatment.
///
/// Keeping this out of the App layer lets the capture pipeline, shelf badge,
/// and tests agree on one answer instead of duplicating the predicate.
public enum MockupPolicy {
    /// Whether a capture should receive the share treatment.
    ///
    /// Area and fullscreen captures qualify when the feature is enabled and the
    /// image is not being pinned. Window and scrolling captures keep raw pixels.
    ///
    /// - Parameters:
    ///   - captureMode: The capture mode that produced the image.
    ///   - isPinning: Whether the capture is being pinned; pinned images keep raw pixels.
    ///   - isEnabled: Whether share appearance is enabled in settings.
    /// - Returns: `true` only for an enabled, unpinned area or fullscreen capture.
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

    /// Resolves a stored preset identifier, falling back to `.light` when it is unknown.
    public static func preset(for presetID: String) -> MockupPreset {
        MockupPreset(rawValue: presetID) ?? .light
    }

    /// The share treatment for a stored preset identifier.
    ///
    /// Unknown identifiers use the same `.light` fallback as ``preset(for:)``.
    public static func style(for presetID: String) -> MockupStyle {
        preset(for: presetID).style
    }
}
