import AppKit
import Testing

@MainActor
struct ScreenshotShelfDragImageRendererTests {
    @Test func imageMatchesTheCardSizePlusShadowPadding() throws {
        let cardSize = CGSize(width: 120, height: 90)
        let image = try #require(
            ScreenshotShelfDragImageRenderer.image(thumbnail: nil, cardSize: cardSize, scale: 2)
        )

        let padding = ScreenshotShelfDragImageRenderer.padding
        #expect(
            image.size
                == CGSize(
                    width: cardSize.width + padding * 2,
                    height: cardSize.height + padding * 2
                )
        )
    }

    @Test func imageIsRenderedAtTheRequestedScale() throws {
        let image = try #require(
            ScreenshotShelfDragImageRenderer.image(
                thumbnail: nil,
                cardSize: CGSize(width: 80, height: 60),
                scale: 2
            )
        )
        let representation = try #require(image.representations.first as? NSBitmapImageRep)

        #expect(representation.pixelsWide == Int((image.size.width * 2).rounded()))
        #expect(representation.pixelsHigh == Int((image.size.height * 2).rounded()))
    }

    @Test func aThumbnailProducesTheSameOuterSize() throws {
        let thumbnail = try makeThumbnail(width: 40, height: 30)
        let withThumbnail = try #require(
            ScreenshotShelfDragImageRenderer.image(
                thumbnail: thumbnail,
                cardSize: CGSize(width: 60, height: 45),
                scale: 1
            )
        )
        let withoutThumbnail = try #require(
            ScreenshotShelfDragImageRenderer.image(
                thumbnail: nil,
                cardSize: CGSize(width: 60, height: 45),
                scale: 1
            )
        )

        #expect(withThumbnail.size == withoutThumbnail.size)
    }

    @Test func zeroCardSizeReturnsNil() {
        #expect(
            ScreenshotShelfDragImageRenderer.image(
                thumbnail: nil,
                cardSize: .zero,
                scale: 2
            ) == nil
        )
    }

    @Test func nonPositiveScaleReturnsNil() {
        #expect(
            ScreenshotShelfDragImageRenderer.image(
                thumbnail: nil,
                cardSize: CGSize(width: 40, height: 30),
                scale: 0
            ) == nil
        )
    }

    private func makeThumbnail(width: Int, height: Int) throws -> CGImage {
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
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }
}
