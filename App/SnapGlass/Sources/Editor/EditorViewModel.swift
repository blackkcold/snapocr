import AnnotationCore
import AppKit
import BarcodeCore
import CaptureCore
import HistoryCore
import OCRCore
import SharedKit
import SwiftUI
import UniformTypeIdentifiers
import os

/// 文字标注的草稿状态。
///
/// 单独成对象、单独发布：草稿原来直接挂在 `EditorViewModel` 的 `@Published`
/// 上，敲一个字就会让整个 `EditorView` 重新求值，`updateNSView` 再把 5K 画布
/// 整张标脏。真正需要草稿的只有提交路径（`commitTextEntry`）和内联编辑器。
@MainActor
public final class TextEntryState: ObservableObject {
    /// The string typed so far, before the text annotation is committed.
    @Published public var draft = ""
}

/// How an edited image should be written back to history.
public enum EditorHistorySaveMode: Sendable, Equatable {
    /// Writes a fresh history entry.
    case newRecord
    /// Replaces the media of the original capture, keeping the entry id and
    /// metadata; the original stays recoverable through `restoreOriginal`.
    case overwriteOriginal
}

/// Which inspector page the editor is showing.
public enum EditorInspectorTab: Hashable, Sendable {
    case annotation
    case share
}

/// State of the downscaled share-appearance preview.
public enum SharePreviewState: Equatable, Sendable {
    case idle
    case rendering
    case ready
    case failed(String)
}

/// View model for the annotation editor window.
///
/// Manages the annotation document lifecycle: creating documents from captured images,
/// tracking the selected tool/color/stroke, applying annotations via `AnnotationInteractor`,
/// and handling save/copy/cancel actions.
@MainActor
public final class EditorViewModel: ObservableObject {
    /// The annotation interactor for applying tools, undo/redo, and rendering.
    public let interactor: AnnotationInteractor

    /// The current annotation document, created from the captured image.
    @Published public var document: AnnotationDocument?

    /// The currently selected annotation tool.
    @Published var selectedTool: EditorTool = .select

    /// Whether the current image supports the specialized long-image trim workflow.
    let supportsVerticalTrim: Bool

    /// Whether crop interaction is currently constrained to the top and bottom edges.
    @Published private(set) var isVerticalTrimEnabled: Bool

    /// Current style preset. Direct control edits switch this to custom.
    @Published var selectedPreset: AnnotationStylePreset = .emphasis

    /// The currently selected color for annotations.
    @Published public var selectedColor: Color = .red

    /// The stroke width for line-based tools.
    @Published public var strokeWidth: CGFloat = 3.0

    /// Opacity applied to new annotations and pushed onto the selected node.
    @Published public var annotationOpacity: CGFloat = 1.0
    /// Whether new shapes are drawn with a fill.
    @Published public var fillEnabled = false
    /// Fill color used when `fillEnabled` is on.
    @Published public var fillColor: Color = .clear
    /// Stroke pattern for line-based tools.
    @Published public var strokeStyle: AnnotationStrokeStyle = .solid
    /// Corner radius in image points for rectangle annotations.
    @Published public var cornerRadius: CGFloat = 0
    /// Head style for arrow annotations.
    @Published public var arrowStyle: AnnotationArrowStyle = .filled
    /// PostScript name of the font used by text annotations.
    @Published public var fontName = "Helvetica"
    /// Font size in image points for text annotations.
    @Published public var fontSize: CGFloat = 24
    /// Horizontal alignment for multi-line text annotations.
    @Published public var textAlignment: AnnotationTextAlignment = .leading
    /// Algorithm used by the blur tool.
    @Published public var blurMode: AnnotationBlurMode = .gaussian
    /// Blur strength, normalized to `0...1`.
    @Published public var blurIntensity: CGFloat = 0.5

    /// Currently selected annotation node.
    @Published public var selectedNodeID: UUID?

    /// OCR overlay state and recognized lines.
    @Published public internal(set) var ocrLines: [OCRLine] = []
    /// Whether a text-recognition pass is in flight.
    @Published public internal(set) var isOCRRunning = false
    /// Whether recognized-line highlights are drawn over the canvas.
    @Published public var showsOCROverlay = true

