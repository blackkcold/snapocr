import Foundation
import SharedKit

/// Supplies the Dock icon mode to `WindowPresentationCoordinator`.
///
/// The coordinator is the only place that may call `setActivationPolicy`. Routing
/// the user's choice through this protocol keeps the mode out of the window
/// lifecycle state machine, which otherwise loses track of whether it should be
/// regular or accessory and makes the Dock icon flicker.
@MainActor
protocol DockIconPolicyProviding: AnyObject {
    /// The user's chosen Dock presentation.
    var mode: DockIconMode { get }
    /// Whether first-run onboarding is still owed.
    ///
    /// While true, `.never` is treated as `.whileWindowsOpen`: a new user who has
    /// never been told the app is a menu-bar app cannot find it if it never shows
    /// a Dock icon.
    var firstRunOverride: Bool { get }
}

/// Reads the Dock icon mode from preferences.
///
/// `firstRunOverride` is supplied by a closure rather than reading defaults
/// directly, so the coordinator tests can drive it without touching `UserDefaults`.
@MainActor
final class PreferencesDockIconPolicyProvider: DockIconPolicyProviding {
    private let defaults: UserDefaults
    private let firstRunProvider: () -> Bool

    /// Creates a provider.
    ///
    /// - Parameters:
    ///   - defaults: The defaults domain holding `general_dockIconMode`.
    ///   - firstRunProvider: Returns true while onboarding is unfinished.
    init(defaults: UserDefaults = .standard, firstRunProvider: @escaping () -> Bool) {
        self.defaults = defaults
        self.firstRunProvider = firstRunProvider
    }

    var mode: DockIconMode {
        let raw = defaults.string(forKey: PreferenceKeys.dockIconMode) ?? PreferenceDefaults.dockIconMode
        return DockIconMode(rawValue: raw) ?? .whileWindowsOpen
    }

    var firstRunOverride: Bool {
        firstRunProvider()
    }
}

/// Fixed provider used where no preference is available, such as previews.
@MainActor
final class StaticDockIconPolicyProvider: DockIconPolicyProviding {
    let mode: DockIconMode
    let firstRunOverride: Bool

    /// Creates a fixed provider.
    ///
    /// - Parameters:
    ///   - mode: Mode to report.
    ///   - firstRunOverride: Override to report.
    init(mode: DockIconMode = .whileWindowsOpen, firstRunOverride: Bool = false) {
        self.mode = mode
        self.firstRunOverride = firstRunOverride
    }
}
