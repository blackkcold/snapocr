import CoreGraphics
import Testing

@testable import CaptureCore

struct ScreenshotShelfDragOutGeometryTests {
    private let panel = CGRect(x: 100, y: 200, width: 300, height: 120)

    @Test func pointsInsideThePanelAreNotOutside() {
        #expect(!ScreenshotShelfDragOutGeometry.isOutside(point: panel.center, panelFrame: panel))
        #expect(!ScreenshotShelfDragOutGeometry.isOutside(point: panel.origin, panelFrame: panel))
    }

    @Test func toleranceKeepsNearEdgePointsInside() {
        // 4 pt past the trailing edge, inside the default 6 pt hysteresis band.
        let nearEdge = CGPoint(x: panel.maxX + 4, y: panel.midY)
        #expect(!ScreenshotShelfDragOutGeometry.isOutside(point: nearEdge, panelFrame: panel))
    }

    @Test func pointsBeyondToleranceAreOutside() {
        let distance = 12.0
        let candidates = [
            CGPoint(x: panel.midX, y: panel.maxY + distance),
            CGPoint(x: panel.midX, y: panel.minY - distance),
            CGPoint(x: panel.minX - distance, y: panel.midY),
            CGPoint(x: panel.maxX + distance, y: panel.midY),
        ]

        for point in candidates {
            #expect(
                ScreenshotShelfDragOutGeometry.isOutside(point: point, panelFrame: panel),
                "\(point)"
            )
        }
    }

    @Test func zeroToleranceTreatsAnyExteriorPointAsOutside() {
        let justPastEdge = CGPoint(x: panel.maxX + 0.5, y: panel.midY)
        #expect(
            ScreenshotShelfDragOutGeometry.isOutside(
                point: justPastEdge,
                panelFrame: panel,
                tolerance: 0
            )
        )
    }

    @Test func negativeToleranceIsClampedToZero() {
        let justPastEdge = CGPoint(x: panel.maxX + 0.5, y: panel.midY)
        #expect(
            ScreenshotShelfDragOutGeometry.isOutside(
                point: justPastEdge,
                panelFrame: panel,
                tolerance: -20
            )
        )
    }

    @Test func nonFiniteInputIsNeverOutside() {
        #expect(
            !ScreenshotShelfDragOutGeometry.isOutside(
                point: CGPoint(x: .infinity, y: panel.midY),
                panelFrame: panel
            )
        )
        #expect(
            !ScreenshotShelfDragOutGeometry.isOutside(
                point: CGPoint(x: .nan, y: panel.midY),
                panelFrame: panel
            )
        )
    }

    @Test func degeneratePanelFrameIsNeverOutside() {
        #expect(
            !ScreenshotShelfDragOutGeometry.isOutside(
                point: .zero,
                panelFrame: CGRect(x: 0, y: 0, width: 0, height: 0)
            )
        )
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}
