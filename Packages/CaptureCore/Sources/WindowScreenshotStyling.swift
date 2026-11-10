import CoreGraphics

/// Composites a window capture onto a transparent canvas with rounded corners
/// and a soft shadow, so a pasted window screenshot reads as a floating window.
public enum WindowScreenshotStyling {
    /// Pixel metrics for the composite. All values are in image pixels.
    public struct Style: Equatable, Sendable {
        public var cornerRadius: CGFloat
        public var padding: CGFloat
        public var shadowRadius: CGFloat
        public var shadowOpacity: CGFloat
        public var shadowOffsetY: CGFloat

        public init(
            cornerRadius: CGFloat,
            padding: CGFloat,
            shadowRadius: CGFloat,
            shadowOpacity: CGFloat,
            shadowOffsetY: CGFloat
        ) {
            self.cornerRadius = cornerRadius
            self.padding = padding
            self.shadowRadius = shadowRadius
            self.shadowOpacity = shadowOpacity
            self.shadowOffsetY = shadowOffsetY
        }

        /// Scales the standard look for a display scale factor.
        ///
        /// Non-positive or non-finite scales fall back to 2x; larger values are
        /// clamped to 4x so an unusual display cannot produce a huge canvas.
        public static func standard(scale: CGFloat) -> Style {
            let resolved = scale.isFinite && scale > 0 ? min(max(scale, 1), 4) : 2
            return Style(
                cornerRadius: 10 * resolved,
                padding: 14 * resolved,
                shadowRadius: 10 * resolved,
                shadowOpacity: 0.28,
                shadowOffsetY: 3 * resolved
            )
        }
    }

    /// Draws the image into a padded, rounded, shadowed canvas.
    ///
    /// - Returns: The composited image, or `nil` when the bitmap context cannot
    ///   be created. A non-finite style is returned unchanged rather than
    ///   producing a broken canvas.
    public static func apply(_ image: CGImage, style: Style) -> CGImage? {
        guard image.width > 0, image.height > 0,
            style.padding.isFinite, style.padding >= 0,
            style.cornerRadius.isFinite, style.cornerRadius >= 0,
            style.shadowRadius.isFinite, style.shadowRadius >= 0
        else { return image }

        let padding = Int(style.padding.rounded())
        let width = image.width + padding * 2
        let height = image.height + padding * 2
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }

        let contentRect = CGRect(
            x: padding,
            y: padding,
            width: image.width,
            height: image.height
        )
        let path = CGPath(
            roundedRect: contentRect,
            cornerWidth: style.cornerRadius,
            cornerHeight: style.cornerRadius,
            transform: nil
        )

        // Cast the shadow from an opaque fill, then draw the image clipped to the
        // same path so the shadow is not painted twice.
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -style.shadowOffsetY),
            blur: style.shadowRadius,
            color: CGColor(gray: 0, alpha: style.shadowOpacity)
        )
        context.setFillColor(gray: 0, alpha: 1)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(path)
        context.clip()
        context.draw(image, in: contentRect)
        context.restoreGState()

        return context.makeImage()
    }

    /// The same float look expressed as reusable presentation metadata.
    ///
    /// Baking the treatment into pixels makes history/shelf replays fall back
    /// to a plain window after the raw image is linked. Returning a
    /// `MockupStyle` keeps the raw capture untouched while every surface can
    /// re-render the exact same padding, radius, and shadow on demand.
    public static func mockupStyle(for image: CGImage, scale: CGFloat) -> MockupStyle? {
        guard image.width > 0, image.height > 0 else { return nil }
        let style = Style.standard(scale: scale)
        let reference = MockupRenderer.referenceSide(
            for: CGSize(width: image.width, height: image.height)
        )
        guard reference.isFinite, reference > 0 else { return nil }
        return MockupStyle(
            background: .transparent,
            paddingRatio: style.padding / reference,
            cornerRadiusRatio: style.cornerRadius / reference,
            shadowBlurRatio: style.shadowRadius / reference,
            shadowOpacity: style.shadowOpacity,
            shadowOffsetRatio: style.shadowOffsetY / reference
        )
    }

    /// Applies the window look only where it is safe: window captures that are
    /// not being pinned. Pinning measures the image against the window's point
    /// size, so the shadow padding must not enter that path.
    public static func applyIfNeeded(
        _ image: CGImage,
        captureMode: CaptureMode,
        isEnabled: Bool,
        isPinning: Bool,
        scale: CGFloat
    ) -> CGImage {
        guard isEnabled, !isPinning, case .window = captureMode else { return image }
        return apply(image, style: .standard(scale: scale)) ?? image
    }
}
