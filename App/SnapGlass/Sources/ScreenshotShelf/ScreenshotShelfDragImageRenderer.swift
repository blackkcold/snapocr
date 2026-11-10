import AppKit

/// Draws the image that follows the pointer during a native drag out of the shelf.
///
/// The image is the card thumbnail clipped to the card's rounded shape, framed by
/// a hairline border and a soft shadow. The shadow is baked into the image padding
/// so the system never clips it at the screen edge.
enum ScreenshotShelfDragImageRenderer {
    /// Transparent margin reserved for the shadow on every side, in points.
    static let padding: CGFloat = 12

    /// Renders the drag image at an explicit backing scale.
    ///
    /// - Parameters:
    ///   - thumbnail: The card's preview image. `nil` still produces a framed
    ///     placeholder so the drag always has a visual.
    ///   - cardSize: The card's size in points.
    ///   - cornerRadius: Corner radius matching the shelf card.
    ///   - scale: Backing scale for the bitmap representation.
    /// - Returns: A ready-to-drag image, or `nil` for non-positive input.
    static func image(
        thumbnail: CGImage?,
        cardSize: CGSize,
        cornerRadius: CGFloat = 14,
        scale: CGFloat = 2
    ) -> NSImage? {
        guard cardSize.width > 0, cardSize.height > 0,
            scale > 0, scale.isFinite
        else { return nil }

        let size = CGSize(
            width: cardSize.width + padding * 2,
            height: cardSize.height + padding * 2
        )
        let pixelWidth = Int((size.width * scale).rounded())
        let pixelHeight = Int((size.height * scale).rounded())
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        guard
            let representation = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixelWidth,
                pixelsHigh: pixelHeight,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        else { return nil }
        representation.size = size

        guard let context = NSGraphicsContext(bitmapImageRep: representation) else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        draw(thumbnail: thumbnail, cardSize: cardSize, cornerRadius: cornerRadius)
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(representation)
        return image
    }

    private static func draw(
        thumbnail: CGImage?,
        cardSize: CGSize,
        cornerRadius: CGFloat
    ) {
        let cardRect = CGRect(origin: CGPoint(x: padding, y: padding), size: cardSize)
        let path = NSBezierPath(
            roundedRect: cardRect,
            xRadius: cornerRadius,
            yRadius: cornerRadius
        )

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.set()
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        if let thumbnail {
            drawAspectFill(thumbnail, in: cardRect)
        }
        NSGraphicsContext.restoreGraphicsState()

        NSColor(calibratedWhite: 0.5, alpha: 0.45).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private static func drawAspectFill(_ image: CGImage, in rect: CGRect) {
        let imageSize = CGSize(width: image.width, height: image.height)
        guard imageSize.width > 0, imageSize.height > 0 else { return }

        let scale = max(rect.width / imageSize.width, rect.height / imageSize.height)
        let drawSize = CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
        let origin = CGPoint(
            x: rect.midX - drawSize.width / 2,
            y: rect.midY - drawSize.height / 2
        )
        NSImage(cgImage: image, size: imageSize).draw(
            in: CGRect(origin: origin, size: drawSize)
        )
    }
}
