import Foundation
import Testing

@testable import SharedKit

struct OnboardingPolicyTests {
    /// A state that finished onboarding at the current content version.
    private func completed(
        contentVersion: Int = OnboardingPolicy.currentContentVersion,
        launchCount: Int = 2,
        tutorialStep: TutorialStep = .none,
        tutorialCompletedAt: Date? = Date(timeIntervalSince1970: 1_000),
        tipsShown: Set<String> = OnboardingTips.all.map(\.id).reduce(into: []) { $0.insert($1) },
        menubarCoachShown: Bool = true,
        lastCoachAt: Date? = nil
    ) -> OnboardingState {
        OnboardingState(
            contentVersion: contentVersion,
            welcomeCompletedAt: Date(timeIntervalSince1970: 500),
            menubarCoachShown: menubarCoachShown,
            tipsShown: tipsShown,
            launchCount: launchCount,
            lastCoachAt: lastCoachAt,
            tutorialCompletedAt: tutorialCompletedAt
        )
    }

    // MARK: - 1. Never interrupt capture

    @Test func captureOrRecordingSuppressesEverything() {
        let fresh = OnboardingState()
        let busy = OnboardingContext(isCapturingOrRecording: true, now: Date(timeIntervalSince1970: 10_000))
        #expect(OnboardingPolicy.action(for: fresh, context: busy) == .none)

        let tipDue = completed(tipsShown: ["area"])
        #expect(OnboardingPolicy.action(for: tipDue, context: busy) == .none)
    }

    // MARK: - 2 & 3. First run beats content update

    @Test func freshInstallIsFirstRunNotContentUpdate() {
        // A brand-new install also has contentVersion == 0; checking version first
        // would mislabel it as a content update.
        let fresh = OnboardingState()
        let context = OnboardingContext(now: Date(timeIntervalSince1970: 10_000))
        #expect(OnboardingPolicy.action(for: fresh, context: context) == .showGuide(.firstRun, resumeAt: .location))
    }

