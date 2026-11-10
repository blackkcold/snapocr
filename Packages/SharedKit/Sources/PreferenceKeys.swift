import Foundation

/// UserDefaults keys shared by the app and feature modules.
public enum PreferenceKeys {
    /// Whether Return inserts a newline instead of committing an annotation.
    public static let editorEnterInsertsNewline = "editor_enterInsertsNewline"
    /// Folder the editor's Save panel opens in; absent means "system default".
    public static let editorSaveDirectory = "editor_saveDirectory"
    /// Whether the annotation inspector stays visible beside the canvas.
    public static let editorInspectorVisible = "editor_inspectorVisible"
    public static let launchAtLogin = "general_launchAtLogin"
    public static let appLanguage = "general_appLanguage"
    public static let appearanceMode = "appearance_mode"

    public static let captureOpenEditor = "capture_openEditor"
    public static let captureCopyToClipboard = "capture_copyToClipboard"
    public static let captureIncludeCursor = "capture_includeCursor"
    public static let captureAutoOCR = "capture_autoOCR"
    public static let captureCopyOCRText = "capture_copyOCRText"
    public static let captureSelectionStyle = "capture_selectionStyle"
    public static let captureOverlayMode = "capture_overlayMode"
    public static let captureHighResolution = "capture_highResolution"
    /// Whether window captures get rounded corners and a soft shadow.
    public static let captureWindowStyling = "capture_windowStyling"
    public static let captureImageFormat = "capture_imageFormat"
    public static let captureJPEGQuality = "capture_jpegQuality"
    public static let pickerDominantColorCount = "capture_pickerDominantColorCount"
    /// Pin shortcut override; absent means "use the code-level default".
    public static let pinSelectionShortcut = "capture_pinSelectionShortcut"
    /// Whether the recent screenshot shelf is enabled.
    public static let screenshotShelfEnabled = "screenshotShelf_enabled"
    /// Maximum number of screenshots shown in the recent screenshot shelf.
    public static let screenshotShelfCount = "screenshotShelf_count"
    /// Screenshot shelf card height in points.
    public static let screenshotShelfCardHeight = "screenshotShelf_cardHeight"
    /// Opacity applied to screenshot shelf images.
    public static let screenshotShelfImageOpacity = "screenshotShelf_imageOpacity"
    /// Screen anchor used to place the screenshot shelf.
    public static let screenshotShelfAnchor = "screenshotShelf_anchor"
    /// Whether the shelf folds down to a rail tab when idle.
    public static let screenshotShelfCollapseToRail = "screenshotShelf_collapseToRail"
    /// Video codec used for new screen recordings.
    public static let recordingVideoCodec = "recording_videoCodec"
    /// Resolution ceiling used for new screen recordings.
    public static let recordingResolution = "recording_resolution"
    /// Frame-rate ceiling used for new screen recordings.
    public static let recordingFrameRate = "recording_frameRate"
    /// Average video bitrate used for new screen recordings.
    public static let recordingAverageVideoBitrate = "recording_averageVideoBitrate"
    /// Whether new screen recordings include system audio.
    public static let recordingSystemAudio = "recording_systemAudio"
    /// Optional user-selected screen-recording destination directory.
    public static let recordingCustomOutputDirectory = "recording_customOutputDirectory"

    public static let ocrLanguagePriority = "ocr_languagePriority"
    public static let ocrEnabledLanguages = "ocr_enabledLanguages"
    public static let ocrConfidenceThreshold = "ocr_confidenceThreshold"
    public static let ocrEngine = "ocr_engine"

    public static let historyRetentionPolicy = "history_retentionPolicy"
    public static let historyRetentionDays = "history_retentionDays"
    public static let historyMaxItems = "history_maxItems"
    public static let historyStorageSize = "history_storageSize"
    public static let historyAutoSave = "history_autoSave"
    public static let historySaveFullText = "history_saveFullText"
    public static let colorHistoryEnabled = "history_colorHistoryEnabled"
    public static let colorHistoryMaxItems = "history_colorHistoryMaxItems"

    public static let developerMode = "dev_devMode"
    public static let engineComparison = "dev_engineComparison"
    public static let forceUpdateAvailable = "dev_forceUpdateAvailable"
}

/// Defaults used when a preference has not been written yet.
public enum PreferenceDefaults {
    /// Preserve Return-to-submit as the default text editing behavior.
    public static let editorEnterInsertsNewline = false
    public static let editorInspectorVisible = true
    public static let launchAtLogin = false
    public static let appLanguage = "system"
    public static let appearanceMode = "system"

