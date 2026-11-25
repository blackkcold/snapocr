import CoreGraphics
import Foundation
import Testing
@testable import SharedKit

struct PreferenceKeysTests {
    @Test func keysAreNamespacedAndUnique() {
        let keys = [
            PreferenceKeys.launchAtLogin,
            PreferenceKeys.appLanguage,
            PreferenceKeys.appearanceMode,
            PreferenceKeys.captureOpenEditor,
            PreferenceKeys.captureCopyToClipboard,
            PreferenceKeys.captureIncludeCursor,
            PreferenceKeys.captureAutoOCR,
            PreferenceKeys.captureCopyOCRText,
            PreferenceKeys.captureSelectionStyle,
            PreferenceKeys.captureOverlayMode,
            PreferenceKeys.captureHighResolution,
            PreferenceKeys.captureImageFormat,
            PreferenceKeys.captureJPEGQuality,
            PreferenceKeys.ocrLanguagePriority,
            PreferenceKeys.ocrConfidenceThreshold,
            PreferenceKeys.ocrEngine,
            PreferenceKeys.historyRetentionPolicy,
            PreferenceKeys.historyRetentionDays,
            PreferenceKeys.historyMaxItems,
            PreferenceKeys.historyStorageSize,
            PreferenceKeys.historyAutoSave,
            PreferenceKeys.historySaveFullText,
            PreferenceKeys.developerMode,
            PreferenceKeys.engineComparison,
        ]

        #expect(Set(keys).count == keys.count)
        #expect(keys.allSatisfy { $0.contains("_") })
    }

    @Test func privacySafeDefaultsAreConservative() {
        #expect(!PreferenceDefaults.launchAtLogin)
        #expect(PreferenceDefaults.appearanceMode == AppearanceMode.system.rawValue)
        #expect(!PreferenceDefaults.captureIncludeCursor)
        #expect(!PreferenceDefaults.captureAutoOCR)
        #expect(!PreferenceDefaults.captureCopyOCRText)
        #expect(PreferenceDefaults.captureSelectionStyle == CaptureSelectionStyle.rectangle.rawValue)
        #expect(PreferenceDefaults.captureOverlayMode == CaptureOverlayMode.live.rawValue)
        #expect(PreferenceDefaults.captureHighResolution)
        #expect(!PreferenceDefaults.historySaveFullText)
        #expect(PreferenceDefaults.historyRetentionDays > 0)
        #expect(PreferenceDefaults.historyMaxItems >= 10)
    }

    @Test func appearanceModesHaveStablePersistedValues() {
        #expect(AppearanceMode.allCases.map(\.rawValue) == ["system", "light", "dark"])
        for mode in AppearanceMode.allCases {
            #expect(AppearanceMode(rawValue: mode.rawValue)?.rawValue == mode.rawValue)
        }
    }

    @Test func captureOverlayModesHaveStablePersistedValues() {
        #expect(CaptureOverlayMode.allCases.map(\.rawValue) == ["live", "snapshot"])
        for mode in CaptureOverlayMode.allCases {
            #expect(CaptureOverlayMode(rawValue: mode.rawValue)?.rawValue == mode.rawValue)
        }
    }
}

struct ImageEncoderTests {
    @Test func encodesPNGAndJPEG() throws {
        let image = try makeImage()
        let png = try ImageEncoder.encode(image, format: .png)
        let jpeg = try ImageEncoder.encode(image, format: .jpeg, jpegQuality: 0.8)

        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(jpeg.starts(with: [0xFF, 0xD8]))
        #expect(!ImageEncoder.containsTransparency(image))
    }

    private func makeImage() throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: 16,
            height: 16,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw AppError.internalError("Unable to create test context")
        }
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        guard let image = context.makeImage() else {
            throw AppError.internalError("Unable to create test image")
        }
        return image
    }
}
