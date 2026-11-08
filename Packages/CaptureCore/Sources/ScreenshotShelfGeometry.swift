import CoreGraphics

/// Geometry helpers for the single, horizontally scrolling screenshot-shelf panel.
public enum ScreenshotShelfGeometry {
    /// Computes a top-centered viewport while preserving each card's supplied width.
    ///
    /// `visibleFrame` must already exclude the menu bar, notch safe areas, and other unusable
    /// screen regions. If the cards do not fit horizontally, the viewport is constrained while
    /// the caller keeps the original card widths in its scroll content.
    ///
    /// - Parameters:
    ///   - visibleFrame: Safe screen frame in AppKit global point coordinates.
    ///   - cardWidths: Per-image widths at `cardHeight`, preserving each image's aspect ratio.
    ///   - cardHeight: Configured card height in points.
    ///   - spacing: Horizontal spacing between cards.
    ///   - horizontalInset: Minimum distance from either horizontal screen edge.
    ///   - topInset: Distance below the safe frame's top edge.
    ///   - verticalInset: Vertical padding around the card row.
    /// - Returns: Panel frame bounded by `visibleFrame`; `.zero` for invalid screen geometry.
    public static func panelFrame(
        visibleFrame: CGRect,
        cardWidths: [CGFloat],
        cardHeight: CGFloat,
        spacing: CGFloat,
        horizontalInset: CGFloat,
        topInset: CGFloat,
        verticalInset: CGFloat
    ) -> CGRect {
        guard visibleFrame.minX.isFinite,
              visibleFrame.minY.isFinite,
              visibleFrame.width.isFinite,
              visibleFrame.height.isFinite,
              visibleFrame.width > 0,
              visibleFrame.height > 0,
              cardHeight.isFinite,
              cardHeight > 0 else { return .zero }

        let sideInset = nonnegative(horizontalInset)
        let verticalPadding = nonnegative(verticalInset)
        let safeSpacing = nonnegative(spacing)
        let validCardWidths = cardWidths.filter { $0.isFinite && $0 > 0 }
        let contentWidth = validCardWidths.reduce(0, +)
            + safeSpacing * CGFloat(max(0, validCardWidths.count - 1))
            + sideInset * 2
        let maximumWidth = max(0, visibleFrame.width - sideInset * 2)
        let width = min(contentWidth, maximumWidth)

        let height = min(cardHeight + verticalPadding * 2, visibleFrame.height)
        let availableTopInset = max(0, visibleFrame.height - height)
        let safeTopInset = min(nonnegative(topInset), availableTopInset)
        let frame = CGRect(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.maxY - safeTopInset - height,
            width: width,
            height: height
        )
        return frame
    }

    private static func nonnegative(_ value: CGFloat) -> CGFloat {
        value.isFinite ? max(0, value) : 0
    }
}