    public static let captureOpenEditor = true
    public static let captureCopyToClipboard = true
    public static let captureIncludeCursor = false
    public static let captureAutoOCR = false
    public static let captureCopyOCRText = false
    public static let captureSelectionStyle = CaptureSelectionStyle.rectangle.rawValue
    public static let captureOverlayMode = CaptureOverlayMode.live.rawValue
    public static let captureHighResolution = true
    public static let captureWindowStyling = true
    public static let captureImageFormat = "png"
    public static let captureJPEGQuality = 0.9
    public static let pickerDominantColorCount = 5
    /// Enable the recent screenshot shelf by default.
    public static let screenshotShelfEnabled = true
    /// Show the three most recent screenshots by default.
    public static let screenshotShelfCount = 3
    /// Use a 96-point shelf card height by default.
    public static let screenshotShelfCardHeight = 96.0
    /// Render shelf images at 90% opacity by default.
    public static let screenshotShelfImageOpacity = 0.9
    /// Keep the shelf centered below the menu bar by default.
    public static let screenshotShelfAnchor = ScreenshotShelfAnchor.top.rawValue
    /// Collapse the shelf to its rail tab after the pointer leaves.
    public static let screenshotShelfCollapseToRail = true
    /// Use H.264 for new recordings by default.
    public static let recordingVideoCodec = "h264"
    /// Limit new recordings to 1080p by default.
    public static let recordingResolution = "1080p"
    /// Record at up to 30 frames per second by default.
    public static let recordingFrameRate = 30
    /// Target 8 Mbps average video bitrate by default.
    public static let recordingAverageVideoBitrate = 8_000_000
    /// Exclude system audio from new recordings by default.
    public static let recordingSystemAudio = false

    public static let ocrLanguagePriority = "auto"
    public static let ocrEnabledLanguages = ["en", "zh-Hans", "zh-Hant", "ja", "ko"]
    public static let ocrConfidenceThreshold = 0.8
    public static let ocrEngine = "vision"

    public static let historyRetentionPolicy = "30days"
    public static let historyRetentionDays = 30
    public static let historyMaxItems = 200
    public static let historyStorageSize = 1.0
    public static let historyAutoSave = true
    public static let historySaveFullText = false
    public static let colorHistoryEnabled = true
    public static let colorHistoryMaxItems = 100

    public static let developerMode = false
    public static let engineComparison = false
    public static let forceUpdateAvailable = false
}

/// Reads and normalizes the persisted screenshot-shelf preferences.
public enum ScreenshotShelfPreferences {
    /// Returns whether the screenshot shelf is enabled, defaulting to `true`.
    public static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: PreferenceKeys.screenshotShelfEnabled) != nil else {
            return PreferenceDefaults.screenshotShelfEnabled
        }
        return defaults.bool(forKey: PreferenceKeys.screenshotShelfEnabled)
    }

    /// Returns the configured shelf count, clamped to `1...6` and persisted when corrected.
    public static func count(in defaults: UserDefaults = .standard) -> Int {
        let key = PreferenceKeys.screenshotShelfCount
        guard let storedValue = defaults.object(forKey: key) as? NSNumber else {
            return PreferenceDefaults.screenshotShelfCount
        }

        let rawValue = storedValue.doubleValue
        let normalizedValue = Int(min(max(rawValue.isNaN ? 3 : rawValue, 1), 6))
        if rawValue != Double(normalizedValue) {
            defaults.set(normalizedValue, forKey: key)
        }
        return normalizedValue
    }

    /// Returns the card height, clamped to `64...160` points and persisted when corrected.
    public static func cardHeight(in defaults: UserDefaults = .standard) -> Double {
        normalizedDouble(
            forKey: PreferenceKeys.screenshotShelfCardHeight,
            defaultValue: PreferenceDefaults.screenshotShelfCardHeight,
            range: 64...160,
            in: defaults
        )
    }

    /// Returns the image opacity, clamped to `0.2...1` and persisted when corrected.
    public static func imageOpacity(in defaults: UserDefaults = .standard) -> Double {
        normalizedDouble(
            forKey: PreferenceKeys.screenshotShelfImageOpacity,
            defaultValue: PreferenceDefaults.screenshotShelfImageOpacity,
            range: 0.2...1,
            in: defaults
        )
    }

    /// Returns the screen anchor for the shelf, falling back to `top` when the stored value is invalid.
    ///
    /// Invalid legacy values are written back so the Settings picker always has a visible selection.
    public static func anchor(in defaults: UserDefaults = .standard) -> ScreenshotShelfAnchor {
        let key = PreferenceKeys.screenshotShelfAnchor
        guard let rawValue = defaults.string(forKey: key) else {
            return ScreenshotShelfAnchor.top
        }
        guard let anchor = ScreenshotShelfAnchor(rawValue: rawValue) else {
            defaults.set(ScreenshotShelfAnchor.top.rawValue, forKey: key)
            return .top
        }
        return anchor
    }

    /// Returns whether the shelf folds down to its rail tab when idle, defaulting to `true`.
    public static func collapseToRail(in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: PreferenceKeys.screenshotShelfCollapseToRail) != nil else {
            return PreferenceDefaults.screenshotShelfCollapseToRail
        }
        return defaults.bool(forKey: PreferenceKeys.screenshotShelfCollapseToRail)
    }

    private static func normalizedDouble(
        forKey key: String,
        defaultValue: Double,
        range: ClosedRange<Double>,
        in defaults: UserDefaults
    ) -> Double {
        guard let storedValue = defaults.object(forKey: key) as? NSNumber else {
            return defaultValue
        }

        let rawValue = storedValue.doubleValue
        let normalizedValue = rawValue.isNaN ? defaultValue : min(max(rawValue, range.lowerBound), range.upperBound)
        if rawValue != normalizedValue {
            defaults.set(normalizedValue, forKey: key)
        }
        return normalizedValue
    }
}

