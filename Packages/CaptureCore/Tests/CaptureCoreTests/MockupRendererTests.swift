import CoreGraphics
import Testing
@testable import CaptureCore

struct MockupRendererTests {
    @Test func outputSizeUsesReferenceEdge() {
        let style = MockupStyle(
            background: .solid(red: 1, green: 1, blue: 1),
            paddingRatio: 0.1
        )

        let size = MockupRenderer.outputSize(
            for: CGSize(width: 100, height: 100),
            style: style
        )

        #expect(size == CGSize(width: 120, height: 120))
    }

    @Test func longCaptureUsesShortEdgeAsReference() {
        let style = MockupStyle(
            background: .solid(red: 1, green: 1, blue: 1),
            paddingRatio: 0.1
        )

        let size = MockupRenderer.outputSize(
            for: CGSize(width: 200, height: 600),
            style: style
        )

        // R = min(600, 200 × 1.8) = 360; padding = 36.
        #expect(size == CGSize(width: 272, height: 672))
    }

    @Test func transparentPresetKeepsCornersClear() throws {
        let image = try makeImage(size: CGSize(width: 100, height: 100))
        let rendered = try #require(MockupRenderer.render(image, style: MockupPreset.transparent.style))

        #expect(alpha(atX: 1, y: 1, in: rendered) == 0)
        #expect(alpha(atX: rendered.width / 2, y: rendered.height / 2, in: rendered) > 0)
    }

    @Test func lightPresetPaintsItsBackground() throws {
        let image = try makeImage(size: CGSize(width: 100, height: 100))
        let rendered = try #require(MockupRenderer.render(image, style: MockupPreset.light.style))
        let corner = color(atX: 1, y: 1, in: rendered)

        #expect(corner.red > 0.9)
        #expect(corner.green > 0.9)
        #expect(corner.blue > 0.9)
    }

    @Test func everyPresetProducesAValidCanvas() throws {
        let image = try makeImage(size: CGSize(width: 120, height: 80))
        for preset in MockupPreset.allCases {
            let rendered = MockupRenderer.render(image, style: preset.style)
            #expect(rendered != nil)
            #expect((rendered?.width ?? 0) >= image.width)
            #expect((rendered?.height ?? 0) >= image.height)
        }
    }

    @Test func layoutMatchesThePaddedCanvas() {
        var style = MockupStyle(background: .solid(red: 0, green: 0, blue: 0))
        style.paddingRatio = 0.1
        style.cornerRadiusRatio = 0
        style.shadowOpacity = 0

        let layout = MockupRenderer.layout(
            for: CGSize(width: 100, height: 100),
            style: style
        )

        #expect(layout.referenceSide == 100)
        #expect(layout.canvasSize == CGSize(width: 120, height: 120))
        #expect(layout.contentRect == CGRect(x: 10, y: 10, width: 100, height: 100))
        #expect(layout.borderWidth == 0)
    }

    @Test func borderStaysInsideTheContentEdge() throws {
        let image = try makeImage(size: CGSize(width: 100, height: 100))
        let style = MockupStyle(
            background: .transparent,
            paddingRatio: 0,
            cornerRadiusRatio: 0,
            shadowBlurRatio: 0,
            shadowOpacity: 0,
            shadowOffsetRatio: 0,
            borderWidthRatio: 0.02,
            borderColor: .custom(red: 1, green: 0, blue: 0, alpha: 1)
        )

        let rendered = try #require(MockupRenderer.render(image, style: style))
        let edge = color(atX: 1, y: 50, in: rendered)
        let center = color(atX: 50, y: 50, in: rendered)

        #expect(rendered.width == 100)
        #expect(rendered.height == 100)
        #expect(edge.red > 0.7)
        #expect(edge.green < 0.25)
        #expect(center.blue > 0.5)
    }

    @Test func rawLayoutMatchesTheImage() {
        let layout = MockupLayout.raw(imageSize: CGSize(width: 300, height: 200))

        #expect(layout.imageSize == CGSize(width: 300, height: 200))
        #expect(layout.canvasSize == CGSize(width: 300, height: 200))
        #expect(layout.contentRect == CGRect(x: 0, y: 0, width: 300, height: 200))
        #expect(layout.padding == 0)
        #expect(layout.cornerRadius == 0)
        #expect(layout.borderWidth == 0)
        #expect(layout.shadow == MockupLayout.ShadowMetrics(blur: 0, offsetY: 0, opacity: 0))
    }

