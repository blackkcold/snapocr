import Foundation

/// How SnapGlass presents itself in the Dock.
///
/// The app is a menu-bar app (`LSUIElement`), so the Dock icon is the strongest
/// available signal that it is running. The mode is read through
/// `DockIconPolicyProviding` and applied by `WindowPresentationCoordinator`;
/// nothing else may call `setActivationPolicy` directly, or the policy and the
/// window lifecycle state machine start fighting each other.
public enum DockIconMode: String, CaseIterable, Identifiable, Sendable {
    /// Show the Dock icon only while a regular window is open. The default.
    case whileWindowsOpen
    /// Always stay `.regular`, so the Dock icon and the app menu persist.
    case always
    /// Never show the Dock icon, except during first-run onboarding.
    case never

    /// Stable identity used by SwiftUI collections and pickers.
    public var id: String { rawValue }

    /// Localization key for the Settings picker row.
    public var localizationKey: String {
        switch self {
        case .whileWindowsOpen: "While windows are open"
        case .always: "Always"
        case .never: "Never"
        }
    }
}
