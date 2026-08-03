import AnnotationCore
import AppKit
import CoreText
import OCRCore
import SwiftUI

struct EditableAnnotationCanvasView: NSViewRepresentable {
    let image: CGImage
    let nodes: [AnnotationNode]
    let tool: EditorTool
    let color: CGColor
    let lineWidth: CGFloat
    let opacity: CGFloat
    let fillColor: CGColor?
    let strokeStyle: AnnotationStrokeStyle
    let cornerRadius: CGFloat
    let arrowStyle: AnnotationArrowStyle
    let fontName: String
    let fontSize: CGFloat
    let textAlignment: AnnotationTextAlignment
    let blurMode: AnnotationBlurMode
    let blurIntensity: CGFloat
    let selectedNodeID: UUID?
    let ocrLines: [OCRLine]
    let showsOCROverlay: Bool
    var onNodeCreated: (AnnotationNode) -> Void
    var onNodeUpdated: (AnnotationNode) -> Void
    var onSelectionChanged: (UUID?) -> Void
    var onDeleteSelection: () -> Void
    var onTextRequested: (CGPoint) -> Void
    var onTextEditRequested: (AnnotationNode) -> Void
    var onOCRLinesCopied: ([OCRLine]) -> Void
    var onOCRTextCopied: (String) -> Void
    var onOCRLineAsAnnotation: (OCRLine) -> Void

    func makeNSView(context: Context) -> EditableAnnotationCanvasNSView {
        EditableAnnotationCanvasNSView()
    }

    func updateNSView(_ view: EditableAnnotationCanvasNSView, context: Context) {
        view.image = image
        view.nodes = nodes
        view.currentTool = tool
        view.currentColor = color
        view.currentLineWidth = lineWidth
        view.currentOpacity = opacity
        view.currentFillColor = fillColor
        view.currentStrokeStyle = strokeStyle
        view.currentCornerRadius = cornerRadius
        view.currentArrowStyle = arrowStyle
        view.currentFontName = fontName
        view.currentFontSize = fontSize
        view.currentTextAlignment = textAlignment
        view.currentBlurMode = blurMode
        view.currentBlurIntensity = blurIntensity
        view.selectedNodeID = selectedNodeID
        view.ocrLines = ocrLines
        view.showsOCROverlay = showsOCROverlay
        view.onNodeCreated = onNodeCreated
        view.onNodeUpdated = onNodeUpdated
        view.onSelectionChanged = onSelectionChanged
        view.onDeleteSelection = onDeleteSelection
        view.onTextRequested = onTextRequested
        view.onTextEditRequested = onTextEditRequested
        view.onOCRLinesCopied = onOCRLinesCopied
        view.onOCRTextCopied = onOCRTextCopied
        view.onOCRLineAsAnnotation = onOCRLineAsAnnotation
        view.invalidateRenderedPreview()
        view.updateOCRTextOverlay()
        view.needsDisplay = true
    }
}

final class EditableAnnotationCanvasNSView: NSView {
    var image: CGImage?
    var nodes: [AnnotationNode] = []
    var currentTool: EditorTool = .select {
        didSet {
            if currentTool != .ocr {
                ocrTextSelection = nil
            }
            if oldValue == .crop, currentTool != .crop {
                cancelPendingCrop()
            }
            window?.invalidateCursorRects(for: self)
        }
    }
    var currentColor = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
    var currentLineWidth: CGFloat = 3
    var currentOpacity: CGFloat = 1
    var currentFillColor: CGColor?
    var currentStrokeStyle: AnnotationStrokeStyle = .solid
    var currentCornerRadius: CGFloat = 0
    var currentArrowStyle: AnnotationArrowStyle = .filled
    var currentFontName = "Helvetica"
    var currentFontSize: CGFloat = 24
    var currentTextAlignment: AnnotationTextAlignment = .leading
    var currentBlurMode: AnnotationBlurMode = .gaussian
    var currentBlurIntensity: CGFloat = 0.5
    var selectedNodeID: UUID?
    var ocrLines: [OCRLine] = []
    var showsOCROverlay = true {
        didSet {
            if !showsOCROverlay {
                ocrTextSelection = nil
            }
            window?.invalidateCursorRects(for: self)
        }
    }

    var onNodeCreated: ((AnnotationNode) -> Void)?
    var onNodeUpdated: ((AnnotationNode) -> Void)?
    var onSelectionChanged: ((UUID?) -> Void)?
    var onDeleteSelection: (() -> Void)?
    var onTextRequested: ((CGPoint) -> Void)?
    var onTextEditRequested: ((AnnotationNode) -> Void)?
    var onOCRLinesCopied: (([OCRLine]) -> Void)?
    var onOCRTextCopied: ((String) -> Void)?
    var onOCRLineAsAnnotation: ((OCRLine) -> Void)?

    enum Interaction {
        case none
        case drawing
        case moving
        case resizing(ResizeHandle)
        case selectingOCRText
        case adjustingCrop
        case movingCrop
        case resizingCrop(ResizeHandle)
    }

    enum ResizeHandle: CaseIterable, Equatable {
        case bottomLeft, bottom, bottomRight, right
        case topRight, top, topLeft, left
        case start, end
    }