    @Test func translocatedInstallIsReportedSeparately() {
        let fresh = OnboardingState()
        let context = OnboardingContext(isTranslocated: true, now: Date(timeIntervalSince1970: 10_000))
        #expect(
            OnboardingPolicy.action(for: fresh, context: context) == .showGuide(.translocated, resumeAt: .location))
    }

    @Test func unfinishedGuideResumesAtSavedPage() {
        var state = OnboardingState()
        state.guidePage = .capture
        let context = OnboardingContext(now: Date(timeIntervalSince1970: 10_000))
        #expect(OnboardingPolicy.action(for: state, context: context) == .showGuide(.firstRun, resumeAt: .capture))
    }

    @Test func higherContentVersionReShowsGuideOnce() {
        var state = completed()
        state.contentVersion = OnboardingPolicy.currentContentVersion - 1
        let context = OnboardingContext(now: Date(timeIntervalSince1970: 10_000))
        #expect(
            OnboardingPolicy.action(for: state, context: context) == .showGuide(.contentUpdate, resumeAt: .location))
    }

    @Test func returningUserSeesNothing() {
        let context = OnboardingContext(now: Date(timeIntervalSince1970: 10_000))
        #expect(OnboardingPolicy.action(for: completed(), context: context) == .none)
    }

    // MARK: - 4. Coach follows dismissal, including the close button

    @Test func dismissalShowsCoachEvenWithoutCompletion() {
        // Closing with the red button does not write the completion marker, but
        // still needs the coach: the window is gone and the icon is the only clue.
        var state = OnboardingState()
        state.contentVersion = OnboardingPolicy.currentContentVersion
        state.welcomeCompletedAt = nil
        var context = OnboardingContext(now: Date(timeIntervalSince1970: 10_000))
        context.welcomeJustDismissed = true

        // The guide the user just closed must not reopen in the same session;
        // the coach follows instead. Reopening it was a visible loop.
        #expect(OnboardingPolicy.action(for: state, context: context) == .showMenuBarCoach)

        // Once the coach was shown, the rest of the launch stays quiet: the
        // unfinished guide resumes next launch, not as a tutorial now.
        state.menubarCoachShown = true
        #expect(OnboardingPolicy.action(for: state, context: context) == .none)

        // A completed guide follows the same dismissal rule.
        state.welcomeCompletedAt = Date(timeIntervalSince1970: 500)
        state.menubarCoachShown = false
        #expect(OnboardingPolicy.action(for: state, context: context) == .showMenuBarCoach)
    }

    @Test func dismissedGuideResumesOnTheNextLaunch() {
        // The dismissal flag is process-scoped. A fresh context without it shows
        // the unfinished guide again, which is what the close button promises.
        var state = OnboardingState()
        state.contentVersion = OnboardingPolicy.currentContentVersion
        var context = OnboardingContext(now: Date(timeIntervalSince1970: 10_000))
        context.welcomeJustDismissed = true
        #expect(OnboardingPolicy.action(for: state, context: context) == .showMenuBarCoach)

        context.welcomeJustDismissed = false
        #expect(OnboardingPolicy.action(for: state, context: context) == .showGuide(.firstRun, resumeAt: .location))
    }

    @Test func dismissedContentUpdateGuideDoesNotReopen() {
        // The same loop existed after a content-version bump: step 3 re-showed
        // the guide the user had just closed.
        var state = completed()
        state.contentVersion = OnboardingPolicy.currentContentVersion - 1
        state.menubarCoachShown = false
        var context = OnboardingContext(now: Date(timeIntervalSince1970: 10_000))
        context.welcomeJustDismissed = true
        #expect(OnboardingPolicy.action(for: state, context: context) == .showMenuBarCoach)
    }

    @Test func coachIsNotRepeatedOnceShown() {
        var context = OnboardingContext(now: Date(timeIntervalSince1970: 10_000))
        context.welcomeJustDismissed = true
        var state = completed()
        state.menubarCoachShown = true
        #expect(OnboardingPolicy.action(for: state, context: context) == .none)
    }

    // MARK: - 5. Tutorial chain never skips

    @Test func tutorialWaitsForPermission() {
        var state = completed(tutorialCompletedAt: nil)
        state.tutorialStep = .none
        let context = OnboardingContext(screenPermissionGranted: false, now: Date(timeIntervalSince1970: 10_000))
        #expect(OnboardingPolicy.action(for: state, context: context) == .none)
    }

    @Test func tutorialStartsAfterPermission() {
        var state = completed(tutorialCompletedAt: nil)
        state.tutorialStep = .none
        let context = OnboardingContext(screenPermissionGranted: true, now: Date(timeIntervalSince1970: 10_000))
        #expect(OnboardingPolicy.action(for: state, context: context) == .showTutorialStep(.pressShortcut))
    }

    @Test func tutorialDoesNotSkipFromPressShortcutWithoutCapture() {
        var state = completed(tutorialCompletedAt: nil)
        state.tutorialStep = .pressShortcut
        let context = OnboardingContext(
            screenPermissionGranted: true,
            now: Date(timeIntervalSince1970: 10_000)
        )
        #expect(OnboardingPolicy.action(for: state, context: context) == .none)
    }

    @Test func tutorialAdvancesToEditorHintAfterCapture() {
        var state = completed(tutorialCompletedAt: nil)
        state.tutorialStep = .pressShortcut
        let context = OnboardingContext(
            didPublishCapture: true,
            hasEverCapturedThisLaunch: true,
            screenPermissionGranted: true,
            now: Date(timeIntervalSince1970: 10_000)
        )
        #expect(OnboardingPolicy.action(for: state, context: context) == .showTutorialStep(.editorHint))
    }

    @Test func tutorialAdvancesToShelfDragWhenShelfVisible() {
        var state = completed(tutorialCompletedAt: nil)
        state.tutorialStep = .editorHint
        let context = OnboardingContext(
            hasEverCapturedThisLaunch: true,
            screenPermissionGranted: true,
            shelfVisible: true,
            now: Date(timeIntervalSince1970: 10_000)
        )
        #expect(OnboardingPolicy.action(for: state, context: context) == .showTutorialStep(.shelfDrag))
    }

    @Test func tutorialDoesNotSkipFromNoneToEditorHint() {
        var state = completed(tutorialCompletedAt: nil)
        state.tutorialStep = .none
        let context = OnboardingContext(
            didPublishCapture: true,
            hasEverCapturedThisLaunch: true,
            screenPermissionGranted: true,
            now: Date(timeIntervalSince1970: 10_000)
        )
        #expect(OnboardingPolicy.action(for: state, context: context) == .showTutorialStep(.pressShortcut))
    }

    // MARK: - 6. Tips are the last resort

    @Test func tipsAreSuppressedWhileTutorialOwed() {
        var state = completed(tutorialCompletedAt: nil, tipsShown: ["area"])
        state.tutorialStep = .none
        let context = OnboardingContext(screenPermissionGranted: false, now: Date(timeIntervalSince1970: 10_000))
        #expect(OnboardingPolicy.action(for: state, context: context) == .none)
    }

    @Test func tipsNeedASecondLaunch() {
        let state = completed(launchCount: 1, tipsShown: [])
        let context = OnboardingContext(now: Date(timeIntervalSince1970: 10_000))
        #expect(OnboardingPolicy.action(for: state, context: context) == .none)
    }

    @Test func firstUnshownTipAppearsInOrder() {
        let state = completed(tipsShown: [])
        let context = OnboardingContext(now: Date(timeIntervalSince1970: 10_000))
        #expect(OnboardingPolicy.action(for: state, context: context) == .showTip(id: "area"))

        let afterArea = completed(tipsShown: ["area"])
        #expect(OnboardingPolicy.action(for: afterArea, context: context) == .showTip(id: "shelf"))
    }

    @Test func tipsRespectTheTwelveHourThrottle() {
        let now = Date(timeIntervalSince1970: 100_000)
        let recent = completed(tipsShown: ["area"], lastCoachAt: now.addingTimeInterval(-60))
        var context = OnboardingContext(now: now)
        #expect(OnboardingPolicy.action(for: recent, context: context) == .none)

        let stale = completed(tipsShown: ["area"], lastCoachAt: now.addingTimeInterval(-13 * 3600))
        context.now = now
        #expect(OnboardingPolicy.action(for: stale, context: context) == .showTip(id: "shelf"))
    }

    @Test func tipsStopAfterAllShown() {
        let state = completed(tipsShown: OnboardingTips.all.map(\.id).reduce(into: []) { $0.insert($1) })
        let context = OnboardingContext(now: Date(timeIntervalSince1970: 10_000))
        #expect(OnboardingPolicy.action(for: state, context: context) == .none)
    }

    @Test func tipsAreSuppressedOnceTheCoachAppearedThisLaunch() {
        let state = completed(tipsShown: ["area"])
        let context = OnboardingContext(alreadyShowedCoachThisLaunch: true, now: Date(timeIntervalSince1970: 10_000))
        #expect(OnboardingPolicy.action(for: state, context: context) == .none)
    }
}

