import Foundation

/// What the Updates settings panel and the menu-bar badge show.
///
/// Sparkle owns checking, downloading, EdDSA verification, installation and
/// relaunch. This type only mirrors the parts the app needs to draw: a check is
/// running, the app is current, an update exists, or a user-initiated check
/// failed. Scheduled failures stay silent on purpose — a menu-bar app should
/// not grow a permanent red badge because a background request timed out.
enum UpdateCheckState: Equatable {
    case idle
    case checking
    case upToDate(String)
    case available(AvailableUpdate)
    case failed(String)

    var isChecking: Bool {
        if case .checking = self { return true }
        return false
    }

    var availableUpdate: AvailableUpdate? {
        if case .available(let update) = self { return update }
        return nil
    }
}

/// The update Sparkle found, in the form the UI needs.
struct AvailableUpdate: Equatable {
    let displayVersion: String
    let releaseNotesURL: URL?
    /// True once Sparkle finished downloading and verifying the update.
    var isDownloaded: Bool = false
}

/// What keeps the app from restarting into a freshly installed update.
enum UpdateBlocker: Equatable {
    /// Unsaved annotation tabs; installing would discard them.
    case unsavedEdits
    /// A screen recording is starting, running or being saved.
    case recording

    var message: String {
        switch self {
        case .unsavedEdits:
            "Update ready. Save your edits; SnapGlass installs it automatically."
        case .recording:
            "Update ready. Stop the recording; SnapGlass installs it automatically."
        }
    }
}
