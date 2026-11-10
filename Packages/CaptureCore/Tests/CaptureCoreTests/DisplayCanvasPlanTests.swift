import CoreGraphics
import Testing
@testable import CaptureCore

struct DisplayCanvasPlanTests {
    private let main = DisplayCanvasDisplay(
        displayID: 1,
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        pixelSize: CGSize(width: 2880, height: 1800)
    )
    private let secondary = DisplayCanvasDisplay(
        displayID: 2,
        frame: CGRect(x: 1440, y: 0, width: 1280, height: 800),
        pixelSize: CGSize(width: 1280, height: 800)
    )
    private let tertiary = DisplayCanvasDisplay(
        displayID: 3,
        frame: CGRect(x: 2720, y: 0, width: 1920, height: 1080),
        pixelSize: CGSize(width: 1920, height: 1080)
    )

    @Test func compactHorizontalAlignsEdgesWithNoGap() {
        let plan = DisplayCanvasPlan.make(
            displays: [tertiary, main, secondary],
            mode: .compactHorizontal
        )

        #expect(plan?.canvasSize == CGSize(width: 4640, height: 1080))
        #expect(plan?.outputPixelSize == CGSize(width: 9280, height: 2160))
        #expect(plan?.commonScale == 2)
        #expect(plan?.placements.map(\.displayID) == [1, 2, 3])
        #expect(plan?.placements.map(\.canvasOrigin.x) == [0, 1440, 2720])
        #expect(plan?.placements[1].outputPixelSize == CGSize(width: 2560, height: 1600))
        #expect(plan?.isIrregular == false)
    }

    @Test func compactHorizontalHonorsOptionalGap() {
        let plan = DisplayCanvasPlan.make(
            displays: [main, secondary],
            mode: .compactHorizontal,
            gap: 16
        )

        #expect(plan?.canvasSize == CGSize(width: 2736, height: 900))
        #expect(plan?.placements[1].canvasOrigin.x == 1456)
    }

    @Test func compactVerticalStacksDisplays() {
        let plan = DisplayCanvasPlan.make(
            displays: [main, secondary],
            mode: .compactVertical
        )

        #expect(plan?.canvasSize == CGSize(width: 1440, height: 1700))
        #expect(plan?.outputPixelSize == CGSize(width: 2880, height: 3400))
        #expect(plan?.placements[1].canvasOrigin.y == 900)
    }

    @Test func physicalModeKeepsRelativePositionAndMarksLShape() {
        let below = DisplayCanvasDisplay(
            displayID: 2,
            frame: CGRect(x: 0, y: 900, width: 1280, height: 800),
            pixelSize: CGSize(width: 1280, height: 800)
        )
        let plan = DisplayCanvasPlan.make(
            displays: [main, below],
            mode: .physical
        )

        #expect(plan?.canvasSize == CGSize(width: 1440, height: 1700))
        #expect(plan?.isIrregular == true)
        #expect(plan?.placements[1].canvasOrigin == CGPoint(x: 0, y: 900))
        #expect(plan?.placements[1].outputPixelSize == CGSize(width: 2560, height: 1600))
    }

    @Test func duplicateDisplaysAreDeduplicatedForMirrors() {
        let duplicate = DisplayCanvasDisplay(
            displayID: 99,
            frame: main.frame,
            pixelSize: main.pixelSize
        )
        let plan = DisplayCanvasPlan.make(
            displays: [main, duplicate],
            mode: .compactHorizontal
        )

        #expect(plan?.placements.count == 1)
        #expect(plan?.placements.first?.displayID == 1)
    }

    @Test func highResolutionOffForcesOneX() {
        let plan = DisplayCanvasPlan.make(
            displays: [main, secondary],
            mode: .compactHorizontal,
            highResolution: false
        )

        #expect(plan?.commonScale == 1)
        #expect(plan?.outputPixelSize == CGSize(width: 2720, height: 900))
    }

    @Test func composerPlacesDisplaysWithoutCropping() throws {
        let left = try makeImage(
            red: 1, green: 0, blue: 0, alpha: 1,
            size: CGSize(width: 100, height: 100)
        )
        let right = try makeImage(
            red: 0, green: 0, blue: 1, alpha: 1,
            size: CGSize(width: 100, height: 100)
        )
        let leftDisplay = DisplayCanvasDisplay(
            displayID: 1,
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            pixelSize: CGSize(width: 100, height: 100)
        )
        let rightDisplay = DisplayCanvasDisplay(
            displayID: 2,
            frame: CGRect(x: 100, y: 0, width: 100, height: 100),
            pixelSize: CGSize(width: 100, height: 100)
        )
        let plan = try #require(DisplayCanvasPlan.make(
            displays: [leftDisplay, rightDisplay],
            mode: .compactHorizontal,
            highResolution: false
        ))
        let image = try #require(DisplayCanvasComposer.compose(
            images: [1: left, 2: right],
            plan: plan
        ))

        #expect(image.width == 200)
        #expect(image.height == 100)
        #expect(color(atX: 10, y: 50, in: image).red > 0.9)
        #expect(color(atX: 190, y: 50, in: image).blue > 0.9)
    }

    private func makeImage(
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat,
        alpha: CGFloat,
        size: CGSize
    ) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(
            red: red,
            green: green,
            blue: blue,
            alpha: alpha
        ))
        context.fill(CGRect(origin: .zero, size: size))
        return try #require(context.makeImage())
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