    /// Live color under the picker cursor while hovering.
    @Published public internal(set) var pickerHoverColor: SampledColor?

    /// Average color of the last picked region.
    @Published public internal(set) var pickerAverageColor: SampledColor?

    /// Dominant colors of the last picked region.
    @Published public internal(set) var pickerDominantColors: [SampledColor] = []

    /// Whether the editor is manually scanning the current image for barcodes.
    @Published public internal(set) var isBarcodeScanning = false

    /// 是否正在后台执行裁剪合成。
    ///
    /// 5K 底图的裁剪需要先把整张文档合成出来；这段合成原来跑在主线程上，
    /// 每次确认裁剪都会冻结界面。现在放到 detached task，期间禁止再次触发。
    @Published public internal(set) var isApplyingCrop = false

    /// 文字草稿状态（独立发布源，避免每次击键都重算整个编辑器视图）。
    public let textEntry = TextEntryState()

    /// Text currently being entered for a pending text annotation.
    ///
    /// 计算属性桥接：读写的仍是同一个字符串，但不再触发 `EditorViewModel`
    /// 的 `objectWillChange`。测试与提交路径的调用方式保持不变。
    public var textDraft: String {
        get { textEntry.draft }
        set { textEntry.draft = newValue }
    }

    /// Whether the in-canvas text editor is active.
    @Published public var isEnteringText = false
    @Published private(set) var textEntryID = UUID()

    /// Whether undo is available.
    public var canUndo: Bool { document?.canUndo == true }

    /// Whether redo is available.
    public var canRedo: Bool { document?.canRedo == true }

    /// Whether a reversible overwrite of the originating history record exists.
    public var canOverwriteOriginal: Bool { sourceEntryID != nil }

    /// Links the history record that finished writing after the editor opened.
    public func attachSourceEntry(_ id: UUID) {
        guard sourceEntryID == nil else { return }
        sourceEntryID = id
        scheduleShareStyleCommit()
    }

    /// The current toast message to display.
    @Published public var toastMessage: ToastMessage?
    let toastDeduplicator = ToastDeduplicator()

