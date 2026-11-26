import Foundation
import KeyboardShortcuts
import SharedKit

/// Runs the onboarding state machine for the app.
///
/// Owns the store, evaluates the policy after each lifecycle event, and asks the
/// presenter to show whatever is due. The presentation side is injected so the
/// decision can be tested without AppKit.
@MainActor
final class OnboardingCoordinator {
    /// What the coordinator needs from the window layer.
    @MainActor
    protocol Presenting: AnyObject {
        /// Opens the guide window on a page.
        func presentGuide(page: GuidePage)
        /// Closes the guide window.
        func dismissGuide()
        /// Whether the guide is on screen.
        var isGuideVisible: Bool { get }
        /// The page the guide is showing.
        var visibleGuidePage: GuidePage { get }
    }

    private let store: OnboardingStore
    private let presenter: Presenting
    private let coach: MenuBarCoachPresenter
    private let permissionProbe: @MainActor () async -> Bool
    private let captureStateProbe: @MainActor () -> Bool
    private let shelfStateProbe: @MainActor () -> Bool

    /// Set when the guide wanted to appear during a capture and must wait.
    private var isWelcomePending = false
    /// Whether a capture has completed in this process.
    private var didPublishCapture = false
    /// Whether a capture ever started in this process.
    private var hasEverCaptured = false

    /// Creates the coordinator.
    ///
    /// - Parameters:
    ///   - store: Persisted onboarding state.
    ///   - presenter: The window layer.
    ///   - coach: The menu-bar coach layer.
    ///   - permissionProbe: Returns whether screen recording is granted.
    ///   - captureStateProbe: Returns whether a capture or recording is running.
    ///   - shelfStateProbe: Returns whether the screenshot shelf is visible.
    init(
        store: OnboardingStore,
        presenter: Presenting,
        coach: MenuBarCoachPresenter,
        permissionProbe: @escaping @MainActor () async -> Bool,
        captureStateProbe: @escaping @MainActor () -> Bool,
        shelfStateProbe: @escaping @MainActor () -> Bool
    ) {
        self.store = store
        self.presenter = presenter
        self.coach = coach
        self.permissionProbe = permissionProbe
        self.captureStateProbe = captureStateProbe
        self.shelfStateProbe = shelfStateProbe
    }

    /// The onboarding store, exposed for the menu's "show the guide again" row.
    var onboardingStore: OnboardingStore { store }

    /// Records this process's launch exactly once.
    ///
    /// Called from the delegate's one-time initialization guard; calling it from a
    /// view `init` would count a launch every time SwiftUI rebuilds the view.
    func recordLaunch() {
        store.recordLaunch()
    }

    /// Reports a finished capture so the tutorial can advance.
    ///
    /// - Parameter openedEditor: Whether an editor window opened for the capture.
    func noteCapturePublished(openedEditor: Bool) {
        hasEverCaptured = true
        store.noteCaptureHappened()
        if openedEditor {
            didPublishCapture = true
        }
    }

    /// Reports that a capture started, so the guide defers instead of interrupting.
    func noteCaptureStarted() {
        hasEverCaptured = true
        store.noteCaptureHappened()
    }

