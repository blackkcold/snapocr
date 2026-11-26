import Foundation

/// Onboarding preference keys, stored in `UserDefaults`.
extension PreferenceKeys {
    /// Version of the onboarding content the user last saw.
    public static let onboardingContentVersion = "onboarding_contentVersion"
    /// When the guide was completed; absent means onboarding never finished.
    public static let onboardingWelcomeCompletedAt = "onboarding_welcomeCompletedAt"
    /// Whether the menu-bar coach has been shown.
    public static let onboardingMenubarCoachShown = "onboarding_menubarCoachShown"
    /// Tip identifiers already presented, stored as an array of strings.
    public static let onboardingTipsShown = "onboarding_tipsShown"
    /// Number of launches, incremented once per launch.
    public static let onboardingLaunchCount = "onboarding_launchCount"
    /// When any coach last appeared, for the tip throttle.
    public static let onboardingLastCoachAt = "onboarding_lastCoachAt"
    /// Guide page the user was last on, so closing the window resumes there.
    public static let onboardingGuidePage = "onboarding_guidePage"
    /// Post-permission tutorial progress.
    public static let onboardingTutorialStep = "onboarding_tutorialStep"
    /// When the post-permission tutorial finished.
    public static let onboardingTutorialCompletedAt = "onboarding_tutorialCompletedAt"
    /// Dock icon presentation mode.
    public static let dockIconMode = "general_dockIconMode"
}

extension PreferenceDefaults {
    /// Treat the guide as never completed by default.
    public static let onboardingContentVersion = 0
    /// No completion time by default.
    public static let onboardingWelcomeCompletedAt: Double = 0
    /// The coach has not been shown by default.
    public static let onboardingMenubarCoachShown = false
    /// No tips shown by default.
    public static let onboardingTipsShown: [String] = []
    /// Zero launches recorded by default.
    public static let onboardingLaunchCount = 0
    /// No previous coach time by default.
    public static let onboardingLastCoachAt: Double = 0
    /// Start on the first guide page by default.
    public static let onboardingGuidePage = 0
    /// The tutorial has not started by default.
    public static let onboardingTutorialStep = 0
    /// The tutorial has not completed by default.
    public static let onboardingTutorialCompletedAt: Double = 0
    /// Follow the window lifecycle for the Dock icon by default.
    public static let dockIconMode = DockIconMode.whileWindowsOpen.rawValue
}
