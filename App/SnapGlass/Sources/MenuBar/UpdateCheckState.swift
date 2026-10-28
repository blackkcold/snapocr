import Foundation
import SharedKit

/// The complete, window-backed state of the user-triggered update flow.
///
/// Every check and download result is stored here instead of being presented by
/// an `NSAlert.runModal()` loop. A menu-bar app is frequently inactive by the
/// time a 30-second network request returns; a modal would then block in the
/// background and steal the key window from whatever the user moved on to.
public enum UpdateCheckState: Equatable {
    /// No check has run in this session.
    case idle

    /// A release lookup is in flight.
    case checking

    /// GitHub reports no newer release.
    case upToDate(SemanticVersion)

    /// A newer release is available and can be downloaded.
    case available(UpdateRelease)

    /// The verified DMG is being downloaded.
    case downloading(UpdateRelease)

    /// The DMG is on disk and ready to hand to the installer.
    case readyToInstall(UpdateRelease, URL)

    /// The release lookup failed; the message is user-facing.
    case checkFailed(String)

    /// The DMG download or SHA-256 verification failed; retry only the download.
    case downloadFailed(UpdateRelease, String)

    /// Whether a release lookup is currently running.
    public var isChecking: Bool {
        if case .checking = self { return true }
        return false
    }

    /// Whether a DMG download is currently running.
    public var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }

    /// The verified DMG location once the download has finished.
    public var downloadedFileURL: URL? {
        if case .readyToInstall(_, let url) = self { return url }
        return nil
    }
}
