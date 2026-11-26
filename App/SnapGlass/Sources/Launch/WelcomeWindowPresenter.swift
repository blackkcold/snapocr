import AppKit
import SharedKit
import SwiftUI

/// Opens and closes the onboarding guide window.
///
/// The guide is a SwiftUI `Window` scene, so AppKit backs it with an `NSWindow`.
/// `Window` rather than `WindowGroup`: the guide is a one-off, and a group would
/// let the user open a second copy from the app menu.
@MainActor
final class WelcomeWindowPresenter: OnboardingCoordinator.Presenting {
    /// Opens the scene by id. Installed by the menu-bar lifecycle bridge.
    var openWindow: ((String) -> Void)?
    /// Closes the scene's window through the coordinator, which also demotes the
    /// app back to `.accessory` once no regular window is visible.
    var closeWindow: () -> Void = {
        AppWindowPresenter.window(id: WelcomeWindowPresenter.windowID)?.performClose(nil)
    }

    /// Window scene identifier.
    static let windowID = "welcome"

    /// Page the visible guide is on, kept in sync by the view.
    private(set) var visibleGuidePage: GuidePage = .location

    var isGuideVisible: Bool {
        guard let window = AppWindowPresenter.window(id: Self.windowID) else { return false }
        return window.isVisible
    }

    func presentGuide(page: GuidePage) {
        visibleGuidePage = page
        guard let openWindow else { return }
        AppWindowPresenter.present(id: Self.windowID) {
            openWindow(Self.windowID)
        }
    }

    func dismissGuide() {
        closeWindow()
    }

    /// Records the page the guide is showing, so a red-button close resumes there.
    ///
    /// - Parameter page: The page now on screen.
    func noteVisiblePage(_ page: GuidePage) {
        visibleGuidePage = page
    }
}
