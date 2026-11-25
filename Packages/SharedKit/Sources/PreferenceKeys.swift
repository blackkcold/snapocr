import Foundation

/// UserDefaults keys shared by the app and feature modules.
public enum PreferenceKeys {
    /// Whether Return inserts a newline instead of committing an annotation.
    public static let editorEnterInsertsNewline = "editor_enterInsertsNewline"
    /// Folder the editor's Save panel opens in; absent means "system default".
    public static let editorSaveDirectory = "editor_saveDirectory"
    /// Whether the annotation inspector stays visible beside the canvas.
    public static let editorInspectorVisible = "editor_inspectorVisible"
    /// Last share-appearance style enabled in the editor, as JSON.
    public static let editorMockupLastStyleJSON = "editor_mockupLastStyleJSON"
    /// Draw share appearance directly on the editor canvas.
    public static let editorShareCanvasPreview = "editor_shareCanvasPreview"
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
    /// Whether area/fullscreen captures get a share-ready background.
    public static let captureMockupEnabled = "capture_mockupEnabled"
    /// Selected mockup template identifier.
    public static let captureMockupPreset = "capture_mockupPreset"
    /// All-display canvas layout identifier.
    public static let displayCanvasMode = "capture_displayCanvasMode"
    /// Gap between displays in compact canvas modes, in points.
    public static let displayCanvasGap = "capture_displayCanvasGap"
    /// Alignment inside compact canvas modes.
    public static let displayCanvasAlignment = "capture_displayCanvasAlignment"
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
    /// Audio sources used by audio-only recordings.
    public static let recordingAudioMode = "recording_audioMode"
    /// Audio sources used by screen recordings.
    public static let recordingScreenAudioMode = "recording_screenAudioMode"
    /// File layout used for a recording's audio output.
    public static let recordingOutputLayout = "recording_outputLayout"
    /// Whether the screenshot shelf hides while a recording is active.
    public static let recordingHideShelfWhileRecording = "recording_hideShelfWhileRecording"
    /// Optional keyboard shortcut for audio-only recordings; empty means none.
    public static let recordingAudioShortcut = "recording_audioShortcut"
    /// Whether the audio-only recording shortcut hint has been shown.
    public static let recordingShortcutHintShown = "recording_shortcutHintShown"
    /// Legacy shared destination directory. Kept for upgrade discovery only.
    public static let recordingCustomOutputDirectory = "recording_customOutputDirectory"
    /// AAC bitrate used by audio-only recordings. Also the legacy shared bitrate key.
    public static let recordingAudioBitRate = "recording_audioBitRate"
    /// AAC bitrate used by screen recordings.
    public static let recordingScreenAudioBitRate = "recording_screenAudioBitRate"
    /// Optional user-selected destination for audio-only recordings.
    public static let recordingAudioCustomOutputDirectory = "recording_audioCustomOutputDirectory"
    /// Optional user-selected destination for screen recordings.
    public static let recordingScreenCustomOutputDirectory = "recording_screenCustomOutputDirectory"
    /// Persistent volume UUID captured when the audio destination was chosen.
    public static let recordingAudioCustomOutputVolumeUUID = "recording_audioCustomOutputVolumeUUID"
    /// Persistent volume UUID captured when the screen destination was chosen.
    public static let recordingScreenCustomOutputVolumeUUID = "recording_screenCustomOutputVolumeUUID"
    /// One-time marker proving the legacy shared values were seeded per kind.
    public static let recordingPerKindPreferencesSeeded = "recording_perKindPreferencesSeeded"
    /// Previously used recording folders, retained for export-window discovery.
    public static let recordingKnownOutputRoots = "recording_knownOutputRoots"
    /// Opacity applied to the floating recording control panel surface.
    public static let recordingHUDOpacity = "recording_hudOpacity"
    /// Whether the recording control panel restores full opacity while the pointer is inside it.
    public static let recordingHUDHoverRestore = "recording_hudHoverRestore"
    /// Whether the floating recording control panel is suppressed during recordings.
    public static let recordingHUDHidden = "recording_hudHidden"
    /// Whether a recording draws a frame around the captured area.
    public static let recordingShowCaptureFrame = "recording_showCaptureFrame"
    /// Whether a finished recording is revealed in Finder.
    public static let recordingRevealOnFinish = "recording_revealOnFinish"
    /// Screen corner used by the floating recording control panel.
    public static let recordingHUDCorner = "recording_hudCorner"

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
}

