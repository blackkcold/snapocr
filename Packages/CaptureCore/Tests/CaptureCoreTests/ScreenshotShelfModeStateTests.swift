import Foundation
import Testing

@testable import CaptureCore

struct ScreenshotShelfModeStateTests {
    @Test func pointerExitStartsTheIdleDeadlineAndEntryCancelsIt() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var state = ScreenshotShelfModeState()
        state.pointerExited(now: start, delay: 2.8)

        #expect(state.idleDeadline == start.addingTimeInterval(2.8))
        let earlyCollapse = state.collapseIfIdle(now: start.addingTimeInterval(1))
        #expect(!earlyCollapse)

        state.pointerEntered(now: start.addingTimeInterval(1))
        #expect(state.idleDeadline == nil)
        #expect(state.mode == .expanded)
    }

    @Test func collapseOnlyHappensAfterTheDeadline() {
        let start = Date(timeIntervalSinceReferenceDate: 2_000)
        var state = ScreenshotShelfModeState()
        state.pointerExited(now: start, delay: 2.8)

        let earlyCollapse = state.collapseIfIdle(now: start.addingTimeInterval(2.7))
        #expect(!earlyCollapse)
        let collapsed = state.collapseIfIdle(now: start.addingTimeInterval(2.8))
        #expect(collapsed)
        #expect(state.mode == .collapsed)
        #expect(!state.isExpansionArmed)
    }

    @Test func interactionAndSuppressionBlockCollapse() {
        let start = Date(timeIntervalSinceReferenceDate: 3_000)
        var state = ScreenshotShelfModeState()
        state.pointerExited(now: start, delay: 1)
        state.beginInteraction()
        let interactionCollapse = state.collapseIfIdle(now: start.addingTimeInterval(2))
        #expect(!interactionCollapse)
        state.endInteraction(now: start.addingTimeInterval(2), delay: 1)
        let interactionEndedCollapse = state.collapseIfIdle(now: start.addingTimeInterval(3))
        #expect(interactionEndedCollapse)

        var suppressed = ScreenshotShelfModeState()
        suppressed.pointerExited(now: start, delay: 1)
        suppressed.beginSuppression()
        let suppressionCollapse = suppressed.collapseIfIdle(now: start.addingTimeInterval(2))
        #expect(!suppressionCollapse)
        suppressed.endSuppression(now: start.addingTimeInterval(2), delay: 1)
        let suppressionEndedCollapse = suppressed.collapseIfIdle(now: start.addingTimeInterval(3))
        #expect(suppressionEndedCollapse)
    }

    @Test func expansionIsArmedOnlyAfterCollapseAndCanBeRearmed() {
        var state = ScreenshotShelfModeState()
        #expect(state.isExpansionArmed)
        state.pointerExited(now: Date(timeIntervalSinceReferenceDate: 4_000), delay: 1)
        state.pointerEntered()
        #expect(state.mode == .expanded)

        state.pointerExited(now: Date(timeIntervalSinceReferenceDate: 4_100), delay: 1)
        let collapsed = state.collapseIfIdle(now: Date(timeIntervalSinceReferenceDate: 4_101))
        #expect(collapsed)
        #expect(!state.isExpansionArmed)

        state.pointerEntered()
        #expect(state.mode == .collapsed, "unarmed hover must not expand")

        state.armExpansion()
        state.pointerEntered()
        #expect(state.mode == .expanded)
    }

    @Test func suppressionEndKeepsTheCurrentModeForRestore() {
        var state = ScreenshotShelfModeState(mode: .collapsed)
        state.beginSuppression()
        let suppressedCollapse = state.collapseIfIdle()
        #expect(!suppressedCollapse)
        state.endSuppression(now: Date(), delay: 1)
        #expect(state.mode == .collapsed)
        #expect(state.isSuppressed == false)
    }

    @Test func hardResetReturnsToExpanded() {
        var state = ScreenshotShelfModeState(mode: .collapsed)
        state.beginInteraction()
        state.beginSuppression()
        state.reset()
        #expect(state.mode == .expanded)
        #expect(!state.isInteractionHeld)
        #expect(!state.isSuppressed)
        #expect(state.isExpansionArmed)
        #expect(state.idleDeadline == nil)
    }
}
