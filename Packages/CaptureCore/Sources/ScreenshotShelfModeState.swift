import CoreGraphics
import Foundation

/// Whether the shelf is showing its cards or has folded down to the rail tab.
public enum ScreenshotShelfMode: String, CaseIterable, Sendable {
    case expanded
    case collapsed
}

/// Pure state for the shelf's expanded/collapsed lifecycle.
///
/// The manager owns the timer; this value owns the guards and the deadlines so the behavior is
/// testable without a panel. Locking is intentionally not represented here: a lock is a hard
/// reset handled by `ScreenshotShelfPresentationState`.
public struct ScreenshotShelfModeState: Equatable, Sendable {
    public private(set) var mode: ScreenshotShelfMode
    public private(set) var isInteractionHeld: Bool
    public private(set) var isSuppressed: Bool
    public private(set) var isExpansionArmed: Bool
    public private(set) var idleDeadline: Date?
    /// Deadline at which a pointer resting on the collapsed handle may expand the shelf.
    public private(set) var dwellDeadline: Date?
    /// Where the pointer entered the collapsed handle, for the movement tolerance.
    public private(set) var dwellOrigin: CGPoint?

    /// Pointer travel beyond this distance cancels a pending dwell expansion.
    public static let dwellMovementTolerance: CGFloat = 5

    public init(mode: ScreenshotShelfMode = .expanded) {
        self.mode = mode
        isInteractionHeld = false
        isSuppressed = false
        isExpansionArmed = true
        idleDeadline = nil
        dwellDeadline = nil
        dwellOrigin = nil
    }

    /// Records a pointer entry on the collapsed handle and arms a dwell deadline.
    ///
    /// Entry alone no longer expands the shelf: a pointer that merely crosses the handle must
    /// not open the panel over the app underneath. `expandIfDwellElapsed` performs the expansion
    /// once the pointer has rested on the handle long enough.
    ///
    /// - Parameters:
    ///   - location: Pointer location in the panel's SwiftUI coordinate space.
    ///   - now: Current time, injectable for tests.
    ///   - dwell: Time the pointer must rest on the handle before expanding.
    public mutating func pointerEntered(
        at location: CGPoint? = nil,
        now: Date = Date(),
        dwell: TimeInterval
    ) {
        idleDeadline = nil
        guard mode == .collapsed, isExpansionArmed, !isSuppressed, !isInteractionHeld else {
            cancelDwell()
            return
        }
        dwellOrigin = location
        dwellDeadline = now.addingTimeInterval(max(0, dwell))
    }

    /// Re-bases the dwell origin when the pointer travels beyond the tolerance.
    ///
    /// The dwell restarts from the new position instead of being cancelled outright. A pointer
    /// that arrives on the handle and then settles still opens the shelf; one that sweeps across
    /// never accumulates enough rest time because it leaves the window first.
    ///
    /// - Returns: `true` when the dwell was re-based and the caller must reschedule it.
    @discardableResult
    public mutating func pointerMoved(
        to location: CGPoint,
        now: Date = Date(),
        dwell: TimeInterval
    ) -> Bool {
        guard dwellDeadline != nil else { return false }
        guard let origin = dwellOrigin else {
            dwellOrigin = location
            return true
        }
        let deltaX = location.x - origin.x
        let deltaY = location.y - origin.y
        let tolerance = Self.dwellMovementTolerance
        guard deltaX * deltaX + deltaY * deltaY > tolerance * tolerance else { return false }
        dwellOrigin = location
        dwellDeadline = now.addingTimeInterval(max(0, dwell))
        return true
    }

    /// Expands a collapsed, armed shelf once its dwell deadline has elapsed.
    ///
    /// - Returns: `true` when the shelf expanded.
    @discardableResult
    public mutating func expandIfDwellElapsed(now: Date = Date()) -> Bool {
        guard mode == .collapsed,
              isExpansionArmed,
              !isSuppressed,
              !isInteractionHeld,
              let deadline = dwellDeadline,
              now >= deadline else { return false }

        mode = .expanded
        idleDeadline = nil
        cancelDwell()
        return true
    }

    /// Clears a pending dwell expansion.
    public mutating func cancelDwell() {
        dwellDeadline = nil
        dwellOrigin = nil
    }

    /// Starts the idle deadline after the pointer leaves an expanded shelf.
    public mutating func pointerExited(now: Date = Date(), delay: TimeInterval) {
        cancelDwell()
        guard mode == .expanded, !isInteractionHeld, !isSuppressed, delay > 0 else {
            idleDeadline = nil
            return
        }
        idleDeadline = now.addingTimeInterval(delay)
    }

    /// Holds the shelf open while dragging or while a menu is tracking.
    public mutating func beginInteraction() {
        isInteractionHeld = true
        idleDeadline = nil
        cancelDwell()
    }

    public mutating func endInteraction(now: Date = Date(), delay: TimeInterval) {
        isInteractionHeld = false
        guard mode == .expanded, !isSuppressed, delay > 0 else { return }
        idleDeadline = now.addingTimeInterval(delay)
    }

    /// Holds the shelf open while capture, recording, or a full-screen app is active.
    public mutating func beginSuppression() {
        isSuppressed = true
        idleDeadline = nil
        cancelDwell()
    }

    public mutating func endSuppression(now: Date = Date(), delay: TimeInterval) {
        isSuppressed = false
        guard mode == .expanded, !isInteractionHeld, delay > 0 else { return }
        idleDeadline = now.addingTimeInterval(delay)
    }

    /// Collapses only when the idle deadline has actually elapsed.
    @discardableResult
    public mutating func collapseIfIdle(now: Date = Date()) -> Bool {
        guard mode == .expanded, !isInteractionHeld, !isSuppressed,
              let deadline = idleDeadline, now >= deadline else {
            return false
        }
        collapse()
        return true
    }

    /// Re-arms hover expansion after a short cooldown so a collapse cannot immediately re-expand.
    public mutating func armExpansion() {
        isExpansionArmed = true
    }

    /// Forces the collapsed mode after the caller has already checked interaction/suppression.
    public mutating func collapse() {
        mode = .collapsed
        isExpansionArmed = false
        idleDeadline = nil
        cancelDwell()
    }

    /// Clears a drag/menu hold without touching the mode.
    public mutating func cancelInteraction() {
        isInteractionHeld = false
    }

    /// Sets suppression from the manager's aggregate capture/recording/full-screen state.
    public mutating func setSuppressed(
        _ suppressed: Bool,
        now: Date = Date(),
        delay: TimeInterval
    ) {
        isSuppressed = suppressed
        if suppressed {
            idleDeadline = nil
            cancelDwell()
        } else if mode == .expanded, !isInteractionHeld, delay > 0 {
            idleDeadline = now.addingTimeInterval(delay)
        }
    }

    public mutating func expand() {
        mode = .expanded
        isExpansionArmed = true
        idleDeadline = nil
        cancelDwell()
    }

    /// Returns to the default expanded mode after a lock or a hard reset.
    public mutating func reset() {
        mode = .expanded
        isInteractionHeld = false
        isSuppressed = false
        isExpansionArmed = true
        idleDeadline = nil
        cancelDwell()
    }
}
