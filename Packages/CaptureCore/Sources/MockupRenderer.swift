import CoreGraphics

/// Renders a screenshot onto a share-ready canvas.
public enum MockupRenderer {
    /// The reference edge used to normalize padding/radius/shadow.
    ///
    /// Using `min(long, 1.8 × short)` keeps an ultra-long scrolling capture
    /// from receiving a huge top/bottom margin while a 6K fullscreen capture
    /// still scales proportionally.
    public static func referenceSide(for size: CGSize) -> CGFloat {
        let long = max(size.width, size.height)
        let short = min(size.width, size.height)
        guard short > 0 else { return 0 }
        return min(long, short * 1.8)
    }

    /// The output canvas size for a style.
    public static func outputSize(for imageSize: CGSize, style: MockupStyle) -> CGSize {
        let reference = referenceSide(for: imageSize)
        let padding = (max(0, style.paddingRatio * reference)).rounded()
        return CGSize(
            width: max(1, imageSize.width + padding * 2),
            height: max(1, imageSize.height + padding * 2)
        )
    }

    /// Draws the image onto a padded, rounded, shadowed canvas.
    ///
    /// - Returns: The composited image, or `nil` when the bitmap context cannot
    ///   be created.
    public static func render(_ image: CGImage, style: MockupStyle) -> CGImage? {
        guard image.width > 0, image.height > 0 else { return nil }
        let imageSize = CGSize(width: image.width, height: image.height)
        let reference = referenceSide(for: imageSize)
        guard reference > 0 else { return nil }

        let padding = (max(0, style.paddingRatio * reference)).rounded()
        let radius = min(
            max(0, style.cornerRadiusRatio * reference),
            min(imageSize.width, imageSize.height) / 2
        )
        let blur = max(0, style.shadowBlurRatio * reference)
        let offset = max(0, style.shadowOffsetRatio * reference)
        let canvasSize = outputSize(for: imageSize, style: style)
        let width = max(1, Int(canvasSize.width))
        let height = max(1, Int(canvasSize.height))

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        context.interpolationQuality = .high
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        drawBackground(style.background, in: context, size: CGSize(width: width, height: height))

        let contentRect = CGRect(
            x: padding,
            y: padding,
            width: imageSize.width,
            height: imageSize.height
        )
        let path = CGPath(
            roundedRect: contentRect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )

        let castsShadow = style.shadowOpacity > 0 && (blur > 0 || offset > 0)
        if castsShadow {
            context.saveGState()
            context.setShadow(
                offset: CGSize(width: 0, height: -offset),
                blur: blur,
                color: CGColor(gray: 0, alpha: style.shadowOpacity)
            )
            context.setFillColor(gray: 0, alpha: 1)
            context.addPath(path)
            context.fillPath()
            context.restoreGState()
        }

        context.saveGState()
        context.addPath(path)
        context.clip()
        if castsShadow {
            // The opaque fill above exists only to cast the shadow. Clear it
            // inside the content so a transparent source (freeform mask) does
            // not turn into a black block, then repaint the style background.
            context.clear(contentRect)
            drawBackground(style.background, in: context, size: CGSize(width: width, height: height))
        }
        context.draw(image, in: contentRect)
        context.restoreGState()

        return context.makeImage()
    }

    private static func drawBackground(
        _ background: MockupStyle.Background,
        in context: CGContext,
        size: CGSize
    ) {
        let rect = CGRect(origin: .zero, size: size)
        switch background {
        case .transparent:
            return
        case .solid(let red, let green, let blue):
            context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
            context.fill(rect)
        case .linear(let stops, let angle):
            guard stops.count >= 2,
                  let gradient = CGGradient(
                      colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                      colors: stops.map {
                          CGColor(red: $0.red, green: $0.green, blue: $0.blue, alpha: 1)
                      } as CFArray,
                      locations: stops.map(\.location)
                  )
            else { return }

            let radians = angle * .pi / 180
            let direction = CGPoint(x: sin(radians), y: -cos(radians))
            let half = (abs(direction.x) * size.width + abs(direction.y) * size.height) / 2
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let start = CGPoint(
                x: center.x - direction.x * half,
                y: center.y - direction.y * half
            )
            let end = CGPoint(
                x: center.x + direction.x * half,
                y: center.y + direction.y * half
            )
            context.drawLinearGradient(
                gradient,
                start: start,
                end: end,
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
    }
}
