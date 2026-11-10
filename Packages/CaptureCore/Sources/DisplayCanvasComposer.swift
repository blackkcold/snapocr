import CoreGraphics

/// Composes per-display captures into the canvas described by `DisplayCanvasPlan`.
///
/// The composer keeps the canvas in a single sRGB pixel space so mixed 1x/2x
/// displays share one grid. It never crops content: compact modes place
/// displays edge to edge, while physical mode leaves transparent empty areas.
public enum DisplayCanvasComposer {
    /// Composes the supplied display images.
    ///
    /// - Parameters:
    ///   - images: Captures keyed by display ID.
    ///   - plan: The geometry to honor.
    ///   - background: An optional opaque/translucent fill behind the displays.
    /// - Returns: The composed image, or `nil` when the canvas cannot be created.
    public static func compose(
        images: [CGDirectDisplayID: CGImage],
        plan: DisplayCanvasPlan,
        background: CGColor? = nil
    ) -> CGImage? {
        let width = max(1, Int(plan.outputPixelSize.width))
        let height = max(1, Int(plan.outputPixelSize.height))
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
        if let background {
            context.setFillColor(background)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }

        for placement in plan.placements {
            guard let image = images[placement.displayID] else { continue }
            let destination = CGRect(
                x: placement.canvasOrigin.x * plan.commonScale,
                y: CGFloat(height)
                    - placement.canvasOrigin.y * plan.commonScale
                    - placement.outputPixelSize.height,
                width: placement.outputPixelSize.width,
                height: placement.outputPixelSize.height
            )
            context.draw(image, in: destination)
        }

        return context.makeImage()
    }
}
