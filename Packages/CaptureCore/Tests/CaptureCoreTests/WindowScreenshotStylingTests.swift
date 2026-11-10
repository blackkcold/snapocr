import CoreGraphics
import Testing

@testable import CaptureCore

struct WindowScreenshotStylingTests {
    @Test func standardStyleScalesWithTheDisplay() {
        let style = WindowScreenshotStyling.Style.standard(scale: 2)

        #expect(style.cornerRadius == 20)
        #expect(style.padding == 28)
        #expect(style.shadowRadius == 20)
        #expect(style.shadowOffsetY == 6)
    }

    @Test func standardStyleFallsBackForInvalidScales() {
        let fallback = WindowScreenshotStyling.Style.standard(scale: 2)

        #expect(WindowScreenshotStyling.Style.standard(scale: 0).padding == fallback.padding)
        #expect(WindowScreenshotStyling.Style.standard(scale: .nan).padding == fallback.padding)
        #expect(
            WindowScreenshotStyling.Style.standard(scale: 99).padding
                == WindowScreenshotStyling.Style.standard(scale: 4).padding
        )
    }

    @Test func mockupStyleMatchesTheBakedWindowLook() throws {
        let image = try makeImage(width: 800, height: 600)
        let style = try #require(
            WindowScreenshotStyling.mockupStyle(for: image, scale: 2)
        )
        let reference = MockupRenderer.referenceSide(
            for: CGSize(width: 800, height: 600)
        )

        #expect(style.background == .transparent)
        #expect(abs(style.paddingRatio - 28 / reference) < 0.000_001)
        #expect(abs(style.cornerRadiusRatio - 20 / reference) < 0.000_001)
        #expect(abs(style.shadowOpacity - 0.28) < 0.000_001)

        let rendered = try #require(MockupRenderer.render(image, style: style))
        #expect(rendered.width == 856)
        #expect(rendered.height == 656)
    }

    @Test func applyGrowsTheCanvasByThePadding() throws {
        let image = try makeImage(width: 40, height: 30)
        let style = WindowScreenshotStyling.Style(
            cornerRadius: 8,
            padding: 6,
            shadowRadius: 4,
            shadowOpacity: 0.2,
            shadowOffsetY: 2
        )

        let output = try #require(WindowScreenshotStyling.apply(image, style: style))

        #expect(output.width == 52)
        #expect(output.height == 42)
    }

    @Test func applyIfNeededReturnsTheSameImageWhenDisabled() throws {
        let image = try makeImage(width: 20, height: 20)

        let output = WindowScreenshotStyling.applyIfNeeded(
            image,
            captureMode: .window(nil),
            isEnabled: false,
            isPinning: false,
            scale: 2
        )

        #expect(output === image)
    }

    @Test func applyIfNeededSkipsAreaCaptures() throws {
        let image = try makeImage(width: 20, height: 20)

        let output = WindowScreenshotStyling.applyIfNeeded(
            image,
            captureMode: .area(nil),
            isEnabled: true,
            isPinning: false,
            scale: 2
        )

        #expect(output === image)
    }

    @Test func applyIfNeededSkipsPinning() throws {
        let image = try makeImage(width: 20, height: 20)

        let output = WindowScreenshotStyling.applyIfNeeded(
            image,
            captureMode: .window(nil),
            isEnabled: true,
            isPinning: true,
            scale: 2
        )

        #expect(output === image)
    }

    @Test func applyIfNeededStylesWindowCaptures() throws {
        let image = try makeImage(width: 20, height: 20)

        let output = WindowScreenshotStyling.applyIfNeeded(
            image,
            captureMode: .window(nil),
            isEnabled: true,
            isPinning: false,
            scale: 2
        )

        #expect(output !== image)
        #expect(output.width == 20 + 28 * 2)
        #expect(output.height == 20 + 28 * 2)
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
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
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }
}
