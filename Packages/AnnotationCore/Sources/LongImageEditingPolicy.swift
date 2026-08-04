import CoreGraphics

/// Determines when the editor should offer a constrained top-and-bottom trim workflow.
public enum LongImageEditingPolicy {
    /// Returns whether a screenshot benefits from vertical endpoint trimming.
    ///
    /// Scrolling captures always qualify. Other screenshots qualify when their height is
    /// at least twice their width, which avoids surfacing the specialized tool for ordinary images.
    public static func supportsVerticalTrim(
        imageWidth: Int,
        imageHeight: Int,
        isScrollingCapture: Bool,
        minimumAspectRatio: CGFloat = 2
    ) -> Bool {
        guard imageWidth > 0, imageHeight > 0, minimumAspectRatio > 0 else { return false }
        return isScrollingCapture
            || CGFloat(imageHeight) / CGFloat(imageWidth) >= minimumAspectRatio
    }
}
