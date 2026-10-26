import AnnotationCore
import AppKit
import OCRCore
import SharedKit
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
    let isAdjustingStyle: Bool
    let ocrLines: [OCRLine]
    let showsOCROverlay: Bool
    let verticalCropOnly: Bool
    let dominantColorCount: Int
    let zoomController: CanvasZoomController
    var onToolShortcut: (EditorTool) -> Void
    var onNodeCreated: (AnnotationNode) -> Void
    var onNodeUpdated: (AnnotationNode) -> Void
    var onSelectionChanged: (UUID?) -> Void
    var onDeleteSelection: () -> Void
    var onTextRequested: (CGPoint) -> Void
    var onTextEditRequested: (AnnotationNode) -> Void
    let textEntryID: UUID
    let textEntryNode: AnnotationNode?
    var onTextCommit: (String) -> Void
    var onTextCancel: () -> Void
    var onTextDraftChanged: (String) -> Void
    var onOCRLinesCopied: ([OCRLine]) -> Void
    var onOCRTextCopied: (String) -> Void
    var onOCRLineAsAnnotation: (OCRLine) -> Void
    var onColorPicked: (SampledColor) -> Void
    var onRegionColorsPicked: ([SampledColor]) -> Void

    func makeNSView(context: Context) -> EditableAnnotationCanvasNSView {
        let view = EditableAnnotationCanvasNSView()
        zoomController.attach(view)
        view.onZoomChanged = { [weak zoomController] scale, pixelScale in
            zoomController?.canvasDidChangeZoom(scale: scale, pixelScale: pixelScale)
        }
        return view
    }

    func updateNSView(_ view: EditableAnnotationCanvasNSView, context: Context) {
        if view.image !== image {
            // A new base image (first load or a crop) starts at fit-to-window.
            view.zoomScale = 1
            view.panOffset = .zero
        }
        zoomController.attach(view)
        view.image = image
        view.nodes = nodes.filter { $0.id != textEntryNode?.id }
        view.verticalCropOnly = verticalCropOnly
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
        view.selectedNodeID = textEntryNode == nil ? selectedNodeID : nil
        view.liveStyleNodeID = isAdjustingStyle ? selectedNodeID : nil
        view.ocrLines = ocrLines
        view.showsOCROverlay = showsOCROverlay
        view.onNodeCreated = onNodeCreated
        view.onNodeUpdated = onNodeUpdated
        view.onSelectionChanged = onSelectionChanged
        view.onDeleteSelection = onDeleteSelection
        view.onTextRequested = onTextRequested
        view.onTextEditRequested = onTextEditRequested
        view.updateTextEntry(id: textEntryID, node: textEntryNode,
                             onCommit: onTextCommit, onCancel: onTextCancel)
        view.onTextDraftChanged = onTextDraftChanged
        view.onOCRLinesCopied = onOCRLinesCopied
        view.onOCRTextCopied = onOCRTextCopied
        view.onOCRLineAsAnnotation = onOCRLineAsAnnotation
        view.onColorPicked = onColorPicked
        view.onRegionColorsPicked = onRegionColorsPicked
        view.onToolShortcut = onToolShortcut
        view.dominantColorCount = dominantColorCount
        view.updateOCRTextOverlay()
        view.needsDisplay = true
    }

    static func dismantleNSView(_ view: EditableAnnotationCanvasNSView, coordinator: ()) {
        view.endTextEntry()
    }
}