struct CoachLayoutResolverTests {
    @Test func resolvesFourLevelsFromUsableArea() {
        #expect(CoachLayoutResolver.resolve(width: 1512, height: 900) == .full)
        #expect(CoachLayoutResolver.resolve(width: 300, height: 120) == .compact)
        #expect(CoachLayoutResolver.resolve(width: 360, height: 160) == .full)
        // 300×100 fits neither the full nor the compact minimum, but does fit the card.
        #expect(CoachLayoutResolver.resolve(width: 300, height: 100) == .centeredCard)
        #expect(CoachLayoutResolver.resolve(width: 200, height: 60) == .announcement)
    }

    @Test func panelSizeNeverExceedsASmallScreen() {
        // A 1280×800 display with the menu bar taken out leaves 775pt. The broken
        // panel asked for 888 and hung 121pt below the bottom edge.
        let size = CoachLayoutResolver.panelSize(
            design: CoachLayout.full.designSize,
            measuredHeight: 888,
            available: CGSize(width: 1280, height: 775)
        )
        #expect(size.width == 288)
        #expect(size.height == 755)
    }

    @Test func panelSizeShrinksTheCardToANarrowVisibleFrame() {
        // A 300pt-wide usable area resolves to `.centeredCard`, whose design width
        // is 320. Only the trailing inset is reserved, so the card may be 288pt:
        // subtracting the margin twice gave away 12pt it could use.
        let size = CoachLayoutResolver.panelSize(
            design: CoachLayout.centeredCard.designSize,
            measuredHeight: 96,
            available: CGSize(width: 300, height: 100)
        )
        #expect(size.width == 288)
        #expect(size.height == 80)
    }

