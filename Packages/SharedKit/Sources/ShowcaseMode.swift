import Foundation

/// Debug-only switch that lets the app's own overlay windows be captured.
///
/// Every floating panel sets `sharingType = .none` so pins, the screenshot
/// shelf, and selection overlays never appear in a capture. That also means
/// they cannot be photographed for documentation. Launching with
/// `SNAPGLASS_SHOWCASE=1` relaxes that exclusion; without the variable the
/// release behavior is unchanged.
public enum ShowcaseMode {
    /// Whether the process was launched for UI capture.
    public static let isEnabled = ProcessInfo.processInfo.environment["SNAPGLASS_SHOWCASE"] == "1"
}
