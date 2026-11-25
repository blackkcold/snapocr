import CoreGraphics

/// Pure geometry for a share-ready screenshot canvas.
///
/// `MockupLayout` is the single source of truth for the padded canvas, the
/// content rectangle, the corner radius, the border and the shadow. The
/// exporter and the editor canvas both consume it; neither recomputes these
/// values locally, so the on-canvas result and the exported file stay in
/// lockstep.
public struct MockupLayout: Equatable, Sendable {
    /// Shadow metrics in image pixels.
    public struct ShadowMetrics: Equatable, Sendable {
        public let blur: CGFloat
        public let offsetY: CGFloat
        public let opacity: CGFloat

        public init(blur: CGFloat, offsetY: CGFloat, opacity: CGFloat) {
            self.blur = blur
            self.offsetY = offsetY
            self.opacity = opacity
        }
    }

    public let imageSize: CGSize
    public let canvasSize: CGSize
    /// Content rectangle in canvas coordinates. Origin is bottom-left, matching
    /// Core Graphics and AppKit's default (non-flipped) view coordinates.
    public let contentRect: CGRect
    public let padding: CGFloat
    public let cornerRadius: CGFloat
    public let borderWidth: CGFloat
    public let shadow: ShadowMetrics
    public let referenceSide: CGFloat

    /// Reference edge used to normalize padding/radius/border/shadow.
    ///
    /// `min(long, 1.8 × short)` keeps an ultra-long scrolling capture from
    /// receiving a huge top/bottom margin while a 6K fullscreen capture still
    /// scales proportionally.
    public static func referenceSide(for size: CGSize) -> CGFloat {
        let long = max(size.width, size.height)
        let short = min(size.width, size.height)
        guard short > 0, long.isFinite else { return 0 }
        return min(long, short * 1.8)
    }

    /// Builds the geometry for an image and a style.
    ///
    /// Non-finite inputs fall back to the style defaults rather than producing a
    /// broken canvas; negative ratios are treated as zero.
    public static func make(imageSize: CGSize, style: MockupStyle) -> MockupLayout {
        let width = max(1, imageSize.width.isFinite ? imageSize.width : 1)
        let height = max(1, imageSize.height.isFinite ? imageSize.height : 1)
        let size = CGSize(width: width, height: height)
        let reference = referenceSide(for: size)

        let padding = (max(0, finite(style.paddingRatio, fallback: 0.08)) * reference).rounded()
        let cornerRadius = min(
            max(0, finite(style.cornerRadiusRatio, fallback: 0.012)) * reference,
            min(width, height) / 2
        )

        let rawBorder = max(0, finite(style.borderWidthRatio, fallback: 0)) * reference
        let borderWidth = rawBorder > 0
            ? min(max(1, rawBorder.rounded()), min(min(width, height) * 0.02, 12))
            : 0

        let blur = max(0, finite(style.shadowBlurRatio, fallback: 0.03)) * reference
        let offsetY = max(0, finite(style.shadowOffsetRatio, fallback: 0.012)) * reference
        let opacity = min(max(0, finite(style.shadowOpacity, fallback: 0.28)), 1)

        let canvasSize = CGSize(
            width: max(1, width + padding * 2),
            height: max(1, height + padding * 2)
        )

        return MockupLayout(
            imageSize: size,
            canvasSize: canvasSize,
            contentRect: CGRect(x: padding, y: padding, width: width, height: height),
            padding: padding,
            cornerRadius: cornerRadius,
            borderWidth: borderWidth,
            shadow: ShadowMetrics(blur: blur, offsetY: offsetY, opacity: opacity),
            referenceSide: reference
        )
    }

    /// Geometry for an un-styled image: the canvas is exactly the image and
    /// every treatment metric is zero.
    ///
    /// The editor canvas uses this when share appearance is off so the same
    /// layout code drives hit testing, zoom and drawing in both states.
    public static func raw(imageSize: CGSize) -> MockupLayout {
        let width = max(1, imageSize.width.isFinite ? imageSize.width : 1)
        let height = max(1, imageSize.height.isFinite ? imageSize.height : 1)
        let size = CGSize(width: width, height: height)
        return MockupLayout(
            imageSize: size,
            canvasSize: size,
            contentRect: CGRect(origin: .zero, size: size),
            padding: 0,
            cornerRadius: 0,
            borderWidth: 0,
            shadow: ShadowMetrics(blur: 0, offsetY: 0, opacity: 0),
            referenceSide: referenceSide(for: size)
        )
    }

    /// Maps the content rectangle into a view/SwiftUI coordinate space.
    ///
    /// - Parameters:
    ///   - origin: Top-left/bottom-left origin of the canvas in the target space.
    ///   - scale: Points (or pixels) per image pixel.
    public func contentRect(in origin: CGPoint, scale: CGFloat) -> CGRect {
        CGRect(
            x: origin.x + contentRect.minX * scale,
            y: origin.y + contentRect.minY * scale,
            width: contentRect.width * scale,
            height: contentRect.height * scale
        )
    }

    private static func finite(_ value: CGFloat, fallback: CGFloat) -> CGFloat {
        value.isFinite ? value : fallback
    }
}
