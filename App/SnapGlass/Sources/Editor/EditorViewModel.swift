import SwiftUI
import AppKit
import AnnotationCore
import BarcodeCore
import HistoryCore
import OCRCore
import SharedKit
import UniformTypeIdentifiers

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

    @Published public var annotationOpacity: CGFloat = 1.0
    @Published public var fillEnabled = false
    @Published public var fillColor: Color = .clear
    @Published public var strokeStyle: AnnotationStrokeStyle = .solid
    @Published public var cornerRadius: CGFloat = 0
    @Published public var arrowStyle: AnnotationArrowStyle = .filled
    @Published public var fontName = "Helvetica"
    @Published public var fontSize: CGFloat = 24
    @Published public var textAlignment: AnnotationTextAlignment = .leading
    @Published public var blurMode: AnnotationBlurMode = .gaussian
    @Published public var blurIntensity: CGFloat = 0.5

    /// Currently selected annotation node.
    @Published public var selectedNodeID: UUID?

    /// OCR overlay state and recognized lines.
    @Published public internal(set) var ocrLines: [OCRLine] = []
    @Published public internal(set) var isOCRRunning = false
    @Published public var showsOCROverlay = true

    /// Live color under the picker cursor while hovering.
    @Published public internal(set) var pickerHoverColor: SampledColor?

    /// Average color of the last picked region.
    @Published public internal(set) var pickerAverageColor: SampledColor?

    /// Dominant colors of the last picked region.
    @Published public internal(set) var pickerDominantColors: [SampledColor] = []

    /// Whether the editor is manually scanning the current image for barcodes.
    @Published public internal(set) var isBarcodeScanning = false

    /// Text currently being entered for a pending text annotation.
    @Published public var textDraft = ""

    /// Whether the text entry dialog is visible.
    @Published public var isEnteringText = false

    /// Whether undo is available.
    public var canUndo: Bool { document?.canUndo == true }

    /// Whether redo is available.
    public var canRedo: Bool { document?.canRedo == true }

    /// The current toast message to display.
    @Published public var toastMessage: ToastMessage?

    /// Number of dominant colors reported for region picks (3–6).
    public var dominantColorCount: Int {
        let stored = UserDefaults.standard.integer(forKey: PreferenceKeys.pickerDominantColorCount)
        if UserDefaults.standard.object(forKey: PreferenceKeys.pickerDominantColorCount) == nil {
            return PreferenceDefaults.pickerDominantColorCount
        }
        return min(max(stored, 3), 6)
    }

    /// Called when the user cancels editing to close the editor window.
    public var onClose: (() -> Void)?

    let logger = Logger(category: "editor")
    let recognizeImage: @Sendable (CGImage, OCROptions) async throws -> OCRResult
    let detectBarcodes: @Sendable (CGImage, [BarcodeType]) async throws -> [BarcodeResult]
    private var pendingTextPoint: CGPoint?
    private var editingTextNodeID: UUID?
    var ocrTask: Task<Void, Never>?
    var ocrGeneration = 0
    var barcodeTask: Task<Void, Never>?
    var barcodeGeneration = 0

    /// Creates a new editor view model.
    ///
    /// - Parameter interactor: The annotation interactor to use.
    public init(
        image: CGImage? = nil,
        context: EditorCaptureContext = .standard,
        interactor: AnnotationInteractor = AnnotationInteractor(),
        ocrPipeline: OCRPipeline = OCRPipeline(),
        barcodeEngine: VisionBarcodeEngine = VisionBarcodeEngine()
    ) {
        self.interactor = interactor
        self.supportsVerticalTrim = context.supportsVerticalTrim
        self.isVerticalTrimEnabled = context.startsInVerticalTrim
        self.recognizeImage = { image, options in
            try await ocrPipeline.recognize(image, options: options)
        }
        self.detectBarcodes = { image, types in
            try await barcodeEngine.detect(in: image, types: types)
        }
        if let image {
            self.document = interactor.createDocument(from: image)
            if context.startsInVerticalTrim {
                self.selectedTool = .crop
            }
            startOCR()
        }
    }

    init(
        image: CGImage? = nil,
        context: EditorCaptureContext = .standard,
        interactor: AnnotationInteractor = AnnotationInteractor(),
        recognizeImage: @escaping @Sendable (CGImage, OCROptions) async throws -> OCRResult,
        detectBarcodes: @escaping @Sendable (CGImage, [BarcodeType]) async throws -> [BarcodeResult] = { image, types in
            try await VisionBarcodeEngine().detect(in: image, types: types)
        }
    ) {
        self.interactor = interactor
        self.supportsVerticalTrim = context.supportsVerticalTrim
        self.isVerticalTrimEnabled = context.startsInVerticalTrim
        self.recognizeImage = recognizeImage
        self.detectBarcodes = detectBarcodes
        if let image {
            self.document = interactor.createDocument(from: image)
            if context.startsInVerticalTrim {
                self.selectedTool = .crop
            }
            startOCR()
        }
    }

    deinit {
        ocrTask?.cancel()
        barcodeTask?.cancel()
    }

    /// Converts the SwiftUI `Color` to a `CGColor` for the `AnnotationNode`.
    public var cgColor: CGColor {
        NSColor(selectedColor).cgColor
    }

    /// Loads a captured image into the editor, creating a new annotation document.
    ///
    /// - Parameter image: The captured background image to annotate.
    public func loadImage(_ image: CGImage) {
        cancelBarcodeScan()
        document = interactor.createDocument(from: image)
        selectedNodeID = nil
        ocrLines = []
        startOCR()
        logger.info("Editor loaded image: \(image.width)×\(image.height)")
    }

    // MARK: - Annotation Operations

    func activateTool(_ tool: EditorTool) {
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

    func setSelectedColor(_ color: Color) {
        selectedColor = color
        selectedPreset = .custom
        if selectedNode != nil {
            updateSelectedStyle()
        } else if fillEnabled {
            fillColor = color
        }
    }

    /// Adds a new annotation node to the document.
    ///
    /// - Parameter node: The annotation node to add.
    public func addNode(_ node: AnnotationNode) {
        guard var doc = document else { return }
        let completedVerticalTrim = node.tool == .crop && isVerticalTrimEnabled
        do {
            try interactor.apply(node.tool, to: &doc, node: node)
            document = doc
            selectedNodeID = node.tool == .crop ? nil : node.id
            if node.tool == .crop {
                restartOCRForCurrentImage()
                if completedVerticalTrim {
                    isVerticalTrimEnabled = false
                    selectedTool = .select
                }
            } else {
                selectedTool = .select
            }
            logger.debug("Added node: \(node.tool.rawValue), id=\(node.id)")
        } catch {
            logger.error("Failed to add node: \(error.localizedDescription)")
            showToast(message: error.localizedDescription, type: .error)
        }
    }

    /// Replaces an existing node as one undoable operation.
    public func updateNode(_ node: AnnotationNode) {
        guard var doc = document else { return }
        doc.updateNode(node)
        document = doc
        selectNode(node.id)
    }

    public func removeSelectedNode() {
        guard let selectedNodeID, var doc = document else { return }
        doc.removeNode(by: selectedNodeID)
        document = doc
        self.selectedNodeID = nil
    }

    public func selectNode(_ id: UUID?) {
        selectedNodeID = id
        guard let node = selectedNode else { return }
        selectedColor = Color(nsColor: NSColor(cgColor: node.color ?? cgColor) ?? .red)
        strokeWidth = node.lineWidth
        annotationOpacity = node.opacity
        fillEnabled = node.fillColor != nil
        if let fill = node.fillColor, let nsFill = NSColor(cgColor: fill) {
            fillColor = Color(nsColor: nsFill)
        }
        strokeStyle = node.strokeStyle
        cornerRadius = node.cornerRadius
        arrowStyle = node.arrowStyle
        fontName = node.fontName
        fontSize = node.fontSize
        textAlignment = node.textAlignment
        blurMode = node.blurMode
        blurIntensity = node.blurIntensity
    }

    public var selectedNode: AnnotationNode? {
        guard let selectedNodeID else { return nil }
        return document?.nodes.first { $0.id == selectedNodeID }
    }

    public func updateSelectedStyle() {
        guard var node = selectedNode else { return }
        node.color = cgColor
        node.lineWidth = strokeWidth
        node.opacity = annotationOpacity
        node.fillColor = fillEnabled ? NSColor(fillColor).cgColor : nil
        node.strokeStyle = strokeStyle
        node.cornerRadius = cornerRadius
        node.arrowStyle = arrowStyle
        node.fontName = fontName
        node.fontSize = fontSize
        node.textAlignment = textAlignment
        node.blurMode = blurMode
        node.blurIntensity = blurIntensity
        if node.tool == .text {
            node = fittedTextNode(node)
        }
        updateNode(node)
    }

    func applyPreset(_ preset: AnnotationStylePreset) {
        selectedPreset = preset
        guard preset != .custom else { return }
        selectedColor = preset.color
        strokeWidth = preset.lineWidth
        annotationOpacity = preset.opacity
        fontSize = preset.fontSize
        switch preset {
        case .emphasis:
            fillEnabled = false
            strokeStyle = .solid
        case .note:
            fillEnabled = true
            fillColor = .black.opacity(0.75)
            strokeStyle = .solid
        case .subtle:
            fillEnabled = false
            strokeStyle = .dashed
        case .monochrome:
            fillEnabled = true
            fillColor = .black.opacity(0.65)
            strokeStyle = .solid
        case .custom:
            break
        }
        if selectedNode != nil {
            updateSelectedStyle()
        }
    }

    public func duplicateSelectedNode() {
        guard var node = selectedNode else { return }
        let offset = CGPoint(x: 0.02, y: 0.02)
        node = AnnotationNode(
            tool: node.tool,
            color: node.color,
            lineWidth: node.lineWidth,
            opacity: node.opacity,
            fillColor: node.fillColor,
            strokeStyle: node.strokeStyle,
            cornerRadius: node.cornerRadius,
            arrowStyle: node.arrowStyle,
            points: node.points.map { CGPoint(x: min($0.x + offset.x, 1), y: min($0.y + offset.y, 1)) },
            text: node.text,
            fontName: node.fontName,
            fontSize: node.fontSize,
            textHorizontalScale: node.textHorizontalScale,
            textAlignment: node.textAlignment,
            blurMode: node.blurMode,
            blurIntensity: node.blurIntensity,
            normalizedRect: node.normalizedRect == .zero
                ? .zero
                : node.normalizedRect.offsetBy(dx: offset.x, dy: offset.y)
        )
        addNode(node)
    }

    public func moveSelectedNodeInLayer(by offset: Int) {
        guard let selectedNodeID, var doc = document else { return }
        doc.moveNode(by: selectedNodeID, offset: offset)
        document = doc
    }

    public func nudgeSelectedNode(dx deltaX: CGFloat, dy deltaY: CGFloat) {
        guard var node = selectedNode else { return }
        node.points = node.points.map {
            CGPoint(x: min(max($0.x + deltaX, 0), 1), y: min(max($0.y + deltaY, 0), 1))
        }
        if node.normalizedRect != .zero {
            let moved = node.normalizedRect.offsetBy(dx: deltaX, dy: deltaY)
            node.normalizedRect.origin.x = min(max(moved.origin.x, 0), 1 - moved.width)
            node.normalizedRect.origin.y = min(max(moved.origin.y, 0), 1 - moved.height)
        }
        updateNode(node)
    }

    /// Undoes the last annotation operation.
    public func undo() {
        guard var doc = document else { return }
        let previousImage = doc.baseImage
        do {
            try interactor.undo(&doc)
            document = doc
            if previousImage !== doc.baseImage {
                restartOCRForCurrentImage()
            }
        } catch {
            logger.warning("Undo failed: \(error.localizedDescription)")
        }
    }

    /// Redoes the last undone annotation operation.
    public func redo() {
        guard var doc = document else { return }
        let previousImage = doc.baseImage
        do {
            try interactor.redo(&doc)
            document = doc
            if previousImage !== doc.baseImage {
                restartOCRForCurrentImage()
            }
        } catch {
            logger.warning("Redo failed: \(error.localizedDescription)")
        }
    }

    /// Starts text entry at a normalized image coordinate.
    public func beginTextEntry(at point: CGPoint) {
        pendingTextPoint = point
        editingTextNodeID = nil
        textDraft = ""
        isEnteringText = true
    }

    public func beginTextEditing(_ node: AnnotationNode) {
        guard node.tool == .text else { return }
        editingTextNodeID = node.id
        pendingTextPoint = node.points.first ?? node.normalizedRect.origin
        textDraft = node.text ?? ""
        isEnteringText = true
    }

    /// Commits the pending text annotation if it contains visible characters.
    public func commitTextEntry() {
        defer {
            pendingTextPoint = nil
            editingTextNodeID = nil
            textDraft = ""
            isEnteringText = false
        }

        let text = textDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let editingTextNodeID,
           var node = document?.nodes.first(where: { $0.id == editingTextNodeID }) {
            node.text = text
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
        pendingTextPoint = nil
        editingTextNodeID = nil
        textDraft = ""
        isEnteringText = false
    }

    // MARK: - OCR

    // MARK: - Color Picker

    // MARK: - Barcode Recognition

    // MARK: - Save / Copy / Cancel

    // MARK: - Toast

}
