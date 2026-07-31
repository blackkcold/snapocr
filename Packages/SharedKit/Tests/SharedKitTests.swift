import CoreGraphics
import Foundation
import Testing
@testable import SharedKit

struct PreferenceKeysTests {
    @Test func keysAreNamespacedAndUnique() {
        let keys = [
            PreferenceKeys.launchAtLogin,
            PreferenceKeys.captureOpenEditor,
            PreferenceKeys.captureCopyToClipboard,
            PreferenceKeys.captureIncludeCursor,
            PreferenceKeys.captureAutoOCR,
            PreferenceKeys.captureCopyOCRText,
            PreferenceKeys.captureSelectionStyle,
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
        #expect(!PreferenceDefaults.captureIncludeCursor)
        #expect(!PreferenceDefaults.captureAutoOCR)
        #expect(!PreferenceDefaults.captureCopyOCRText)
        #expect(PreferenceDefaults.captureSelectionStyle == CaptureSelectionStyle.rectangle.rawValue)
        #expect(PreferenceDefaults.captureHighResolution)
        #expect(!PreferenceDefaults.historySaveFullText)
        #expect(PreferenceDefaults.historyRetentionDays > 0)
        #expect(PreferenceDefaults.historyMaxItems >= 10)
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

struct LocalKeyStoreTests {
    @Test func createsStableOwnerOnlyKeyFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapglass-key-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let keyURL = root.appendingPathComponent("Security/history-v2.key")

        let first = try LocalKeyStore.loadOrCreateKey(at: keyURL)
        let second = try LocalKeyStore.loadOrCreateKey(at: keyURL)
        let firstData = first.withUnsafeBytes { Data($0) }
        let secondData = second.withUnsafeBytes { Data($0) }
        let attributes = try FileManager.default.attributesOfItem(atPath: keyURL.path)

        #expect(firstData.count == 32)
        #expect(firstData == secondData)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}
