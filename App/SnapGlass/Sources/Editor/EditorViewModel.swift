import SwiftUI
import AppKit
import AnnotationCore
import BarcodeCore
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
    @Published public private(set) var ocrLines: [OCRLine] = []
    @Published public private(set) var isOCRRunning = false
    @Published public var showsOCROverlay = true

    /// Whether the editor is manually scanning the current image for barcodes.
    @Published public private(set) var isBarcodeScanning = false

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

    /// Called when the user cancels editing to close the editor window.
    public var onClose: (() -> Void)?

    private let logger = Logger(category: "editor")
    private let recognizeImage: @Sendable (CGImage, OCROptions) async throws -> OCRResult
    private let detectBarcodes: @Sendable (CGImage, [BarcodeType]) async throws -> [BarcodeResult]
    private var pendingTextPoint: CGPoint?
    private var editingTextNodeID: UUID?
    private var ocrTask: Task<Void, Never>?
    private var ocrGeneration = 0
    private var barcodeTask: Task<Void, Never>?
    private var barcodeGeneration = 0

    /// Creates a new editor view model.
    ///
    /// - Parameter interactor: The annotation interactor to use.
    public init(
        image: CGImage? = nil,
        interactor: AnnotationInteractor = AnnotationInteractor(),
        ocrPipeline: OCRPipeline = OCRPipeline(),
        barcodeEngine: VisionBarcodeEngine = VisionBarcodeEngine()
    ) {
        self.interactor = interactor
        self.recognizeImage = { image, options in
            try await ocrPipeline.recognize(image, options: options)
        }
        self.detectBarcodes = { image, types in
            try await barcodeEngine.detect(in: image, types: types)
        }
        if let image {
            self.document = interactor.createDocument(from: image)
            startOCR()
        }
    }

    init(
        image: CGImage? = nil,
        interactor: AnnotationInteractor = AnnotationInteractor(),
        recognizeImage: @escaping @Sendable (CGImage, OCROptions) async throws -> OCRResult,
        detectBarcodes: @escaping @Sendable (CGImage, [BarcodeType]) async throws -> [BarcodeResult] = {
            image,
            types in
            try await VisionBarcodeEngine().detect(in: image, types: types)
        }
    ) {
        self.interactor = interactor
        self.recognizeImage = recognizeImage
        self.detectBarcodes = detectBarcodes
        if let image {
            self.document = interactor.createDocument(from: image)
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
        selectedTool = tool
        if tool == .ocr {
            showsOCROverlay = true
        }
        if tool != .select {
            selectNode(nil)
        }
        if tool == .rect {
            fillEnabled = true
            fillColor = selectedColor
        } else if tool != .select {
            fillEnabled = false
        }
    }

    func setSelectedColor(_ color: Color) {
        selectedColor = color
        selectedPreset = .custom
        if selectedNode != nil {
            updateSelectedStyle()
        } else if selectedTool == .rect {
            fillEnabled = true
            fillColor = color
        }
    }

    /// Adds a new annotation node to the document.
    ///
    /// - Parameter node: The annotation node to add.
    public func addNode(_ node: AnnotationNode) {
        guard var doc = document else { return }
        do {
            try interactor.apply(node.tool, to: &doc, node: node)
            document = doc
            selectedNodeID = node.tool == .crop ? nil : node.id
            if node.tool == .crop {
                restartOCRForCurrentImage()
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

    public func nudgeSelectedNode(dx: CGFloat, dy: CGFloat) {
        guard var node = selectedNode else { return }
        node.points = node.points.map {
            CGPoint(x: min(max($0.x + dx, 0), 1), y: min(max($0.y + dy, 0), 1))
        }
        if node.normalizedRect != .zero {
            let moved = node.normalizedRect.offsetBy(dx: dx, dy: dy)
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

    public func startOCR() {
        ocrTask?.cancel()
        ocrGeneration &+= 1
        let generation = ocrGeneration
        guard let image = document?.baseImage else {
            isOCRRunning = false
            return
        }
        isOCRRunning = true
        ocrTask = Task { [weak self] in
            guard let self else { return }
            do {
                let options = OCROptions(
                    languages: ["zh-Hans", "en-US"],
                    minConfidence: 0.1,
                    preserveLayout: true
                )
                let result = try await recognizeImage(image, options)
                guard !Task.isCancelled, generation == ocrGeneration else { return }
                ocrLines = result.observations
                showsOCROverlay = true
                isOCRRunning = false
                logger.info("Editor OCR completed with \(result.observations.count) lines")
            } catch is CancellationError {
                guard generation == ocrGeneration else { return }
                isOCRRunning = false
            } catch {
                guard !Task.isCancelled, generation == ocrGeneration else { return }
                ocrLines = []
                isOCRRunning = false
                showToast(message: "OCR failed: \(error.localizedDescription)", type: .error)
            }
        }
    }

    private func restartOCRForCurrentImage() {
        cancelBarcodeScan()
        ocrLines = []
        startOCR()
    }

    public func copyOCRLine(_ line: OCRLine) {
        copyOCRText(line.text)
    }

    public func copyOCRLines(_ lines: [OCRLine]) {
        copyOCRText(lines.map(\.text).joined(separator: "\n"))
    }

    public func copyOCRSelection(_ text: String) {
        copyOCRText(text)
    }

    public func copyAllOCRText() {
        copyOCRLines(ocrLines)
    }

    public func addOCRLineAsAnnotation(_ line: OCRLine) {
        let rect = line.editorBoundingBox
        let node = AnnotationNode(
            tool: .text,
            color: cgColor,
            lineWidth: strokeWidth,
            opacity: annotationOpacity,
            fillColor: fillEnabled ? NSColor(fillColor).cgColor : nil,
            points: [rect.origin],
            text: line.text,
            fontName: fontName,
            fontSize: max(fontSize, rect.height * CGFloat(document?.baseImage.height ?? 1) * 0.8),
            textAlignment: textAlignment,
            normalizedRect: rect
        )
        addNode(fittedTextNode(node))
        selectedTool = .select
    }

    private func fittedTextNode(_ source: AnnotationNode) -> AnnotationNode {
        guard source.tool == .text, let image = document?.baseImage else { return source }
        var node = source
        let origin = node.normalizedRect.origin != .zero
            ? node.normalizedRect.origin
            : (node.points.first ?? .zero)
        let size = TextTool().suggestedSize(for: node)
        let normalizedWidth = size.width / CGFloat(max(image.width, 1))
        let normalizedHeight = size.height / CGFloat(max(image.height, 1))
        let fittedWidth = min(max(normalizedWidth, 0.01), 1)
        let fittedHeight = min(max(normalizedHeight, 0.01), 1)
        node.normalizedRect = CGRect(
            x: min(max(origin.x, 0), 1 - fittedWidth),
            y: min(max(origin.y, 0), 1 - fittedHeight),
            width: fittedWidth,
            height: fittedHeight
        )
        node.points = [node.normalizedRect.origin]
        return node
    }

    private func copyOCRText(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showToast(message: "Copied OCR text", type: .success)
    }

    // MARK: - Barcode Recognition

    /// Manually scans the current editor image and copies decoded barcode content.
    public func scanBarcodes() {
        barcodeTask?.cancel()
        barcodeGeneration &+= 1
        let generation = barcodeGeneration
        guard let image = document?.baseImage else {
            isBarcodeScanning = false
            return
        }

        isBarcodeScanning = true
        barcodeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let results = try await detectBarcodes(image, [])
                guard !Task.isCancelled, generation == barcodeGeneration else { return }
                isBarcodeScanning = false

                let payloads = results.map(\.payload).filter {
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                guard !payloads.isEmpty else {
                    showToast(
                        message: NSLocalizedString("No barcode found", comment: "Editor barcode scan empty result"),
                        type: .info
                    )
                    return
                }

                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(payloads.joined(separator: "\n"), forType: .string)
                if payloads.count == 1 {
                    showToast(
                        message: NSLocalizedString("Barcode copied to clipboard", comment: "Editor barcode copy success"),
                        type: .success
                    )
                } else {
                    showToast(
                        message: String(
                            format: NSLocalizedString(
                                "%d barcodes copied to clipboard",
                                comment: "Editor multiple barcode copy success"
                            ),
                            payloads.count
                        ),
                        type: .success
                    )
                }
                logger.info("Editor barcode scan copied \(payloads.count) result(s)")
            } catch is CancellationError {
                guard generation == barcodeGeneration else { return }
                isBarcodeScanning = false
            } catch {
                guard !Task.isCancelled, generation == barcodeGeneration else { return }
                isBarcodeScanning = false
                showToast(
                    message: String(
                        format: NSLocalizedString(
                            "Barcode scan failed: %@",
                            comment: "Editor barcode scan failure"
                        ),
                        error.localizedDescription
                    ),
                    type: .error
                )
            }
        }
    }

    private func cancelBarcodeScan() {
        barcodeTask?.cancel()
        barcodeGeneration &+= 1
        isBarcodeScanning = false
    }

    // MARK: - Save / Copy / Cancel

    /// Saves the annotated image to a user-chosen file location.
    public func save() {
        guard let doc = document else { return }
        let configuredFormat = ImageFileFormat(
            rawValue: UserDefaults.standard.string(forKey: PreferenceKeys.captureImageFormat)
                ?? PreferenceDefaults.captureImageFormat
        ) ?? .png
        let format = ImageEncoder.containsTransparency(doc.baseImage) ? ImageFileFormat.png : configuredFormat
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .png ? .png : .jpeg]
        panel.nameFieldStringValue = "Snapshot.\(format.fileExtension)"

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                let image = try self.interactor.render(doc)
                let quality = UserDefaults.standard.object(forKey: PreferenceKeys.captureJPEGQuality) == nil
                    ? PreferenceDefaults.captureJPEGQuality
                    : UserDefaults.standard.double(forKey: PreferenceKeys.captureJPEGQuality)
                try ImageEncoder.write(image, to: url, format: format, jpegQuality: quality)
                self.showToast(message: "Saved to \(url.lastPathComponent)", type: .success)
                self.logger.info("Saved annotated image to \(url.path())")
            } catch {
                self.showToast(message: "Save failed: \(error.localizedDescription)", type: .error)
            }
        }
    }

    /// Renders the annotated image and copies it to the system clipboard.
    public func copyToClipboard() {
        guard let doc = document else { return }
        do {
            let image = try interactor.render(doc)
            let nsImage = NSImage(
                cgImage: image,
                size: NSSize(width: image.width, height: image.height)
            )
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([nsImage])
            showToast(message: "Copied to clipboard", type: .success)
            logger.info("Copied annotated image to clipboard")
        } catch {
            showToast(message: "Copy failed: \(error.localizedDescription)", type: .error)
        }
    }

    /// Cancels editing and signals the editor window to close.
    public func cancel() {
        logger.info("Editor cancelled")
        onClose?()
    }

    // MARK: - Toast

    /// Shows a transient toast notification.
    ///
    /// - Parameters:
    ///   - message: The message text.
    ///   - type: The type of toast.
    public func showToast(message: String, type: ToastType) {
        let toast = ToastMessage(message: message, type: type)
        toastMessage = toast
        Task {
            try? await Task.sleep(for: .seconds(3))
            if toastMessage?.id == toast.id {
                toastMessage = nil
            }
        }
    }
}
