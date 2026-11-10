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
