import CoreGraphics
import Testing
@testable import CaptureCore

struct CaptureProtocolTests {
    @Test func captureOptions_defaults() {
        let options = CaptureOptions()
        #expect(options.includeCursor)
        #expect(options.highResolution)
        #expect(options.preferredScaleFactor == 2.0)
    }

    @Test func captureOptions_customValues() {
        let options = CaptureOptions(includeCursor: false, highResolution: false, preferredScaleFactor: 1.0)
        #expect(!options.includeCursor)
        #expect(!options.highResolution)
        #expect(options.preferredScaleFactor == 1.0)
    }

    @Test func captureOptions_standardResolutionUsesOnePointPerPixel() {
        let options = CaptureOptions(highResolution: false, preferredScaleFactor: 1.0)
        #expect(!options.highResolution)
        #expect(options.preferredScaleFactor == 1.0)
    }

    @Test func captureDisplayInfo_storesValues() {
        let frame = CGRect(x: 1, y: 2, width: 300, height: 200)
        let info = CaptureDisplayInfo(displayID: 42, scaleFactor: 2.0, frame: frame)
        #expect(info.displayID == 42)
        #expect(info.scaleFactor == 2.0)
        #expect(info.frame == frame)
    }

    @Test func pixelScale_usesCapturedPixelWidth() {
        let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        #expect(SCKAdapter.pixelScale(imageWidth: 1920, displayFrame: frame) == 1)
        #expect(SCKAdapter.pixelScale(imageWidth: 3840, displayFrame: frame) == 2)
    }

    @Test func pixelCropRect_convertsDisplayPointsToPixels() {
        let display = CGRect(x: 100, y: 50, width: 1000, height: 800)
        let area = CGRect(x: 200, y: 150, width: 300, height: 200)

        let crop = SCKAdapter.pixelCropRect(
            areaRect: area,
            displayFrame: display,
            imageSize: CGSize(width: 2000, height: 1600)
        )

        #expect(crop == CGRect(x: 200, y: 1000, width: 600, height: 400))
    }

    @Test func pixelCropRect_rejectsCrossDisplayArea() {
        let display = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let crossingArea = CGRect(x: 900, y: 100, width: 200, height: 200)

        let crop = SCKAdapter.pixelCropRect(
            areaRect: crossingArea,
            displayFrame: display,
            imageSize: CGSize(width: 2000, height: 1600)
        )

        #expect(crop == nil)
    }

    @Test func freeformMaskPreservesSizeAndAddsAlpha() throws {
        let source = try makeOpaqueImage(width: 20, height: 10)
        let masked = try SelectionMaskProcessor.apply(
            to: source,
            normalizedPath: [
                CGPoint(x: 0.2, y: 0.2),
                CGPoint(x: 0.8, y: 0.2),
                CGPoint(x: 0.5, y: 0.8),
            ]
        )

        #expect(masked.width == source.width)
        #expect(masked.height == source.height)
        #expect(masked.alphaInfo == .premultipliedLast)
        #expect(alpha(atX: 0, y: 0, in: masked) == 0)
        #expect(alpha(atX: 10, y: 5, in: masked) > 0)
    }

    private func makeOpaqueImage(width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw CaptureError.captureFailed(reason: "Unable to create test image")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw CaptureError.captureFailed(reason: "Unable to finalize test image")
        }
        return image
    }

    private func alpha(atX x: Int, y: Int, in image: CGImage) -> UInt8 {
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else {
            return 0
        }
        return bytes[y * image.bytesPerRow + x * 4 + 3]
    }
}
