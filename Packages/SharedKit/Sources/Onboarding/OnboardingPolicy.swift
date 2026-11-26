import Foundation

/// Decides what onboarding shows next.
///
/// Pure logic: no AppKit, no defaults, no clock. The ordering below is the
/// contract, and each step exists because getting it wrong is a real failure
/// mode rather than a matter of taste.
public enum OnboardingPolicy {
    /// Onboarding content version this build ships.
    public static let currentContentVersion = 1

    /// Minimum gap between two rotating tips.
    public static let tipInterval: TimeInterval = 12 * 60 * 60

    /// Resolves the single next thing to show.
    ///
    /// Order is priority:
    /// 1. Never interrupt a capture or recording.
    /// 2. Unfinished onboarding always wins, so a new user is never left with
    ///    nothing on screen — unless the user closed the guide in this process;
    ///    it then stays closed until the next launch instead of reopening in a
    ///    loop.
    /// 3. Only after step 2: a new content version re-shows the guide, with the
    ///    same dismissal exception. Reversing these would report a fresh install
    ///    as `.contentUpdate`, because a new install also has
    ///    `contentVersion == 0`.
    /// 4. The coach follows any guide dismissal, including the red close button.
    ///    A user who closed the window is exactly the user who now wonders where
    ///    the app went.
    /// 5. The tutorial is chained; no step is skipped.
    /// 6. Tips are the last resort and stay silent until the tutorial is done,
    ///    because stacking hints on an unfinished tutorial is noise.
    ///
    /// - Parameters:
    ///   - state: Persisted onboarding state.
    ///   - context: Current moment's facts.
    /// - Returns: The action to perform, or `.none`.
    public static func action(for state: OnboardingState, context: OnboardingContext) -> OnboardingAction {
        if context.isCapturingOrRecording {
            return .none
        }

        // A guide the user closed during this process stays closed: reopening it
        // in the same session is a visible loop, and `dismissGuideWithoutCompleting`
        // promises the guide resumes on the next launch. The coach still follows
        // the dismissal, because the window is gone and the icon is the only clue.
        if state.welcomeCompletedAt == nil {
            if !context.welcomeJustDismissed {
                let reason: WelcomeReason = context.isTranslocated ? .translocated : .firstRun
                return .showGuide(reason, resumeAt: GuidePage.clamped(state.guidePage.rawValue))
            }
        } else if state.contentVersion < currentContentVersion {
            if !context.welcomeJustDismissed {
                return .showGuide(.contentUpdate, resumeAt: .location)
            }
        }

        if context.welcomeJustDismissed, !state.menubarCoachShown {
            return .showMenuBarCoach
        }

        if context.welcomeJustDismissed, state.welcomeCompletedAt == nil {
            // Unfinished onboarding that the user closed this launch: stop here
            // rather than start a tutorial the guide never introduced. The guide
            // resumes next launch.
            return .none
        }

        if let step = activeTutorialStep(for: state, context: context) {
            return .showTutorialStep(step)
        }

        if shouldShowTip(state: state, context: context),
            let tip = OnboardingTips.next(shownIDs: state.tipsShown)
        {
            return .showTip(id: tip.id)
        }

        return .none
    }

    /// The tutorial step to present, or `nil` when the tutorial owes nothing.
    ///
    /// The last step has no successor, so it stays pending until the caller marks
    /// the tutorial complete after the shelf hint is handled.
    private static func activeTutorialStep(
        for state: OnboardingState,
        context: OnboardingContext
    ) -> TutorialStep? {
        guard state.tutorialCompletedAt == nil else { return nil }

        switch state.tutorialStep {
        case .none:
            guard context.screenPermissionGranted else { return nil }
            return .pressShortcut
        case .pressShortcut:
            // A user who already captured this launch has nothing left to learn
            // here; `didPublishCapture` also covers a capture started from the guide.
            guard context.didPublishCapture, context.hasEverCapturedThisLaunch else { return nil }
            return .editorHint
        case .editorHint:
            guard context.shelfVisible else { return nil }
            return .shelfDrag
        case .shelfDrag:
            return nil
        }
    }

    /// The tip the menu bar should show inline, if any.
    ///
    /// Same conditions as the automated `.showTip` path, exposed separately because
    /// the menu renders the tip inline when the user opens it rather than presenting
    /// a panel. Keeping one implementation means the two surfaces cannot disagree
    /// about which tip is next.
    ///
    /// - Parameters:
    ///   - state: Persisted onboarding state.
    ///   - context: Current moment's facts.
    /// - Returns: The next tip, or `nil` when the menu should show none.
    public static func menuTip(for state: OnboardingState, context: OnboardingContext) -> OnboardingTip? {
        guard !context.isCapturingOrRecording else { return nil }
        guard state.welcomeCompletedAt != nil else { return nil }
        guard state.contentVersion >= currentContentVersion else { return nil }
        guard shouldShowTip(state: state, context: context) else { return nil }
        return OnboardingTips.next(shownIDs: state.tipsShown)
    }

    /// Whether a rotating tip may appear now.
    private static func shouldShowTip(state: OnboardingState, context: OnboardingContext) -> Bool {
        guard state.launchCount >= 2 else { return false }
        guard state.tutorialCompletedAt != nil else { return false }
        guard !context.alreadyShowedCoachThisLaunch else { return false }
        guard OnboardingTips.next(shownIDs: state.tipsShown) != nil else { return false }
        guard let last = state.lastCoachAt else { return true }
        return context.now.timeIntervalSince(last) >= tipInterval
    }
}
