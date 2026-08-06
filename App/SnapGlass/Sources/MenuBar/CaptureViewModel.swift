import SwiftUI
import SharedKit
import CaptureCore
import OCRCore
import BarcodeCore
import HistoryCore
import ScrollCore
import AppKit

/// View model for managing capture state and coordinating between menu bar and capture services.
///
/// This view model handles:
/// - Triggering captures (area, window, fullscreen)
/// - Performing OCR from the clipboard and suggesting detected barcode content
/// - Managing toast notifications
/// - Setting up global hotkeys
@MainActor
public final class CaptureViewModel: ObservableObject {
    /// The orchestrator for handling screen captures
    public let captureOrchestrator: CaptureOrchestrator
    
    /// The pipeline for performing OCR
    public let ocrPipeline: OCRPipeline
    
    /// The engine for detecting barcodes
    public let barcodeEngine: VisionBarcodeEngine

    /// The actor responsible for assembling scrolling screenshots.
    public let scrollEngine: ScrollStitchActor
    
    /// Whether a capture is currently in progress
    @Published public var isCapturing = false
    
    /// The image to open in the annotation editor
    @Published public var editorImage: CGImage?

    /// Changes whenever a different image should create a fresh editor document.
    @Published public private(set) var editorSessionID = UUID()

    /// Capture metadata used to configure image-specific editor affordances.
    @Published private(set) var editorContext = EditorCaptureContext.standard

    /// The current toast message to display
    @Published public var toastMessage: ToastMessage?

    /// Whether a manual scrolling capture session is active.
    @Published public private(set) var isScrollCaptureActive = false

    /// Number of unique frames currently collected for scrolling capture.
    @Published public private(set) var scrollCapturedFrameCount = 0

    /// Whether a user-triggered update check is running.
    @Published public private(set) var isCheckingForUpdates = false

    /// Whether a verified update DMG is being downloaded.
    @Published public private(set) var isDownloadingUpdate = false
    
    /// Closure to open a specific window by ID
    public var openWindow: ((String) -> Void)?

    private var scrollSession: ScrollSession?
    private var scrollFrames: [ScrollFrame] = []
    private var scrollSourceAppName: String?
    private var scrollSourceWindowTitle: String?
    private let updateService: UpdateService
    private let logger = Logger(category: "capture")

    private enum CaptureDestination {
        case configured
        case clipboardOnly
        case editorOnly
    }

    /// Initializes a new CaptureViewModel.
    ///
    /// - Parameters:
    ///   - captureOrchestrator: The orchestrator for handling screen captures.
    ///   - ocrPipeline: The pipeline for performing OCR.
    ///   - barcodeEngine: The engine for detecting barcodes.
    public init(
        captureOrchestrator: CaptureOrchestrator = CaptureOrchestrator(),
        ocrPipeline: OCRPipeline = OCRPipeline(),
        barcodeEngine: VisionBarcodeEngine = VisionBarcodeEngine(),
        scrollEngine: ScrollStitchActor = ScrollStitchActor(),
        updateService: UpdateService = UpdateService()
    ) {
        self.captureOrchestrator = captureOrchestrator
        self.ocrPipeline = ocrPipeline
        self.barcodeEngine = barcodeEngine
        self.scrollEngine = scrollEngine
        self.updateService = updateService
        
        setupHotKeys()
    }
    
    /// Sets up the global hotkeys using HotKeyManager.
    private func setupHotKeys() {
        HotKeyManager.shared.onCaptureArea = { [weak self] in
            self?.captureArea()
        }
        
        HotKeyManager.shared.onCaptureWindow = { [weak self] in
            self?.captureWindow()
        }
        
        HotKeyManager.shared.onCaptureFullscreen = { [weak self] in
            self?.captureFullscreen()
        }
        
        HotKeyManager.shared.onOCRFromClipboard = { [weak self] in
            self?.ocrFromClipboard()
        }
    }
    
    /// Checks screen recording permissions on launch and opens the permission guide if needed.
    public func checkPermissionsOnLaunch() {
        Task {
            let status = await captureOrchestrator.checkPermissionStatus()
            if !status {
                openWindow?("permission")
            }
        }
    }