    var imageDisplayRect: CGRect = .zero
    var interaction: Interaction = .none
    var dragStartPoint: CGPoint = .zero
    var dragCurrentPoints: [CGPoint] = []
    var dragCurrentRect: CGRect = .zero
    var pendingCropRect: CGRect = .zero
    var cropInteractionStartRect: CGRect = .zero
    private var originalNode: AnnotationNode?
    private var interactiveNode: AnnotationNode?
    private var renderedPreview: CGImage?
    private var contextualOCRLine: OCRLine?
    private var ocrTextSelection: OCRTextSelection?
    private var ocrContentSignature = ""
    private var resizePointerOffset: CGPoint = .zero

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard currentTool == .ocr, showsOCROverlay else { return }
        for line in orderedOCRLines {
            addCursorRect(
                viewRect(from: line.editorBoundingBox).insetBy(dx: -3, dy: -3),
                cursor: .iBeam
            )
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(CGColor(gray: 0.12, alpha: 1))
        context.fill(bounds)

        if let image {
            let displayImage = previewImage(for: image) ?? image
            imageDisplayRect = aspectFitRect(
                imageSize: CGSize(width: displayImage.width, height: displayImage.height),
                in: bounds
            )
            context.draw(displayImage, in: imageDisplayRect)
        } else {
            imageDisplayRect = bounds
        }

        if showsOCROverlay {
            drawOCROverlay(in: context)
        }
        if case .drawing = interaction {
            drawCreationPreview(in: context)
        }
        drawPendingCrop(in: context)
        drawSelection(in: context)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard imageDisplayRect.contains(point) else { return }
        dragStartPoint = point

        switch currentTool {
        case .select:
            beginSelectionInteraction(at: point, clickCount: event.clickCount)
        case .ocr:
            beginOCRTextSelection(
                at: point,
                clickCount: event.clickCount,
                extendsSelection: event.modifierFlags.contains(.shift)
            )
        case .crop:
            beginCropInteraction(at: point, clickCount: event.clickCount)
        default:
            interaction = .drawing
            dragCurrentPoints = [normalizedPoint(point)]
            dragCurrentRect = .zero
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = clampedViewPoint(convert(event.locationInWindow, from: nil))
        switch interaction {
        case .drawing:
            updateCreationPreview(to: point)
        case .moving:
            updateMove(to: point)
        case .resizing(let handle):
            let adjustedPoint = CGPoint(
                x: point.x + resizePointerOffset.x,
                y: point.y + resizePointerOffset.y
            )
            updateResize(
                handle: handle,
                to: adjustedPoint,
                allowsFreeformTextScaling: event.modifierFlags.contains(.shift)
            )
        case .selectingOCRText:
            updateOCRTextSelection(to: point)
        case .adjustingCrop:
            break
        case .movingCrop:
            updateCropMove(to: point)
        case .resizingCrop(let handle):
            updateCropResize(handle: handle, to: point)
        case .none:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = clampedViewPoint(convert(event.locationInWindow, from: nil))
        var keepsPendingCrop = false
        defer {
            interaction = keepsPendingCrop ? .adjustingCrop : .none
            originalNode = nil
            interactiveNode = nil
            dragCurrentPoints = []
            dragCurrentRect = .zero
            cropInteractionStartRect = .zero
            resizePointerOffset = .zero
            invalidateRenderedPreview()
            needsDisplay = true
        }

        switch interaction {
        case .drawing:
            if currentTool == .crop {
                updateCreationPreview(to: point)
                let viewRect = viewRect(from: dragCurrentRect)
                if viewRect.width > 5, viewRect.height > 5 {
                    pendingCropRect = dragCurrentRect.standardized
                    keepsPendingCrop = true
                } else {
                    pendingCropRect = .zero
                }
            } else if currentTool == .text {
                onTextRequested?(normalizedPoint(point))
            } else if let node = createNode(at: normalizedPoint(point)) {
                onNodeCreated?(node)
            }
        case .moving, .resizing:
            if let interactiveNode {
                onNodeUpdated?(interactiveNode)
            }
        case .selectingOCRText:
            updateOCRTextSelection(to: point)
        case .adjustingCrop:
            keepsPendingCrop = !pendingCropRect.isEmpty
        case .movingCrop, .resizingCrop:
            keepsPendingCrop = !pendingCropRect.isEmpty
        case .none:
            break
        }
    }

    override func keyDown(with event: NSEvent) {
        if currentTool == .crop, !pendingCropRect.isEmpty {
            switch event.keyCode {
            case 36, 76:
                confirmPendingCrop()
            case 53:
                cancelPendingCrop()
            default:
                super.keyDown(with: event)
            }
            return
        }
        if currentTool == .ocr, handleOCRKeyDown(event) {
            return
        }
        switch event.keyCode {
        case 51, 117:
            onDeleteSelection?()
        case 53:
            onSelectionChanged?(nil)
        case 123, 124, 125, 126:
            nudgeSelection(keyCode: event.keyCode, multiplier: event.modifierFlags.contains(.shift) ? 10 : 1)
        default:
            super.keyDown(with: event)
        }
    }

    private func handleOCRKeyDown(_ event: NSEvent) -> Bool {
        let character = event.charactersIgnoringModifiers?.lowercased()
        if event.modifierFlags.contains(.command) {
            if character == "c" {
                return copySelectedOCRText()
            }
            if character == "a", let lastLine = orderedOCRLines.indices.last {
                ocrTextSelection = OCRTextSelection(
                    anchor: OCRTextPosition(lineIndex: 0, offset: 0),
                    extent: OCRTextPosition(
                        lineIndex: lastLine,
                        offset: (orderedOCRLines[lastLine].text as NSString).length
                    )
                )
                needsDisplay = true
                return true
            }
        }

        if event.keyCode == 53 {
            ocrTextSelection = nil
            needsDisplay = true
            return true
        }

        guard [UInt16(123), 124, 125, 126].contains(event.keyCode),
              !orderedOCRLines.isEmpty else { return false }
        moveOCRCaret(
            keyCode: event.keyCode,
            extendsSelection: event.modifierFlags.contains(.shift)
        )
        return true
    }

    private func moveOCRCaret(keyCode: UInt16, extendsSelection: Bool) {
        let lines = orderedOCRLines.map(\.text)
        let fallback = OCRTextPosition(lineIndex: 0, offset: 0)
        let selection = ocrTextSelection ?? OCRTextSelection(anchor: fallback, extent: fallback)

        if !extendsSelection, !selection.isEmpty {
            let endpoints = selection.orderedEndpoints
            let collapsed = keyCode == 123 || keyCode == 126
                ? endpoints.start
                : endpoints.end
            ocrTextSelection = OCRTextSelection(anchor: collapsed, extent: collapsed)
            needsDisplay = true
            return
        }

        let moved = movedOCRPosition(selection.extent, keyCode: keyCode, lines: lines)
        let anchor = extendsSelection ? selection.anchor : moved
        ocrTextSelection = OCRTextSelection(anchor: anchor, extent: moved)
        needsDisplay = true
    }

    private func movedOCRPosition(
        _ position: OCRTextPosition,
        keyCode: UInt16,
        lines: [String]
    ) -> OCRTextPosition {
        let lineIndex = min(position.lineIndex, lines.count - 1)
        let text = lines[lineIndex] as NSString
        let offset = min(position.offset, text.length)

        switch keyCode {
        case 123:
            if offset > 0 {
                let range = text.rangeOfComposedCharacterSequence(at: offset - 1)
                return OCRTextPosition(lineIndex: lineIndex, offset: range.location)
            }
            guard lineIndex > 0 else { return OCRTextPosition(lineIndex: 0, offset: 0) }
            return OCRTextPosition(
                lineIndex: lineIndex - 1,
                offset: (lines[lineIndex - 1] as NSString).length
            )
        case 124:
            if offset < text.length {
                let range = text.rangeOfComposedCharacterSequence(at: offset)
                return OCRTextPosition(lineIndex: lineIndex, offset: NSMaxRange(range))
            }
            guard lineIndex + 1 < lines.count else { return OCRTextPosition(lineIndex: lineIndex, offset: offset) }
            return OCRTextPosition(lineIndex: lineIndex + 1, offset: 0)
        case 125:
            guard lineIndex + 1 < lines.count else { return OCRTextPosition(lineIndex: lineIndex, offset: offset) }
            return OCRTextPosition(
                lineIndex: lineIndex + 1,
                offset: min(offset, (lines[lineIndex + 1] as NSString).length)
            )
        default:
            guard lineIndex > 0 else { return OCRTextPosition(lineIndex: 0, offset: min(offset, text.length)) }
            return OCRTextPosition(
                lineIndex: lineIndex - 1,
                offset: min(offset, (lines[lineIndex - 1] as NSString).length)
            )
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard currentTool == .ocr else { return super.menu(for: event) }
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = ocrLineHit(at: point) else { return nil }
        let line = hit.line
        contextualOCRLine = line
        let position = textPosition(in: hit, at: point)
        if ocrTextSelection?.contains(position) != true {
            ocrTextSelection = .wordSelection(
                in: line.text,
                lineIndex: hit.index,
                offset: position.offset
            )
            needsDisplay = true
        }

        let menu = NSMenu()
        let copySelection = menu.addItem(
            withTitle: "Copy",
            action: #selector(copyContextualOCRSelection),
            keyEquivalent: ""
        )
        copySelection.isEnabled = ocrTextSelection?.isEmpty == false
        menu.addItem(withTitle: "Copy Line", action: #selector(copyContextualOCRLine), keyEquivalent: "")
        menu.addItem(withTitle: "Add as Text Annotation", action: #selector(addContextualOCRLine), keyEquivalent: "")
        menu.items.forEach { $0.target = self }
        return menu
    }

    @objc private func copyContextualOCRSelection() {
        _ = copySelectedOCRText()
    }

    @objc private func copyContextualOCRLine() {
        guard let contextualOCRLine else { return }
        onOCRLinesCopied?([contextualOCRLine])
    }

    @objc private func addContextualOCRLine() {
        guard let contextualOCRLine else { return }
        onOCRLineAsAnnotation?(contextualOCRLine)
    }

    private func beginSelectionInteraction(at point: CGPoint, clickCount: Int) {
        if let selectedNode = selectedNode,
           let handle = resizeHandle(at: point, for: selectedNode) {
            originalNode = selectedNode
            interactiveNode = selectedNode
            let contentPoint = contentHandlePoint(handle, for: selectedNode)
            resizePointerOffset = CGPoint(
                x: contentPoint.x - point.x,
                y: contentPoint.y - point.y
            )
            interaction = .resizing(handle)
            return
        }

        guard let hitNode = hitNode(at: point) else {
            onSelectionChanged?(nil)
            interaction = .none
            return
        }
        onSelectionChanged?(hitNode.id)
        if clickCount == 2, hitNode.tool == .text {
            onTextEditRequested?(hitNode)
            interaction = .none
            return
        }
        originalNode = hitNode
        interactiveNode = hitNode
        interaction = .moving
    }

    private func updateCreationPreview(to point: CGPoint) {
        guard let annotationTool = currentTool.annotationTool else { return }
        let normalized = normalizedPoint(point)
        switch annotationTool {
        case .pen:
            dragCurrentPoints.append(normalized)
        case .arrow:
            dragCurrentPoints = [normalizedPoint(dragStartPoint), normalized]
        case .rect, .highlight, .blur, .crop:
            dragCurrentRect = normalizedRect(from: dragStartPoint, to: point)
        case .text:
            dragCurrentPoints = [normalized]
        }
    }

    private func updateMove(to point: CGPoint) {
        guard var node = originalNode else { return }
        let start = normalizedPoint(dragStartPoint)
        let current = normalizedPoint(point)
        let delta = CGPoint(x: current.x - start.x, y: current.y - start.y)
        let bounds = normalizedBounds(for: node)
        let safeDX = min(max(delta.x, -bounds.minX), 1 - bounds.maxX)
        let safeDY = min(max(delta.y, -bounds.minY), 1 - bounds.maxY)
        node.points = node.points.map { CGPoint(x: $0.x + safeDX, y: $0.y + safeDY) }
        if node.normalizedRect != .zero {
            node.normalizedRect = node.normalizedRect.offsetBy(dx: safeDX, dy: safeDY)
        }
        interactiveNode = node
        invalidateRenderedPreview()
    }

    private func updateResize(
        handle: ResizeHandle,
        to point: CGPoint,
        allowsFreeformTextScaling: Bool
    ) {
        guard var node = originalNode else { return }
        let normalized = normalizedPoint(point)
        if node.tool == .arrow, node.points.count >= 2 {
            if handle == .start { node.points[0] = normalized }
            if handle == .end { node.points[1] = normalized }
        } else {
            let oldBounds = normalizedBounds(for: node)
            let newBounds = resizedBounds(oldBounds, handle: handle, point: normalized)
            if node.tool == .text {
                node = resizedTextNode(
                    node,
                    from: oldBounds,
                    to: newBounds,
                    handle: handle,
                    allowsFreeformScaling: allowsFreeformTextScaling
                )
                interactiveNode = node
                invalidateRenderedPreview()
                return
            }
            if node.normalizedRect != .zero {
                node.normalizedRect = newBounds
            } else if !node.points.isEmpty {
                node.points = scaledPoints(node.points, from: oldBounds, to: newBounds)
            }
        }
        interactiveNode = node
        invalidateRenderedPreview()
    }

    private func resizedTextNode(
        _ source: AnnotationNode,
        from oldBounds: CGRect,
        to proposedBounds: CGRect,
        handle: ResizeHandle,
        allowsFreeformScaling: Bool
    ) -> AnnotationNode {
        guard oldBounds.width > 0, oldBounds.height > 0 else { return source }
        var node = source
        let widthScale = proposedBounds.width / oldBounds.width
        let heightScale = proposedBounds.height / oldBounds.height

        if allowsFreeformScaling {
            let requestedFontSize = source.fontSize * heightScale
            let newFontSize = min(max(requestedFontSize, 4), 512)
            let appliedVerticalScale = newFontSize / max(source.fontSize, 1)
            node.fontSize = newFontSize
            node.textHorizontalScale = min(
                max(source.textHorizontalScale * widthScale / max(appliedVerticalScale, 0.001), 0.1),
                10
            )
            node.normalizedRect = proposedBounds
        } else {
            let requestedScale: CGFloat = switch handle {
            case .left, .right:
                widthScale
            case .top, .bottom:
                heightScale
            case .bottomLeft, .bottomRight, .topLeft, .topRight:
                abs(widthScale - 1) >= abs(heightScale - 1) ? widthScale : heightScale
            case .start, .end:
                1
            }
            let minimumScale = max(
                max(4 / max(source.fontSize, 1), 0.01 / oldBounds.width),
                0.01 / oldBounds.height
            )
            let maximumScale = min(
                min(512 / max(source.fontSize, 1), 1 / oldBounds.width),
                1 / oldBounds.height
            )
            let scale = min(max(requestedScale, minimumScale), maximumScale)
            node.fontSize = source.fontSize * scale
            node.normalizedRect = proportionalBounds(
                oldBounds,
                scale: scale,
                handle: handle
            )
        }

        node.points = [node.normalizedRect.origin]
        return node
    }

    private func proportionalBounds(_ oldBounds: CGRect, scale: CGFloat, handle: ResizeHandle) -> CGRect {
        let size = CGSize(width: oldBounds.width * scale, height: oldBounds.height * scale)
        var origin = CGPoint.zero

        switch handle {
        case .bottomLeft, .left, .topLeft:
            origin.x = oldBounds.maxX - size.width
        case .bottomRight, .right, .topRight:
            origin.x = oldBounds.minX
        case .bottom, .top:
            origin.x = oldBounds.midX - size.width / 2
        case .start, .end:
            origin.x = oldBounds.minX
        }

        switch handle {
        case .bottomLeft, .bottom, .bottomRight:
            origin.y = oldBounds.maxY - size.height
        case .topLeft, .top, .topRight:
            origin.y = oldBounds.minY
        case .left, .right:
            origin.y = oldBounds.midY - size.height / 2
        case .start, .end:
            origin.y = oldBounds.minY
        }

        origin.x = min(max(origin.x, 0), 1 - size.width)
        origin.y = min(max(origin.y, 0), 1 - size.height)
        return CGRect(origin: origin, size: size)
    }

    private func beginOCRTextSelection(
        at point: CGPoint,
        clickCount: Int,
        extendsSelection: Bool
    ) {
        guard let hit = ocrLineHit(at: point) else {
            ocrTextSelection = nil
            interaction = .none
            needsDisplay = true
            return
        }

        let position = textPosition(in: hit, at: point)
        if clickCount >= 3 {
            ocrTextSelection = .lineSelection(in: hit.line.text, lineIndex: hit.index)
            interaction = .none
        } else if clickCount == 2 {
            ocrTextSelection = .wordSelection(
                in: hit.line.text,
                lineIndex: hit.index,
                offset: position.offset
            )
            interaction = .none
        } else {
            let anchor = extendsSelection ? (ocrTextSelection?.anchor ?? position) : position
            ocrTextSelection = OCRTextSelection(anchor: anchor, extent: position)
            interaction = .selectingOCRText
        }
        needsDisplay = true
    }

    private func updateOCRTextSelection(to point: CGPoint) {
        guard let anchor = ocrTextSelection?.anchor,
              let hit = closestOCRLineHit(to: point) else { return }
        ocrTextSelection = OCRTextSelection(
            anchor: anchor,
            extent: textPosition(in: hit, at: point)
        )
    }

    @discardableResult
    private func copySelectedOCRText() -> Bool {
        guard let selection = ocrTextSelection, !selection.isEmpty else { return false }
        let text = selection.selectedText(in: orderedOCRLines.map(\.text))
        guard !text.isEmpty else { return false }
        onOCRTextCopied?(text)
        return true
    }

    private func createNode(at endPoint: CGPoint) -> AnnotationNode? {
        guard let annotationTool = currentTool.annotationTool else { return nil }
        let startPoint = normalizedPoint(dragStartPoint)
        let rect = normalizedRect(from: dragStartPoint, to: viewPoint(from: endPoint))
        let common = { (points: [CGPoint], normalizedRect: CGRect, opacity: CGFloat) in
            self.makeNode(
                tool: annotationTool,
                points: points,
                normalizedRect: normalizedRect,
                opacity: opacity
            )
        }
        switch annotationTool {
        case .pen:
            guard dragCurrentPoints.count >= 2 else { return nil }
            return common(dragCurrentPoints, .zero, currentOpacity)
        case .arrow:
            return common([startPoint, endPoint], .zero, currentOpacity)
        case .rect:
            return common([], rect, currentOpacity)
        case .highlight:
            return common([], rect, min(currentOpacity, 0.45))
        case .blur, .crop:
            return common([], rect, currentOpacity)
        case .text:
            return nil
        }
    }

    private func drawSelection(in context: CGContext) {
        guard currentTool == .select, let node = interactiveNode ?? selectedNode else { return }
        context.saveGState()
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.setLineWidth(1.5)
        context.setLineDash(phase: 0, lengths: [5, 3])
        context.stroke(selectionFrameRect(for: node))
        context.setLineDash(phase: 0, lengths: [])
        for handle in visibleHandles(for: node) {
            let center = handlePoint(handle, for: node)
            let handleSize: CGFloat = node.tool == .text ? 7 : 8
            let handleRect = CGRect(
                x: center.x - handleSize / 2,
                y: center.y - handleSize / 2,
                width: handleSize,
                height: handleSize
            )
            context.fill(handleRect)
            context.stroke(handleRect)
        }
        context.restoreGState()
    }

    private func drawOCROverlay(in context: CGContext) {
        context.saveGState()
        for line in ocrLines {
            let rect = viewRect(from: line.editorBoundingBox)
            context.setFillColor(NSColor.systemBlue.withAlphaComponent(currentTool == .ocr ? 0.06 : 0.035).cgColor)
            context.setStrokeColor(NSColor.systemBlue.withAlphaComponent(currentTool == .ocr ? 0.55 : 0.25).cgColor)
            context.setLineWidth(currentTool == .ocr ? 1 : 0.75)
            context.fill(rect)
            context.stroke(rect)
        }

        if currentTool == .ocr, let selection = ocrTextSelection {
            if selection.isEmpty {
                drawOCRInsertionPoint(selection.extent, in: context)
            } else {
                context.setFillColor(
                    NSColor.selectedContentBackgroundColor.withAlphaComponent(0.68).cgColor
                )
                for rect in ocrSelectionRects(for: selection) {
                    context.fill(rect)
                }
                // 保留截图中的原始文字像素。重新绘制近似系统字体会因字形、基线和
                // 水平缩放不同而让选中文字产生视觉位移。
            }
        }
        context.restoreGState()
    }

    private func drawOCRInsertionPoint(_ position: OCRTextPosition, in context: CGContext) {
        guard orderedOCRLines.indices.contains(position.lineIndex) else { return }
        let line = orderedOCRLines[position.lineIndex]
        let layout = ocrLineLayout(for: line)
        let offset = min(position.offset, (line.text as NSString).length)
        let x = layout.rect.minX
            + CTLineGetOffsetForStringIndex(layout.line, offset, nil) * layout.horizontalScale
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1.5)
        context.move(to: CGPoint(x: x, y: layout.rect.minY + 1))
        context.addLine(to: CGPoint(x: x, y: layout.rect.maxY - 1))
        context.strokePath()
    }

    private func ocrSelectionRects(for selection: OCRTextSelection) -> [CGRect] {
        let lines = orderedOCRLines
        return selection.slices(in: lines.map(\.text)).compactMap { slice in
            guard slice.length > 0, lines.indices.contains(slice.lineIndex) else { return nil }
            let layout = ocrLineLayout(for: lines[slice.lineIndex])
            let start = CTLineGetOffsetForStringIndex(layout.line, slice.location, nil)
            let end = CTLineGetOffsetForStringIndex(layout.line, NSMaxRange(slice.range), nil)
            let minX = layout.rect.minX + min(start, end) * layout.horizontalScale
            let maxX = layout.rect.minX + max(start, end) * layout.horizontalScale
            return CGRect(
                x: minX,
                y: layout.rect.minY,
                width: max(maxX - minX, 1.5),
                height: layout.rect.height
            )
        }
    }

    private var selectedNode: AnnotationNode? {
        guard let selectedNodeID else { return nil }
        return nodes.first { $0.id == selectedNodeID }
    }

    private func hitNode(at point: CGPoint) -> AnnotationNode? {
        let normalized = normalizedPoint(point)
        let tolerance = max(8 / max(imageDisplayRect.width, 1), 8 / max(imageDisplayRect.height, 1))
        return displayNodes.reversed().first { node in
            if node.tool == .arrow, node.points.count >= 2 {
                return distance(normalized, toSegmentFrom: node.points[0], to: node.points[1]) <= tolerance
            }
            if node.tool == .pen, node.points.count >= 2 {
                return zip(node.points, node.points.dropFirst()).contains {
                    distance(normalized, toSegmentFrom: $0.0, to: $0.1) <= tolerance
                }
            }
            return normalizedBounds(for: node).insetBy(dx: -tolerance, dy: -tolerance).contains(normalized)
        }
    }

    private struct OCRLineHit {
        let index: Int
        let line: OCRLine
        let rect: CGRect
    }

    private struct OCRLineLayout {
        let line: CTLine
        let rect: CGRect
        let horizontalScale: CGFloat
    }

    private var orderedOCRLines: [OCRLine] {
        ocrLines
            .filter { !$0.text.isEmpty && !$0.editorBoundingBox.isEmpty }
            .sorted { lhs, rhs in
                let lhsRect = lhs.editorBoundingBox
                let rhsRect = rhs.editorBoundingBox
                let rowTolerance = max(lhsRect.height, rhsRect.height) * 0.5
                if abs(lhsRect.midY - rhsRect.midY) > rowTolerance {
                    return lhsRect.midY > rhsRect.midY
                }
                return lhsRect.minX < rhsRect.minX
            }
    }

    private func ocrLineHit(at point: CGPoint) -> OCRLineHit? {
        orderedOCRLines.enumerated().compactMap { index, line -> OCRLineHit? in
            let rect = viewRect(from: line.editorBoundingBox).insetBy(dx: -3, dy: -3)
            return rect.contains(point) ? OCRLineHit(index: index, line: line, rect: rect) : nil
        }.min { lhs, rhs in
            abs(lhs.rect.midY - point.y) < abs(rhs.rect.midY - point.y)
        }
    }

    private func closestOCRLineHit(to point: CGPoint) -> OCRLineHit? {
        let hits = orderedOCRLines.enumerated().map { index, line in
            OCRLineHit(index: index, line: line, rect: viewRect(from: line.editorBoundingBox))
        }
        return hits.min { lhs, rhs in
            distance(from: point, to: lhs.rect) < distance(from: point, to: rhs.rect)
        }
    }

    private func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(max(rect.minX - point.x, 0), point.x - rect.maxX)
        let dy = max(max(rect.minY - point.y, 0), point.y - rect.maxY)
        return hypot(dx, dy)
    }

    private func textPosition(in hit: OCRLineHit, at point: CGPoint) -> OCRTextPosition {
        let layout = ocrLineLayout(for: hit.line)
        let textLength = (hit.line.text as NSString).length
        let localX = (point.x - layout.rect.minX) / max(layout.horizontalScale, 0.001)
        let index = CTLineGetStringIndexForPosition(
            layout.line,
            CGPoint(x: localX, y: 0)
        )
        let offset: Int
        if index == kCFNotFound {
            offset = point.x <= layout.rect.midX ? 0 : textLength
        } else {
            offset = min(max(index, 0), textLength)
        }
        return OCRTextPosition(lineIndex: hit.index, offset: offset)
    }

    private func ocrLineLayout(for line: OCRLine) -> OCRLineLayout {
        let rect = viewRect(from: line.editorBoundingBox)
        let font = fittedOCRFont(for: line.text, in: rect.size)
        let attributedString = NSAttributedString(
            string: line.text,
            attributes: [.font: font]
        )
        let textLine = CTLineCreateWithAttributedString(attributedString)
        let measuredWidth = CGFloat(CTLineGetTypographicBounds(textLine, nil, nil, nil))
        return OCRLineLayout(
            line: textLine,
            rect: rect,
            horizontalScale: rect.width / max(measuredWidth, 1)
        )
    }

    private func normalizedBounds(for node: AnnotationNode) -> CGRect {
        if node.normalizedRect != .zero { return node.normalizedRect.standardized }
        guard let first = node.points.first else { return .zero }
        let minX = node.points.reduce(first.x) { min($0, $1.x) }
        let maxX = node.points.reduce(first.x) { max($0, $1.x) }
        let minY = node.points.reduce(first.y) { min($0, $1.y) }
        let maxY = node.points.reduce(first.y) { max($0, $1.y) }
        let paddingX = max(6 / max(imageDisplayRect.width, 1), 0.002)
        let paddingY = max(6 / max(imageDisplayRect.height, 1), 0.002)
        return CGRect(
            x: minX - paddingX,
            y: minY - paddingY,
            width: max(maxX - minX, paddingX * 2),
            height: max(maxY - minY, paddingY * 2)
        )
    }

    private func visibleHandles(for node: AnnotationNode) -> [ResizeHandle] {
        if node.tool == .arrow { return [.start, .end] }
        if node.tool == .text {
            let contentRect = viewRect(from: normalizedBounds(for: node))
            if contentRect.width < 72 || contentRect.height < 36 {
                return [.bottomLeft, .bottomRight, .topRight, .topLeft]
            }
        }
        return [
            .bottomLeft, .bottom, .bottomRight, .right,
            .topRight, .top, .topLeft, .left,
        ]
    }

    private func resizeHandle(at point: CGPoint, for node: AnnotationNode) -> ResizeHandle? {
        visibleHandles(for: node).first {
            let center = handlePoint($0, for: node)
            return hypot(point.x - center.x, point.y - center.y) <= 9
        }
    }

    private func handlePoint(_ handle: ResizeHandle, for node: AnnotationNode) -> CGPoint {
        if node.tool == .arrow, node.points.count >= 2 {
            return viewPoint(from: handle == .start ? node.points[0] : node.points[1])
        }
        let rect = node.tool == .text
            ? selectionFrameRect(for: node)
            : viewRect(from: normalizedBounds(for: node))
        return handlePoint(handle, in: rect)
    }

    private func contentHandlePoint(_ handle: ResizeHandle, for node: AnnotationNode) -> CGPoint {
        if node.tool == .arrow, node.points.count >= 2 {
            return viewPoint(from: handle == .start ? node.points[0] : node.points[1])
        }
        return handlePoint(handle, in: viewRect(from: normalizedBounds(for: node)))
    }

    func handlePoint(_ handle: ResizeHandle, in rect: CGRect) -> CGPoint {
        return switch handle {
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .bottom: CGPoint(x: rect.midX, y: rect.minY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .right: CGPoint(x: rect.maxX, y: rect.midY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.maxY)
        case .top: CGPoint(x: rect.midX, y: rect.maxY)
        case .topLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .left: CGPoint(x: rect.minX, y: rect.midY)
        case .start, .end: .zero
        }
    }

    private func selectionFrameRect(for node: AnnotationNode) -> CGRect {
        let contentRect = viewRect(from: normalizedBounds(for: node))
        guard node.tool == .text else {
            return contentRect.insetBy(dx: -4, dy: -4)
        }
        let displayScale: CGFloat
        if let image, image.width > 0 {
            displayScale = imageDisplayRect.width / CGFloat(image.width)
        } else {
            displayScale = 1
        }
        let displayedFontSize = node.fontSize * displayScale
        let safetyMargin = min(max(displayedFontSize * 0.3, 6), 14)
        return contentRect.insetBy(dx: -safetyMargin, dy: -safetyMargin)
    }

    private func resizedBounds(_ bounds: CGRect, handle: ResizeHandle, point: CGPoint) -> CGRect {
        let minimum = CGSize(width: 0.01, height: 0.01)
        var minX = bounds.minX
        var maxX = bounds.maxX
        var minY = bounds.minY
        var maxY = bounds.maxY
        switch handle {
        case .bottomLeft: minX = point.x; minY = point.y
        case .bottom: minY = point.y
        case .bottomRight: maxX = point.x; minY = point.y
        case .right: maxX = point.x
        case .topRight: maxX = point.x; maxY = point.y
        case .top: maxY = point.y
        case .topLeft: minX = point.x; maxY = point.y
        case .left: minX = point.x
        case .start, .end: break
        }
        let standardized = CGRect(
            x: min(minX, maxX),
            y: min(minY, maxY),
            width: max(abs(maxX - minX), minimum.width),
            height: max(abs(maxY - minY), minimum.height)
        )
        return standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private func scaledPoints(_ points: [CGPoint], from old: CGRect, to new: CGRect) -> [CGPoint] {
        guard old.width > 0, old.height > 0 else { return points }
        return points.map { point in
            CGPoint(
                x: new.minX + ((point.x - old.minX) / old.width) * new.width,
                y: new.minY + ((point.y - old.minY) / old.height) * new.height
            )
        }
    }

    private func nudgeSelection(keyCode: UInt16, multiplier: CGFloat) {
        guard var node = selectedNode, let image else { return }
        let dx = multiplier / CGFloat(max(image.width, 1))
        let dy = multiplier / CGFloat(max(image.height, 1))
        let offset: CGPoint = switch keyCode {
        case 123: CGPoint(x: -dx, y: 0)
        case 124: CGPoint(x: dx, y: 0)
        case 125: CGPoint(x: 0, y: -dy)
        default: CGPoint(x: 0, y: dy)
        }
        node.points = node.points.map {
            CGPoint(x: min(max($0.x + offset.x, 0), 1), y: min(max($0.y + offset.y, 0), 1))
        }
        if node.normalizedRect != .zero {
            let moved = node.normalizedRect.offsetBy(dx: offset.x, dy: offset.y)
            node.normalizedRect.origin.x = min(max(moved.origin.x, 0), 1 - moved.width)
            node.normalizedRect.origin.y = min(max(moved.origin.y, 0), 1 - moved.height)
        }
        onNodeUpdated?(node)
    }

    private func distance(_ point: CGPoint, toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let t = min(max(((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared, 0), 1)
        let projection = CGPoint(x: start.x + t * dx, y: start.y + t * dy)
        return hypot(point.x - projection.x, point.y - projection.y)
    }

    private var displayNodes: [AnnotationNode] {
        guard let interactiveNode else { return nodes }
        return nodes.map { $0.id == interactiveNode.id ? interactiveNode : $0 }
    }

    func invalidateRenderedPreview() {
        renderedPreview = nil
    }

    override func setFrameSize(_ newSize: NSSize) {
        if frame.size != newSize { invalidateRenderedPreview() }
        super.setFrameSize(newSize)
        updateOCRTextOverlay()
    }

    override func layout() {
        super.layout()
        updateOCRTextOverlay()
    }

    private func previewImage(for image: CGImage) -> CGImage? {
        if displayNodes.isEmpty { return image }
        if let renderedPreview { return renderedPreview }
        var document = AnnotationDocument(baseImage: image)
        document.nodes = displayNodes
        let backingScale = window?.backingScaleFactor ?? 2
        let maximumDimension = max(bounds.width, bounds.height) * backingScale
        renderedPreview = try? Renderer().render(document, maximumDimension: maximumDimension)
        return renderedPreview
    }

    func normalizedPoint(_ point: CGPoint) -> CGPoint {
        guard imageDisplayRect.width > 0, imageDisplayRect.height > 0 else { return .zero }
        return CGPoint(
            x: min(max((point.x - imageDisplayRect.minX) / imageDisplayRect.width, 0), 1),
            y: min(max((point.y - imageDisplayRect.minY) / imageDisplayRect.height, 0), 1)
        )
    }

    private func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        let a = normalizedPoint(start)
        let b = normalizedPoint(end)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    func viewPoint(from normalized: CGPoint) -> CGPoint {
        CGPoint(
            x: imageDisplayRect.minX + normalized.x * imageDisplayRect.width,
            y: imageDisplayRect.minY + normalized.y * imageDisplayRect.height
        )
    }

    func viewRect(from normalized: CGRect) -> CGRect {
        CGRect(
            x: imageDisplayRect.minX + normalized.minX * imageDisplayRect.width,
            y: imageDisplayRect.minY + normalized.minY * imageDisplayRect.height,
            width: normalized.width * imageDisplayRect.width,
            height: normalized.height * imageDisplayRect.height
        )
    }

    private func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    private func clampedViewPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, imageDisplayRect.minX), imageDisplayRect.maxX),
            y: min(max(point.y, imageDisplayRect.minY), imageDisplayRect.maxY)
        )
    }

    private func aspectFitRect(imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    func updateOCRTextOverlay() {
        if let image, bounds.width > 0, bounds.height > 0 {
            imageDisplayRect = aspectFitRect(
                imageSize: CGSize(width: image.width, height: image.height),
                in: bounds
            )
        }
        let newContentSignature = ocrLines.map {
            "\($0.text)|\($0.editorBoundingBox.origin.x)|\($0.editorBoundingBox.origin.y)|\($0.editorBoundingBox.width)|\($0.editorBoundingBox.height)"
        }.joined(separator: "\n")
        if newContentSignature != ocrContentSignature {
            ocrContentSignature = newContentSignature
            ocrTextSelection = nil
            if case .selectingOCRText = interaction {
                interaction = .none
            }
        }
        if let selection = ocrTextSelection {
            let lines = orderedOCRLines
            let endpoints = selection.orderedEndpoints
            if lines.isEmpty || endpoints.end.lineIndex >= lines.count {
                ocrTextSelection = nil
            }
        }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    private func fittedOCRFont(for text: String, in size: CGSize) -> NSFont {
        let heightLimitedSize = max(8, size.height * 0.78)
        let baseFont = NSFont.systemFont(ofSize: heightLimitedSize)
        let measuredWidth = (text as NSString).size(withAttributes: [.font: baseFont]).width
        guard measuredWidth > size.width, measuredWidth > 0 else { return baseFont }
        return NSFont.systemFont(ofSize: max(6, heightLimitedSize * size.width / measuredWidth))
    }
}
