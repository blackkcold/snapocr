import Foundation
import KeyboardShortcuts
import SharedKit

/// Owns the onboarding objects and wires them together.
///
/// Exists because the coordinator needs the presenter, the presenter needs the
/// window router, and the router is installed by a view — a container keeps that
/// wiring in one place instead of threading three optionals through the app struct.
@MainActor
final class OnboardingRuntime: ObservableObject {
    /// Persisted onboarding state.
    let store: OnboardingStore
    /// Opens and closes the guide window.
    let presenter: WelcomeWindowPresenter
    /// Shows the menu-bar coach panel.
    let coach: MenuBarCoachPresenter
    /// Probes installed by the app once the view model exists.
    var permissionProbe: @MainActor () async -> Bool = { false }
    var captureStateProbe: @MainActor () -> Bool = { false }
    var shelfStateProbe: @MainActor () -> Bool = { false }

    /// Runs the state machine.
    ///
    /// Created lazily so it can close over `self` for the probes without an
    /// implicitly unwrapped optional. The probes default to "nothing is happening",
    /// so evaluating before the app wires them cannot interrupt a capture.
    private lazy var coordinator = OnboardingCoordinator(
        store: store,
        presenter: presenter,
        coach: coach,
        permissionProbe: { [weak self] in await self?.permissionProbe() ?? false },
        captureStateProbe: { [weak self] in self?.captureStateProbe() ?? false },
        shelfStateProbe: { [weak self] in self?.shelfStateProbe() ?? false }
    )

    /// Creates the runtime.
    ///
    /// - Parameters:
    ///   - store: Persisted onboarding state.
    ///   - presenter: The guide window layer.
    ///   - coach: The menu-bar coach layer.
    init(
        store: OnboardingStore = OnboardingStore(),
        presenter: WelcomeWindowPresenter = WelcomeWindowPresenter(),
        coach: MenuBarCoachPresenter = MenuBarCoachPresenter()
    ) {
        self.store = store
        self.presenter = presenter
        self.coach = coach
    }

    /// The page the guide should open on.
    var savedGuidePage: GuidePage {
        coordinator.savedGuidePage
    }

    /// Marks the guide finished because the user completed or skipped it.
    ///
    /// - Parameter page: The page the user finished on.
    func finishGuide(at page: GuidePage) {
        coordinator.finishGuide(at: page)
    }

    /// Marks the guide closed without completion.
    ///
    /// - Parameter page: The page the user closed on.
    func dismissGuideWithoutCompleting(at page: GuidePage) {
        coordinator.dismissGuideWithoutCompleting(at: page)
    }

    /// Re-opens the guide because the user asked for it from the menu.
    func showGuideOnUserRequest() {
        coordinator.showGuideOnUserRequest()
    }

    /// Replays the guide from the first page without clearing the completion marker.
    func replayGuide() {
        coordinator.replayGuideOnUserRequest()
    }

    /// Summons the menu-bar coach because the user asked where the app is.
    func showCoach() {
        coordinator.showCoachOnUserRequest()
    }

    /// Whether onboarding has never been finished.
    var isFirstRun: Bool {
        coordinator.isFirstRun
    }

    /// Records that the coach appeared, so it is not repeated on every launch.
    func recordCoachShown() {
        store.recordCoachShown()
    }

    /// The tip the menu bar should show inline, if any.
    ///
    /// Uses the same policy as the automated path, so the menu and the panel can
    /// never disagree about which tip is next.
    var menuTip: OnboardingTip? {
        let state = store.state
        let context = OnboardingContext(
            isCapturingOrRecording: captureStateProbe(),
            welcomeJustDismissed: store.welcomeJustDismissed,
            alreadyShowedCoachThisLaunch: store.alreadyShowedCoachThisLaunch,
            now: Date()
        )
        return OnboardingPolicy.menuTip(for: state, context: context)
    }

    /// The current area-capture shortcut, as the user would press it.
    ///
    /// Falls back to a localized "your shortcut" when nothing is recorded, so a tip
    /// that reads "Press %@ anywhere" never shows an empty gap or literal `%@`.
    var areaShortcutLabel: String {
        // The `??` right side is a `Shortcut`, so the name has to be spelled out or
        // the compiler looks for `captureArea` on `Shortcut` instead of on `Name`.
        let shortcut =
            KeyboardShortcuts.getShortcut(for: .captureArea)
            ?? KeyboardShortcuts.Name.captureArea.defaultShortcut
        guard let shortcut else { return AppLocalization.string("your shortcut") }
        return shortcut.description
    }

    /// Records a tip shown from the menu.
    ///
    /// - Parameter id: The tip identifier.
    func recordTipShown(_ id: String) {
        store.recordTipShown(id)
    }

    /// Reports a capture that has been published to the shelf.
    ///
    /// Advances the chained tutorial and, if the guide was deferred because the app
    /// was busy, lets it through now. Done in one call because both answers depend on
    /// the same fact — the app has just gone idle.
    ///
    /// - Parameter openedEditor: Whether an annotation editor opened for it.
    func noteCapturePublished(openedEditor: Bool) async {
        coordinator.noteCapturePublished(openedEditor: openedEditor)
        TutorialHints.shared.refresh()
        await coordinator.flushPendingWelcome()
        await coordinator.evaluate()
    }

    /// Runs the policy evaluation.
    ///
    /// - Parameter welcomeJustDismissed: Overrides the store flag for the turn that
    ///   closes the guide, so the coach can follow immediately.
    func evaluate(welcomeJustDismissed: Bool? = nil) async {
        await coordinator.evaluate(welcomeJustDismissed: welcomeJustDismissed)
    }

    /// Runs the first evaluation for this launch.
    func start() async {
        coordinator.recordLaunch()
        await coordinator.evaluate()
    }

    /// Re-evaluates when the app becomes active again.
    ///
    /// The tutorial's first step waits for screen-recording permission, and there is
    /// no notification when the user grants it in System Settings — they switch away,
    /// toggle it, and come back. Without this the coach never appears and the tutorial
    /// silently never starts, which is the same "nothing happened" failure this work
    /// exists to remove. Re-evaluating is idempotent: the policy returns the same
    /// answer for the same state.
    func applicationDidBecomeActive() async {
        await coordinator.evaluate()
    }
}
