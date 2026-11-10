import CoreGraphics
import Testing
@testable import CaptureCore

struct WindowCapturePlanTests {
    private let mainDisplay = WindowCaptureDisplay(
        displayID: 1,
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        pixelSize: CGSize(width: 2880, height: 1800)
    )

    private let secondaryDisplay = WindowCaptureDisplay(
        displayID: 2,
        frame: CGRect(x: 1440, y: 0, width: 1280, height: 800),
        pixelSize: CGSize(width: 1280, height: 800)
    )

    @Test func desktopIndependentPlanKeepsTheWholeWindow() {
        let plan = WindowCapturePlan.make(
            windowID: 42,
            windowFrame: CGRect(x: 200, y: 120, width: 900, height: 600),
            displays: [mainDisplay],
            usesDesktopIndependentWindow: true
        )

        #expect(plan?.strategy == .desktopIndependentWindow)
        #expect(plan?.contentRect == CGRect(x: 200, y: 120, width: 900, height: 600))
        #expect(plan?.outputPixelSize == CGSize(width: 1800, height: 1200))
        #expect(plan?.pointPixelScale == 2)
        #expect(plan?.displayID == 1)
        #expect(plan?.isCrossDisplay == false)
        #expect(plan?.segments.isEmpty == true)
    }

    @Test func desktopIndependentPlanMarksCrossDisplayWindows() {
        let plan = WindowCapturePlan.make(
            windowID: 42,
            windowFrame: CGRect(x: 1200, y: 100, width: 600, height: 500),
            displays: [mainDisplay, secondaryDisplay],
            usesDesktopIndependentWindow: true
        )

        #expect(plan?.strategy == .desktopIndependentWindow)
        #expect(plan?.isCrossDisplay == true)
        // The secondary display owns the larger visible slice, so it supplies
        // the metadata display. The actual 14+ capture uses filter.contentRect
        // and filter.pointPixelScale rather than this estimate.
        #expect(plan?.displayID == 2)
        #expect(plan?.outputPixelSize == CGSize(width: 600, height: 500))
    }

    @Test func singleDisplayPlanUsesVisibleRectForPartiallyOffscreenWindow() {
        let plan = WindowCapturePlan.make(
            windowID: 42,
            windowFrame: CGRect(x: 1300, y: 100, width: 600, height: 400),
            displays: [mainDisplay],
            usesDesktopIndependentWindow: false
        )

        #expect(plan?.strategy == .singleDisplaySourceRect)
        #expect(plan?.contentRect == CGRect(x: 1300, y: 100, width: 140, height: 400))
        #expect(plan?.outputPixelSize == CGSize(width: 280, height: 800))
        #expect(plan?.segments.count == 1)
        #expect(plan?.segments.first?.sourceRect == CGRect(x: 1300, y: 100, width: 140, height: 400))
        #expect(plan?.segments.first?.capturePixelSize == CGSize(width: 280, height: 800))
        #expect(plan?.segments.first?.outputOrigin == .zero)
    }

    @Test func segmentedPlanStitchesMixedScaleSlicesWithoutGaps() {
        let plan = WindowCapturePlan.make(
            windowID: 42,
            windowFrame: CGRect(x: 1200, y: 100, width: 1600, height: 700),
            displays: [mainDisplay, secondaryDisplay],
            usesDesktopIndependentWindow: false
        )

        #expect(plan?.strategy == .displaySegments)
        #expect(plan?.isCrossDisplay == true)
        #expect(plan?.contentRect == CGRect(x: 1200, y: 100, width: 1520, height: 700))
        #expect(plan?.outputPixelSize == CGSize(width: 3040, height: 1400))
        #expect(plan?.segments.count == 2)

        let mainSlice = plan?.segments.first(where: { $0.displayID == 1 })
        #expect(mainSlice?.sourceRect == CGRect(x: 1200, y: 100, width: 240, height: 700))
        #expect(mainSlice?.capturePixelSize == CGSize(width: 480, height: 1400))
        #expect(mainSlice?.outputPixelSize == CGSize(width: 480, height: 1400))
        #expect(mainSlice?.outputOrigin == .zero)

        let secondarySlice = plan?.segments.first(where: { $0.displayID == 2 })
        #expect(secondarySlice?.sourceRect == CGRect(x: 0, y: 100, width: 1280, height: 700))
        #expect(secondarySlice?.capturePixelSize == CGSize(width: 1280, height: 700))
        #expect(secondarySlice?.outputPixelSize == CGSize(width: 2560, height: 1400))
        #expect(secondarySlice?.outputOrigin == CGPoint(x: 480, y: 0))
    }

