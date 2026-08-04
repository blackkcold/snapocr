import CoreGraphics
import Foundation

/// Platform-neutral metadata used to decide whether a window belongs in the capture picker.
public struct WindowCaptureCandidate: Sendable {
    public let bundleIdentifier: String?
    public let layer: Int
    public let frame: CGRect
    public let isOnScreen: Bool

    public init(
        bundleIdentifier: String?,
        layer: Int,
        frame: CGRect,
        isOnScreen: Bool
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.layer = layer
        self.frame = frame
        self.isOnScreen = isOnScreen
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

        return !excludedSystemBundleIdentifiers.contains(bundleIdentifier)
    }
}
