import Foundation
import OCRCore
import SharedKit

/// The single place that turns the OCR preferences into `OCROptions`.
///
/// Capture and the editor both read through here, so turning a language off or
/// switching to Tesseract takes effect in both instead of drifting apart.
enum OCRSettings {
    /// Reads the user's language priority, enabled languages, engine and
    /// confidence threshold.
    static func current() -> OCROptions {
        let defaults = UserDefaults.standard

        let languagePreference = defaults.string(forKey: PreferenceKeys.ocrLanguagePriority)
            ?? PreferenceDefaults.ocrLanguagePriority

        let enabledLanguages = defaults.stringArray(forKey: PreferenceKeys.ocrEnabledLanguages)
            ?? PreferenceDefaults.ocrEnabledLanguages

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

        let enginePreference = defaults.string(forKey: PreferenceKeys.ocrEngine)
            ?? PreferenceDefaults.ocrEngine
        let engine: OCREngineType = enginePreference == "tesseract"
            ? .tesseract(languageDataPath: nil)
            : .vision

        let threshold: Double
        if defaults.object(forKey: PreferenceKeys.ocrConfidenceThreshold) == nil {
            threshold = PreferenceDefaults.ocrConfidenceThreshold
        } else {
            threshold = defaults.double(forKey: PreferenceKeys.ocrConfidenceThreshold)
        }

        return OCROptions(
            languages: ordered.map(visionLanguageCode),
            minConfidence: Float(min(max(threshold, 0), 1)),
            engineSelection: engine
        )
    }

    /// Maps a compact language code to the Vision-framework identifier.
    static func visionLanguageCode(_ code: String) -> String {
        switch code {
        case "en": return "en-US"
        case "ja": return "ja-JP"
        case "ko": return "ko-KR"
        default: return code
        }
    }
}
