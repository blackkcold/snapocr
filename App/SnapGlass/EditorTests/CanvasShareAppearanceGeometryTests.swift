import AppKit
import CaptureCore
import Testing

/// Geometry contract for the live share-appearance canvas.
///
/// `imageDisplayRect` is the only anchor every hit test, crop, OCR and text
/// path reads. These tests pin it to the layout's content rect, keep fit and
/// 1:1 honest, and check that toggling the treatment does not throw away the
/// user's zoom.
@MainActor
struct CanvasShareAppearanceGeometryTests {
    private func image(width: Int = 1000, height: Int = 500) throws -> CGImage {
        let context = try #require(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private func makeCanvas(size: CGSize = CGSize(width: 800, height: 600)) -> EditableAnnotationCanvasNSView {
        let canvas = EditableAnnotationCanvasNSView(
            frame: CGRect(origin: .zero, size: size)
        )
        canvas.showsOCROverlay = false
        return canvas
    }

    private func style(padding: CGFloat = 0.1) -> MockupStyle {
        MockupStyle(
            background: .solid(red: 1, green: 1, blue: 1),
            paddingRatio: padding,
            cornerRadiusRatio: 0.012,
            shadowBlurRatio: 0,
            shadowOpacity: 0,
            shadowOffsetRatio: 0
        )
    }

    private func prepare(_ canvas: EditableAnnotationCanvasNSView) throws -> CGSize {
        let image = try image()
        let size = CGSize(width: image.width, height: image.height)
        canvas.image = image
        canvas.lastImageSize = size
        return size
    }

    @Test func fitShowsTheWholeTreatedCanvas() throws {
        let canvas = makeCanvas()
        let size = try prepare(canvas)
        canvas.applyShareStyle(style())

        let frame = canvas.canvasRect(for: size)
        let content = canvas.imageRect(for: size)

        #expect(canvas.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame))
        #expect(frame.contains(content))
        #expect(content.width < frame.width)
        #expect(content.height < frame.height)
        // Image 1000×500 → reference 900 → padding 90 → canvas 1180×680.
        // Fit into 800×600 scales by 800/1180, so the content is ~678 wide.
        #expect(abs(content.width - 677.966) < 0.5)
    }

    @Test func paddingIsOutsideTheImageRect() throws {
        let canvas = makeCanvas()
        let size = try prepare(canvas)
        canvas.applyShareStyle(style())

        let frame = canvas.canvasRect(for: size)
        let content = canvas.imageDisplayRect

        #expect(!content.contains(CGPoint(x: frame.minX + 2, y: frame.midY)))
        #expect(content.contains(CGPoint(x: content.minX + 1, y: content.midY)))
        #expect(frame.contains(CGPoint(x: content.maxX + 2, y: content.midY)))
    }

    @Test func actualSizeUsesImagePixels() throws {
        let canvas = makeCanvas()
        let size = try prepare(canvas)
        canvas.applyShareStyle(style())

        canvas.actualSizeZoom()

        #expect(abs(canvas.imageDisplayRect.width - size.width) < 1)
        #expect(canvas.zoomScale > 1)
    }

    @Test func actualSizeReachesOneToOneForALargeCapture() throws {
        let canvas = makeCanvas(size: CGSize(width: 700, height: 500))
        let image = try image(width: 5120, height: 2880)
        canvas.image = image
        canvas.lastImageSize = CGSize(width: 5120, height: 2880)
        canvas.applyShareStyle(style(padding: 0.08))

        canvas.actualSizeZoom()

        // Needs ~8.5× once padding is included; an 8× cap would land at ~92%.
        #expect(abs(canvas.imageDisplayRect.width - 5120) < 2)
        #expect(canvas.zoomScale > 8)
    }

    @Test func zoomAnchorKeepsTheImagePoint() throws {
        let canvas = makeCanvas()
        _ = try prepare(canvas)
        canvas.applyShareStyle(style())

        let anchor = CGPoint(x: canvas.bounds.midX + 60, y: canvas.bounds.midY - 40)
        let before = canvas.normalizedPoint(anchor)
        canvas.applyZoom(2, around: anchor)
        let after = canvas.normalizedPoint(anchor)

        #expect(abs(before.x - after.x) < 0.005)
        #expect(abs(before.y - after.y) < 0.005)
    }

    @Test func togglingTreatmentAtFitShowsTheWholeCard() throws {
        let canvas = makeCanvas()
        let size = try prepare(canvas)
        let bare = canvas.imageRect(for: size)
        canvas.imageDisplayRect = bare

        canvas.applyShareStyle(style())

        // At fit the card, not the bare image, is fitted: nothing is clipped.
        let frame = canvas.canvasRect(for: size)
        #expect(canvas.zoomScale == 1)
        #expect(canvas.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame))
        #expect(canvas.imageDisplayRect.width < bare.width)

        canvas.applyShareStyle(nil)
        #expect(canvas.zoomScale == 1)
        #expect(abs(canvas.imageDisplayRect.width - bare.width) < 1)
    }

