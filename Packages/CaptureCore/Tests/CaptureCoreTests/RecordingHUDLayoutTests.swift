import CoreGraphics
import Testing

@testable import CaptureCore

struct RecordingHUDLayoutTests {
    private let screen = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)

    @Test func originRespectsTheScreenMarginForEveryCorner() {
        let size = RecordingHUDMetrics.recordingSize
        let margin = RecordingHUDMetrics.screenMargin

        #expect(RecordingHUDPlacement.origin(for: .topTrailing, size: size, in: screen)
            == CGPoint(x: 1_920 - size.width - margin, y: 1_080 - size.height - margin))
        #expect(RecordingHUDPlacement.origin(for: .topLeading, size: size, in: screen)
            == CGPoint(x: margin, y: 1_080 - size.height - margin))
        #expect(RecordingHUDPlacement.origin(for: .bottomTrailing, size: size, in: screen)
            == CGPoint(x: 1_920 - size.width - margin, y: margin))
        #expect(RecordingHUDPlacement.origin(for: .bottomLeading, size: size, in: screen)
            == CGPoint(x: margin, y: margin))
    }

    @Test func displayCaptureKeepsTheStoredCorner() {
        #expect(RecordingHUDPlacement.preferredCorner(
            size: RecordingHUDMetrics.recordingSize,
            screenFrame: screen,
            capturedRect: nil,
            preferred: .bottomLeading
        ) == .bottomLeading)
    }

    @Test func regionInTheTopTrailingCornerMovesThePanel() {
        let size = RecordingHUDMetrics.recordingSize
        let captured = CGRect(x: 1_400, y: 700, width: 500, height: 360)

        #expect(RecordingHUDPlacement.preferredCorner(
            size: size,
            screenFrame: screen,
            capturedRect: captured,
            preferred: .topTrailing
        ) == .topLeading)
    }

    @Test func regionThatOnlyTouchesTheBottomMovesThePanelUp() {
        let size = RecordingHUDMetrics.recordingSize
        let captured = CGRect(x: 0, y: 0, width: 900, height: 300)

        #expect(RecordingHUDPlacement.preferredCorner(
            size: size,
            screenFrame: screen,
            capturedRect: captured,
            preferred: .bottomLeading
        ) == .topTrailing)
    }

    @Test func fullScreenCaptureKeepsThePanelReachable() {
        let size = RecordingHUDMetrics.recordingSize
        let captured = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)

        #expect(RecordingHUDPlacement.preferredCorner(
            size: size,
            screenFrame: screen,
            capturedRect: captured,
            preferred: .topLeading
        ) == .topLeading)
    }

    @Test func draggingSnapsToTheNearestCorner() {
        let size = RecordingHUDMetrics.recordingSize
        let nearTopTrailing = CGPoint(x: 1_500, y: 900)
        let nearBottomLeading = CGPoint(x: 40, y: 40)

        #expect(RecordingHUDPlacement.nearestCorner(to: nearTopTrailing, size: size, in: screen)
            == .topTrailing)
        #expect(RecordingHUDPlacement.nearestCorner(to: nearBottomLeading, size: size, in: screen)
            == .bottomLeading)
    }

    @Test func storedCornerParsingFallsBackWhenInvalid() {
        #expect(RecordingHUDPlacement.corner(rawValue: "bottomLeading") == .bottomLeading)
        #expect(RecordingHUDPlacement.corner(rawValue: "middle") == .topTrailing)
        #expect(RecordingHUDPlacement.corner(rawValue: "", fallback: .bottomTrailing) == .bottomTrailing)
    }
}
