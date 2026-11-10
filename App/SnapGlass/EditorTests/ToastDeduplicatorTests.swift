import CaptureCore
import Foundation
import Testing

@testable import EditorInteractionTests

/// 同一文案 1 秒内只弹一次；不同文案和超过 1 秒的重复仍要出现。
@MainActor
struct ToastDeduplicatorTests {
    @Test func suppressesSameMessageWithinOneSecond() {
        let deduplicator = ToastDeduplicator()
        #expect(deduplicator.shouldPresent("Saved", now: 100))
        #expect(!deduplicator.shouldPresent("Saved", now: 100.9))
        #expect(deduplicator.shouldPresent("Saved", now: 101.1))
    }

    @Test func allowsDifferentMessagesImmediately() {
        let deduplicator = ToastDeduplicator()
        #expect(deduplicator.shouldPresent("Saved", now: 100))
        #expect(deduplicator.shouldPresent("Copied", now: 100.1))
    }
}

struct RecordingErrorLocalizationTests {
    @Test func localizesFixedEngineErrorsThroughTheAppLanguageLookup() {
        let result = AppLocalization.recordingErrorDescription(.invalidRegion) { key in
            "localized: \(key)"
        }

        #expect(result == "localized: The recording region is outside the selected display.")
    }

    @Test func localizesFailureReasonAndRetainedPartialPath() {
        let partialURL = URL(fileURLWithPath: "/recordings/recoverable.partial")
        let result = AppLocalization.recordingErrorDescription(
            .recordingFailed("No video frame was captured.", partialURL: partialURL)
        ) { key in
            switch key {
            case "No video frame was captured.":
                "没有捕获到视频帧。"
            case "Retained partial: %@":
                "已保留的临时文件：%@"
            default:
                key
            }
        }

        #expect(result == "没有捕获到视频帧。 已保留的临时文件：/recordings/recoverable.partial")
    }

    @Test func localizesAtomicPublicationFailures() {
        let reason = RecordingOutputTransactionError.unsupportedDestination.localizedDescription
        let result = AppLocalization.recordingErrorDescription(
            .finalizationFailed(reason, partialURL: nil)
        ) { key in
            if key == "This destination does not support safe recording publication. Choose another destination." {
                return "此位置不支持安全发布录屏文件，请选择其他保存位置。"
            }
            return key
        }

        #expect(result == "此位置不支持安全发布录屏文件，请选择其他保存位置。")
    }

    @Test func preservesUnknownSystemErrorDescriptions() {
        let result = AppLocalization.recordingErrorDescription(
            .finalizationFailed("AVFoundation error -11800", partialURL: nil)
        ) { key in key }

        #expect(result == "AVFoundation error -11800")
    }

    @Test func localizesTheCaptureStopFailurePrefixAndKeepsItsUnderlyingReason() {
        let result = AppLocalization.recordingErrorDescription(
            .recordingFailed("The capture stream could not stop cleanly: device disconnected", partialURL: nil)
        ) { key in
            if key == "The capture stream could not stop cleanly: %@" {
                return "录制流未能正常停止：%@"
            }
            return key
        }

        #expect(result == "录制流未能正常停止：device disconnected")
    }
}
