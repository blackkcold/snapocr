import Foundation

/// Everything onboarding remembers between launches.
///
/// One struct, one source of truth. Earlier drafts had separate "first run
/// completed" markers in two documents; when they disagree, the app either
/// greets a returning user on every launch or never greets a new one.
public struct OnboardingState: Equatable, Sendable {
    /// Version of the onboarding content; bumping it re-shows the guide once.
    public var contentVersion: Int
    /// When the guide was completed. `nil` means onboarding never finished.
    public var welcomeCompletedAt: Date?
    /// Whether the menu-bar coach has been shown ever.
    public var menubarCoachShown: Bool
    /// Identifiers of tips already presented.
    public var tipsShown: Set<String>
    /// Number of launches, incremented exactly once per launch.
    public var launchCount: Int
    /// When any coach last appeared, for the 12-hour throttle.
    public var lastCoachAt: Date?
    /// Guide page the user was last on, so closing the window resumes there.
    public var guidePage: GuidePage
    /// Progress through the post-permission tutorial.
    public var tutorialStep: TutorialStep
    /// When the tutorial finished; `nil` while it is still owed.
    public var tutorialCompletedAt: Date?

    /// Creates onboarding state.
    public init(
        contentVersion: Int = 0,
        welcomeCompletedAt: Date? = nil,
        menubarCoachShown: Bool = false,
        tipsShown: Set<String> = [],
        launchCount: Int = 0,
        lastCoachAt: Date? = nil,
        guidePage: GuidePage = .location,
        tutorialStep: TutorialStep = .none,
        tutorialCompletedAt: Date? = nil
    ) {
        self.contentVersion = contentVersion
        self.welcomeCompletedAt = welcomeCompletedAt
        self.menubarCoachShown = menubarCoachShown
        self.tipsShown = tipsShown
        self.launchCount = launchCount
        self.lastCoachAt = lastCoachAt
        self.guidePage = guidePage
        self.tutorialStep = tutorialStep
        self.tutorialCompletedAt = tutorialCompletedAt
    }
}

/// Why the guide is being shown.
public enum WelcomeReason: String, Sendable {
    /// The app was launched for the first time.
    case firstRun
    /// New onboarding content shipped since the guide was completed.
    case contentUpdate
    /// macOS is running the app from a translocated quarantine path.
    case translocated
    /// The user asked for the guide from the menu.
    case userRequested
}

/// The four pages of the guide, in order.
public enum GuidePage: Int, CaseIterable, Identifiable, Sendable {
    /// Where the app lives in the menu bar.
    case location = 0
    /// Hot keys, editable right there.
    case shortcuts = 1
    /// What happens after a capture.
    case capture = 2
    /// Recording and the permissions it needs.
    case record = 3

    /// Stable identity used by SwiftUI collections.
    public var id: Int { rawValue }

    /// The page after this one, or `nil` on the last page.
    public var next: GuidePage? { GuidePage(rawValue: rawValue + 1) }

    /// The page before this one, or `nil` on the first page.
    public var previous: GuidePage? { GuidePage(rawValue: rawValue - 1) }

    /// Clamps an arbitrary stored value into the valid page range.
    ///
    /// - Parameter value: A page index read from defaults.
    /// - Returns: The matching page, or the first page when out of range.
    public static func clamped(_ value: Int) -> GuidePage {
        GuidePage(rawValue: value) ?? .location
    }
}

/// Progress through the tutorial shown after screen recording is granted.
///
/// Steps are chained: each one appears only after the previous was handled, so a
/// user who has never captured is never told what to do with a capture.
public enum TutorialStep: Int, Equatable, Sendable {
    /// Not started; `pressShortcut` comes next.
    case none = 0
    /// Waiting for the first capture triggered from the coach.
    case pressShortcut = 1
    /// Waiting for the editor to show its banner.
    case editorHint = 2
    /// Waiting for the shelf to show its drag hint.
    case shelfDrag = 3

    /// The step after this one, if any.
    public var next: TutorialStep? { TutorialStep(rawValue: rawValue + 1) }

    /// Clamps an arbitrary stored value into the valid step range.
    ///
    /// - Parameter value: A step index read from defaults.
    /// - Returns: The matching step, or `.none` when out of range.
    public static func clamped(_ value: Int) -> TutorialStep {
        TutorialStep(rawValue: value) ?? .none
    }
}

/// What onboarding wants to show right now.
public enum OnboardingAction: Equatable, Sendable {
    /// Present the guide window.
    case showGuide(WelcomeReason, resumeAt: GuidePage)
    /// Present the menu-bar coach panel.
    case showMenuBarCoach
    /// Advance the post-permission tutorial.
    case showTutorialStep(TutorialStep)
    /// Show one rotating tip.
    case showTip(id: String)
    /// Nothing to show.
    case none
}

/// Facts from the current moment that the decision needs.
///
/// Process-scoped flags (`welcomeJustDismissed`, `alreadyShowedCoachThisLaunch`)
/// live here rather than in `OnboardingState` so they cannot be persisted by
/// accident and survive a restart.
public struct OnboardingContext: Sendable {
    /// A capture or recording is running; never interrupt it.
    public var isCapturingOrRecording: Bool
    /// macOS is running the app from a quarantine-translocated path.
    public var isTranslocated: Bool
    /// The guide was closed earlier in this process.
    public var welcomeJustDismissed: Bool
    /// A capture finished and its editor opened in this process.
    public var didPublishCapture: Bool
    /// The user already captured something during this launch.
    public var hasEverCapturedThisLaunch: Bool
    /// Screen recording permission is granted, confirmed by enumeration.
    public var screenPermissionGranted: Bool
    /// The screenshot shelf is on screen.
    public var shelfVisible: Bool
    /// The coach was already shown in this process.
    public var alreadyShowedCoachThisLaunch: Bool
    /// Current time, injected so the throttle is testable.
    public var now: Date

    /// Creates a context.
    public init(
        isCapturingOrRecording: Bool = false,
        isTranslocated: Bool = false,
        welcomeJustDismissed: Bool = false,
        didPublishCapture: Bool = false,
        hasEverCapturedThisLaunch: Bool = false,
        screenPermissionGranted: Bool = false,
        shelfVisible: Bool = false,
        alreadyShowedCoachThisLaunch: Bool = false,
        now: Date = Date()
    ) {
        self.isCapturingOrRecording = isCapturingOrRecording
        self.isTranslocated = isTranslocated
        self.welcomeJustDismissed = welcomeJustDismissed
        self.didPublishCapture = didPublishCapture
        self.hasEverCapturedThisLaunch = hasEverCapturedThisLaunch
        self.screenPermissionGranted = screenPermissionGranted
        self.shelfVisible = shelfVisible
        self.alreadyShowedCoachThisLaunch = alreadyShowedCoachThisLaunch
        self.now = now
    }
}
