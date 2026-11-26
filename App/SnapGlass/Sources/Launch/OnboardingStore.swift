import Foundation
import SharedKit

/// Persists onboarding state and process-scoped flags.
///
/// Writes are immediate rather than batched: onboarding advances one step at a
/// time and the user may quit at any moment, so a lost write means showing the
/// same guide again on the next launch.
@MainActor
final class OnboardingStore {
    private let defaults: UserDefaults

    /// Set when the guide was closed during this process, so the coach follows it.
    private(set) var welcomeJustDismissed = false
    /// Set when the coach appeared during this process, to throttle tips.
    private(set) var alreadyShowedCoachThisLaunch = false
    /// Set when the user captured something during this process.
    private(set) var hasEverCapturedThisLaunch = false

    /// Creates a store.
    ///
    /// - Parameter defaults: The defaults domain to read and write.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Persisted state

    /// The current persisted state.
    var state: OnboardingState {
        OnboardingState(
            contentVersion: defaults.integer(forKey: PreferenceKeys.onboardingContentVersion),
            welcomeCompletedAt: date(forKey: PreferenceKeys.onboardingWelcomeCompletedAt),
            menubarCoachShown: defaults.bool(forKey: PreferenceKeys.onboardingMenubarCoachShown),
            tipsShown: Set(defaults.stringArray(forKey: PreferenceKeys.onboardingTipsShown) ?? []),
            launchCount: defaults.integer(forKey: PreferenceKeys.onboardingLaunchCount),
            lastCoachAt: date(forKey: PreferenceKeys.onboardingLastCoachAt),
            guidePage: GuidePage.clamped(defaults.integer(forKey: PreferenceKeys.onboardingGuidePage)),
            tutorialStep: TutorialStep.clamped(defaults.integer(forKey: PreferenceKeys.onboardingTutorialStep)),
            tutorialCompletedAt: date(forKey: PreferenceKeys.onboardingTutorialCompletedAt)
        )
    }

    /// Whether onboarding has never been finished.
    var isFirstRun: Bool {
        state.welcomeCompletedAt == nil
    }

    /// Increments the launch counter exactly once per process.
    ///
    /// Called from inside the delegate's one-time initialization guard. Calling it
    /// from `init` would double-count when SwiftUI re-creates the environment.
    func recordLaunch() {
        defaults.set(state.launchCount + 1, forKey: PreferenceKeys.onboardingLaunchCount)
    }

    /// Marks onboarding complete and records the content version.
    ///
    /// - Parameter page: The page the user finished on; kept for the record.
    func completeWelcome(at page: GuidePage = .record) {
        let now = Date()
        defaults.set(now.timeIntervalSince1970, forKey: PreferenceKeys.onboardingWelcomeCompletedAt)
        defaults.set(OnboardingPolicy.currentContentVersion, forKey: PreferenceKeys.onboardingContentVersion)
        defaults.set(page.rawValue, forKey: PreferenceKeys.onboardingGuidePage)
    }

    /// Remembers the page the guide was on, so a closed window resumes there.
    ///
    /// - Parameter page: The page now displayed.
    func rememberGuidePage(_ page: GuidePage) {
        defaults.set(page.rawValue, forKey: PreferenceKeys.onboardingGuidePage)
    }

    /// Records that the coach appeared.
    func recordCoachShown() {
        let now = Date()
        defaults.set(now.timeIntervalSince1970, forKey: PreferenceKeys.onboardingLastCoachAt)
        defaults.set(true, forKey: PreferenceKeys.onboardingMenubarCoachShown)
        alreadyShowedCoachThisLaunch = true
    }

    /// Records that a tip was shown.
    ///
    /// - Parameter id: The tip identifier.
    func recordTipShown(_ id: String) {
        var shown = state.tipsShown
        shown.insert(id)
        defaults.set(Array(shown).sorted(), forKey: PreferenceKeys.onboardingTipsShown)
        defaults.set(Date().timeIntervalSince1970, forKey: PreferenceKeys.onboardingLastCoachAt)
        alreadyShowedCoachThisLaunch = true
    }

    /// Advances the tutorial to a step.
    ///
    /// - Parameter step: The step that was just presented or handled.
    func advanceTutorial(to step: TutorialStep) {
        defaults.set(step.rawValue, forKey: PreferenceKeys.onboardingTutorialStep)
    }

    /// Marks the tutorial finished.
    func completeTutorial() {
        let now = Date()
        defaults.set(now.timeIntervalSince1970, forKey: PreferenceKeys.onboardingTutorialCompletedAt)
        defaults.set(TutorialStep.shelfDrag.rawValue, forKey: PreferenceKeys.onboardingTutorialStep)
    }

    /// Resets onboarding so the guide shows again on the next evaluation.
    ///
    /// Used by the menu's permanent "Show the welcome guide again" row.
    func requestGuideAgain() {
        defaults.set(0, forKey: PreferenceKeys.onboardingGuidePage)
    }

    // MARK: - Process-scoped flags

    /// Records that the guide was closed without completing it.
    func noteWelcomeDismissed() {
        welcomeJustDismissed = true
    }

    /// Records that the guide was completed, clearing the dismissed flag.
    func noteWelcomeCompleted() {
        welcomeJustDismissed = false
    }

    /// Records that the user captured something this launch.
    func noteCaptureHappened() {
        hasEverCapturedThisLaunch = true
    }

    // MARK: - Helpers

    private func date(forKey key: String) -> Date? {
        let interval = defaults.double(forKey: key)
        guard interval > 0 else { return nil }
        return Date(timeIntervalSince1970: interval)
    }
}
