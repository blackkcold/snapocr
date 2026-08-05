import CoreGraphics
import Foundation

/// Platform-neutral metadata used to decide whether a window belongs in the capture picker.
public struct WindowCaptureCandidate: Sendable {
    public let bundleIdentifier: String?
    public let layer: Int
    public let frame: CGRect
    public let isOnScreen: Bool
    public let windowTitle: String?

    public init(
        bundleIdentifier: String?,
        layer: Int,
        frame: CGRect,
        isOnScreen: Bool,
        windowTitle: String? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.layer = layer
        self.frame = frame
        self.isOnScreen = isOnScreen
        self.windowTitle = windowTitle
    }
}

/// Filtering rules shared by the window picker and its unit tests.
public enum WindowCapturePolicy {
    private static let excludedSystemBundleIdentifiers: Set<String> = [
        "com.apple.controlcenter",
        "com.apple.dock",
        "com.apple.notificationcenterui",
        "com.apple.systemuiserver",
        "com.apple.windowserver",
    ]

    /// Window titles whose windows are never offered as capture targets. Used to
    /// hide window-manager overlays (e.g. DDPM) that appear as ordinary windows
    /// but carry no useful content. Comparison is case-insensitive substring.
    private static let excludedWindowTitleKeywords: Set<String> = [
        "ddpm",
    ]

    /// Returns whether a window is a useful user-facing capture target.
    ///
    /// - Parameters:
    ///   - candidate: Window metadata to evaluate.
    ///   - currentBundleIdentifier: Bundle identifier of SnapGlass, which must not capture itself.
    ///   - systemWindowLevel: First Core Graphics level reserved for system UI, normally the Dock level.
    public static func isSelectable(
        _ candidate: WindowCaptureCandidate,
        currentBundleIdentifier: String?,
        systemWindowLevel: Int
    ) -> Bool {
        guard candidate.isOnScreen,
              candidate.layer >= 0,
              candidate.layer < systemWindowLevel,
              candidate.frame.width >= 64,
              candidate.frame.height >= 48,
              let bundleIdentifier = candidate.bundleIdentifier?.lowercased(),
              !bundleIdentifier.isEmpty else {
            return false
        }

        if let currentBundleIdentifier,
           bundleIdentifier == currentBundleIdentifier.lowercased() {
            return false
        }

        if excludedSystemBundleIdentifiers.contains(bundleIdentifier) {
            return false
        }

        // Only offer windows that carry user-facing content: a blank title usually
        // indicates an overlay, a utility surface, or a window manager's floating
        // panel that has nothing worth capturing.
        guard let windowTitle = candidate.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !windowTitle.isEmpty else {
            return false
        }

        let lowercasedTitle = windowTitle.lowercased()
        return !excludedWindowTitleKeywords.contains { lowercasedTitle.contains($0) }
    }
}
