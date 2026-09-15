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
    @Published public internal(set) var editorSessionID = UUID()

    /// Capture metadata used to configure image-specific editor affordances.
    @Published internal(set) var editorContext = EditorCaptureContext.standard

    /// The current toast message to display
    @Published public var toastMessage: ToastMessage?

    /// Whether a manual scrolling capture session is active.
    @Published public internal(set) var isScrollCaptureActive = false

    /// Number of unique frames currently collected for scrolling capture.
    @Published public internal(set) var scrollCapturedFrameCount = 0

    /// Whether a user-triggered update check is running.
    @Published public internal(set) var isCheckingForUpdates = false

    /// Whether a verified update DMG is being downloaded.
    @Published public internal(set) var isDownloadingUpdate = false
    
    /// Closure to open a specific window by ID
    public var openWindow: ((String) -> Void)?

    var scrollSession: ScrollSession?
    var scrollFrames: [ScrollFrame] = []
    var scrollSourceAppName: String?
    var scrollSourceWindowTitle: String?
    let updateService: UpdateService
    let logger = Logger(category: "capture")

    enum CaptureDestination {
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
                        title: AppLocalization.string("SnapGlass is Up to Date"),
                        message: AppLocalization.string(
                            "You are running the latest version (%@).",
                            latestVersion.description
                        )
                    )
                case .updateAvailable(let release):
                    await presentUpdate(release)
                }
            } catch {
                presentInformationAlert(
                    title: AppLocalization.string("Unable to Check for Updates"),
                    message: error.localizedDescription,
                    style: .warning
                )
            }
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

/// 截图来源应用信息，用于历史记录保存。
struct CaptureSourceInfo {
    let appName: String?
    let windowTitle: String?
}
