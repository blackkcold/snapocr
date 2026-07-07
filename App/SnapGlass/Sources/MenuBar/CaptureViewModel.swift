import SwiftUI
import SharedKit
import CaptureCore
import OCRCore
import BarcodeCore
import HistoryCore
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
    
    /// Whether a capture is currently in progress
    @Published public var isCapturing = false
    
    /// The image to open in the annotation editor
    @Published public var editorImage: CGImage?
    
    /// The current toast message to display
    @Published public var toastMessage: ToastMessage?
    
    /// Closure to open a specific window by ID
    public var openWindow: ((String) -> Void)?
    
    /// Initializes a new CaptureViewModel.
    ///
    /// - Parameters:
    ///   - captureOrchestrator: The orchestrator for handling screen captures.
    ///   - ocrPipeline: The pipeline for performing OCR.
    ///   - barcodeEngine: The engine for detecting barcodes.
    public init(
        captureOrchestrator: CaptureOrchestrator = CaptureOrchestrator(),
        ocrPipeline: OCRPipeline = OCRPipeline(),
        barcodeEngine: VisionBarcodeEngine = VisionBarcodeEngine()
    ) {
        self.captureOrchestrator = captureOrchestrator
        self.ocrPipeline = ocrPipeline
        self.barcodeEngine = barcodeEngine
        
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

            let selectedRect: CGRect? = await withCheckedContinuation { continuation in
                var didResume = false
                DispatchQueue.main.async {
                    AreaSelectionPanel.show { rect in
                        guard !didResume else { return }
                        didResume = true
                        continuation.resume(returning: rect)
                    }
                }
            }

            guard let rect = selectedRect else { return }
            await performCapture(mode: CaptureCore.CaptureMode.area(rect))
        }
    }
    
    /// Triggers a window capture.
    public func captureWindow() {
        Task {
            guard !isCapturing else { return }

            guard await captureOrchestrator.checkPermissionStatus() else {
                openWindow?("permission")
                return
            }

            let selectedWindow: WindowSelectionResult? = await withCheckedContinuation { continuation in
                var didResume = false
                DispatchQueue.main.async {
                    WindowSelectionPanel.show { result in
                        guard !didResume else { return }
                        didResume = true
                        continuation.resume(returning: result)
                    }
                }
            }

            guard let selectedWindow else { return }

            await performCapture(
                mode: CaptureCore.CaptureMode.window(selectedWindow.windowID),
                sourceAppName: selectedWindow.appName,
                sourceWindowTitle: selectedWindow.windowTitle
            )
        }
    }
    
    /// Triggers a fullscreen capture.
    public func captureFullscreen() {
        Task {
            await performCapture(mode: CaptureCore.CaptureMode.fullscreen)
        }
    }
    
    /// Performs OCR on the image currently in the clipboard.
    public func ocrFromClipboard() {
        Task {
            guard let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage,
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                showToast(message: "No image found in clipboard", type: .error)
                return
            }
            
            _ = await performOCR(on: cgImage)
        }
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
        sourceWindowTitle: String? = nil
    ) async {
        guard !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }
        
        do {
            let result = try await captureOrchestrator.capture(mode: mode)
            showToast(message: "Capture successful", type: .success)
            
            // Open annotation editor
            editorImage = result.image
            openWindow?("editor")
            
            // Copy to clipboard
            let nsImage = NSImage(cgImage: result.image, size: NSSize(width: result.image.width, height: result.image.height))
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([nsImage])
            
            // Perform OCR automatically
            let ocrResult = await performOCR(on: result.image)

            let autoSave = Self.boolPreference(forKey: "history_autoSave", defaultValue: true)
            let saveFullText = Self.boolPreference(forKey: "history_saveFullText", defaultValue: false)

            if autoSave {
                let image = result.image
                let textToStore = saveFullText ? (ocrResult?.text ?? "") : ""
                let confidence = ocrResult?.confidence ?? 0
                let captureMode = Self.historyModeDescription(for: result.captureMode)
                let sourceAppName = sourceAppName
                let sourceWindowTitle = sourceWindowTitle

                Task.detached(priority: .utility) {
                    try? await HistoryActor.shared.saveCapture(
                        image: image,
                        textContent: textToStore,
                        ocrConfidence: confidence,
                        captureMode: captureMode,
                        sourceType: .screenshot,
                        sourceAppName: sourceAppName,
                        sourceWindowTitle: sourceWindowTitle
                    )
                }
            }
            
        } catch CaptureError.permissionDenied {
            openWindow?("permission")
        } catch {
            showToast(message: "Capture failed: \(error.localizedDescription)", type: .error)
        }
    }
    
    /// Performs OCR on the specified image.
    ///
    /// - Parameter image: The image to perform OCR on.
    private func performOCR(on image: CGImage) async -> OCRResult? {
        do {
            let result = try await ocrPipeline.recognize(image)
            if result.text.isEmpty {
                showToast(message: "No text found", type: .info)
            } else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.text, forType: .string)
                showToast(message: "Text copied to clipboard", type: .success)
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
