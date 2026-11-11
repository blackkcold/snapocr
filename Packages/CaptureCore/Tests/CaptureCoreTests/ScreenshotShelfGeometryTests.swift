import CoreGraphics
import SharedKit
import Testing

@testable import CaptureCore

struct ScreenshotShelfGeometryTests {
    private let metrics = ScreenshotShelfMetrics()

    @Test func topCenterSitsBelowTheMenuBarAndAboveTheCardRow() {
        let visibleFrame = CGRect(x: 100, y: 50, width: 1_000, height: 700)
        let frame = ScreenshotShelfGeometry.panelFrame(
            visibleFrame: visibleFrame,
            cardWidths: [160, 240],
            cardHeight: 96,
            anchor: .top,
            metrics: metrics
        )

        // Visual content: 160 + 240 + 12 spacing + 28 menu = 440; panel adds 16 pt shadow each side.
        #expect(frame.width == 472)
        #expect(frame.height == 142)
        #expect(frame.midX == visibleFrame.midX)
        #expect(frame.maxY == visibleFrame.maxY - 8)
        #expect(frame.minY == visibleFrame.maxY - 150)

        // Rail is 16 pt below the usable top; card top is 22 pt below the rail.
        let railY = frame.maxY - metrics.topInset
        #expect(railY == visibleFrame.maxY - 16)
        let cardTopY = frame.maxY - metrics.cardTopOffset
        #expect(cardTopY == railY - (metrics.railZone + metrics.railGap))
    }

    @Test func allAnchorsKeepThePanelInsideTheUsableFrame() {
        let visibleFrame = CGRect(x: 100, y: 50, width: 1_000, height: 700)
        for anchor in ScreenshotShelfAnchor.allCases {
            let frame = ScreenshotShelfGeometry.panelFrame(
                visibleFrame: visibleFrame,
                cardWidths: [160, 240],
                cardHeight: 96,
                anchor: anchor,
                metrics: metrics
            )
            #expect(frame.minX >= visibleFrame.minX - 0.5, "\(anchor)")
            #expect(frame.maxX <= visibleFrame.maxX + 0.5, "\(anchor)")
            #expect(frame.minY >= visibleFrame.minY - 0.5, "\(anchor)")
            #expect(frame.maxY <= visibleFrame.maxY + 0.5, "\(anchor)")
        }
    }

    @Test func leadingAndTrailingAnchorsSitFlushWithTheUsableEdges() {
        let visibleFrame = CGRect(x: 100, y: 50, width: 1_000, height: 700)
        let leading = ScreenshotShelfGeometry.panelFrame(
            visibleFrame: visibleFrame,
            cardWidths: [160, 240],
            cardHeight: 96,
            anchor: .topLeading,
            metrics: metrics
        )
        let trailing = ScreenshotShelfGeometry.panelFrame(
            visibleFrame: visibleFrame,
            cardWidths: [160, 240],
            cardHeight: 96,
            anchor: .topTrailing,
            metrics: metrics
        )

        #expect(leading.minX == visibleFrame.minX)
        #expect(trailing.maxX == visibleFrame.maxX)
    }

    @Test func effectiveVisibleFrameReservesOnlyTheAutoHiddenMenuBar() {
        let screen = CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        let effective = ScreenshotShelfGeometry.effectiveVisibleFrame(
            visibleFrame: screen,
            screenFrame: screen
        )

        // The top anchor no longer needs Dock reveal room, only the 28 pt menu-bar reveal.
        #expect(effective.minY == 0)
        #expect(effective.maxY == 972)
    }