    /// Checks GitHub Releases after an explicit user action and offers a verified DMG download.
    public func checkForUpdates() {
        guard !isCheckingForUpdates, !isDownloadingUpdate else { return }
        isCheckingForUpdates = true

        Task {
            defer { isCheckingForUpdates = false }
            do {
                let forceUpdate = Self.boolPreference(
                    forKey: PreferenceKeys.forceUpdateAvailable,
                    defaultValue: PreferenceDefaults.forceUpdateAvailable
                )
                let result = try await updateService.check(
                    currentVersion: Self.currentVersion,
                    force: forceUpdate
                )
                switch result {
                case .upToDate(let latestVersion):
                    presentInformationAlert(
                        title: NSLocalizedString("SnapGlass is Up to Date", comment: "Update status title"),
                        message: String(
                            format: NSLocalizedString(
                                "You are running the latest version (%@).",
                                comment: "Latest version message"
                            ),
                            latestVersion.description
                        )
                    )
                case .updateAvailable(let release):
                    await presentUpdate(release)
                }
            } catch {
                presentInformationAlert(
                    title: NSLocalizedString("Unable to Check for Updates", comment: "Update error title"),
                    message: error.localizedDescription,
                    style: .warning
                )
            }
        }
    }
    
    /// Triggers an area capture with interactive region selection overlay.
    public func captureArea() {
        startAreaCapture()
    }

    private func startAreaCapture() {
        Task {
            guard !isCapturing else { return }
            isCapturing = true
            defer { isCapturing = false }

            let selectionStyle = CaptureSelectionStyle(
                rawValue: Self.stringPreference(
                    forKey: PreferenceKeys.captureSelectionStyle,
                    defaultValue: PreferenceDefaults.captureSelectionStyle
                )
            ) ?? .rectangle
            let selection: AreaSelectionResult? = await withCheckedContinuation { continuation in
                var didResume = false
                DispatchQueue.main.async {
                    AreaSelectionPanel.show(style: selectionStyle) { result in
                        guard !didResume else { return }
                        didResume = true
                        continuation.resume(returning: result)
                    }
                }
            }

            guard let selection else { return }
            let destination: CaptureDestination = switch selection.action {
            case .copy: .clipboardOnly
            case .edit: .editorOnly
            }
            await performCapture(
                mode: CaptureCore.CaptureMode.area(selection.screenRect),
                normalizedMaskPath: selection.normalizedPath,
                historyModeOverride: selection.isFreeform ? "freeform" : nil,
                destination: destination,
                managesCaptureState: false
            )
        }
    }
    
    /// Triggers a window capture.
    public func captureWindow() {
        startWindowCapture(destination: .configured)
    }

    /// Captures a selected window directly to the clipboard without opening the editor.
    public func captureWindowToClipboard() {
        startWindowCapture(destination: .clipboardOnly)
    }

    private func startWindowCapture(destination: CaptureDestination) {
        Task {
            guard !isCapturing, !isScrollCaptureActive else { return }
            isCapturing = true
            defer { isCapturing = false }

            guard await captureOrchestrator.checkPermissionStatus() else {
                openWindow?("permission")
                return
            }

            guard let selectedWindow = await selectWindow() else { return }

            switch selectedWindow.action {
            case .still:
                await performCapture(
                    mode: CaptureCore.CaptureMode.window(selectedWindow.windowID),
                    sourceAppName: selectedWindow.appName,
                    sourceWindowTitle: selectedWindow.windowTitle,
                    destination: destination,
                    managesCaptureState: false
                )
            case .edit:
                // Double-clicking a window preview opens it directly in the editor.
                await performCapture(
                    mode: CaptureCore.CaptureMode.window(selectedWindow.windowID),
                    sourceAppName: selectedWindow.appName,
                    sourceWindowTitle: selectedWindow.windowTitle,
                    destination: .editorOnly,
                    managesCaptureState: false
                )
            case .scrolling:
                await beginScrollCapture(with: selectedWindow)
            }
        }
    }
    
    /// Triggers a fullscreen capture.
    public func captureFullscreen() {
        Task {
            await performCapture(mode: CaptureCore.CaptureMode.fullscreen, destination: .configured)
        }
    }

    /// Captures the fullscreen image directly to the clipboard without opening the editor.
    public func captureFullscreenToClipboard() {
        Task {
            await performCapture(mode: CaptureCore.CaptureMode.fullscreen, destination: .clipboardOnly)
        }
    }

