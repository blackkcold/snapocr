import CoreGraphics
import Testing

@testable import CaptureCore

struct PinnedImageGeometryTests {
    @Test func initialFrameReusesSelectionRectForOriginalPosition() {
        let selection = CGRect(x: 300, y: 400, width: 500, height: 250)
        let frame = PinnedImageGeometry.initialPinFrame(
            appKitRect: selection,
            imageSize: CGSize(width: 1000, height: 500),
            displayScale: 2
        )

        #expect(frame == selection)
    }

    @Test func initialFrameFallsBackToScaledImageSizeWhenRectIsEmpty() {
        let frame = PinnedImageGeometry.initialPinFrame(
            appKitRect: .zero,
            imageSize: CGSize(width: 800, height: 400),
            displayScale: 2
        )

        #expect(frame == CGRect(x: 0, y: 0, width: 400, height: 200))
    }

    @Test func initialFrameDefaultsToOneWhenDisplayScaleIsInvalid() {
        let frame = PinnedImageGeometry.initialPinFrame(
            appKitRect: .zero,
            imageSize: CGSize(width: 800, height: 400),
            displayScale: 0
        )

        #expect(frame == CGRect(x: 0, y: 0, width: 800, height: 400))
    }

    @Test func displayScaleUsesPixelWidthOverPointWidth() {
        #expect(PinnedImageGeometry.displayScale(imagePixelWidth: 1000, pointWidth: 500) == 2)
        #expect(PinnedImageGeometry.displayScale(imagePixelWidth: 640, pointWidth: 640) == 1)
        #expect(PinnedImageGeometry.displayScale(imagePixelWidth: 1000.5, pointWidth: 500) == 2.001)
    }

    @Test func displayScaleFallsBackToOneForInvalidWidths() {
        #expect(PinnedImageGeometry.displayScale(imagePixelWidth: 0, pointWidth: 500) == 1)
        #expect(PinnedImageGeometry.displayScale(imagePixelWidth: 1000, pointWidth: 0) == 1)
    }

    @Test func cascadeOffsetGrowsDownRightAndIgnoresNegativeIndex() {
        #expect(PinnedImageGeometry.cascadeOffset(forIndex: 0) == .zero)
        #expect(PinnedImageGeometry.cascadeOffset(forIndex: 1) == CGPoint(x: 24, y: -24))
        #expect(PinnedImageGeometry.cascadeOffset(forIndex: 3) == CGPoint(x: 72, y: -72))
        #expect(PinnedImageGeometry.cascadeOffset(forIndex: -5) == .zero)
    }

    @Test func fitToScreenShrinksOversizedFrameAndCentersIt() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let oversized = CGRect(x: 0, y: 0, width: 4000, height: 2000)

        let fitted = PinnedImageGeometry.fitToScreen(oversized, screenFrame: screen)