    /// Whether the document holds annotations that were never written to a file
    /// or to history. Drives the close confirmation.
    ///
    /// Compares content rather than a mutation counter, so undoing every change
    /// back to the saved state counts as clean again.
    public var hasUnsavedChanges: Bool {
        // 裁剪在后台合成期间文档还没变，但结果随时会落回文档。此时关闭窗口
        // 会把这次裁剪连同撤销记录一起丢掉，所以按「有未保存内容」处理。
        if isApplyingCrop { return true }
        if isEnteringText {
            let trimmed = textDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                // Opening an existing text node and leaving it unchanged is not dirty.
                let unchangedExistingDraft =
                    editingTextNodeID.flatMap { id in document?.nodes.first(where: { $0.id == id }) }
                    .map { $0.text == textDraft } ?? false
                if !unchangedExistingDraft { return true }
            }
        }
        guard let document else { return false }
        guard hasSavedSnapshot else { return true }
        if savedBaseImage !== document.baseImage { return true }
        return document.nodes != savedDocumentNodes
    }

    /// Set while a full-size render/encode is running, so the toolbar cannot
    /// start a second save or copy before the first one finishes.
    @Published var isWritingImage = false

    /// Increments on every document mutation; kept for change notifications and
    /// diagnostics. Dirty tracking itself compares document content.
    @Published var changeCount = 0

    /// Set once the user has accepted losing the changes, so the window may close.
    @Published var hasAcceptedClose = false

    /// Whether the close confirmation sheet is on screen.
    @Published public var showsCloseConfirmation = false

    /// Number of dominant colors reported for region picks (3–6).
    public var dominantColorCount: Int {
        let stored = UserDefaults.standard.integer(forKey: PreferenceKeys.pickerDominantColorCount)
        if UserDefaults.standard.object(forKey: PreferenceKeys.pickerDominantColorCount) == nil {
            return PreferenceDefaults.pickerDominantColorCount
        }
        return min(max(stored, 3), 6)
    }

    /// Zoom and pan state shared with the toolbar.
    let canvasZoom = CanvasZoomController()

    /// Called when the user cancels editing to close the editor window.
    public var onClose: (() -> Void)?

    /// Closes the editor window even though it still has unsaved annotations.
    public var onForceClose: (() -> Void)?

    /// Snapshot of the document as last written to disk or history.
    var savedDocumentNodes: [AnnotationNode] = []
    var savedBaseImage: CGImage?
    var hasSavedSnapshot = false

    var savedChangeCount = 0

    let logger = Logger(category: "editor")
    /// Instruments「Points of Interest」里的裁剪区间；用于验证主线程空档。
    let cropSignposter = OSSignposter(subsystem: "com.snapglass.app", category: "crop")
    let recognizeImage: @Sendable (CGImage, OCROptions) async throws -> OCRResult
    let detectBarcodes: @Sendable (CGImage, [BarcodeType]) async throws -> [BarcodeResult]
    let historySaver: @Sendable (CGImage, EditorHistorySaveMode, UUID?, MockupStyle?) async throws -> Void
    /// The history record this image was saved as.
    ///
    /// Capture opens the editor before the (slower) history write finishes, so
    /// this is filled in later via `attachSourceEntry(_:)`.
    @Published public private(set) var sourceEntryID: UUID?
    /// Presentation style carried from capture; applied on export, never baked
    /// into the editable base image. `nil` means share appearance is off.
    @Published public var mockupStyle: MockupStyle?
    /// Downscaled preview of the current document + style, for the inspector.
    @Published public internal(set) var sharePreview: CGImage?
    /// Progress of the downscaled share-appearance preview shown in the inspector.
    @Published public internal(set) var sharePreviewState: SharePreviewState = .idle
    /// Preset shown as selected in the share page; nil means custom.
    @Published public internal(set) var selectedMockupPreset: MockupPreset?
    /// Which inspector page is visible. The bottom-bar toggle drives this too.
    @Published public var inspectorTab: EditorInspectorTab = .annotation
    /// Capture mode string carried from the capture ("window", "scroll", ...).
    let captureMode: String?
    /// Writes only the presentation metadata for an existing history entry.
    let historyStyleUpdater: @Sendable (UUID, String?) async throws -> Void
    var lastEnabledMockupStyle: MockupStyle?
    var baselineMockupStyle: MockupStyle?
    var lastCommittedMockupStyle: MockupStyle?
    var sharePreviewTask: Task<Void, Never>?
    var sharePreviewGeneration = 0
    var shareStyleCommitTask: Task<Void, Never>?
    private var pendingTextPoint: CGPoint?
    private var editingTextNodeID: UUID?
    var ocrTask: Task<Void, Never>?
    var ocrGeneration = 0
    var barcodeTask: Task<Void, Never>?
    var barcodeGeneration = 0

    /// Creates a new editor view model.
    ///
    /// - Parameters:
    ///   - image: The base image to annotate; `nil` starts an empty document.
    ///   - context: Presentation context carried from capture, including the
    ///     history entry and mockup style the editor opened with.
    ///   - interactor: The annotation interactor to use.
    ///   - ocrPipeline: The pipeline used by text recognition actions.
    ///   - barcodeEngine: The engine used by barcode detection actions.
    ///   - historySaver: Persists an edited image into history; `nil` uses the
    ///     app's default history saver.
    ///   - historyStyleUpdater: Writes only presentation metadata for an existing
    ///     history entry; `nil` uses the app's default updater.
    public init(
        image: CGImage? = nil,
        context: EditorCaptureContext = .standard,
        interactor: AnnotationInteractor = AnnotationInteractor(),
        ocrPipeline: OCRPipeline = OCRPipeline(),
        barcodeEngine: VisionBarcodeEngine = VisionBarcodeEngine(),
        historySaver: (@Sendable (CGImage, EditorHistorySaveMode, UUID?, MockupStyle?) async throws -> Void)? = nil,
        historyStyleUpdater: (@Sendable (UUID, String?) async throws -> Void)? = nil
    ) {
        let contextStyle = context.mockupStyle
        let fallbackStyle = Self.lastPersistedMockupStyle()
        let effectiveStyle = contextStyle ?? fallbackStyle
        self.interactor = interactor
        self.supportsVerticalTrim = context.supportsVerticalTrim
        self.isVerticalTrimEnabled = context.startsInVerticalTrim
        self.recognizeImage = { image, options in
            try await ocrPipeline.recognize(image, options: options)
        }
        self.detectBarcodes = { image, types in
            try await barcodeEngine.detect(in: image, types: types)
        }
        self.sourceEntryID = context.sourceEntryID
        self.captureMode = context.captureMode
        self.mockupStyle = contextStyle
        self.lastEnabledMockupStyle = effectiveStyle
        self.baselineMockupStyle = effectiveStyle
        self.lastCommittedMockupStyle = contextStyle
        self.selectedMockupPreset = effectiveStyle.flatMap(Self.preset(matching:))
        self.historySaver = historySaver ?? Self.defaultHistorySaver
        self.historyStyleUpdater = historyStyleUpdater ?? Self.defaultHistoryStyleUpdater
        if let image {
            self.document = interactor.createDocument(from: image)
            if context.startsInVerticalTrim {
                self.selectedTool = .crop
            }
            startOCR()
        }
        resetSavedSnapshot()
    }

    deinit {
        ocrTask?.cancel()
        barcodeTask?.cancel()
        sharePreviewTask?.cancel()
        shareStyleCommitTask?.cancel()
    }

    /// Converts the SwiftUI `Color` to a `CGColor` for the `AnnotationNode`.
    public var cgColor: CGColor {
        NSColor(selectedColor).cgColor
    }

    /// Loads a captured image into the editor, creating a new annotation document.
    ///
    /// - Parameter image: The captured background image to annotate.
    public func loadImage(_ image: CGImage) {
        cancelTextEntry()
        cancelBarcodeScan()
        document = interactor.createDocument(from: image)
        selectedNodeID = nil
        ocrLines = []
        resetSavedSnapshot()
        startOCR()
        logger.info("Editor loaded image: \(image.width)×\(image.height)")
    }

    // MARK: - Annotation Operations

    func activateTool(_ tool: EditorTool) {
        cancelTextEntry()
        inspectorTab = .annotation
        isVerticalTrimEnabled = false
        selectedTool = tool
        if tool == .ocr {
            showsOCROverlay = true
        }
        if tool != .select {
            selectNode(nil)
        }
        if tool != .select {
            // 画框默认线框；仍播种填充色，避免手动开填充时产生透明填充。
            fillEnabled = false
            if fillColor == .clear || tool == .rect {
                fillColor = selectedColor
            }
        }
    }

    func activateVerticalTrim() {
        guard supportsVerticalTrim else { return }
        isVerticalTrimEnabled = true
        selectedTool = .crop
        selectNode(nil)
    }

    /// Adds a new annotation node to the document.
    ///
    /// - Parameter node: The annotation node to add.
    public func addNode(_ node: AnnotationNode) {
        guard !isApplyingCrop else {
            showToast(message: AppLocalization.string("Processing…"), type: .info)
            return
        }
        inspectorTab = .annotation

        if node.tool == .crop {
            applyCropNode(node)
            return
        }

        guard var doc = document else { return }
        do {
            try interactor.apply(node.tool, to: &doc, node: node)
            document = doc
            markChanged()
            selectedNodeID = node.id
            selectedTool = .select
            logger.debug("Added node: \(node.tool.rawValue), id=\(node.id)")
        } catch {
            logger.error("Failed to add node: \(error.localizedDescription)")
            showToast(message: error.localizedDescription, type: .error)
        }
    }

    /// 裁剪：合成 + 裁剪放到后台线程，主线程只做结果替换。
    ///
    /// 撤销语义不变——传进去的是完整文档快照，`replaceContent` 仍会把
    /// 原图与节点压进撤销栈，撤销后回到裁剪前。
    private func applyCropNode(_ node: AnnotationNode) {
        guard let snapshot = document else { return }
        let completedVerticalTrim = isVerticalTrimEnabled
        // 合成期间用户仍可能撤销/改样式：记下版本号，回来时若文档已变就丢弃这次裁剪，
        // 而不是用旧快照把用户的编辑整体覆盖掉。
        let baselineChangeCount = changeCount
        let interactor = self.interactor
        isApplyingCrop = true

        Task {
            let signposter = cropSignposter
            let interval = signposter.beginInterval("crop")
            let outcome = await Task.detached(priority: .userInitiated) {
                () -> Result<AnnotationDocument, AnnotationError> in
                let renderInterval = signposter.beginInterval("crop.render")
                defer { signposter.endInterval("crop.render", renderInterval) }
                var doc = snapshot
                do {
                    try interactor.apply(.crop, to: &doc, node: node)
                    return .success(doc)
                } catch let error as AnnotationError {
                    return .failure(error)
                } catch {
                    return .failure(.renderFailed(reason: error.localizedDescription))
                }
            }.value
            signposter.endInterval("crop", interval)

            isApplyingCrop = false

            guard changeCount == baselineChangeCount else {
                logger.info("Crop discarded: document changed while rendering")
                showToast(
                    message: AppLocalization.string(
                        "The document changed while cropping, so this crop was cancelled."),
                    type: .info
                )
                return
            }

            switch outcome {
            case .success(let doc):
                document = doc
                markChanged()
                selectedNodeID = nil
                restartOCRForCurrentImage()
                if completedVerticalTrim {
                    isVerticalTrimEnabled = false
                    selectedTool = .select
                }
                logger.debug("Added node: \(node.tool.rawValue), id=\(node.id)")
            case .failure(let error):
                logger.error("Failed to add node: \(error.localizedDescription)")
                showToast(message: error.localizedDescription, type: .error)
            }
        }
    }

    /// Replaces an existing node as one undoable operation.
    public func updateNode(_ node: AnnotationNode) {
        guard var doc = document else { return }
        doc.updateNode(node)
        document = doc
        markChanged()
        selectNode(node.id)
    }

    /// Deletes the selected node as one undoable change and clears the selection.
    public func removeSelectedNode() {
        guard let selectedNodeID, var doc = document else { return }
        doc.removeNode(by: selectedNodeID)
        document = doc
        markChanged()
        self.selectedNodeID = nil
    }

    /// The node matching `selectedNodeID`, if it still exists.
    public var selectedNode: AnnotationNode? {
        guard let selectedNodeID else { return nil }
        return document?.nodes.first { $0.id == selectedNodeID }
    }

    /// True while a continuous style control (a slider) is being dragged.
    private var isCoalescingStyleEdit = false
    /// Whether the pre-drag snapshot was already pushed for this gesture.
    private var styleEditRecordedUndo = false
    /// Published so the canvas can exclude the node being restyled from its
    /// cached preview and draw only that node live.
    @Published private(set) var isAdjustingStyle = false

    /// Starts one undoable style gesture.
    ///
    /// A slider fires its binding dozens of times per drag. Without coalescing
    /// every tick became its own undo step, so ⌘Z had to be pressed dozens of
    /// times to get back to the previous annotation.
    func beginStyleEdit() {
        isCoalescingStyleEdit = true
        styleEditRecordedUndo = false
        isAdjustingStyle = true
    }

    /// Ends the style gesture; the next change records a fresh undo step.
    func endStyleEdit() {
        isCoalescingStyleEdit = false
        styleEditRecordedUndo = false
        isAdjustingStyle = false
    }

    /// Applies the current inspector style to the selected node.
    ///
    /// Dragging a continuous control records one undo step for the whole
    /// gesture; a single change goes through `updateNode(_:)` and records its own.
    public func updateSelectedStyle() {
        guard !isEnteringText else { return }
        guard var node = selectedNode, var doc = document else { return }
        node = applyingCurrentStyle(to: node)
        if node.tool == .text {
            node = fittedTextNode(node)
        }
        guard isCoalescingStyleEdit else {
            updateNode(node)
            return
        }
        if !styleEditRecordedUndo {
            doc.pushUndoState()
            styleEditRecordedUndo = true
        }
        doc.replaceNode(node)
        document = doc
        markChanged()
        selectNode(node.id)
    }

    /// Undoes the last annotation operation.
    public func undo() {
        guard !isApplyingCrop else {
            showToast(message: AppLocalization.string("Processing…"), type: .info)
            return
        }
        guard var doc = document else { return }
        let previousImage = doc.baseImage
        do {
            try interactor.undo(&doc)
            document = doc
            markChanged()
            if previousImage !== doc.baseImage {
                restartOCRForCurrentImage()
            }
        } catch {
            logger.warning("Undo failed: \(error.localizedDescription)")
        }
    }

    /// Redoes the last undone annotation operation.
    public func redo() {
        guard !isApplyingCrop else {
            showToast(message: AppLocalization.string("Processing…"), type: .info)
            return
        }
        guard var doc = document else { return }
        let previousImage = doc.baseImage
        do {
            try interactor.redo(&doc)
            document = doc
            markChanged()
            if previousImage !== doc.baseImage {
                restartOCRForCurrentImage()
            }
        } catch {
            logger.warning("Redo failed: \(error.localizedDescription)")
        }
    }

    /// Starts text entry at a normalized image coordinate.
    public func beginTextEntry(at point: CGPoint) {
        textEntryID = UUID()
        pendingTextPoint = point
        editingTextNodeID = nil
        textDraft = ""
        isEnteringText = true
    }

    /// Reopens an existing text node for in-place editing at its own position.
    ///
    /// Non-text nodes are ignored. The draft starts from the node's current
    /// text, so the user edits the existing content rather than a blank line.
    public func beginTextEditing(_ node: AnnotationNode) {
        guard node.tool == .text else { return }
        textEntryID = UUID()
        editingTextNodeID = node.id
        pendingTextPoint = node.points.first ?? node.normalizedRect.origin
        textDraft = node.text ?? ""
        isEnteringText = true
    }

    /// A draft snapshot; typing never mutates the document until commit.
    var pendingTextNode: AnnotationNode? {
        guard isEnteringText, let point = pendingTextPoint else { return nil }
        if let editingTextNodeID, let node = document?.nodes.first(where: { $0.id == editingTextNodeID }) {
            return applyingCurrentStyle(to: node)
        }
        return AnnotationNode(
            tool: .text, color: cgColor, lineWidth: strokeWidth, opacity: annotationOpacity,
            fillColor: fillEnabled ? NSColor(fillColor).cgColor : nil,
            points: [point], text: textDraft, fontName: fontName, fontSize: fontSize,
            textAlignment: textAlignment, normalizedRect: CGRect(origin: point, size: .zero)
        )
    }

    /// Commits the pending text annotation if it contains visible characters.
    public func commitTextEntry() {
        defer {
            pendingTextPoint = nil
            editingTextNodeID = nil
            textDraft = ""
            isEnteringText = false
        }

        let text = textDraft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let editingTextNodeID, var node = document?.nodes.first(where: { $0.id == editingTextNodeID }) {
            node.text = text
            node = applyingCurrentStyle(to: node)
            updateNode(fittedTextNode(node))
            return
        }
        guard let point = pendingTextPoint else { return }
        let node = AnnotationNode(
            tool: .text,
            color: cgColor,
            lineWidth: strokeWidth,
            opacity: annotationOpacity,
            fillColor: fillEnabled ? NSColor(fillColor).cgColor : nil,
            points: [point],
            text: text,
            fontName: fontName,
            fontSize: fontSize,
            textAlignment: textAlignment,
            normalizedRect: CGRect(origin: point, size: .zero)
        )
        addNode(fittedTextNode(node))
    }

    /// Cancels the pending text annotation.
    public func cancelTextEntry() {
        let editingTextNodeID = editingTextNodeID
        pendingTextPoint = nil
        self.editingTextNodeID = nil
        textDraft = ""
        isEnteringText = false
        if let editingTextNodeID {
            selectNode(editingTextNodeID)
        }
    }

    // MARK: - OCR

    // MARK: - Color Picker

    // MARK: - Barcode Recognition

    // MARK: - Save / Copy / Cancel

    // MARK: - Toast

}