    /// Starts a permission-minimal scrolling capture session.
    /// The user scrolls the selected Safari or Chrome window manually between frames.
    public func startScrollCapture() {
        captureWindow()
    }

    private func beginScrollCapture(with selectedWindow: WindowSelectionResult) async {
        var startedSession: ScrollSession?
        do {
            let session = try await scrollEngine.startCapture(windowID: selectedWindow.windowID)
            startedSession = session
            let result = try await captureOrchestrator.capture(
                mode: .window(selectedWindow.windowID),
                options: Self.currentCaptureOptions()
            )

            scrollSession = session
            scrollFrames = [ScrollFrame(image: result.image, index: 0, timestamp: result.timestamp)]
            scrollSourceAppName = selectedWindow.appName
            scrollSourceWindowTitle = selectedWindow.windowTitle
            scrollCapturedFrameCount = 1
            isScrollCaptureActive = true
            showToast(message: "Scroll the window, then capture the next frame", type: .info)
        } catch CaptureError.permissionDenied {
            if let startedSession {
                await scrollEngine.cancelCapture(session: startedSession)
            }
            openWindow?("permission")
        } catch {
            if let startedSession {
                await scrollEngine.cancelCapture(session: startedSession)
            }
            resetScrollCaptureState()
            showToast(message: error.localizedDescription, type: .error)
        }
    }

    /// Captures another frame after the user has manually scrolled the target window.
    public func captureNextScrollFrame() {
        Task {
            guard !isCapturing,
                  let session = scrollSession,
                  let previousFrame = scrollFrames.last else { return }
            isCapturing = true
            defer { isCapturing = false }

            do {
                let result = try await captureOrchestrator.capture(
                    mode: .window(session.windowID),
                    options: Self.currentCaptureOptions()
                )
                let isDuplicate = await Task.detached(priority: .userInitiated) {
                    FrameDeduper().isDuplicate(previousFrame.image, result.image)
                }.value
                guard !isDuplicate else {
                    showToast(message: "No visual change detected; scroll and try again", type: .info)
                    return
                }

                scrollFrames.append(ScrollFrame(
                    image: result.image,
                    index: scrollFrames.count,
                    timestamp: result.timestamp
                ))
                scrollCapturedFrameCount = scrollFrames.count
                showToast(message: "Frame \(scrollCapturedFrameCount) captured", type: .success)
            } catch CaptureError.permissionDenied {
                openWindow?("permission")
            } catch {
                showToast(message: "Scroll frame failed: \(error.localizedDescription)", type: .error)
            }
        }
    }

    /// Finishes the active scrolling capture and sends the long image through the normal capture flow.
    public func finishScrollCapture() {
        Task {
            guard !isCapturing, scrollFrames.count >= 2 else { return }
            isCapturing = true
            defer { isCapturing = false }

            do {
                let image = try await scrollEngine.stitchFrames(scrollFrames)
                let sourceAppName = scrollSourceAppName
                let sourceWindowTitle = scrollSourceWindowTitle
                resetScrollCaptureState()
                await processCapturedImage(
                    image,
                    captureMode: .scroll,
                    sourceAppName: sourceAppName,
                    sourceWindowTitle: sourceWindowTitle,
                    destination: .editorOnly
                )
            } catch {
                showToast(message: error.localizedDescription, type: .error)
            }
        }
    }

    /// Cancels the active scrolling capture and releases its buffered frames.
    public func cancelScrollCapture() {
        let session = scrollSession
        resetScrollCaptureState()
        Task {
            if let session {
                await scrollEngine.cancelCapture(session: session)
            }
        }
        showToast(message: "Scrolling capture cancelled", type: .info)
    }
    