/// Reads and updates the optional destination for screen recordings.
public enum RecordingDestinationPreferences {
    /// Returns the selected destination, defaulting to `Movies/SnapGlass/Recordings`.
    ///
    /// This lookup never creates the directory.
    ///
    /// - Parameters:
    ///   - defaults: Defaults store containing the optional custom directory.
    ///   - moviesDirectory: Optional Movies-directory override, primarily for tests.
    ///   - fileManager: File manager used to locate the user's Movies directory.
    /// - Returns: The custom or default directory, or `nil` if Movies cannot be resolved.
    public static func directory(
        in defaults: UserDefaults = .standard,
        moviesDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL? {
        if let customDirectory = customDirectory(in: defaults) {
            return customDirectory
        }
        guard let moviesDirectory = moviesDirectory
            ?? fileManager.urls(for: .moviesDirectory, in: .userDomainMask).first else {
            return nil
        }
        return moviesDirectory
            .appendingPathComponent("SnapGlass", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    /// Returns the remembered custom directory, if one was selected.
    public static func customDirectory(in defaults: UserDefaults = .standard) -> URL? {
        guard let path = defaults.string(forKey: PreferenceKeys.recordingCustomOutputDirectory),
              !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    /// Remembers a user-selected directory without creating it or moving files.
    public static func setCustomDirectory(_ directory: URL, in defaults: UserDefaults = .standard) {
        guard directory.isFileURL else { return }
        defaults.set(
            directory.standardizedFileURL.path,
            forKey: PreferenceKeys.recordingCustomOutputDirectory
        )
    }

    /// Clears the custom directory and restores the Movies default.
    public static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: PreferenceKeys.recordingCustomOutputDirectory)
    }
}

/// Screen anchors supported by the floating screenshot shelf.
public enum ScreenshotShelfAnchor: String, CaseIterable, Sendable {
    case topLeading
    case top
    case topTrailing
    case bottomLeading
    case bottom
    case bottomTrailing

    /// Whether the shelf hangs from the top edge of the usable screen.
    public var isTop: Bool {
        switch self {
        case .topLeading, .top, .topTrailing: true
        case .bottomLeading, .bottom, .bottomTrailing: false
        }
    }

    /// Horizontal placement within the usable screen.
    public enum HorizontalPlacement: Sendable {
        case leading
        case center
        case trailing
    }

    public var horizontalPlacement: HorizontalPlacement {
        switch self {
        case .topLeading, .bottomLeading: .leading
        case .top, .bottom: .center
        case .topTrailing, .bottomTrailing: .trailing
        }
    }

    /// Localization key used by the Settings position picker.
    public var localizationKey: String {
        switch self {
        case .topLeading: "Top Left"
        case .top: "Top Center"
        case .topTrailing: "Top Right"
        case .bottomLeading: "Bottom Left"
        case .bottom: "Bottom Center"
        case .bottomTrailing: "Bottom Right"
        }
    }
}

/// Interactive area-selection styles supported by the capture overlay.
public enum CaptureSelectionStyle: String, CaseIterable, Sendable {
    /// Axis-aligned rectangle with resize handles.
    case rectangle
    /// Freehand closed path that produces a transparent PNG.
    case freeform
}

/// Background behavior used while selecting an area to capture.
public enum CaptureOverlayMode: String, CaseIterable, Sendable {
    /// Keep the overlay transparent so the current desktop remains visible.
    case live
    /// Display the frame captured immediately before the overlay appeared.
    case snapshot
}