    @Test func panelWidthReservesOnlyTheTrailingInset() {
        // 260 - 12 = 248. `cardMinimumWidth` already includes the margin.
        let width = CoachLayoutResolver.panelWidth(
            design: CoachLayout.centeredCard.designSize,
            available: CGSize(width: 260, height: 200)
        )
        #expect(width == 248)
    }

    @Test func panelSizeClampsRoundingToAFractionalCeiling() {
        // 140.5 - 8 - 12 = 120.5; rounding the height up must not cross it.
        let size = CoachLayoutResolver.panelSize(
            design: CoachLayout.centeredCard.designSize,
            measuredHeight: 200,
            available: CGSize(width: 400, height: 140.5)
        )
        #expect(size.height <= 120.5)
    }

    @Test func panelSizeGrowsForTheTutorialRow() {
        // The tutorial variant adds a "Try it" button; a fixed 96pt clipped it.
        let size = CoachLayoutResolver.panelSize(
            design: CoachLayout.full.designSize,
            measuredHeight: 120,
            available: CGSize(width: 1512, height: 957)
        )
        #expect(size == CGSize(width: 288, height: 120))
    }

    @Test func panelSizeKeepsTheDesignFloorWhenContentIsShorter() {
        // The zh-Hans subtitle needs only 78pt; the floor keeps the panel from
        // visibly changing height between content variants.
        let size = CoachLayoutResolver.panelSize(
            design: CoachLayout.full.designSize,
            measuredHeight: 78,
            available: CGSize(width: 1512, height: 957)
        )
        #expect(size.height == 96)
    }

    @Test func panelSizeRejectsDegenerateInput() {
        let zeroSpace = CoachLayoutResolver.panelSize(
            design: CoachLayout.full.designSize,
            measuredHeight: 96,
            available: .zero
        )
        #expect(zeroSpace == CGSize(width: 1, height: 1))
        let noMeasurement = CoachLayoutResolver.panelSize(
            design: CoachLayout.full.designSize,
            measuredHeight: .nan,
            available: CGSize(width: 1512, height: 957)
        )
        #expect(noMeasurement == CGSize(width: 1, height: 1))
    }

    @Test func rightAlignedFrameStaysInsideANarrowVisibleFrame() {
        let visible = CGRect(x: 0, y: 60, width: 300, height: 100)
        let frame = CoachLayoutResolver.panelFrame(
            layout: .full,
            size: CGSize(width: 276, height: 80),
            visible: visible
        )
        #expect(frame.minX >= visible.minX)
        #expect(frame.maxX <= visible.maxX)
        #expect(frame.maxY <= visible.maxY)
        #expect(frame.minY >= visible.minY)
    }

    @Test func centeredCardNeverStartsAtANegativeX() {
        // Regression: a 320pt card in a 300pt visible area started at x = -10.
        let visible = CGRect(x: 0, y: 60, width: 300, height: 100)
        let frame = CoachLayoutResolver.panelFrame(
            layout: .centeredCard,
            size: CGSize(width: 276, height: 80),
            visible: visible
        )
        #expect(frame.minX == 12)
        #expect(frame.minY >= visible.minY)
    }

    @Test func panelFramePinsAnOversizedSizeToTheVisibleOrigin() {
        // The card cannot fit a 300×100 area, but its origin must still not go
        // negative; this used to return x = -20 / y = -28.
        let visible = CGRect(x: -1920, y: 0, width: 300, height: 100)
        let frame = CoachLayoutResolver.panelFrame(
            layout: .centeredCard,
            size: CGSize(width: 320, height: 120),
            visible: visible
        )
        #expect(frame.minX == visible.minX)
        #expect(frame.minY == visible.minY)
        #expect(frame.size == CGSize(width: 320, height: 120))
    }

    @Test func announcementHasNoFrame() {
        let visible = CGRect(x: 0, y: 60, width: 1512, height: 900)
        let frame = CoachLayoutResolver.panelFrame(
            layout: .announcement,
            size: CGSize(width: 1, height: 1),
            visible: visible
        )
        #expect(frame == .zero)
    }