        #expect(fitted.width <= screen.width * 0.9)
        #expect(fitted.height <= screen.height * 0.9)
        #expect(fitted.midX == screen.midX)
        #expect(fitted.midY == screen.midY)
        #expect(abs(fitted.width / fitted.height - 2) < 0.0001)
    }

    @Test func fitToScreenKeepsFrameAlreadyInside() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let inside = CGRect(x: 100, y: 100, width: 300, height: 200)

        let fitted = PinnedImageGeometry.fitToScreen(inside, screenFrame: screen)

        #expect(fitted.width == inside.width)
        #expect(fitted.height == inside.height)
    }

    @Test func fitToScreenReturnsFrameWhenScreenIsInvalid() {
        let frame = CGRect(x: 10, y: 20, width: 30, height: 40)
        #expect(PinnedImageGeometry.fitToScreen(frame, screenFrame: .zero) == frame)
    }

    @Test func clampedScaleRespectsBounds() {
        #expect(PinnedImageGeometry.clampedScale(0.01) == PinnedImageGeometry.minimumScale)
        #expect(PinnedImageGeometry.clampedScale(100) == PinnedImageGeometry.maximumScale)
        #expect(PinnedImageGeometry.clampedScale(1.5) == 1.5)
    }

    @Test func clampedOpacityRespectsBounds() {
        #expect(PinnedImageGeometry.clampedOpacity(0) == PinnedImageGeometry.minimumOpacity)
        #expect(PinnedImageGeometry.clampedOpacity(-1) == PinnedImageGeometry.minimumOpacity)
        #expect(PinnedImageGeometry.clampedOpacity(5) == PinnedImageGeometry.maximumOpacity)
        #expect(PinnedImageGeometry.clampedOpacity(0.5) == 0.5)
    }

    // MARK: - 缩放真源（由 frame 反推）

    @Test func scaleDerivesFromFrameWidth() {
        // 1000px 图、displayScale=2 → 1:1 时 frame 宽 500pt。
        #expect(
            PinnedImageGeometry.scale(frameWidth: 500, imagePixelWidth: 1000, displayScale: 2) == 1
        )
        #expect(
            PinnedImageGeometry.scale(frameWidth: 250, imagePixelWidth: 1000, displayScale: 2) == 0.5
        )
        #expect(
            PinnedImageGeometry.scale(frameWidth: 4000, imagePixelWidth: 1000, displayScale: 2) == 8
        )
    }

    @Test func scaleFallsBackToOneForInvalidInputs() {
        #expect(PinnedImageGeometry.scale(frameWidth: 0, imagePixelWidth: 1000, displayScale: 2) == 1)
        #expect(PinnedImageGeometry.scale(frameWidth: 500, imagePixelWidth: 0, displayScale: 2) == 1)
        #expect(PinnedImageGeometry.scale(frameWidth: 500, imagePixelWidth: 1000, displayScale: 0) == 1)
    }

    @Test func scaleStaysConsistentAfterFitToScreen() {
        // 回归既有缺陷：Fit to Screen 只改 frame，倍率必须随之变化而非停留在 1。
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let oversized = CGRect(x: 0, y: 0, width: 4000, height: 2000)
        let fitted = PinnedImageGeometry.fitToScreen(oversized, screenFrame: screen)

        let derived = PinnedImageGeometry.scale(
            frameWidth: fitted.width,
            imagePixelWidth: 8000,
            displayScale: 2
        )

        // 原 frame（4000pt）对应 1.0；适应屏幕后应显著小于 1。
        #expect(derived < 1)
        #expect(abs(derived - fitted.width / 4000) < 0.0001)
    }

    @Test func clampFrameToScaleRangePullsBackOversizedAndUndersized() {
        // 1000px 图、displayScale=2 → 小于 50pt 即低于 minimumScale(0.1)。
        let tiny = CGRect(x: 10, y: 20, width: 40, height: 20)
        let pulled = PinnedImageGeometry.clampFrameToScaleRange(
            tiny,
            imagePixelWidth: 1000,
            displayScale: 2
        )
        #expect(abs(pulled.width - 50) < 0.0001)
        #expect(abs(pulled.height - 25) < 0.0001)
        #expect(pulled.origin == tiny.origin)

        let huge = CGRect(x: 0, y: 0, width: 8000, height: 4000)
        let shrunk = PinnedImageGeometry.clampFrameToScaleRange(
            huge,
            imagePixelWidth: 1000,
            displayScale: 2
        )
        #expect(abs(shrunk.width - 4000) < 0.0001)
    }

    @Test func clampFrameToScaleRangeKeepsFrameAlreadyInside() {
        let frame = CGRect(x: 5, y: 5, width: 500, height: 250)
        #expect(
            PinnedImageGeometry.clampFrameToScaleRange(
                frame,
                imagePixelWidth: 1000,
                displayScale: 2
            ) == frame
        )
    }

    // MARK: - 对数滑杆映射

    @Test func logScalePositionMapsEndpointsToRange() {
        #expect(PinnedImageGeometry.logScalePosition(forScale: PinnedImageGeometry.minimumScale) == 0)
        #expect(PinnedImageGeometry.logScalePosition(forScale: PinnedImageGeometry.maximumScale) == 1)
        // 对数映射的中点是几何平均 sqrt(0.1 × 8) = 0.894，不是 1。这条断言专门
        // 防止有人误用「线性中点 = 1」的直觉。
        let geometricMean = (PinnedImageGeometry.minimumScale * PinnedImageGeometry.maximumScale)
            .squareRoot()
        #expect(abs(PinnedImageGeometry.logScalePosition(forScale: geometricMean) - 0.5) < 0.0001)
    }

    @Test func logScalePositionClampsOutOfRangeInput() {
        #expect(PinnedImageGeometry.logScalePosition(forScale: 0) == 0)
        #expect(PinnedImageGeometry.logScalePosition(forScale: 1000) == 1)
    }

    @Test func logScaleValueIsInverseOfPosition() {
        for position in [0.0, 0.25, 0.5, 0.75, 1.0] as [CGFloat] {
            let value = PinnedImageGeometry.logScaleValue(atPosition: position)
            let roundTrip = PinnedImageGeometry.logScalePosition(forScale: value)
            #expect(abs(roundTrip - position) < 0.0001)
        }
    }

    @Test func logScaleValueClampsPosition() {
        #expect(PinnedImageGeometry.logScaleValue(atPosition: -1) == PinnedImageGeometry.minimumScale)
        #expect(PinnedImageGeometry.logScaleValue(atPosition: 2) == PinnedImageGeometry.maximumScale)
    }

    // MARK: - 工具条定位

    @Test func toolbarPlacementPrefersBelowWhenSpaceAvailable() {
        let panel = CGRect(x: 400, y: 400, width: 200, height: 200)
        let toolbar = CGSize(width: 300, height: 40)
        let screen = CGRect(x: 0, y: 0, width: 1200, height: 900)

        let frame = PinnedImageGeometry.toolbarPlacement(
            panelFrame: panel,
            toolbarSize: toolbar,
            screenFrame: screen
        )

        #expect(frame.width == 300)
        #expect(frame.height == 40)
        #expect(frame.midX == panel.midX)
        #expect(frame.maxY == panel.minY - PinnedImageGeometry.toolbarSpacing)
    }

    /// 核心回归：面板贴近屏幕底部时，工具条必须翻到面板**上侧**，
    /// 而不是像旧实现那样贴着面板下沿内侧压住图片内容。
    @Test func toolbarPlacementFlipsAboveWhenBottomIsBlocked() {
        let panel = CGRect(x: 400, y: 10, width: 200, height: 200)
        let toolbar = CGSize(width: 300, height: 40)
        let screen = CGRect(x: 0, y: 0, width: 1200, height: 900)

        let frame = PinnedImageGeometry.toolbarPlacement(
            panelFrame: panel,
            toolbarSize: toolbar,
            screenFrame: screen
        )

        #expect(frame.minY == panel.maxY + PinnedImageGeometry.toolbarSpacing)
        #expect(frame.midX == panel.midX)
        #expect(frame.minY >= screen.minY)
        #expect(frame.maxY <= screen.maxY)
    }

    /// 面板贴近屏幕顶部时下方空间充足，应保持在下侧（不因「上侧放不下」而误判）。
    @Test func toolbarPlacementStaysBelowWhenPanelHugsTopEdge() {
        let panel = CGRect(x: 400, y: 700, width: 200, height: 180)
        let toolbar = CGSize(width: 300, height: 40)
        let screen = CGRect(x: 0, y: 0, width: 1200, height: 900)

        let frame = PinnedImageGeometry.toolbarPlacement(
            panelFrame: panel,
            toolbarSize: toolbar,
            screenFrame: screen
        )

        #expect(frame.maxY == panel.minY - PinnedImageGeometry.toolbarSpacing)
    }

    /// 上下外侧都放不下（面板几乎占满屏高）时，回退到面板底部内侧。
    @Test func toolbarPlacementUsesPanelBottomInsideAsLastResort() {
        let panel = CGRect(x: 400, y: 20, width: 200, height: 860)
        let toolbar = CGSize(width: 300, height: 40)
        let screen = CGRect(x: 0, y: 0, width: 1200, height: 900)

        let frame = PinnedImageGeometry.toolbarPlacement(
            panelFrame: panel,
            toolbarSize: toolbar,
            screenFrame: screen
        )

        #expect(frame.minY == panel.minY + PinnedImageGeometry.toolbarSpacing)
        #expect(frame.minY >= screen.minY)
        #expect(frame.maxY <= screen.maxY)
    }

    @Test func toolbarPlacementClampsHorizontallyToScreen() {
        let panel = CGRect(x: 0, y: 500, width: 200, height: 200)
        let toolbar = CGSize(width: 300, height: 40)
        let screen = CGRect(x: 0, y: 0, width: 1200, height: 900)

        let frame = PinnedImageGeometry.toolbarPlacement(
            panelFrame: panel,
            toolbarSize: toolbar,
            screenFrame: screen
        )

        #expect(frame.minX >= screen.minX)
        #expect(frame.maxX <= screen.maxX)
    }

    @Test func toolbarPlacementKeepsToolbarFullyOnScreen() {
        let toolbar = CGSize(width: 300, height: 40)
        let screen = CGRect(x: 100, y: 50, width: 800, height: 600)
        // 面板越过屏幕四角，逐一验证工具条仍完整落在屏幕可见区域内。
        let panels = [
            CGRect(x: -200, y: -100, width: 120, height: 120),
            CGRect(x: 1100, y: -100, width: 120, height: 120),
            CGRect(x: -200, y: 700, width: 120, height: 120),
            CGRect(x: 1100, y: 700, width: 120, height: 120),
            CGRect(x: -200, y: 20, width: 2000, height: 700),
        ]

        for panel in panels {
            let frame = PinnedImageGeometry.toolbarPlacement(
                panelFrame: panel,
                toolbarSize: toolbar,
                screenFrame: screen
            )
            #expect(frame.minX >= screen.minX)
            #expect(frame.maxX <= screen.maxX)
            #expect(frame.minY >= screen.minY)
            #expect(frame.maxY <= screen.maxY)
        }
    }

    @Test func toolbarPlacementFallsBackToPanelOriginWhenPanelIsDegenerate() {
        let size = CGSize(width: 300, height: 40)
        let frame = PinnedImageGeometry.toolbarPlacement(
            panelFrame: CGRect(x: 12, y: 34, width: 0, height: 0),
            toolbarSize: size,
            screenFrame: CGRect(x: 0, y: 0, width: 1200, height: 900)
        )
        #expect(frame == CGRect(origin: CGPoint(x: 12, y: 34), size: size))
    }

    @Test func toolbarPlacementReturnsZeroForInvalidSize() {
        let frame = PinnedImageGeometry.toolbarPlacement(
            panelFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            toolbarSize: .zero,
            screenFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)
        )
        #expect(frame == .zero)
    }
}
