import AnnotationCore
import AppKit
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
    let verticalCropOnly: Bool
    let dominantColorCount: Int
    var onNodeCreated: (AnnotationNode) -> Void
    var onNodeUpdated: (AnnotationNode) -> Void
    var onSelectionChanged: (UUID?) -> Void
    var onDeleteSelection: () -> Void
    var onTextRequested: (CGPoint) -> Void
    var onTextEditRequested: (AnnotationNode) -> Void
    var onOCRLinesCopied: ([OCRLine]) -> Void
    var onOCRTextCopied: (String) -> Void
    var onOCRLineAsAnnotation: (OCRLine) -> Void
    var onColorPicked: (String) -> Void
    var onRegionColorsPicked: ([String]) -> Void

    func makeNSView(context: Context) -> EditableAnnotationCanvasNSView { EditableAnnotationCanvasNSView() }

    func updateNSView(_ view: EditableAnnotationCanvasNSView, context: Context) {
        view.image = image
        view.nodes = nodes
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
        view.onColorPicked = onColorPicked
        view.onRegionColorsPicked = onRegionColorsPicked
        view.dominantColorCount = dominantColorCount
        view.invalidateRenderedPreview()
        view.updateOCRTextOverlay()
        view.needsDisplay = true
    }
}