    @Test func cardMinimumStaysBelowCompactMinimum() {
        // The card is the fallback when the compact strip does not fit. If its
        // minimum were larger, L2 would be unreachable and a small screen would
        // jump straight from L1 to L3.
        #expect(CoachLayoutResolver.cardMinimumWidth < CoachLayoutResolver.compactMinimumWidth)
        #expect(CoachLayoutResolver.cardMinimumHeight < CoachLayoutResolver.compactMinimumHeight)
        #expect(CoachLayoutResolver.compactMinimumWidth < CoachLayoutResolver.fullMinimumWidth)
        #expect(CoachLayoutResolver.compactMinimumHeight < CoachLayoutResolver.fullMinimumHeight)
    }

    @Test func degenerateInputNeverClaimsRoom() {
        #expect(CoachLayoutResolver.resolve(width: 0, height: 900) == .announcement)
        #expect(CoachLayoutResolver.resolve(width: 1512, height: 0) == .announcement)
        #expect(CoachLayoutResolver.resolve(width: -100, height: -100) == .announcement)
        #expect(CoachLayoutResolver.resolve(width: .nan, height: 900) == .announcement)
        #expect(CoachLayoutResolver.resolve(width: 1512, height: .infinity) == .announcement)
    }

    @Test func boundariesAreInclusive() {
        #expect(
            CoachLayoutResolver.resolve(
                width: CoachLayoutResolver.fullMinimumWidth,
                height: CoachLayoutResolver.fullMinimumHeight
            ) == .full)
        #expect(
            CoachLayoutResolver.resolve(
                width: CoachLayoutResolver.compactMinimumWidth,
                height: CoachLayoutResolver.compactMinimumHeight
            ) == .compact)
    }
}

struct OnboardingTipsTests {
    @Test func nextFollowsDeclarationOrder() {
        #expect(OnboardingTips.next(shownIDs: [])?.id == "area")
        #expect(OnboardingTips.next(shownIDs: ["area"])?.id == "shelf")
        #expect(OnboardingTips.next(shownIDs: ["area", "shelf"])?.id == "record")
        #expect(OnboardingTips.next(shownIDs: ["area", "shelf", "record"]) == nil)
    }

    @Test func recordTipIsNotActionable() {
        // Its copy says audio and screen recording both start here; a click that
        // begins an audio recording would contradict it.
        let record = OnboardingTips.all.first { $0.id == "record" }
        #expect(record?.isActionable == false)
        #expect(OnboardingTips.area.isActionable)
        #expect(OnboardingTips.shelf.isActionable)
    }

    @Test func titlesReuseExistingLocalizationKeys() {
        #expect(OnboardingTips.area.titleKey == "Area Capture")
        #expect(OnboardingTips.shelf.titleKey == "Screenshot Shelf")
        #expect(OnboardingTips.record.titleKey == "Start Audio Recording")
    }
}

struct DockIconModeTests {
    @Test func defaultFollowsTheWindowLifecycle() {
        #expect(DockIconMode(rawValue: PreferenceDefaults.dockIconMode) == .whileWindowsOpen)
        #expect(PreferenceKeys.dockIconMode == "general_dockIconMode")
    }

    @Test func storedRawValuesAreStable() {
        // Raw values are persisted; renaming them silently resets a user's choice.
        #expect(DockIconMode.whileWindowsOpen.rawValue == "whileWindowsOpen")
        #expect(DockIconMode.always.rawValue == "always")
        #expect(DockIconMode.never.rawValue == "never")
    }
}

struct GuidePageTests {
    @Test func navigationStopsAtTheEnds() {
        #expect(GuidePage.location.previous == nil)
        #expect(GuidePage.location.next == .shortcuts)
        #expect(GuidePage.record.next == nil)
        #expect(GuidePage.record.previous == .capture)
    }

    @Test func outOfRangeValuesClamp() {
        #expect(GuidePage.clamped(-5) == .location)
        #expect(GuidePage.clamped(99) == .location)
        #expect(GuidePage.clamped(2) == .capture)
        #expect(TutorialStep.clamped(-1) == .none)
        #expect(TutorialStep.clamped(3) == .shelfDrag)
        #expect(TutorialStep.clamped(99) == .none)
    }
}
