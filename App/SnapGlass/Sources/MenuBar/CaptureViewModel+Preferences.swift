import CaptureCore
import OCRCore
import SharedKit
import SwiftUI

// MARK: - CaptureViewModel Preferences & Static Helpers

extension CaptureViewModel {
    static func boolPreference(forKey key: String, defaultValue: Bool) -> Bool {
        if UserDefaults.standard.object(forKey: key) == nil {
            return defaultValue
        }
        return UserDefaults.standard.bool(forKey: key)
    }

    static func currentCaptureOptions() -> CaptureOptions {
        let highResolution = boolPreference(
            forKey: PreferenceKeys.captureHighResolution,
            defaultValue: PreferenceDefaults.captureHighResolution
        )
        return CaptureOptions(
            includeCursor: boolPreference(
                forKey: PreferenceKeys.captureIncludeCursor,
                defaultValue: PreferenceDefaults.captureIncludeCursor
            ),
            highResolution: highResolution,
            preferredScaleFactor: highResolution ? 2 : 1
        )
    }

    static func currentOCROptions() -> OCROptions {
        let languagePreference = stringPreference(
            forKey: PreferenceKeys.ocrLanguagePriority,
            defaultValue: PreferenceDefaults.ocrLanguagePriority
        )

        let enabledLanguages = UserDefaults.standard.stringArray(
            forKey: PreferenceKeys.ocrEnabledLanguages
        ) ?? PreferenceDefaults.ocrEnabledLanguages

        // The priority language is hoisted to the front; remaining enabled
        // languages follow in their stored order, deduplicated and filtered.
        var priorityCode: String?
        switch languagePreference {
        case "en": priorityCode = "en"
        case "zh": priorityCode = "zh-Hans"
        case "ja": priorityCode = "ja"
        case "ko": priorityCode = "ko"
        default: priorityCode = nil
        }

        var ordered: [String] = []
        if let priorityCode, enabledLanguages.contains(priorityCode) {
            ordered.append(priorityCode)
        }
        for code in enabledLanguages where !ordered.contains(code) {
            ordered.append(code)
        }

        let languages: [String] = ordered.map(Self.visionLanguageCode)
        let enginePreference = stringPreference(
            forKey: PreferenceKeys.ocrEngine,
            defaultValue: PreferenceDefaults.ocrEngine
        )
        let engine: OCREngineType = enginePreference == "tesseract"
            ? .tesseract(languageDataPath: nil)
            : .vision

        let threshold = doublePreference(
            forKey: PreferenceKeys.ocrConfidenceThreshold,
            defaultValue: PreferenceDefaults.ocrConfidenceThreshold
        )

        return OCROptions(
            languages: languages,
            minConfidence: Float(min(max(threshold, 0), 1)),
            engineSelection: engine
        )
    }

    /// Maps a compact language code to the Vision-framework identifier used for OCR.
    private static func visionLanguageCode(_ code: String) -> String {
        switch code {
        case "en": return "en-US"
        case "ja": return "ja-JP"
        case "ko": return "ko-KR"
        default: return code
        }
    }

    static func stringPreference(forKey key: String, defaultValue: String) -> String {
        UserDefaults.standard.string(forKey: key) ?? defaultValue
    }

    private static func doublePreference(forKey key: String, defaultValue: Double) -> Double {
        guard UserDefaults.standard.object(forKey: key) != nil else {
            return defaultValue
        }
        return UserDefaults.standard.double(forKey: key)
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static func historyModeDescription(for mode: CaptureCore.CaptureMode) -> String {
        switch mode {
        case .area:
            return "area"
        case .window:
            return "window"
        case .fullscreen:
            return "fullscreen"
        case .scroll:
            return "scroll"
        }
    }
}