/// Defaults used when a preference has not been written yet.
public enum PreferenceDefaults {
    /// Preserve Return-to-submit as the default text editing behavior.
    public static let editorEnterInsertsNewline = false
    public static let editorInspectorVisible = true
    /// Draw share appearance live on the editor canvas.
    public static let editorShareCanvasPreview = true
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
    public static let captureMockupEnabled = false
    public static let captureMockupPreset = "light"
    public static let displayCanvasMode = "compactHorizontal"
    public static let displayCanvasGap = 0.0
    public static let displayCanvasAlignment = "start"
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
    /// Capture system audio and microphone audio by default for audio-only recordings.
    public static let recordingAudioMode = "systemAndMicrophone"
    /// Capture system audio by default for screen recordings.
    public static let recordingScreenAudioMode = "system"
    /// Mix active audio sources into one output track by default.
    public static let recordingOutputLayout = "mixed"
    /// Keep the screenshot shelf visible during recordings by default.
    public static let recordingHideShelfWhileRecording = false
    /// Define no audio-only recording shortcut by default.
    public static let recordingAudioShortcut = ""
    /// Treat the audio-only shortcut hint as not yet shown by default.
    public static let recordingShortcutHintShown = false
    /// Encode audio-only tracks at 128 kbps by default.
    public static let recordingAudioBitRate = 128_000
    /// Encode screen-recording audio tracks at 128 kbps by default.
    public static let recordingScreenAudioBitRate = 128_000
    /// Render the recording control panel surface at 85% opacity by default.
    public static let recordingHUDOpacity = 0.85
    /// Restore full panel opacity while the pointer is inside it.
    public static let recordingHUDHoverRestore = true
    /// Show the floating recording control panel by default.
    public static let recordingHUDHidden = false
    /// Draw a frame around the captured area by default.
    public static let recordingShowCaptureFrame = true
    /// Keep Finder closed when a recording finishes by default.
    public static let recordingRevealOnFinish = false
    /// Keep the recording control panel in the top-trailing corner by default.
    public static let recordingHUDCorner = "topTrailing"

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
    /// Removed `bottom*` anchors and other invalid legacy values are written back as `top` so the
    /// Settings picker always has a visible selection.
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

/// Reads the appearance preferences of the floating recording control panel.
public enum RecordingHUDPreferences {
    /// Allowed surface opacity range for the floating control panel.
    public static let opacityRange: ClosedRange<Double> = 0.30...1

    /// Returns the panel surface opacity, clamped to `opacityRange` and persisted when corrected.
    public static func opacity(in defaults: UserDefaults = .standard) -> Double {
        let key = PreferenceKeys.recordingHUDOpacity
        guard let storedValue = defaults.object(forKey: key) as? NSNumber else {
            return PreferenceDefaults.recordingHUDOpacity
        }
        let rawValue = storedValue.doubleValue
        let normalizedValue =
            rawValue.isNaN
            ? PreferenceDefaults.recordingHUDOpacity
            : min(max(rawValue, opacityRange.lowerBound), opacityRange.upperBound)
        if rawValue != normalizedValue {
            defaults.set(normalizedValue, forKey: key)
        }
        return normalizedValue
    }

    /// Returns whether the panel restores full opacity while hovered, defaulting to `true`.
    public static func hoverRestore(in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: PreferenceKeys.recordingHUDHoverRestore) != nil else {
            return PreferenceDefaults.recordingHUDHoverRestore
        }
        return defaults.bool(forKey: PreferenceKeys.recordingHUDHoverRestore)
    }