    /// Performs OCR on the image currently in the clipboard.
    public func ocrFromClipboard() {
        Task {
            guard let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage,
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                showToast(message: "No image found in clipboard", type: .error)
                return
            }
            
            _ = await performOCR(on: cgImage, copyToClipboard: true)
        }
    }

    /// Opens a fresh annotation editor session for an image.
    public func openEditor(with image: CGImage, captureMode: String? = nil) {
        editorImage = image
        editorContext = EditorCaptureContext(image: image, captureMode: captureMode)
        editorSessionID = UUID()
        openWindow?("editor")
    }
    
    /// Performs a capture with the specified mode.
    ///
    /// - Parameter mode: The capture mode to use.
    private func performCapture(
        mode: CaptureCore.CaptureMode,
        sourceAppName: String? = nil,
        sourceWindowTitle: String? = nil,
        normalizedMaskPath: [CGPoint]? = nil,
        historyModeOverride: String? = nil,
        destination: CaptureDestination = .configured,
        managesCaptureState: Bool = true
    ) async {
        if managesCaptureState {
            guard !isCapturing else { return }
            isCapturing = true
        }
        defer {
            if managesCaptureState {
                isCapturing = false
            }
        }
        
        do {
            let result = try await captureOrchestrator.capture(
                mode: mode,
                options: Self.currentCaptureOptions()
            )
            let image = if let normalizedMaskPath {
                try SelectionMaskProcessor.apply(to: result.image, normalizedPath: normalizedMaskPath)
            } else {
                result.image
            }
            await processCapturedImage(
                image,
                captureMode: result.captureMode,
                sourceAppName: sourceAppName,
                sourceWindowTitle: sourceWindowTitle,
                historyModeOverride: historyModeOverride,
                destination: destination
            )
        } catch CaptureError.permissionDenied {
            openWindow?("permission")
        } catch {
            showToast(message: "Capture failed: \(error.localizedDescription)", type: .error)
        }
    }

    private func processCapturedImage(
        _ image: CGImage,
        captureMode: CaptureCore.CaptureMode,
        sourceAppName: String? = nil,
        sourceWindowTitle: String? = nil,
        historyModeOverride: String? = nil,
        destination: CaptureDestination = .configured
    ) async {
        let modeDescription = historyModeOverride ?? Self.historyModeDescription(for: captureMode)
        let shouldOpenEditor: Bool
        let shouldCopyImage: Bool
        switch destination {
        case .configured:
            shouldOpenEditor = Self.boolPreference(
                forKey: PreferenceKeys.captureOpenEditor,
                defaultValue: PreferenceDefaults.captureOpenEditor
            )
            shouldCopyImage = Self.boolPreference(
                forKey: PreferenceKeys.captureCopyToClipboard,
                defaultValue: PreferenceDefaults.captureCopyToClipboard
            )
        case .clipboardOnly:
            shouldOpenEditor = false
            shouldCopyImage = true
        case .editorOnly:
            shouldOpenEditor = true
            shouldCopyImage = false
        }

        if shouldOpenEditor {
            openEditor(with: image, captureMode: modeDescription)
        }

        let imageCopySucceeded = !shouldCopyImage || writeImageToClipboard(image)
        // Opening the editor is itself the success feedback, so suppress the
        // success toast to avoid it overlapping the editor UI. Failure to copy
        // (when copying was requested) is still surfaced as an error toast.
        if !imageCopySucceeded {
            showToast(
                message: NSLocalizedString("Unable to copy image", comment: "Capture copy failure"),
                type: .error
            )
        } else if !shouldOpenEditor {
            let completionMessage: String
            if destination == .clipboardOnly {
                completionMessage = NSLocalizedString(
                    "Screenshot copied to clipboard",
                    comment: "Direct capture copy success"
                )
            } else {
                completionMessage = NSLocalizedString("Capture successful", comment: "Capture completion")
            }
            showToast(
                message: completionMessage,
                type: .success
            )
        }

        let barcodeResults = shouldOpenEditor ? await detectBarcodesForSuggestion(in: image) : []

        let shouldRunOCR = Self.boolPreference(
            forKey: PreferenceKeys.captureAutoOCR,
            defaultValue: PreferenceDefaults.captureAutoOCR
        )
        let shouldCopyOCRText = destination != .clipboardOnly && Self.boolPreference(
            forKey: PreferenceKeys.captureCopyOCRText,
            defaultValue: PreferenceDefaults.captureCopyOCRText
        )
        let ocrResult = shouldRunOCR
            ? await performOCR(on: image, copyToClipboard: shouldCopyOCRText)
            : nil

        if let payload = BarcodeCopyCandidate.singlePayload(from: barcodeResults) {
            showBarcodeCopySuggestion(payload: payload)
        }

        let autoSave = Self.boolPreference(
            forKey: PreferenceKeys.historyAutoSave,
            defaultValue: PreferenceDefaults.historyAutoSave
        )
        let saveFullText = Self.boolPreference(
            forKey: PreferenceKeys.historySaveFullText,
            defaultValue: PreferenceDefaults.historySaveFullText
        )

        let shouldSaveToHistory = switch destination {
        case .configured: autoSave
        case .clipboardOnly: imageCopySucceeded
        case .editorOnly: true
        }
        if shouldSaveToHistory {
            let textToStore = saveFullText ? (ocrResult?.text ?? "") : ""
            let confidence = ocrResult?.confidence ?? 0
            scheduleHistorySave(
                image: image,
                textContent: textToStore,
                confidence: confidence,
                captureMode: modeDescription,
                sourceAppName: sourceAppName,
                sourceWindowTitle: sourceWindowTitle
            )
        }
    }

    private func scheduleHistorySave(
        image: CGImage,
        textContent: String,
        confidence: Float,
        captureMode: String,
        sourceAppName: String?,
        sourceWindowTitle: String?
    ) {
        Task.detached(priority: .utility) { [weak self] in
            let logger = Logger(category: "capture")
            guard let history = HistoryActor.shared else {
                logger.error("HistoryActor unavailable, save skipped")
                await MainActor.run {
                    self?.showToast(message: "History unavailable; capture not saved", type: .error)
                }
                return
            }
            do {
                try await history.saveCapture(
                    image: image,
                    textContent: textContent,
                    ocrConfidence: confidence,
                    captureMode: captureMode,
                    sourceType: .screenshot,
                    sourceAppName: sourceAppName,
                    sourceWindowTitle: sourceWindowTitle
                )
            } catch {
                logger.error("History save failed: \(error.localizedDescription)")
                await MainActor.run {
                    self?.showToast(message: "History save failed", type: .error)
                }
            }
        }
    }

    private func selectWindow() async -> WindowSelectionResult? {
        await withCheckedContinuation { continuation in
            var didResume = false
            let resumeOnce: (WindowSelectionResult?) -> Void = { result in
                guard !didResume else { return }
                didResume = true
                continuation.resume(returning: result)
            }

            DispatchQueue.main.async {
                WindowSelectionPanel.show { result in
                    resumeOnce(result)
                }
            }

            // Safety net: if the panel never completes (e.g. a stale/leaked
            // instance), force-resume so `isCapturing` is always released.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(8))
                resumeOnce(nil)
            }
        }
    }

    private func resetScrollCaptureState() {
        scrollSession = nil
        scrollFrames.removeAll()
        scrollSourceAppName = nil
        scrollSourceWindowTitle = nil
        scrollCapturedFrameCount = 0
        isScrollCaptureActive = false
    }

    private func presentUpdate(_ release: UpdateRelease) async {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(
            format: NSLocalizedString("SnapGlass %@ is Available", comment: "Available update title"),
            release.tagName
        )
        let notes = release.releaseNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.informativeText = notes.isEmpty
            ? NSLocalizedString("A new version is ready to download.", comment: "Empty release notes")
            : String(notes.prefix(1_500))
        alert.addButton(withTitle: NSLocalizedString("Download Update", comment: "Download update button"))
        alert.addButton(withTitle: NSLocalizedString("View on GitHub", comment: "Open release page button"))
        alert.addButton(withTitle: NSLocalizedString("Later", comment: "Dismiss update button"))

        NSApplication.shared.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            await download(release)
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(release.releasePageURL)
        default:
            break
        }
    }

    private func download(_ release: UpdateRelease) async {
        isDownloadingUpdate = true
        defer { isDownloadingUpdate = false }
        do {
            let fileURL = try await updateService.download(release)
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            presentInformationAlert(
                title: NSLocalizedString("Update Downloaded", comment: "Update download title"),
                message: String(
                    format: NSLocalizedString(
                        "%@ passed SHA-256 verification and is ready in Downloads.",
                        comment: "Verified update message"
                    ),
                    fileURL.lastPathComponent
                )
            )
        } catch {
            presentInformationAlert(
                title: NSLocalizedString("Update Download Failed", comment: "Update download error title"),
                message: error.localizedDescription,
                style: .warning
            )
        }
    }

    private func presentInformationAlert(
        title: String,
        message: String,
        style: NSAlert.Style = .informational
    ) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: NSLocalizedString("OK", comment: "Alert confirmation"))
        NSApplication.shared.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    
    /// Performs OCR on the specified image.
    ///
    /// - Parameter image: The image to perform OCR on.
    private func performOCR(on image: CGImage, copyToClipboard: Bool) async -> OCRResult? {
        do {
            let options = Self.currentOCROptions()
            let result = try await ocrPipeline.recognize(image, options: options)
            if result.text.isEmpty {
                showToast(message: "No text found", type: .info)
            } else if copyToClipboard {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.text, forType: .string)
                showToast(message: "Text copied to clipboard", type: .success)
            } else {
                showToast(message: "OCR completed", type: .success)
            }
            return result
        } catch {
            showToast(message: "OCR failed: \(error.localizedDescription)", type: .error)
            return nil
        }
    }

    private func writeImageToClipboard(_ image: CGImage) -> Bool {
        let nsImage = NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.writeObjects([nsImage])
    }

    private func detectBarcodesForSuggestion(in image: CGImage) async -> [BarcodeResult] {
        do {
            return try await barcodeEngine.detect(in: image, types: [])
        } catch {
            logger.warning("Automatic barcode hint failed: \(error.localizedDescription)")
            return []
        }
    }

    private func showBarcodeCopySuggestion(payload: String) {
        showToast(
            message: NSLocalizedString("One barcode detected", comment: "Single barcode hint"),
            type: .info,
            actionLabel: NSLocalizedString("Copy Content", comment: "Barcode copy action")
        ) { [weak self] in
            self?.copyBarcodePayload(payload)
        }
    }

    private func copyBarcodePayload(_ payload: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload, forType: .string)
        showToast(
            message: NSLocalizedString("Barcode copied to clipboard", comment: "Barcode copy success"),
            type: .success
        )
    }

    private static func boolPreference(forKey key: String, defaultValue: Bool) -> Bool {
        if UserDefaults.standard.object(forKey: key) == nil {
            return defaultValue
        }
        return UserDefaults.standard.bool(forKey: key)
    }

    private static func currentCaptureOptions() -> CaptureOptions {
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

    private static func currentOCROptions() -> OCROptions {
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

    private static func stringPreference(forKey key: String, defaultValue: String) -> String {
        UserDefaults.standard.string(forKey: key) ?? defaultValue
    }

    private static func doublePreference(forKey key: String, defaultValue: Double) -> Double {
        guard UserDefaults.standard.object(forKey: key) != nil else {
            return defaultValue
        }
        return UserDefaults.standard.double(forKey: key)
    }

    private static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private static func historyModeDescription(for mode: CaptureCore.CaptureMode) -> String {
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
    
    /// Shows a toast notification.
    ///
    /// - Parameters:
    ///   - message: The message to display.
    ///   - type: The type of toast (success, error, info).
    ///   - actionLabel: Optional label for an action button.
    ///   - action: Optional action invoked from the toast button.
    public func showToast(
        message: String,
        type: ToastType,
        actionLabel: String? = nil,
        action: (@MainActor () -> Void)? = nil
    ) {
        let toast = ToastMessage(
            message: message,
            type: type,
            actionLabel: actionLabel,
            action: action
        )
        toastMessage = toast
        
        // Auto dismiss
        Task {
            try? await Task.sleep(for: .seconds(action == nil ? 3 : 6))
            if toastMessage?.id == toast.id {
                toastMessage = nil
            }
        }
    }
}

/// Represents a toast message.
public struct ToastMessage: Equatable {
    /// Stable identity for presentation and dismissal.
    public let id: UUID

    /// The message text.
    public let message: String
    
    /// The type of toast.
    public let type: ToastType

    /// Optional title for a user action.
    public let actionLabel: String?

    let action: (@MainActor () -> Void)?

    init(
        id: UUID = UUID(),
        message: String,
        type: ToastType,
        actionLabel: String? = nil,
        action: (@MainActor () -> Void)? = nil
    ) {
        self.id = id
        self.message = message
        self.type = type
        self.actionLabel = actionLabel
        self.action = action
    }

    public static func == (lhs: ToastMessage, rhs: ToastMessage) -> Bool {
        lhs.id == rhs.id
    }
}

/// The type of toast notification.
public enum ToastType {
    /// A success notification.
    case success
    
    /// An error notification.
    case error
    
    /// An informational notification.
    case info
}
