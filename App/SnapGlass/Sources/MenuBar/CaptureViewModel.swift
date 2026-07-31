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
/// - Performing OCR and barcode scanning from clipboard
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
    
    /// The current toast message to display
    @Published public var toastMessage: ToastMessage?

    /// Whether a manual scrolling capture session is active.
    @Published public private(set) var isScrollCaptureActive = false

    /// Number of unique frames currently collected for scrolling capture.
    @Published public private(set) var scrollCapturedFrameCount = 0
    
    /// Closure to open a specific window by ID
    public var openWindow: ((String) -> Void)?

    private var scrollSession: ScrollSession?
    private var scrollFrames: [ScrollFrame] = []
    private var scrollSourceAppName: String?
    private var scrollSourceWindowTitle: String?
    
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
        scrollEngine: ScrollStitchActor = ScrollStitchActor()
    ) {
        self.captureOrchestrator = captureOrchestrator
        self.ocrPipeline = ocrPipeline
        self.barcodeEngine = barcodeEngine
        self.scrollEngine = scrollEngine
        
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
    
    /// Triggers an area capture with interactive region selection overlay.
    public func captureArea() {
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
            await performCapture(
                mode: CaptureCore.CaptureMode.area(selection.screenRect),
                normalizedMaskPath: selection.normalizedPath,
                historyModeOverride: selection.isFreeform ? "freeform" : nil,
                managesCaptureState: false
            )
        }
    }
    
    /// Triggers a window capture.
    public func captureWindow() {
        Task {
            guard !isCapturing else { return }
            isCapturing = true
            defer { isCapturing = false }

            guard await captureOrchestrator.checkPermissionStatus() else {
                openWindow?("permission")
                return
            }

            guard let selectedWindow = await selectWindow() else { return }

            await performCapture(
                mode: CaptureCore.CaptureMode.window(selectedWindow.windowID),
                sourceAppName: selectedWindow.appName,
                sourceWindowTitle: selectedWindow.windowTitle,
                managesCaptureState: false
            )
        }
    }
    
    /// Triggers a fullscreen capture.
    public func captureFullscreen() {
        Task {
            await performCapture(mode: CaptureCore.CaptureMode.fullscreen)
        }
    }

    /// Starts a permission-minimal scrolling capture session.
    /// The user scrolls the selected Safari or Chrome window manually between frames.
    public func startScrollCapture() {
        Task {
            guard !isCapturing, !isScrollCaptureActive else { return }
            isCapturing = true
            defer { isCapturing = false }

            guard await captureOrchestrator.checkPermissionStatus() else {
                openWindow?("permission")
                return
            }

            guard let selectedWindow = await selectWindow() else { return }

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
                    sourceWindowTitle: sourceWindowTitle
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
    public func openEditor(with image: CGImage) {
        editorImage = image
        editorSessionID = UUID()
        openWindow?("editor")
    }
    
    /// Scans for barcodes in the image currently in the clipboard.
    public func scanBarcodeFromClipboard() {
        Task {
            guard let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage,
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                showToast(message: "No image found in clipboard", type: .error)
                return
            }
            
            await performBarcodeScan(on: cgImage)
        }
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
                historyModeOverride: historyModeOverride
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
        historyModeOverride: String? = nil
    ) async {
        showToast(message: "Capture successful", type: .success)

        if Self.boolPreference(
            forKey: PreferenceKeys.captureOpenEditor,
            defaultValue: PreferenceDefaults.captureOpenEditor
        ) {
            openEditor(with: image)
        }

        if Self.boolPreference(
            forKey: PreferenceKeys.captureCopyToClipboard,
            defaultValue: PreferenceDefaults.captureCopyToClipboard
        ) {
            let nsImage = NSImage(
                cgImage: image,
                size: NSSize(width: image.width, height: image.height)
            )
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([nsImage])
        }

        let shouldRunOCR = Self.boolPreference(
            forKey: PreferenceKeys.captureAutoOCR,
            defaultValue: PreferenceDefaults.captureAutoOCR
        )
        let shouldCopyOCRText = Self.boolPreference(
            forKey: PreferenceKeys.captureCopyOCRText,
            defaultValue: PreferenceDefaults.captureCopyOCRText
        )
        let ocrResult = shouldRunOCR
            ? await performOCR(on: image, copyToClipboard: shouldCopyOCRText)
            : nil

        let autoSave = Self.boolPreference(
            forKey: PreferenceKeys.historyAutoSave,
            defaultValue: PreferenceDefaults.historyAutoSave
        )
        let saveFullText = Self.boolPreference(
            forKey: PreferenceKeys.historySaveFullText,
            defaultValue: PreferenceDefaults.historySaveFullText
        )

        if autoSave {
            let textToStore = saveFullText ? (ocrResult?.text ?? "") : ""
            let confidence = ocrResult?.confidence ?? 0
            let modeDescription = historyModeOverride ?? Self.historyModeDescription(for: captureMode)
            let sourceAppName = sourceAppName
            let sourceWindowTitle = sourceWindowTitle

            Task(priority: .utility) { [weak self] in
                let logger = Logger(category: "capture")
                guard let history = HistoryActor.shared else {
                    logger.error("HistoryActor unavailable, auto-save skipped")
                    await MainActor.run {
                        self?.showToast(message: "History unavailable; capture not saved", type: .error)
                    }
                    return
                }
                do {
                    try await history.saveCapture(
                        image: image,
                        textContent: textToStore,
                        ocrConfidence: confidence,
                        captureMode: modeDescription,
                        sourceType: .screenshot,
                        sourceAppName: sourceAppName,
                        sourceWindowTitle: sourceWindowTitle
                    )
                } catch {
                    logger.error("Auto-save failed: \(error.localizedDescription)")
                    await MainActor.run {
                        self?.showToast(message: "History save failed", type: .error)
                    }
                }
            }
        }
    }

    private func selectWindow() async -> WindowSelectionResult? {
        await withCheckedContinuation { continuation in
            var didResume = false
            DispatchQueue.main.async {
                WindowSelectionPanel.show { result in
                    guard !didResume else { return }
                    didResume = true
                    continuation.resume(returning: result)
                }
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
        let languages: [String]
        switch languagePreference {
        case "en":
            languages = ["en-US", "zh-Hans"]
        case "zh":
            languages = ["zh-Hans", "en-US"]
        default:
            languages = ["zh-Hans", "en-US"]
        }

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

    private static func stringPreference(forKey key: String, defaultValue: String) -> String {
        UserDefaults.standard.string(forKey: key) ?? defaultValue
    }

    private static func doublePreference(forKey key: String, defaultValue: Double) -> Double {
        guard UserDefaults.standard.object(forKey: key) != nil else {
            return defaultValue
        }
        return UserDefaults.standard.double(forKey: key)
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
    
    /// Scans for barcodes in the specified image.
    ///
    /// - Parameter image: The image to scan for barcodes.
    private func performBarcodeScan(on image: CGImage) async {
        do {
            let results = try await barcodeEngine.detect(in: image, types: [])
            if let first = results.first {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(first.payload, forType: .string)
                showToast(message: "Barcode copied to clipboard", type: .success)
            } else {
                showToast(message: "No barcode found", type: .info)
            }
        } catch {
            showToast(message: "Barcode scan failed: \(error.localizedDescription)", type: .error)
        }
    }
    
    /// Shows a toast notification.
    ///
    /// - Parameters:
    ///   - message: The message to display.
    ///   - type: The type of toast (success, error, info).
    public func showToast(message: String, type: ToastType) {
        toastMessage = ToastMessage(message: message, type: type)
        
        // Auto dismiss
        Task {
            try? await Task.sleep(for: .seconds(3))
            if toastMessage?.message == message {
                toastMessage = nil
            }
        }
    }
}

/// Represents a toast message.
public struct ToastMessage: Equatable {
    /// The message text.
    public let message: String
    
    /// The type of toast.
    public let type: ToastType
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