    @Test func thumbnailPlanScalesSegmentsWithoutCroppingContent() throws {
        let plan = try #require(WindowCapturePlan.make(
            windowID: 42,
            windowFrame: CGRect(x: 1200, y: 100, width: 1600, height: 700),
            displays: [mainDisplay, secondaryDisplay],
            usesDesktopIndependentWindow: false
        ))
        let thumbnail = plan.scaledForThumbnail(
            maxPixelSize: CGSize(width: 760, height: 380)
        )

        #expect(thumbnail.contentRect == plan.contentRect)
        #expect(thumbnail.outputPixelSize.width <= 760)
        #expect(thumbnail.outputPixelSize.height <= 380)
        #expect(thumbnail.segments.count == plan.segments.count)
        #expect(thumbnail.segments.allSatisfy { $0.sourceRect.width > 0 })
        #expect(thumbnail.segments.first(where: { $0.displayID == 1 })?.outputOrigin.x == 0)
    }

    @Test func duplicateDisplaysAreDeduplicated() {
        let duplicate = WindowCaptureDisplay(
            displayID: 99,
            frame: mainDisplay.frame,
            pixelSize: mainDisplay.pixelSize
        )
        let plan = WindowCapturePlan.make(
            windowID: 42,
            windowFrame: CGRect(x: 200, y: 120, width: 900, height: 600),
            displays: [mainDisplay, duplicate],
            usesDesktopIndependentWindow: true
        )

        #expect(plan?.segments.isEmpty == true)
        #expect(plan?.displayID == 1)
    }

    @Test func highResolutionOffForcesOneXOutput() {
        let plan = WindowCapturePlan.make(
            windowID: 42,
            windowFrame: CGRect(x: 200, y: 120, width: 900, height: 600),
            displays: [mainDisplay],
            usesDesktopIndependentWindow: false,
            highResolution: false
        )

        #expect(plan?.pointPixelScale == 1)
        #expect(plan?.outputPixelSize == CGSize(width: 900, height: 600))
        #expect(plan?.segments.first?.pixelScale == 1)
    }

    @Test func macOS13PlanRejectsFullyOffscreenWindow() {
        let plan = WindowCapturePlan.make(
            windowID: 42,
            windowFrame: CGRect(x: 4000, y: 2000, width: 600, height: 400),
            displays: [mainDisplay],
            usesDesktopIndependentWindow: false
        )

        #expect(plan == nil)
    }

    @Test func thumbnailOutputSizeNeverUpscales() {
        let size = SCKAdapter.thumbnailOutputSize(
            contentPixelSize: CGSize(width: 800, height: 600),
            maximumPixelSize: CGSize(width: 240, height: 140)
        )

        #expect(size.width <= 240)
        #expect(size.height <= 140)
        #expect(abs(size.width / size.height - 800 / 600) < 0.02)
    }

    @Test func thumbnailOutputSizeKeepsSmallContentAtNativeSize() {
        let size = SCKAdapter.thumbnailOutputSize(
            contentPixelSize: CGSize(width: 120, height: 80),
            maximumPixelSize: CGSize(width: 240, height: 140)
        )

        #expect(size == CGSize(width: 120, height: 80))
    }
}
