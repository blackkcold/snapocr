import CoreGraphics
import Foundation
import Testing

@testable import CaptureCore

struct ScreenshotShelfModeStateDwellTests {
    private let epoch = Date(timeIntervalSinceReferenceDate: 10_000)

    private func collapsedState(armed: Bool = true) -> ScreenshotShelfModeState {
        var state = ScreenshotShelfModeState()
        state.pointerExited(now: epoch, delay: 1)
        state.collapseIfIdle(now: epoch.addingTimeInterval(1))
        if armed {
            state.armExpansion()
        }
        return state
    }

    @Test func pointerEntryWaitsForTheDwellDeadline() {
        var state = collapsedState()

        state.pointerEntered(at: .zero, now: epoch, dwell: 0.25)

        #expect(state.mode == .collapsed)
        #expect(state.dwellDeadline == epoch.addingTimeInterval(0.25))
        let earlyExpansion = state.expandIfDwellElapsed(now: epoch.addingTimeInterval(0.24))
        #expect(!earlyExpansion)
        let expansion = state.expandIfDwellElapsed(now: epoch.addingTimeInterval(0.25))
        #expect(expansion)
        #expect(state.mode == .expanded)
        #expect(state.dwellDeadline == nil)
    }

    @Test func pointerMovementBeyondToleranceRestartsTheDwell() {
        var state = collapsedState()
        state.pointerEntered(at: CGPoint(x: 10, y: 10), now: epoch, dwell: 0.25)

        let restarted = state.pointerMoved(
            to: CGPoint(x: 10, y: 20),
            now: epoch.addingTimeInterval(0.1),
            dwell: 0.25
        )
        #expect(restarted)
        #expect(state.dwellDeadline == epoch.addingTimeInterval(0.35))

        let earlyExpansion = state.expandIfDwellElapsed(now: epoch.addingTimeInterval(0.34))
        #expect(!earlyExpansion)
        let expansion = state.expandIfDwellElapsed(now: epoch.addingTimeInterval(0.35))
        #expect(expansion)
    }

    @Test func pointerMovementWithinToleranceKeepsDwell() {
        var state = collapsedState()
        state.pointerEntered(at: CGPoint(x: 10, y: 10), now: epoch, dwell: 0.25)

        let restarted = state.pointerMoved(to: CGPoint(x: 13, y: 13), now: epoch, dwell: 0.25)
        #expect(!restarted)
        #expect(state.dwellDeadline == epoch.addingTimeInterval(0.25))
        let expansion = state.expandIfDwellElapsed(now: epoch.addingTimeInterval(0.25))
        #expect(expansion)
    }

    @Test func pointerExitCancelsDwell() {
        var state = collapsedState()
        state.pointerEntered(at: .zero, now: epoch, dwell: 0.25)

        state.pointerExited(now: epoch.addingTimeInterval(0.1), delay: 0.7)

        #expect(state.dwellDeadline == nil)
        #expect(state.dwellOrigin == nil)
        let expansion = state.expandIfDwellElapsed(now: epoch.addingTimeInterval(1))
        #expect(!expansion)
    }

    @Test func interactionAndSuppressionCancelPendingDwell() {
        var interacting = collapsedState()
        interacting.pointerEntered(at: .zero, now: epoch, dwell: 0.25)
        interacting.beginInteraction()
        #expect(interacting.dwellDeadline == nil)

        var suppressed = collapsedState()
        suppressed.pointerEntered(at: .zero, now: epoch, dwell: 0.25)
        suppressed.beginSuppression()
        #expect(suppressed.dwellDeadline == nil)

        var aggregate = collapsedState()
        aggregate.pointerEntered(at: .zero, now: epoch, dwell: 0.25)
        aggregate.setSuppressed(true, now: epoch, delay: 2.8)
        #expect(aggregate.dwellDeadline == nil)
    }

    @Test func tapExpandClearsDwell() {
        var state = collapsedState()
        state.pointerEntered(at: .zero, now: epoch, dwell: 0.25)

        state.expand()

        #expect(state.mode == .expanded)
        #expect(state.dwellDeadline == nil)
    }

    @Test func dwellIsIgnoredWhileUnarmed() {
        var state = collapsedState(armed: false)

        state.pointerEntered(at: .zero, now: epoch, dwell: 0.25)

        #expect(state.dwellDeadline == nil)
        let expansion = state.expandIfDwellElapsed(now: epoch.addingTimeInterval(1))
        #expect(!expansion)
        #expect(state.mode == .collapsed)
    }

    @Test func repeatedEntryRestartsTheDwellDeadline() {
        var state = collapsedState()

        state.pointerEntered(at: .zero, now: epoch, dwell: 1)
        state.pointerEntered(at: .zero, now: epoch.addingTimeInterval(0.5), dwell: 1)

        #expect(state.dwellDeadline == epoch.addingTimeInterval(1.5))
        let earlyExpansion = state.expandIfDwellElapsed(now: epoch.addingTimeInterval(1))
        #expect(!earlyExpansion)
        let expansion = state.expandIfDwellElapsed(now: epoch.addingTimeInterval(1.5))
        #expect(expansion)
    }
}
