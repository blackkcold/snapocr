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

        #expect(crop == CGRect(x: 200, y: 200, width: 600, height: 400))
    }

    @Test func pixelCropRect_handlesSecondaryDisplayAboveMain() {
        let display = CGRect(x: 0, y: -900, width: 1440, height: 900)
        let area = CGRect(x: 120, y: -700, width: 400, height: 250)

        let crop = SCKAdapter.pixelCropRect(
            areaRect: area,
            displayFrame: display,
            imageSize: CGSize(width: 2880, height: 1800)
        )

        #expect(crop == CGRect(x: 240, y: 400, width: 800, height: 500))
    }

    @Test func pixelCropRect_handlesSecondaryDisplayBelowMainAtOneX() {
        let display = CGRect(x: 0, y: 1080, width: 1920, height: 1080)
        let area = CGRect(x: 320, y: 1320, width: 640, height: 360)

        let crop = SCKAdapter.pixelCropRect(
            areaRect: area,
            displayFrame: display,
            imageSize: CGSize(width: 1920, height: 1080)
        )

        #expect(crop == CGRect(x: 320, y: 240, width: 640, height: 360))
    }

    @Test func pixelCropRect_usesIndependentMixedDisplayScale() {
        let display = CGRect(x: -1280, y: 0, width: 1280, height: 1024)
        let area = CGRect(x: -1180, y: 100, width: 500, height: 300)

        let crop = SCKAdapter.pixelCropRect(
            areaRect: area,
            displayFrame: display,
            imageSize: CGSize(width: 1280, height: 1024)
        )

        #expect(crop == CGRect(x: 100, y: 100, width: 500, height: 300))
    }

    @Test func quartzRect_convertsMainDisplayCoordinates() {
        let rect = ScreenCoordinateGeometry.quartzRect(
            from: CGRect(x: 100, y: 200, width: 300, height: 150),
            appKitScreenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            quartzScreenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )

        #expect(rect == CGRect(x: 100, y: 550, width: 300, height: 150))
    }

    @Test func quartzRect_convertsDisplayAboveMain() {
        let rect = ScreenCoordinateGeometry.quartzRect(
            from: CGRect(x: 80, y: 1020, width: 320, height: 180),
            appKitScreenFrame: CGRect(x: 0, y: 900, width: 1280, height: 1024),
            quartzScreenFrame: CGRect(x: 0, y: -1024, width: 1280, height: 1024)
        )

        #expect(rect == CGRect(x: 80, y: -300, width: 320, height: 180))
    }

    @Test func quartzRect_preservesDisplayLocalOffsetWhenOriginsDiffer() {
        let rect = ScreenCoordinateGeometry.quartzRect(
            from: CGRect(x: -1180, y: 100, width: 500, height: 300),
            appKitScreenFrame: CGRect(x: -1280, y: 0, width: 1280, height: 1024),
            quartzScreenFrame: CGRect(x: -1280, y: 0, width: 1280, height: 1024)
        )

        #expect(rect == CGRect(x: -1180, y: 624, width: 500, height: 300))
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

    @Test func windowCapturePolicyKeepsNormalApplicationWindows() {
        let candidate = WindowCaptureCandidate(
            bundleIdentifier: "com.example.browser",
            layer: 0,
            frame: CGRect(x: 20, y: 20, width: 1_200, height: 800),
            isOnScreen: true,
            windowTitle: "Settings — com.example.browser"
        )

        #expect(WindowCapturePolicy.isSelectable(
            candidate,
            currentBundleIdentifier: "com.snapglass.app",
            systemWindowLevel: 20
        ))
    }

    @Test func windowCapturePolicyRejectsBlankTitleWindows() {
        let blankTitle = WindowCaptureCandidate(
            bundleIdentifier: "com.example.helper",
            layer: 0,
            frame: CGRect(x: 0, y: 0, width: 900, height: 700),
            isOnScreen: true,
            windowTitle: "   "
        )
        let nilTitle = WindowCaptureCandidate(
            bundleIdentifier: "com.example.helper",
            layer: 0,
            frame: CGRect(x: 0, y: 0, width: 900, height: 700),
            isOnScreen: true,
            windowTitle: nil
        )

        #expect(!WindowCapturePolicy.isSelectable(
            blankTitle,
            currentBundleIdentifier: nil,
            systemWindowLevel: 20
        ))
        #expect(!WindowCapturePolicy.isSelectable(
            nilTitle,
            currentBundleIdentifier: nil,
            systemWindowLevel: 20
        ))
    }

    @Test func windowCapturePolicyRejectsWindowManagerTitles() {
        let ddpm = WindowCaptureCandidate(
            bundleIdentifier: "com.example.windowmanager",
            layer: 0,
            frame: CGRect(x: 0, y: 0, width: 900, height: 700),
            isOnScreen: true,
            windowTitle: "DDPM Window Manager"
        )
        let lowercasedDDPM = WindowCaptureCandidate(
            bundleIdentifier: "com.example.other",
            layer: 0,
            frame: CGRect(x: 0, y: 0, width: 900, height: 700),
            isOnScreen: true,
            windowTitle: "ddpm helper panel"
        )

        #expect(!WindowCapturePolicy.isSelectable(
            ddpm,
            currentBundleIdentifier: nil,
            systemWindowLevel: 20
        ))
        #expect(!WindowCapturePolicy.isSelectable(
            lowercasedDDPM,
            currentBundleIdentifier: nil,
            systemWindowLevel: 20
        ))
    }

    @Test func windowCapturePolicyRejectsSelfAndSystemUI() {
        let selfWindow = WindowCaptureCandidate(
            bundleIdentifier: "com.snapglass.app",
            layer: 0,
            frame: CGRect(x: 0, y: 0, width: 700, height: 500),
            isOnScreen: true,
            windowTitle: "SnapGlass"
        )
        let dockWindow = WindowCaptureCandidate(
            bundleIdentifier: "com.apple.dock",
            layer: 0,
            frame: CGRect(x: 0, y: 0, width: 900, height: 80),
            isOnScreen: true,
            windowTitle: "Dock"
        )
        let menuBarWindow = WindowCaptureCandidate(
            bundleIdentifier: "com.apple.WindowServer",
            layer: 24,
            frame: CGRect(x: 0, y: 0, width: 1_440, height: 28),
            isOnScreen: true,
            windowTitle: "Window Server"
        )

        #expect(!WindowCapturePolicy.isSelectable(
            selfWindow,
            currentBundleIdentifier: "com.snapglass.app",
            systemWindowLevel: 20
        ))
        #expect(!WindowCapturePolicy.isSelectable(
            dockWindow,
            currentBundleIdentifier: "com.snapglass.app",
            systemWindowLevel: 20
        ))
        #expect(!WindowCapturePolicy.isSelectable(
            menuBarWindow,
            currentBundleIdentifier: "com.snapglass.app",
            systemWindowLevel: 20
        ))
    }

    @Test func windowCapturePolicyRejectsTinyOrOffscreenWindows() {
        let tinyWindow = WindowCaptureCandidate(
            bundleIdentifier: "com.example.helper",
            layer: 0,
            frame: CGRect(x: 0, y: 0, width: 20, height: 20),
            isOnScreen: true,
            windowTitle: "Helper"
        )
        let offscreenWindow = WindowCaptureCandidate(
            bundleIdentifier: "com.example.browser",
            layer: 0,
            frame: CGRect(x: 0, y: 0, width: 900, height: 700),
            isOnScreen: false,
            windowTitle: "Browser"
        )

        #expect(!WindowCapturePolicy.isSelectable(
            tinyWindow,
            currentBundleIdentifier: nil,
            systemWindowLevel: 20
        ))
        #expect(!WindowCapturePolicy.isSelectable(
            offscreenWindow,
            currentBundleIdentifier: nil,
            systemWindowLevel: 20
        ))
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