    /// Evaluates the policy and shows what is due.
    ///
    /// - Parameter welcomeJustDismissed: Overrides the store's dismissal flag for
    ///   the turn that closes the guide, so the coach can follow it immediately.
    func evaluate(welcomeJustDismissed: Bool? = nil) async {
        let state = store.state
        let context = OnboardingContext(
            isCapturingOrRecording: captureStateProbe(),
            isTranslocated: Self.isTranslocated(),
            welcomeJustDismissed: welcomeJustDismissed ?? store.welcomeJustDismissed,
            didPublishCapture: didPublishCapture,
            hasEverCapturedThisLaunch: hasEverCaptured,
            screenPermissionGranted: await permissionProbe(),
            shelfVisible: shelfStateProbe(),
            alreadyShowedCoachThisLaunch: store.alreadyShowedCoachThisLaunch,
            now: Date()
        )

        switch OnboardingPolicy.action(for: state, context: context) {
        case let .showGuide(reason, page):
            guard !presenter.isGuideVisible else { return }
            if context.isCapturingOrRecording {
                isWelcomePending = true
                return
            }
            isWelcomePending = false
            store.rememberGuidePage(page)
            presenter.presentGuide(page: page)
            _ = reason

        case .showMenuBarCoach:
            // Deferred by 250ms inside the presenter: the guide's window teardown is
            // still in flight in this turn, and a panel ordered in now competes with
            // it for the key slot.
            coach.schedule(.location)

        case let .showTutorialStep(step):
            store.advanceTutorial(to: step)
            presentTutorial(step)

        case let .showTip(id):
            store.recordTipShown(id)

        case .none:
            break
        }
    }

    /// Consumes a pending guide request after a capture finishes.
    func flushPendingWelcome() async {
        guard isWelcomePending else { return }
        await evaluate()
    }

    /// Marks the guide finished because the user completed or skipped it.
    func finishGuide(at page: GuidePage) {
        store.completeWelcome(at: page)
        store.noteWelcomeCompleted()
        presenter.dismissGuide()
        store.noteWelcomeDismissed()
    }

    /// Marks the guide closed without completion.
    ///
    /// The completion marker stays unset so the guide resumes on the next launch,
    /// but the coach still follows: at that moment the window is gone and the icon
    /// is the only remaining clue.
    func dismissGuideWithoutCompleting(at page: GuidePage) {
        store.rememberGuidePage(page)
        presenter.dismissGuide()
        store.noteWelcomeDismissed()
    }

    /// Re-opens the guide because the user asked to read it again.
    ///
    /// Deliberately leaves the completion marker alone: this is a replay of a guide
    /// the user already finished, and clearing the marker would make the app treat
    /// them as a new install on the next launch.
    func replayGuideOnUserRequest() {
        store.rememberGuidePage(.location)
        presenter.presentGuide(page: .location)
    }

    /// Summons the menu-bar coach because the user asked where the app is.
    func showCoachOnUserRequest() {
        coach.presentOnUserRequest()
    }

    /// Re-opens the guide when onboarding is unfinished, the coach otherwise.
    ///
    /// On a first run the guide is what the user needs. Afterwards it already
    /// completed, so re-opening it would contradict the state; the coach answers the
    /// actual question ("where is it?") without claiming onboarding is unfinished.
    func showGuideOnUserRequest() {
        if store.isFirstRun {
            presenter.presentGuide(page: store.state.guidePage)
        } else {
            coach.presentOnUserRequest()
        }
    }

    /// The page the guide should open on.
    var savedGuidePage: GuidePage {
        presenter.isGuideVisible ? presenter.visibleGuidePage : store.state.guidePage
    }

    /// Whether onboarding has never been finished.
    var isFirstRun: Bool {
        store.isFirstRun
    }

    private static func isTranslocated() -> Bool {
        Bundle.main.bundlePath.contains("/AppTranslocation/")
    }

    /// Shows the tutorial step that the policy just advanced to.
    ///
    /// - Parameter step: The step now owed to the user.
    private func presentTutorial(_ step: TutorialStep) {
        switch step {
        case .pressShortcut:
            // Reuse the coach: the user just gained permission, and the coach is the
            // one surface already proven to point at the menu bar.
            let shortcut = KeyboardShortcuts.getShortcut(for: .captureArea)?.description ?? ""
            coach.schedule(.tutorial(shortcut: shortcut))
        case .editorHint, .shelfDrag:
            // These two attach to the editor and the shelf themselves, because a
            // floating panel would cover the very surface being explained. Publishing
            // the hint is enough: both surfaces read the same shared state.
            TutorialHints.shared.refresh()
        case .none:
            break
        }
    }
}