    @Test func effectiveVisibleFrameLeavesVisibleBarsAlone() {
        let screen = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let visible = CGRect(x: 0, y: 85, width: 1_440, height: 785)

        #expect(
            ScreenshotShelfGeometry.effectiveVisibleFrame(
                visibleFrame: visible,
                screenFrame: screen
            ) == visible
        )
    }

    @Test func sixCardsAtMaximumHeightFitWithoutOverflowingTheScreen() {
        let naturalWidths = Array(repeating: CGFloat(284.4), count: 6)
        let visibleWidth: CGFloat = 1_470
        let fitted = ScreenshotShelfGeometry.fittedCardWidths(
            naturalWidths: naturalWidths,
            availableWidth: visibleWidth,
            metrics: metrics
        )

        #expect(fitted.count == 6)
        let contentWidth = fitted.reduce(0, +)
            + metrics.cardSpacing * 5
            + metrics.endMenuWidth
        #expect(contentWidth <= visibleWidth - metrics.screenMargin * 2 + 0.5)
        #expect(fitted.allSatisfy { $0 > 0 })

        let frame = ScreenshotShelfGeometry.panelFrame(
            visibleFrame: CGRect(x: 0, y: 0, width: visibleWidth, height: 900),
            cardWidths: fitted,
            cardHeight: 160,
            anchor: .top,
            metrics: metrics
        )
        #expect(frame.width <= visibleWidth)
    }

    @Test func veryNarrowDisplaysStillReturnAPositivePanelWidth() {
        let fitted = ScreenshotShelfGeometry.fittedCardWidths(
            naturalWidths: [180, 220, 140],
            availableWidth: 300,
            metrics: metrics
        )
        #expect(fitted.count == 3)
        #expect(fitted.allSatisfy { $0 >= 1 })

        let frame = ScreenshotShelfGeometry.panelFrame(
            visibleFrame: CGRect(x: 50, y: 20, width: 300, height: 600),
            cardWidths: fitted,
            cardHeight: 96,
            anchor: .top,
            metrics: metrics
        )
        #expect(frame.width > 0)
        #expect(frame.width <= 300)
        #expect(frame.height == 142)
    }

    @Test func invalidGeometryReturnsZero() {
        #expect(
            ScreenshotShelfGeometry.panelFrame(
                visibleFrame: CGRect(x: 10, y: 20, width: 20, height: 100),
                cardWidths: [80],
                cardHeight: 40,
                anchor: .top,
                metrics: metrics
            ) == .zero
        )
        #expect(
            ScreenshotShelfGeometry.fittedCardWidths(
                naturalWidths: [80],
                availableWidth: 0,
                metrics: metrics
            ) == []
        )
        #expect(
            ScreenshotShelfGeometry.collapsedFrame(
                expandedFrame: .zero
            ) == .zero
        )
    }

    @Test func dragPreviewFrameReservesRoomForHangerAndPadding() {
        let frame = ScreenshotShelfGeometry.dragPreviewFrame(
            cardTopLeft: CGPoint(x: 100, y: 700),
            cardWidth: 200,
            cardHeight: 150,
            padding: 32,
            hangerHeight: 23
        )

        #expect(frame == CGRect(x: 68, y: 518, width: 264, height: 237))
        #expect(frame.minX + 32 == 100)
        #expect(frame.maxY - 32 - 23 == 700)
    }

    @Test func dragPreviewFrameRejectsInvalidInput() {
        #expect(
            ScreenshotShelfGeometry.dragPreviewFrame(
                cardTopLeft: .zero,
                cardWidth: 0,
                cardHeight: 150,
                padding: 32,
                hangerHeight: 23
            ) == .zero
        )
        #expect(
            ScreenshotShelfGeometry.dragPreviewFrame(
                cardTopLeft: .zero,
                cardWidth: 200,
                cardHeight: 150,
                padding: -1,
                hangerHeight: 23
            ) == .zero
        )
    }

    @Test func railLineMatchesTheHangingRingCentre() {
        #expect(metrics.railLineY == metrics.cardTopOffset - ScreenshotShelfMetrics.ringCenterAboveCard)
    }

    @Test func shelfScreenTopLeftFlipsAppKitYAxis() {
        let point = ScreenshotShelfGeometry.shelfScreenTopLeft(
            panelFrame: CGRect(x: 100, y: 500, width: 300, height: 200),
            localX: 20,
            localY: 30
        )
        #expect(point == CGPoint(x: 120, y: 670))
        #expect(
            ScreenshotShelfGeometry.shelfScreenTopLeft(
                panelFrame: .zero,
                localX: .infinity,
                localY: 0
            ) == .zero
        )
    }

    @Test func collapsedHandleStaysInsideTheExpandedFrameForAllAnchors() {
        let visibleFrame = CGRect(x: 100, y: 50, width: 1_000, height: 700)
        for anchor in ScreenshotShelfAnchor.allCases {
            let expanded = ScreenshotShelfGeometry.panelFrame(
                visibleFrame: visibleFrame,
                cardWidths: [160, 240],
                cardHeight: 96,
                anchor: anchor,
                metrics: metrics
            )
            let collapsed = ScreenshotShelfGeometry.collapsedFrame(expandedFrame: expanded)

            #expect(collapsed.maxY == expanded.maxY, "\(anchor)")
            #expect(collapsed.midX == expanded.midX, "\(anchor)")
            #expect(collapsed.width == ScreenshotShelfMetrics.collapsedHandleWidth, "\(anchor)")
            #expect(collapsed.height == ScreenshotShelfMetrics.collapsedHandleHeight, "\(anchor)")
            #expect(collapsed.minX >= expanded.minX - 0.5, "\(anchor)")
            #expect(collapsed.maxX <= expanded.maxX + 0.5, "\(anchor)")
            #expect(collapsed.minY >= expanded.minY - 0.5, "\(anchor)")
        }
    }
}
