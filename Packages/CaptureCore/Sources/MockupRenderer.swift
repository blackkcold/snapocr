import CoreGraphics

/// Renders a screenshot onto a share-ready canvas.
public enum MockupRenderer {
    /// The reference edge used to normalize padding/radius/shadow.
    ///
    /// Kept as a compatibility entry point; `MockupLayout` owns the math.
    public static func referenceSide(for size: CGSize) -> CGFloat {
        MockupLayout.referenceSide(for: size)
    }

    /// The geometry for an image and a style.
    public static func layout(for imageSize: CGSize, style: MockupStyle) -> MockupLayout {
        MockupLayout.make(imageSize: imageSize, style: style)
    }

    /// The output canvas size for a style.
    public static func outputSize(for imageSize: CGSize, style: MockupStyle) -> CGSize {
        layout(for: imageSize, style: style).canvasSize
    }

    /// Draws the image onto a padded, rounded, shadowed canvas.
    ///
    /// - Returns: The composited image, or `nil` when the bitmap context cannot
    ///   be created.
    public static func render(_ image: CGImage, style: MockupStyle) -> CGImage? {
        guard image.width > 0, image.height > 0 else { return nil }
        let layout = layout(
            for: CGSize(width: image.width, height: image.height),
            style: style
        )
        guard layout.referenceSide > 0 else { return nil }

        let width = max(1, Int(layout.canvasSize.width))
        let height = max(1, Int(layout.canvasSize.height))

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
        draw(image, style: style, layout: layout, in: context)
        return context.makeImage()
    }

    /// Renders at a bounded preview size while preserving the style's ratios.
    ///
    /// The source is downsampled first; the layout is then computed from the
    /// downsampled image, so padding, radius, shadow and border keep the same
    /// visual weight as the full-resolution export.
    public static func render(
        _ image: CGImage,
        style: MockupStyle,
        maximumDimension: CGFloat
    ) -> CGImage? {
        guard maximumDimension > 0 else { return render(image, style: style) }
        let source = downscaled(image, maxDimension: maximumDimension) ?? image
        return render(source, style: style)
    }

    /// Draws a style into an existing context.
    ///
    /// The context is expected to be in the target space; `origin` and `scale`
    /// map the image-pixel layout into that space. This is the shared entry
    /// point for the exporter and (later) the editor canvas.
    ///
    /// - Parameters:
    ///   - image: The source image, already at its final pixel size.
    ///   - style: Background, padding, radius, shadow, and border to apply.
    ///   - layout: Geometry computed for the image in its own pixel space.
    ///   - context: The destination context to draw into.
    ///   - origin: Target-space position of the canvas origin.
    ///   - scale: Target points (or pixels) per image pixel.
    ///   - backdrop: Repaints the area behind a transparent image after the
    ///     shadow's opaque fill is cleared. The editor canvas uses it to keep its
    ///     checkerboard visible through transparent pixels.
    public static func draw(
        _ image: CGImage,
        style: MockupStyle,
        layout: MockupLayout,
        in context: CGContext,
        origin: CGPoint = .zero,
        scale: CGFloat = 1,
        backdrop: ((CGContext, CGRect) -> Void)? = nil
    ) {
        guard scale.isFinite, scale > 0 else { return }

        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        context.scaleBy(x: scale, y: scale)
        // `render` discards anything outside the bitmap, so the editor must
        // clip to the same canvas or a large shadow shows a halo the export
        // will never have.
        context.clip(to: CGRect(origin: .zero, size: layout.canvasSize))

        drawBackground(style.background, in: context, size: layout.canvasSize)

        let path = CGPath(
            roundedRect: layout.contentRect,
            cornerWidth: max(0, layout.cornerRadius),
            cornerHeight: max(0, layout.cornerRadius),
            transform: nil
        )

        let castsShadow =
            layout.shadow.opacity > 0
            && (layout.shadow.blur > 0 || layout.shadow.offsetY > 0)
        if castsShadow {
            context.saveGState()
            context.setShadow(
                offset: CGSize(width: 0, height: -layout.shadow.offsetY),
                blur: layout.shadow.blur,
                color: CGColor(gray: 0, alpha: layout.shadow.opacity)
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
            context.clear(layout.contentRect)
            backdrop?(context, layout.contentRect)
            drawBackground(style.background, in: context, size: layout.canvasSize)
        }
        context.draw(image, in: layout.contentRect)
        context.restoreGState()

        drawBorder(
            style: style,
            layout: layout,
            path: path,
            in: context
        )

        context.restoreGState()
    }

    private static func drawBorder(
        style: MockupStyle,
        layout: MockupLayout,
        path: CGPath,
        in context: CGContext
    ) {
        guard layout.borderWidth > 0,
            let color = resolvedBorderColor(for: style, layout: layout)
        else { return }

        let inset = layout.borderWidth / 2
        let borderRect = layout.contentRect.insetBy(dx: inset, dy: inset)
        guard borderRect.width > 0, borderRect.height > 0 else { return }

        let borderPath = CGPath(
            roundedRect: borderRect,
            cornerWidth: max(0, layout.cornerRadius - inset),
            cornerHeight: max(0, layout.cornerRadius - inset),
            transform: nil
        )

        context.saveGState()
        context.addPath(path)
        context.clip()
        context.addPath(borderPath)
        context.setLineWidth(layout.borderWidth)
        context.setStrokeColor(color)
        context.strokePath()
        context.restoreGState()
    }

    private static func resolvedBorderColor(
        for style: MockupStyle,
        layout: MockupLayout
    ) -> CGColor? {
        guard layout.borderWidth > 0 else { return nil }
        switch style.borderColor {
        case .automatic:
            let luminance = averageLuminance(of: style.background)
            if let luminance, luminance >= 0.5 {
                return CGColor(gray: 0, alpha: 0.18)
            }
            return CGColor(gray: 1, alpha: 0.55)
        case .custom(let red, let green, let blue, let alpha):
            return CGColor(red: red, green: green, blue: blue, alpha: alpha)
        }
    }

    private static func averageLuminance(of background: MockupStyle.Background) -> CGFloat? {
        switch background {
        case .transparent:
            return nil
        case .solid(let red, let green, let blue):
            return luminance(red: red, green: green, blue: blue)
        case .linear(let stops, _):
            guard !stops.isEmpty else { return nil }
            let total = stops.reduce(CGFloat.zero) { partial, stop in
                partial + luminance(red: stop.red, green: stop.green, blue: stop.blue)
            }
            return total / CGFloat(stops.count)
        }
    }

    private static func luminance(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGFloat {
        0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    private static func downscaled(_ image: CGImage, maxDimension: CGFloat) -> CGImage? {
        let longEdge = max(image.width, image.height)
        guard longEdge > 0, CGFloat(longEdge) > maxDimension else { return image }
        let scale = maxDimension / CGFloat(longEdge)
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
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
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
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
