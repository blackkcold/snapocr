import CoreGraphics

/// The interaction state that decides whether the shelf may follow the pointer.
///
/// Every flag is a reason to stay put, so a shelf that is being dragged,
/// keyboard-controlled, covered by a menu, or suppressed never jumps away from under
/// the user.
public struct ScreenshotShelfFollowConditions: Sendable {
    /// The shelf is fully visible (not hidden, appearing or disappearing).
    public var isShelfVisible = false
    /// A card is being dragged inside the shelf.
    public var hasActiveCardDrag = false
    /// A native drag session (dragging a capture out) is running.
    public var hasActiveNativeDrag = false
    /// A menu is tracking the mouse.
    public var isMenuTracking = false
    /// The shelf panel is in keyboard mode.
    public var isKeyboardMode = false
    /// Capture, recording, full-screen or editing suppression is active.
    public var isSuppressed = false
    /// Any mouse button is held down.
    public var isPointerButtonDown = false
    /// The pointer is inside the shelf.
    public var isPointerOnShelf = false

    public init() {}
}

/// Pure decisions for the Dock-like shelf handoff between displays.
///
/// The follower polls the pointer's display, but every move is gated here so a shelf that
/// is being dragged, keyboard-controlled, covered by a menu, or suppressed never jumps
/// away from under the user.
public enum ScreenshotShelfDisplayFollowPolicy {
    /// Whether the shelf may move to the pointer's newly settled display.
    public static func shouldFollow(_ conditions: ScreenshotShelfFollowConditions) -> Bool {
        guard conditions.isShelfVisible else { return false }
        guard !conditions.hasActiveCardDrag, !conditions.hasActiveNativeDrag else { return false }
        guard !conditions.isMenuTracking, !conditions.isKeyboardMode else { return false }
        guard !conditions.isSuppressed else { return false }
        guard !conditions.isPointerButtonDown, !conditions.isPointerOnShelf else { return false }
        return true
    }

    /// Index of the display whose frame is nearest to a point.
    ///
    /// Displays with different heights leave gaps that belong to no screen. Falling back
    /// to the main display there would make the shelf jump back while the pointer is only
    /// crossing the seam, so the nearest frame wins instead.
    ///
    /// - Parameters:
    ///   - point: A point in the same coordinate space as the frames (screen points).
    ///   - displayFrames: Frames in the order the caller maps back to displays.
    /// - Returns: The nearest frame's index, or `nil` for an empty list.
    public static func nearestDisplayIndex(
        for point: CGPoint,
        displayFrames: [CGRect]
    ) -> Int? {
        guard !displayFrames.isEmpty else { return nil }
        var bestIndex = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (index, frame) in displayFrames.enumerated() {
            let distance = squaredDistance(from: point, to: frame)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        return bestIndex
    }

    private static func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let horizontal = max(max(rect.minX - point.x, 0), point.x - rect.maxX)
        let vertical = max(max(rect.minY - point.y, 0), point.y - rect.maxY)
        return horizontal * horizontal + vertical * vertical
    }
}
