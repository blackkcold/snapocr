import CoreGraphics
import Foundation
import Testing

@testable import CaptureCore

struct ScreenshotShelfDisplayFollowPolicyTests {
    @Test func followsWhenTheShelfIsIdleAndVisible() {
        #expect(ScreenshotShelfDisplayFollowPolicy.shouldFollow(.idleOnScreen))
    }

    @Test func neverFollowsWhileTheShelfIsHidden() {
        #expect(!ScreenshotShelfDisplayFollowPolicy.shouldFollow(ScreenshotShelfFollowConditions()))
    }

    @Test func neverFollowsWhileTheUserIsInteractingWithTheShelf() {
        let blockers: [(String, WritableKeyPath<ScreenshotShelfFollowConditions, Bool>)] = [
            ("card drag", \.hasActiveCardDrag),
            ("native drag", \.hasActiveNativeDrag),
            ("menu", \.isMenuTracking),
            ("keyboard", \.isKeyboardMode),
            ("suppressed", \.isSuppressed),
            ("mouse down", \.isPointerButtonDown),
            ("pointer on shelf", \.isPointerOnShelf),
        ]

        for (name, keyPath) in blockers {
            var conditions = ScreenshotShelfFollowConditions.idleOnScreen
            conditions[keyPath: keyPath] = true
            #expect(!ScreenshotShelfDisplayFollowPolicy.shouldFollow(conditions), "\(name)")
        }
    }

    @Test func nearestDisplayIndexPrefersTheDisplayUnderThePoint() {
        let frames = [
            CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
            CGRect(x: 1_920, y: 124, width: 1_470, height: 956),
        ]

        #expect(ScreenshotShelfDisplayFollowPolicy.nearestDisplayIndex(
            for: CGPoint(x: 800, y: 500),
            displayFrames: frames
        ) == 0)
        #expect(ScreenshotShelfDisplayFollowPolicy.nearestDisplayIndex(
            for: CGPoint(x: 2_500, y: 500),
            displayFrames: frames
        ) == 1)
    }

    @Test func nearestDisplayIndexResolvesTheGapBetweenScreens() {
        let frames = [
            CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
            CGRect(x: 1_920, y: 124, width: 1_470, height: 956),
        ]

        #expect(ScreenshotShelfDisplayFollowPolicy.nearestDisplayIndex(
            for: CGPoint(x: 2_000, y: 100),
            displayFrames: frames
        ) == 1)
        #expect(ScreenshotShelfDisplayFollowPolicy.nearestDisplayIndex(
            for: CGPoint(x: 1_960, y: 40),
            displayFrames: frames
        ) == 0)
    }

    @Test func nearestDisplayIndexIgnoresAnEmptyList() {
        #expect(
            ScreenshotShelfDisplayFollowPolicy.nearestDisplayIndex(
                for: .zero,
                displayFrames: []
            ) == nil
        )
    }
}

private extension ScreenshotShelfFollowConditions {
    /// A visible shelf with nothing else going on.
    static var idleOnScreen: ScreenshotShelfFollowConditions {
        var conditions = ScreenshotShelfFollowConditions()
        conditions.isShelfVisible = true
        return conditions
    }
}