    /// Returns whether the floating panel is suppressed, defaulting to `false`.
    public static func isHidden(in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: PreferenceKeys.recordingHUDHidden) != nil else {
            return PreferenceDefaults.recordingHUDHidden
        }
        return defaults.bool(forKey: PreferenceKeys.recordingHUDHidden)
    }

    /// Returns whether a recording frame is drawn around the captured area, defaulting to `true`.
    public static func showsCaptureFrame(in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: PreferenceKeys.recordingShowCaptureFrame) != nil else {
            return PreferenceDefaults.recordingShowCaptureFrame
        }
        return defaults.bool(forKey: PreferenceKeys.recordingShowCaptureFrame)
    }

    /// Returns whether a finished recording is revealed in Finder, defaulting to `false`.
    public static func revealsOnFinish(in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: PreferenceKeys.recordingRevealOnFinish) != nil else {
            return PreferenceDefaults.recordingRevealOnFinish
        }
        return defaults.bool(forKey: PreferenceKeys.recordingRevealOnFinish)
    }

    /// Returns the stored panel corner identifier, defaulting to `topTrailing`.
    ///
    /// The value is validated by `CaptureCore`, which owns the corner model.
    public static func cornerIdentifier(in defaults: UserDefaults = .standard) -> String {
        guard let rawValue = defaults.string(forKey: PreferenceKeys.recordingHUDCorner),
            !rawValue.isEmpty
        else {
            return PreferenceDefaults.recordingHUDCorner
        }
        return rawValue
    }
}

/// Recording kinds that own independent destination and AAC preferences.
///
/// This type is deliberately kind-agnostic: `SharedKit` must not depend on
/// `CaptureCore.RecordingKind`. The app maps its recording kind to this enum.
public enum RecordingOutputKind: String, CaseIterable, Sendable {
    /// Audio-only recordings.
    case audio
    /// Screen recordings, including their embedded audio tracks.
    case screen
}

/// Reads and updates per-kind recording destinations and seeds legacy values once.
///
/// Priority, before the one-time seed exists:
/// 1. the per-kind key;
/// 2. the legacy shared `recording_customOutputDirectory`;
/// 3. the `Movies/SnapGlass/Recordings` default.
///
/// After the seed marker exists, only the per-kind key is read. Resetting one
/// kind removes that key and returns it to the default without re-coupling the
/// other kind or the legacy key.
public enum RecordingDestinationPreferences {
    /// Maximum number of previously used folders retained for discovery.
    public static let maximumKnownDirectories = 12