    @Test func rawLayoutSanitisesNonFiniteInput() {
        let layout = MockupLayout.raw(imageSize: CGSize(width: CGFloat.nan, height: 0))

        #expect(layout.canvasSize == CGSize(width: 1, height: 1))
        #expect(layout.contentRect == CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    @Test func drawClipsShadowToTheCanvas() throws {
        let image = try makeImage(size: CGSize(width: 100, height: 100))
        let style = MockupStyle(
            background: .transparent,
            paddingRatio: 0,
            cornerRadiusRatio: 0,
            shadowBlurRatio: 0.2,
            shadowOpacity: 0.8,
            shadowOffsetRatio: 0.02
        )
        let layout = MockupRenderer.layout(
            for: CGSize(width: 100, height: 100),
            style: style
        )
        let context = try #require(CGContext(
            data: nil,
            width: 300,
            height: 300,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))

        MockupRenderer.draw(
            image,
            style: style,
            layout: layout,
            in: context,
            origin: CGPoint(x: 100, y: 100),
            scale: 1
        )

        let rendered = try #require(context.makeImage())
        // The shadow would reach here without the canvas clip.
        #expect(color(atX: 95, y: 150, in: rendered).alpha == 0)
        #expect(color(atX: 150, y: 150, in: rendered).alpha > 0)
    }

    @Test func borderWidthIsClamped() {
        var style = MockupStyle(background: .transparent)
        style.borderWidthRatio = 0.02

        let small = MockupRenderer.layout(
            for: CGSize(width: 100, height: 100),
            style: style
        )
        let large = MockupRenderer.layout(
            for: CGSize(width: 1000, height: 1000),
            style: style
        )

        #expect(small.borderWidth == 2)
        #expect(large.borderWidth == 12)
    }

    @Test func borderFollowsOriginAndScale() throws {
        let image = try makeImage(size: CGSize(width: 100, height: 100))
        let style = MockupStyle(
            background: .transparent,
            paddingRatio: 0,
            cornerRadiusRatio: 0,
            shadowBlurRatio: 0,
            shadowOpacity: 0,
            shadowOffsetRatio: 0,
            borderWidthRatio: 0.02,
            borderColor: .custom(red: 1, green: 0, blue: 0, alpha: 1)
        )
        let layout = MockupRenderer.layout(
            for: CGSize(width: 100, height: 100),
            style: style
        )
        let context = try #require(CGContext(
            data: nil,
            width: 300,
            height: 300,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))

        MockupRenderer.draw(
            image,
            style: style,
            layout: layout,
            in: context,
            origin: CGPoint(x: 20, y: 30),
            scale: 2
        )

        let rendered = try #require(context.makeImage())
        let edge = color(atX: 21, y: 130, in: rendered)

        #expect(edge.red > 0.7)
        #expect(edge.green < 0.25)
    }

    @Test func drawPreservesCallerClipAndState() throws {
        let image = try makeImage(size: CGSize(width: 100, height: 100))
        let style = MockupStyle(
            background: .transparent,
            paddingRatio: 0,
            cornerRadiusRatio: 0,
            shadowBlurRatio: 0,
            shadowOpacity: 0,
            shadowOffsetRatio: 0
        )
        let layout = MockupRenderer.layout(
            for: CGSize(width: 100, height: 100),
            style: style
        )
        let context = try #require(CGContext(
            data: nil,
            width: 100,
            height: 100,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))

        context.saveGState()
        context.clip(to: CGRect(x: 0, y: 0, width: 10, height: 10))
        MockupRenderer.draw(image, style: style, layout: layout, in: context)
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        context.restoreGState()

        let rendered = try #require(context.makeImage())
        let outside = color(atX: 50, y: 50, in: rendered)

        #expect(outside.alpha == 0)
    }

    @Test func previewIsBoundedByMaximumDimension() throws {
        let image = try makeImage(size: CGSize(width: 400, height: 200))
        var style = MockupStyle(background: .solid(red: 1, green: 1, blue: 1))
        style.paddingRatio = 0.1

        let full = try #require(MockupRenderer.render(image, style: style))
        let preview = try #require(
            MockupRenderer.render(image, style: style, maximumDimension: 100)
        )

        #expect(full.width == 472)
        #expect(preview.width == 118)
        #expect(preview.height == 68)
    }

    private func makeImage(size: CGSize) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        return try #require(context.makeImage())
    }

    private func alpha(atX xPosition: Int, y yPosition: Int, in image: CGImage) -> CGFloat {
        color(atX: xPosition, y: yPosition, in: image).alpha
    }

    private struct PixelColor {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat
    }

    private func color(
        atX xPosition: Int,
        y yPosition: Int,
        in image: CGImage
    ) -> PixelColor {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.draw(
            image,
            in: CGRect(
                x: -CGFloat(xPosition),
                y: -CGFloat(image.height - 1 - yPosition),
                width: CGFloat(image.width),
                height: CGFloat(image.height)
            )
        )
        return PixelColor(
            red: CGFloat(pixel[0]) / 255,
            green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255,
            alpha: CGFloat(pixel[3]) / 255
        )
    }
}
