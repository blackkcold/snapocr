import CoreGraphics

/// Pure geometry that decides when a shelf card drag has left the shelf and
/// should become a system file drag.
public enum ScreenshotShelfDragOutGeometry {
    /// Returns whether a point lies beyond the panel frame grown by a tolerance band.
    ///
    /// The tolerance exists so a pointer resting on the panel edge cannot flip
    /// between the in-shelf reorder state and the drag-out state. A negative
    /// tolerance is treated as zero.
    ///
    /// - Parameters:
    ///   - point: Location in AppKit screen coordinates (origin at the bottom left).
    ///   - panelFrame: The shelf panel's frame in the same coordinate space.
    ///   - tolerance: Extra distance in points the pointer must travel past an edge.
    /// - Returns: `true` when the point is outside the grown frame. Non-finite
    ///   input and degenerate frames always return `false` so a drag never starts
    ///   from unusable geometry.
    public static func isOutside(
        point: CGPoint,
        panelFrame: CGRect,
        tolerance: CGFloat = 6
    ) -> Bool {
        guard point.x.isFinite, point.y.isFinite,
            panelFrame.minX.isFinite, panelFrame.minY.isFinite,
            panelFrame.width.isFinite, panelFrame.height.isFinite,
            panelFrame.width > 0, panelFrame.height > 0
        else { return false }

        let grown = panelFrame.insetBy(dx: -max(0, tolerance), dy: -max(0, tolerance))
        return !grown.contains(point)
    }
}
