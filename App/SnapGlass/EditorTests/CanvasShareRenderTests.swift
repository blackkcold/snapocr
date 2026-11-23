import AppKit
import CaptureCore
import Testing

/// Offscreen render coverage for the live share-appearance canvas.
///
/// These tests draw the real `EditableAnnotationCanvasNSView` through AppKit's
/// display path into a bitmap and compare it with `MockupRenderer.render`, the
/// same call the exporter uses. They need no running app, no screen-recording
/// permission, and no manual inspection.
@MainActor
struct CanvasShareRenderTests {
    private func image(
        width: Int = 400,
        height: Int = 200
    ) throws -> CGImage {
        let context = try #require(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private func style(
        background: MockupStyle.Background = .solid(red: 1, green: 1, blue: 1),
        padding: CGFloat = 0.1,
        borderWidth: CGFloat = 0,
        borderColor: MockupStyle.BorderColor = .automatic
    ) -> MockupStyle {
        MockupStyle(
            background: background,
            paddingRatio: padding,
            cornerRadiusRatio: 0,
            shadowBlurRatio: 0,
            shadowOpacity: 0,
            shadowOffsetRatio: 0,
            borderWidthRatio: borderWidth,
            borderColor: borderColor
        )
    }

    private func renderCanvas(
        image: CGImage,
        style: MockupStyle,
        size: CGSize = CGSize(width: 800, height: 600)
    ) throws -> (bitmap: NSBitmapImageRep, canvas: EditableAnnotationCanvasNSView) {
        let canvas = EditableAnnotationCanvasNSView(
            frame: CGRect(origin: .zero, size: size)
        )
        canvas.image = image
        canvas.lastImageSize = CGSize(width: image.width, height: image.height)
        canvas.shareStyle = style
        canvas.showsOCROverlay = false

        let window = NSWindow(
            contentRect: canvas.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        canvas.layoutSubtreeIfNeeded()
        canvas.displayIfNeeded()

        let bitmap = try #require(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
        return (bitmap, canvas)
    }

    /// Samples a point in view coordinates (origin bottom-left) from a bitmap
    /// whose row 0 is the top edge. `cacheDisplay` may return a Retina rep, so
    /// view points are scaled to the bitmap's own pixel grid.
    private func color(
        in bitmap: NSBitmapImageRep,
        atViewPoint point: CGPoint,
        viewSize: CGSize = CGSize(width: 800, height: 600)
    ) -> NSColor {
        let scaleX = CGFloat(bitmap.pixelsWide) / max(viewSize.width, 1)
        let scaleY = CGFloat(bitmap.pixelsHigh) / max(viewSize.height, 1)
        let x = min(max(Int((point.x * scaleX).rounded()), 0), bitmap.pixelsWide - 1)
        let flippedY = bitmap.pixelsHigh - 1 - Int((point.y * scaleY).rounded())
        let y = min(max(flippedY, 0), bitmap.pixelsHigh - 1)
        return bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) ?? .clear
    }