    @Test func togglingTreatmentWhileZoomedKeepsTheImageWidth() throws {
        let canvas = makeCanvas()
        let size = try prepare(canvas)
        canvas.imageDisplayRect = canvas.imageRect(for: size)
        canvas.applyShareStyle(style())
        canvas.applyZoom(2, around: nil)
        let zoomedWidth = canvas.imageDisplayRect.width

        canvas.applyShareStyle(nil)

        #expect(canvas.zoomScale > 1)
        #expect(abs(canvas.imageDisplayRect.width - zoomedWidth) < 1)
    }

    @Test func togglingTreatmentPreservesDeepZoom() throws {
        let canvas = makeCanvas()
        let size = try prepare(canvas)
        canvas.imageDisplayRect = canvas.imageRect(for: size)
        canvas.applyShareStyle(style())
        canvas.applyZoom(12, around: nil)
        let zoomedWidth = canvas.imageDisplayRect.width

        canvas.applyShareStyle(nil)

        // Removing padding shrinks the fit, so the relative zoom legitimately
        // drops; the image width must not. The old preserve path clamped the
        // relative zoom at 8× and would shrink the image.
        #expect(canvas.zoomScale > 8)
        #expect(abs(canvas.imageDisplayRect.width - zoomedWidth) < 1)
    }

    @Test func editingTheStyleKeepsTheCurrentZoom() throws {
        let canvas = makeCanvas()
        _ = try prepare(canvas)
        canvas.applyShareStyle(style())
        canvas.applyZoom(2, around: nil)
        let zoomed = canvas.imageDisplayRect

        canvas.applyShareStyle(style(padding: 0.05))

        #expect(abs(canvas.zoomScale - 2) < 0.001)
        #expect(abs(canvas.imageDisplayRect.midX - zoomed.midX) < 0.5)
        #expect(abs(canvas.imageDisplayRect.midY - zoomed.midY) < 0.5)
    }

    @Test func panClampUsesTheCanvasFrame() throws {
        let canvas = makeCanvas()
        let size = try prepare(canvas)
        canvas.applyShareStyle(style())

        // Exercise the layout path, not `clampedPan` in isolation: the bug was
        // the call site clamping against the image rect instead of the frame.
        canvas.zoomScale = 2
        canvas.panOffset = CGSize(width: 10_000, height: 10_000)
        _ = canvas.canvasRect(for: size)

        let fit = canvas.fitCanvasRect(for: size)
        #expect(abs(canvas.panOffset.width - (fit.width * 2 - canvas.bounds.width) / 2) < 0.5)
        #expect(abs(canvas.panOffset.height - (fit.height * 2 - canvas.bounds.height) / 2) < 0.5)
    }

    @Test func normalizedCoordinatesRoundTripAtHighZoom() throws {
        let canvas = makeCanvas()
        _ = try prepare(canvas)
        canvas.applyShareStyle(style())
        canvas.applyZoom(8, around: nil)

        let normalized = CGPoint(x: 0.32, y: 0.61)
        let viewPoint = canvas.viewPoint(from: normalized)
        let roundTrip = canvas.normalizedPoint(viewPoint)

        #expect(abs(roundTrip.x - normalized.x) < 0.001)
        #expect(abs(roundTrip.y - normalized.y) < 0.001)
    }

    @Test func cropRectStaysInsideTheImageRect() throws {
        let canvas = makeCanvas()
        _ = try prepare(canvas)
        canvas.applyShareStyle(style())
        canvas.applyZoom(2, around: nil)

        let crop = CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6)
        let viewRect = canvas.viewRect(from: crop)

        #expect(canvas.imageDisplayRect.insetBy(dx: -0.5, dy: -0.5).contains(viewRect))
        #expect(abs(viewRect.width - canvas.imageDisplayRect.width * crop.width) < 0.5)
        #expect(abs(viewRect.height - canvas.imageDisplayRect.height * crop.height) < 0.5)
    }

    @Test func resetZoomShowsTheWholeFrame() throws {
        let canvas = makeCanvas()
        let size = try prepare(canvas)
        canvas.applyShareStyle(style())
        canvas.applyZoom(3, around: nil)

        canvas.resetZoom()

        let frame = canvas.canvasRect(for: size)
        #expect(canvas.zoomScale == 1)
        #expect(canvas.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame))
    }
}
