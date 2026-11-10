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

    public init(mode: ScreenshotShelfMode = .expanded) {
        self.mode = mode
        isInteractionHeld = false
        isSuppressed = false
        isExpansionArmed = true
        idleDeadline = nil
    }

    /// Cancels any pending idle collapse and expands a collapsed shelf when expansion is armed.
    public mutating func pointerEntered(now: Date = Date()) {
        idleDeadline = nil
        guard mode == .collapsed, isExpansionArmed, !isSuppressed else { return }
        mode = .expanded
    }

    /// Starts the idle deadline after the pointer leaves an expanded shelf.
    public mutating func pointerExited(now: Date = Date(), delay: TimeInterval) {
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
        } else if mode == .expanded, !isInteractionHeld, delay > 0 {
            idleDeadline = now.addingTimeInterval(delay)
        }
    }

    public mutating func expand() {
        mode = .expanded
        isExpansionArmed = true
        idleDeadline = nil
    }

    /// Returns to the default expanded mode after a lock or a hard reset.
    public mutating func reset() {
        mode = .expanded
        isInteractionHeld = false
        isSuppressed = false
        isExpansionArmed = true
        idleDeadline = nil
    }
}