    private func color(
        in bitmap: NSBitmapImageRep,
        normalized point: CGPoint
    ) -> NSColor {
        let x = min(max(Int((point.x * CGFloat(bitmap.pixelsWide)).rounded()), 0), bitmap.pixelsWide - 1)
        let y = min(max(Int(((1 - point.y) * CGFloat(bitmap.pixelsHigh)).rounded()), 0), bitmap.pixelsHigh - 1)
        return bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) ?? .clear
    }

    private func expectClose(
        _ lhs: NSColor,
        _ rhs: NSColor,
        tolerance: CGFloat = 0.06,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(abs(lhs.redComponent - rhs.redComponent) < tolerance, sourceLocation: sourceLocation)
        #expect(abs(lhs.greenComponent - rhs.greenComponent) < tolerance, sourceLocation: sourceLocation)
        #expect(abs(lhs.blueComponent - rhs.blueComponent) < tolerance, sourceLocation: sourceLocation)
    }

    @Test func canvasDrawsPaddingBackgroundAndImage() throws {
        let image = try image()
        let rendered = try renderCanvas(image: image, style: style())
        let frame = rendered.canvas.canvasRect(
            for: CGSize(width: image.width, height: image.height)
        )

        let padding = color(
            in: rendered.bitmap,
            atViewPoint: CGPoint(x: frame.minX + 4, y: frame.midY)
        )
        let content = color(
            in: rendered.bitmap,
            atViewPoint: CGPoint(x: frame.midX, y: frame.midY)
        )

        #expect(padding.redComponent > 0.95)
        #expect(padding.greenComponent > 0.95)
        #expect(padding.blueComponent > 0.95)
        #expect(content.redComponent > 0.8)
        #expect(content.greenComponent < 0.3)
    }

    @Test func canvasMatchesExportedShareImage() throws {
        let image = try image()
        let style = style(padding: 0.1)
        let rendered = try renderCanvas(image: image, style: style)
        let frame = rendered.canvas.canvasRect(
            for: CGSize(width: image.width, height: image.height)
        )
        let exported = try #require(MockupRenderer.render(image, style: style))
        let exportBitmap = NSBitmapImageRep(cgImage: exported)

        // Padding must match exactly: it is the style background in both paths.
        // The content point only proves the image is drawn in the same place;
        // `cacheDisplay` renders through the window's backing colour space, so
        // exact component equality there would test colour management, not
        // geometry.
        let paddingPoints = [
            CGPoint(x: 0.02, y: 0.5),
            CGPoint(x: 0.98, y: 0.5),
            CGPoint(x: 0.5, y: 0.02),
            CGPoint(x: 0.5, y: 0.98),
        ]
        for point in paddingPoints {
            let canvasColor = color(
                in: rendered.bitmap,
                atViewPoint: CGPoint(
                    x: frame.minX + point.x * frame.width,
                    y: frame.minY + point.y * frame.height
                )
            )
            let exportColor = color(in: exportBitmap, normalized: point)
            expectClose(canvasColor, exportColor, tolerance: 0.02)
        }

        let center = CGPoint(x: 0.5, y: 0.5)
        let canvasCenter = color(
            in: rendered.bitmap,
            atViewPoint: CGPoint(
                x: frame.minX + center.x * frame.width,
                y: frame.minY + center.y * frame.height
            )
        )
        let exportCenter = color(in: exportBitmap, normalized: center)
        #expect(canvasCenter.redComponent > 0.8)
        #expect(canvasCenter.greenComponent < 0.5)
        #expect(canvasCenter.blueComponent < 0.5)
        #expect(exportCenter.redComponent > 0.8)
        #expect(exportCenter.greenComponent < 0.5)
        #expect(exportCenter.blueComponent < 0.5)
    }

    @Test func transparentStyleShowsCheckerboardInPadding() throws {
        let image = try image()
        let rendered = try renderCanvas(
            image: image,
            style: style(background: .transparent)
        )
        let frame = rendered.canvas.canvasRect(
            for: CGSize(width: image.width, height: image.height)
        )

        let padding = color(
            in: rendered.bitmap,
            atViewPoint: CGPoint(x: frame.minX + 2, y: frame.midY)
        )
        let content = color(
            in: rendered.bitmap,
            atViewPoint: CGPoint(x: frame.midX, y: frame.midY)
        )

        // The workspace is 0.12 gray; the checkerboard is 0.17/0.23.
        #expect(padding.redComponent > 0.14)
        #expect(padding.redComponent < 0.28)
        #expect(abs(padding.redComponent - padding.greenComponent) < 0.02)
        #expect(content.redComponent > 0.8)
    }

    @Test func canvasDrawsTheBorderInsideTheContentEdge() throws {
        let image = try image()
        let rendered = try renderCanvas(
            image: image,
            style: style(
                borderWidth: 0.02,
                borderColor: .custom(red: 0, green: 0, blue: 0, alpha: 1)
            )
        )
        let content = rendered.canvas.imageDisplayRect

        let border = color(
            in: rendered.bitmap,
            atViewPoint: CGPoint(x: content.minX + 2, y: content.midY)
        )
        let inside = color(
            in: rendered.bitmap,
            atViewPoint: CGPoint(x: content.midX, y: content.midY)
        )

        #expect(border.redComponent < 0.3)
        #expect(border.greenComponent < 0.3)
        #expect(inside.redComponent > 0.8)
    }
}