    /// Returns the selected destination for `kind`, defaulting to `Movies/SnapGlass/Recordings`.
    ///
    /// This lookup never creates the directory.
    ///
    /// - Parameters:
    ///   - kind: The recording kind whose destination should be read.
    ///   - defaults: Defaults store containing the optional custom directory.
    ///   - moviesDirectory: Optional Movies-directory override, primarily for tests.
    ///   - fileManager: File manager used to locate the user's Movies directory.
    /// - Returns: The custom or default directory, or `nil` if Movies cannot be resolved.
    public static func directory(
        for kind: RecordingOutputKind = .screen,
        in defaults: UserDefaults = .standard,
        moviesDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL? {
        if let customDirectory = customDirectory(for: kind, in: defaults) {
            return customDirectory
        }
        guard
            let moviesDirectory = moviesDirectory
                ?? fileManager.urls(for: .moviesDirectory, in: .userDomainMask).first
        else {
            return nil
        }
        return
            moviesDirectory
            .appendingPathComponent("SnapGlass", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    /// Returns the remembered custom directory for `kind`, if one was selected.
    ///
    /// Before the one-time seed has run, the legacy shared key is still read so an
    /// upgraded user's existing folder is found. Once the marker exists, a missing
    /// per-kind key means the user reset it (or never chose one) and the legacy key
    /// is never consulted again.
    public static func customDirectory(
        for kind: RecordingOutputKind = .screen,
        in defaults: UserDefaults = .standard
    ) -> URL? {
        if let path = defaults.string(forKey: customDirectoryKey(for: kind)), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        guard defaults.object(forKey: PreferenceKeys.recordingPerKindPreferencesSeeded) == nil else {
            return nil
        }
        return legacyCustomDirectory(in: defaults)
    }

    /// Remembers a user-selected directory without creating it or moving files.
    ///
    /// Also records the folder for export-window discovery, including after it is
    /// later changed or reset.
    public static func setCustomDirectory(
        _ directory: URL,
        for kind: RecordingOutputKind = .screen,
        in defaults: UserDefaults = .standard
    ) {
        guard directory.isFileURL else { return }
        seedLegacySharedValuesIfNeeded(in: defaults)
        let standardized = directory.standardizedFileURL
        defaults.set(standardized.path, forKey: customDirectoryKey(for: kind))
        let volumeKey = customDirectoryVolumeUUIDKey(for: kind)
        if let volumeUUID = RecordingVolumeIdentityPolicy.volumeUUIDString(for: standardized),
            !RecordingVolumeIdentityPolicy.isStaleVolumesMountPoint(standardized)
        {
            defaults.set(volumeUUID, forKey: volumeKey)
        } else {
            // A reserved /Volumes directory that looks like a stale mount point
            // must not capture the current (system) UUID and bypass the guard.
            defaults.removeObject(forKey: volumeKey)
        }
        rememberDirectory(standardized, in: defaults)
    }

    /// Returns the persistent volume UUID captured when the custom folder was chosen.
    ///
    /// `nil` means the setting predates UUID capture, the volume does not report a
    /// persistent UUID, or the custom folder is not currently set. Callers must not
    /// treat a missing value as a mismatch.
    public static func customDirectoryVolumeUUID(
        for kind: RecordingOutputKind = .screen,
        in defaults: UserDefaults = .standard
    ) -> String? {
        let pathKey = customDirectoryKey(for: kind)
        guard let path = defaults.string(forKey: pathKey), !path.isEmpty else {
            return nil
        }
        guard let value = defaults.string(forKey: customDirectoryVolumeUUIDKey(for: kind)),
            !value.isEmpty
        else {
            return nil
        }
        return value
    }

    /// Clears the custom directory for `kind` and restores the Movies default.
    ///
    /// The folder stays in the discovery list so existing recordings remain
    /// visible; the legacy keys are never removed.
    public static func reset(
        for kind: RecordingOutputKind = .screen,
        in defaults: UserDefaults = .standard
    ) {
        seedLegacySharedValuesIfNeeded(in: defaults)
        defaults.removeObject(forKey: customDirectoryKey(for: kind))
        defaults.removeObject(forKey: customDirectoryVolumeUUIDKey(for: kind))
    }

    /// Copies legacy shared values into per-kind keys exactly once.
    ///
    /// New values already present are never overwritten. The marker is written
    /// last, after every value has been computed and applied. Legacy keys are
    /// retained for upgrade discovery.
    public static func seedLegacySharedValuesIfNeeded(in defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: PreferenceKeys.recordingPerKindPreferencesSeeded) == nil else {
            return
        }

        var pending: [String: Any] = [:]
        let legacyPath = legacyCustomDirectoryPath(in: defaults)
        if let legacyPath {
            for kind in RecordingOutputKind.allCases {
                let key = customDirectoryKey(for: kind)
                if defaults.object(forKey: key) == nil {
                    pending[key] = legacyPath
                }
            }
        }
        // Audio keeps the legacy bitrate key as its own key; screen gets a copy.
        if defaults.object(forKey: PreferenceKeys.recordingScreenAudioBitRate) == nil,
            let legacyBitRate = defaults.object(forKey: PreferenceKeys.recordingAudioBitRate) as? NSNumber
        {
            pending[PreferenceKeys.recordingScreenAudioBitRate] = legacyBitRate.intValue
        }

        for (key, value) in pending {
            defaults.set(value, forKey: key)
        }
        if let legacyPath {
            rememberDirectory(
                URL(fileURLWithPath: legacyPath, isDirectory: true).standardizedFileURL,
                in: defaults
            )
        }
        defaults.set(true, forKey: PreferenceKeys.recordingPerKindPreferencesSeeded)
    }

    /// Returns every folder worth scanning for completed recordings.
    ///
    /// Includes previously used folders and the legacy shared custom folder, even
    /// after the user changes or resets the current destination. This list is for
    /// discovery only; it never changes where new recordings are written.
    public static func knownDirectories(in defaults: UserDefaults = .standard) -> [URL] {
        var standardizedPaths: [String] = []

        func append(_ path: String?) {
            guard let path, !path.isEmpty else { return }
            let standardized = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
            guard !standardizedPaths.contains(standardized) else { return }
            standardizedPaths.append(standardized)
        }

        for path in defaults.stringArray(forKey: PreferenceKeys.recordingKnownOutputRoots) ?? [] {
            append(path)
        }
        append(legacyCustomDirectoryPath(in: defaults))
        return standardizedPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Records a folder for export-window discovery without creating it.
    public static func rememberDirectory(_ directory: URL, in defaults: UserDefaults = .standard) {
        guard directory.isFileURL else { return }
        let path = directory.standardizedFileURL.path
        var paths = (defaults.stringArray(forKey: PreferenceKeys.recordingKnownOutputRoots) ?? [])
            .filter { !$0.isEmpty && $0 != path }
        paths.insert(path, at: 0)
        if paths.count > maximumKnownDirectories {
            paths.removeLast(paths.count - maximumKnownDirectories)
        }
        let storedPaths = defaults.stringArray(forKey: PreferenceKeys.recordingKnownOutputRoots) ?? []
        if paths != storedPaths {
            defaults.set(paths, forKey: PreferenceKeys.recordingKnownOutputRoots)
        }
    }

    /// Returns the legacy shared custom directory, if one was selected.
    private static func legacyCustomDirectory(in defaults: UserDefaults) -> URL? {
        guard let path = legacyCustomDirectoryPath(in: defaults) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    private static func legacyCustomDirectoryPath(in defaults: UserDefaults) -> String? {
        guard let path = defaults.string(forKey: PreferenceKeys.recordingCustomOutputDirectory),
            !path.isEmpty
        else {
            return nil
        }
        return path
    }

    private static func customDirectoryKey(for kind: RecordingOutputKind) -> String {
        switch kind {
        case .audio: PreferenceKeys.recordingAudioCustomOutputDirectory
        case .screen: PreferenceKeys.recordingScreenCustomOutputDirectory
        }
    }

    private static func customDirectoryVolumeUUIDKey(for kind: RecordingOutputKind) -> String {
        switch kind {
        case .audio: PreferenceKeys.recordingAudioCustomOutputVolumeUUID
        case .screen: PreferenceKeys.recordingScreenCustomOutputVolumeUUID
        }
    }
}

/// Top-edge anchors supported by the floating screenshot shelf.
///
/// The shelf always hangs from the top edge, just below the menu bar. Legacy
/// `bottom*` values are normalized to `.top` when read by `ScreenshotShelfPreferences`.
public enum ScreenshotShelfAnchor: String, CaseIterable, Sendable {
    case topLeading
    case top
    case topTrailing

    /// Horizontal placement within the usable screen.
    public enum HorizontalPlacement: Sendable {
        case leading
        case center
        case trailing
    }

    public var horizontalPlacement: HorizontalPlacement {
        switch self {
        case .topLeading: .leading
        case .top: .center
        case .topTrailing: .trailing
        }
    }

    /// Localization key used by the Settings position picker.
    public var localizationKey: String {
        switch self {
        case .topLeading: "Top Left"
        case .top: "Top Center"
        case .topTrailing: "Top Right"
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
