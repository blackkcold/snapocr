import AppKit
import BarcodeCore
import CaptureCore
import HistoryCore
import OCRCore
import ScrollCore
import SharedKit
import SwiftUI

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

    /// The current UI-facing screen-recording phase.
    @Published var recordingStatus: RecordingSessionStatus = .idle

    /// Monotonic sequence for status updates applied one runloop later.
    ///
    /// The update is deferred so the status item label render never shares the
    /// recording controller's transition turn. Only the newest status may land, so a
    /// delayed older update can never overwrite a newer one.
    var recordingStatusSequence = 0

    /// A failed recording that is still awaiting the user's attention.
    @Published var recordingFailure: RecordingControlPanelFailure?

    /// Owns source selection, countdown, stream capture, and writer finalization.
    let recordingSessionController: RecordingSessionController

    /// The manager for the session-only recent screenshot shelf.
    let screenshotShelfManager = ScreenshotShelfManager()

    /// Whether the recent screenshot shelf panel is currently visible.
    @Published public internal(set) var isScreenshotShelfVisible = false

    /// Whether at least one screenshot remains in the recent shelf.
    @Published public internal(set) var hasScreenshotShelfItems = false

    /// Whether the screenshot shelf is enabled in Preferences.
    @Published public internal(set) var isScreenshotShelfEnabled = true

    /// Whether the shelf can currently be toggled from the menu.
    @Published public internal(set) var canToggleScreenshotShelf = false

    /// 编辑器窗口的多标签工作区：一个窗口承载多份文档。
    ///
    /// 新截图永远作为新标签打开，不再替换当前会话，因此「截图时正在编辑
    /// 的标注」不会被静默丢弃。
    public let editorWorkspace = EditorWorkspace()

    /// The current toast message to display
    @Published public var toastMessage: ToastMessage?
    private let toastDeduplicator = ToastDeduplicator()

    /// Whether a manual scrolling capture session is active.
    @Published public internal(set) var isScrollCaptureActive = false

    /// Number of unique frames currently collected for scrolling capture.
    @Published public internal(set) var scrollCapturedFrameCount = 0

    /// Closure to open a specific window by ID
    public var openWindow: ((String) -> Void)?

    var scrollSession: ScrollSession?
    /// 采帧不再在 VM 里堆全分辨率数组：首帧进引擎画布后就地释放，
    /// 之后每帧追加完即丢，稳态内存 = 画布 + 1 帧。
    var scrollSourceAppName: String?
    var scrollSourceWindowTitle: String?
    var scrollSourcePointWidth: CGFloat?
    /// 本次会话是否已经提示过「已达尺寸上限」，避免每次采帧都刷同一条 toast。
    var scrollReachedSizeLimit = false
    /// 在途的采帧任务。取消时先 cancel，避免迟到的帧写进新会话。
    var scrollCaptureTask: Task<Void, Never>?
    let logger = Logger(category: "capture")

    enum CaptureDestination {
        case configured
        case clipboardOnly
        case editorOnly
        case pinOnly
    }

    /// Initializes a new CaptureViewModel.
    ///
    /// - Parameters:
    ///   - captureOrchestrator: The orchestrator for handling screen captures.
    ///   - ocrPipeline: The pipeline for performing OCR.
    ///   - barcodeEngine: The engine for detecting barcodes.
    ///   - scrollEngine: The engine used by scrolling capture sessions.
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

        let fileManager = FileManager.default
        // Seed legacy shared preferences once, before any destination is resolved.
        RecordingDestinationPreferences.seedLegacySharedValuesIfNeeded(in: .standard)
        for kind in RecordingOutputKind.allCases {
            if let directory = RecordingDestinationPreferences.directory(
                for: kind,
                in: .standard,
                fileManager: fileManager
            ) {
                // Retain current folders for export-window discovery after changes.
                RecordingDestinationPreferences.rememberDirectory(directory, in: .standard)
            }
        }
        let backlog = RecordingBacklogPolicy(
            highWatermarkBytes: 512 * 1_024 * 1_024,
            lowWatermarkBytes: 128 * 1_024 * 1_024
        )
        recordingSessionController = RecordingSessionController(
            captureOrchestrator: captureOrchestrator,
            audioPipelineFactory: { configuration, roots, expectedVolumeUUID in
                try await RecordingPipelineSetupQueue.run {
                    try RecordingAudioPipelineFactory.makeSpaceGated(
                        configuration: configuration,
                        roots: roots,
                        expectedVolumeUUID: expectedVolumeUUID,
                        backlog: backlog
                    )
                }
            }
        )

        configureScreenshotShelf()
        configureRecording()
        setupHotKeys()
        PinnedWindowManager.shared.setToastHandler { [weak self] message, type in
            self?.showToast(message: message, type: type)
        }
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

        HotKeyManager.shared.onScreenshotShelf = { [weak self] in
            self?.toggleScreenshotShelf()
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
        guard toastDeduplicator.shouldPresent(message) else { return }
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

/// 历史保存所需的捕获元数据，避免单个函数参数过多。
struct HistorySaveContext {
    let modeDescription: String
    let appName: String?
    let windowTitle: String?
    let mockupStyle: MockupStyle?
    let mockupStyleJSON: String?
}
