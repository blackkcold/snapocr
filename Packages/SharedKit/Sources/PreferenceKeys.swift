import Foundation

/// UserDefaults keys shared by the app and feature modules.
public enum PreferenceKeys {
    public static let launchAtLogin = "general_launchAtLogin"
    public static let appLanguage = "general_appLanguage"

    public static let captureOpenEditor = "capture_openEditor"
    public static let captureCopyToClipboard = "capture_copyToClipboard"
    public static let captureIncludeCursor = "capture_includeCursor"
    public static let captureAutoOCR = "capture_autoOCR"
    public static let captureCopyOCRText = "capture_copyOCRText"
    public static let captureSelectionStyle = "capture_selectionStyle"
    public static let captureHighResolution = "capture_highResolution"
    public static let captureImageFormat = "capture_imageFormat"
    public static let captureJPEGQuality = "capture_jpegQuality"

    public static let ocrLanguagePriority = "ocr_languagePriority"
    public static let ocrConfidenceThreshold = "ocr_confidenceThreshold"
    public static let ocrEngine = "ocr_engine"

    public static let historyRetentionPolicy = "history_retentionPolicy"
    public static let historyRetentionDays = "history_retentionDays"
    public static let historyMaxItems = "history_maxItems"
    public static let historyStorageSize = "history_storageSize"
    public static let historyAutoSave = "history_autoSave"
    public static let historySaveFullText = "history_saveFullText"

    public static let developerMode = "dev_devMode"
    public static let engineComparison = "dev_engineComparison"
    public static let forceUpdateAvailable = "dev_forceUpdateAvailable"
}

/// Defaults used when a preference has not been written yet.
public enum PreferenceDefaults {
    public static let launchAtLogin = false
    public static let appLanguage = "system"

    public static let captureOpenEditor = true
    public static let captureCopyToClipboard = true
    public static let captureIncludeCursor = false
    public static let captureAutoOCR = false
    public static let captureCopyOCRText = false
    public static let captureSelectionStyle = CaptureSelectionStyle.rectangle.rawValue
    public static let captureHighResolution = true
    public static let captureImageFormat = "png"
    public static let captureJPEGQuality = 0.9

    public static let ocrLanguagePriority = "auto"
    public static let ocrConfidenceThreshold = 0.8
    public static let ocrEngine = "vision"

    public static let historyRetentionPolicy = "30days"
    public static let historyRetentionDays = 30
    public static let historyMaxItems = 200
    public static let historyStorageSize = 1.0
    public static let historyAutoSave = true
    public static let historySaveFullText = false

    public static let developerMode = false
    public static let engineComparison = false
    public static let forceUpdateAvailable = false
}

/// Interactive area-selection styles supported by the capture overlay.
public enum CaptureSelectionStyle: String, CaseIterable, Sendable {
    /// Axis-aligned rectangle with resize handles.
    case rectangle
    /// Freehand closed path that produces a transparent PNG.
    case freeform
}
