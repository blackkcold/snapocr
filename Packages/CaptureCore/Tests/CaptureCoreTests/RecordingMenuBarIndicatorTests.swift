import AppKit
import Testing
@testable import CaptureCore

struct RecordingMenuBarIndicatorTests {
    @Test func idleShowsCamera() {
        #expect(RecordingSessionStatus.idle.menuBarIndicator(isCapturing: false) == .camera)
    }

    @Test func selectingCountdownAndStartingAllReadAsPreparing() {
        let statuses: [RecordingSessionStatus] = [
            .selectingSource,
            .countdown(3),
            .starting,
        ]
        for status in statuses {
            #expect(status.menuBarIndicator(isCapturing: false) == .preparing)
        }
    }

    @Test func activeRecordingShowsRecording() {
        #expect(RecordingSessionStatus.recording.menuBarIndicator(isCapturing: false) == .recording)
    }

    @Test func savingShowsSaving() {
        #expect(RecordingSessionStatus.saving.menuBarIndicator(isCapturing: false) == .saving)
    }

    @Test func areaCaptureTakesPrecedenceOverEveryRecordingStatus() {
        let statuses: [RecordingSessionStatus] = [
            .idle,
            .selectingSource,
            .countdown(3),
            .starting,
            .recording,
            .saving,
        ]
        for status in statuses {
            #expect(status.menuBarIndicator(isCapturing: true) == .capturing)
        }
    }

    @Test func everyIndicatorUsesAnAvailableSystemSymbol() {
        for indicator in RecordingMenuBarIndicator.allCases {
            #expect(
                NSImage(systemSymbolName: indicator.systemImage, accessibilityDescription: nil) != nil,
                "\(indicator)"
            )
        }
    }

    @Test func onlyRecordingShowsTheRecordingDot() {
        #expect(RecordingMenuBarIndicator.recording.showsRecordingDot)
        for indicator in RecordingMenuBarIndicator.allCases where indicator != .recording {
            #expect(!indicator.showsRecordingDot, "\(indicator)")
        }
    }

    @Test func startingRecordingAndSavingNeedStopConfirmation() {
        #expect(!RecordingSessionStatus.idle.needsQuitConfirmation)
        #expect(!RecordingSessionStatus.selectingSource.needsQuitConfirmation)
        #expect(!RecordingSessionStatus.countdown(3).needsQuitConfirmation)
        #expect(RecordingSessionStatus.starting.needsQuitConfirmation)
        #expect(RecordingSessionStatus.recording.needsQuitConfirmation)
        #expect(RecordingSessionStatus.saving.needsQuitConfirmation)
    }
}
