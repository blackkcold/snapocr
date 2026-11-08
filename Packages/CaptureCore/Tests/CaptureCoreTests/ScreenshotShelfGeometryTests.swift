import CoreGraphics
import Testing

@testable import CaptureCore

struct ScreenshotShelfGeometryTests {
    @Test func panelIsCenteredAndPlacedBelowTheSafeTopEdge() {
        let frame = ScreenshotShelfGeometry.panelFrame(
            visibleFrame: CGRect(x: 100, y: 50, width: 1_000, height: 700),
            cardWidths: [160, 240],
            cardHeight: 96,
            spacing: 8,
            horizontalInset: 16,
            topInset: 12,
            verticalInset: 8
        )

        #expect(frame == CGRect(x: 380, y: 626, width: 440, height: 112))
    }

    @Test func narrowDisplayConstrainsViewportButPreservesScrollableCardContent() {
        let cardWidths: [CGFloat] = [180, 220, 140]
        let frame = ScreenshotShelfGeometry.panelFrame(
            visibleFrame: CGRect(x: 50, y: 20, width: 300, height: 600),
            cardWidths: cardWidths,
            cardHeight: 96,
            spacing: 8,
            horizontalInset: 16,
            topInset: 10,
            verticalInset: 8
        )
        let contentWidth = cardWidths.reduce(0, +) + 2 * 8 + 2 * 16

        #expect(frame.minX == 66)
        #expect(frame.maxX == 334)
        #expect(frame.width == 268)
        #expect(frame.width < contentWidth)
        #expect(frame.height == 112)
    }
}
