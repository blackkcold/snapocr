import CoreGraphics
import Foundation
import Testing

@testable import CaptureCore

struct RecordingHUDTimeFormatterTests {
    @Test func shortRecordingsUseMinutesAndSeconds() {
        #expect(RecordingHUDTimeFormatter.string(elapsed: 0) == "00:00")
        #expect(RecordingHUDTimeFormatter.string(elapsed: 5) == "00:05")
        #expect(RecordingHUDTimeFormatter.string(elapsed: 65) == "01:05")
        #expect(RecordingHUDTimeFormatter.string(elapsed: 3_599) == "59:59")
    }

    @Test func recordingsPastOneHourUseHours() {
        #expect(RecordingHUDTimeFormatter.string(elapsed: 3_600) == "1:00:00")
        #expect(RecordingHUDTimeFormatter.string(elapsed: 3_661) == "1:01:01")
    }

    @Test func invalidIntervalsReadAsZero() {
        #expect(RecordingHUDTimeFormatter.string(elapsed: -12) == "00:00")
        #expect(RecordingHUDTimeFormatter.string(elapsed: .infinity) == "00:00")
        #expect(RecordingHUDTimeFormatter.string(elapsed: .nan) == "00:00")
    }
}

struct RecordingCaptureFrameGeometryTests {
    @Test func topLeftLocalRectFlipsIntoAppKitCoordinates() {
        let rect = RecordingCaptureFrameGeometry.appKitRect(
            localRect: CGRect(x: 100, y: 50, width: 200, height: 100),
            displayFrame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
            appKitScreenFrame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        )
        #expect(rect == CGRect(x: 100, y: 930, width: 200, height: 100))
    }

    @Test func secondaryDisplayOffsetIsPreserved() {
        let rect = RecordingCaptureFrameGeometry.appKitRect(
            localRect: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            displayFrame: CGRect(x: 1_920, y: 0, width: 1_440, height: 900),
            appKitScreenFrame: CGRect(x: 1_920, y: 0, width: 1_440, height: 900)
        )
        #expect(rect == CGRect(x: 1_920, y: 0, width: 1_440, height: 900))
    }

    @Test func invalidGeometryReturnsNil() {
        #expect(RecordingCaptureFrameGeometry.appKitRect(
            localRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            displayFrame: .zero,
            appKitScreenFrame: CGRect(x: 0, y: 0, width: 100, height: 100)
        ) == nil)
        #expect(RecordingCaptureFrameGeometry.appKitRect(
            localRect: CGRect(x: 0, y: 0, width: 0, height: 100),
            displayFrame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
            appKitScreenFrame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        ) == nil)
    }
}
