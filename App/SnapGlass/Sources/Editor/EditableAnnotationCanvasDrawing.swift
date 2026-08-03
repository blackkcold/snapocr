import AnnotationCore
import AppKit

extension EditableAnnotationCanvasNSView {
    func makeNode(
        tool: AnnotationToolType,
        points: [CGPoint],
        normalizedRect: CGRect,
        opacity: CGFloat
    ) -> AnnotationNode {
        AnnotationNode(
            tool: tool,
            color: currentColor,
            lineWidth: currentLineWidth,
            opacity: opacity,
            fillColor: currentFillColor,
            strokeStyle: currentStrokeStyle,
            cornerRadius: currentCornerRadius,
            arrowStyle: currentArrowStyle,
            points: points,
            fontName: currentFontName,
            fontSize: currentFontSize,
            textAlignment: currentTextAlignment,
            blurMode: currentBlurMode,
            blurIntensity: currentBlurIntensity,
            normalizedRect: normalizedRect
        )
    }

    func drawCreationPreview(in context: CGContext) {
        context.saveGState()
        context.setStrokeColor(currentColor)
        context.setLineWidth(previewLineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setAlpha(currentOpacity)
        switch currentTool.annotationTool {
        case .pen:
            guard dragCurrentPoints.count >= 2 else { break }
            context.move(to: viewPoint(from: dragCurrentPoints[0]))
            for point in dragCurrentPoints.dropFirst() {
                context.addLine(to: viewPoint(from: point))
            }
            context.strokePath()
        case .arrow:
            guard dragCurrentPoints.count >= 2 else { break }
            context.move(to: viewPoint(from: dragCurrentPoints[0]))
            context.addLine(to: viewPoint(from: dragCurrentPoints[1]))
            context.strokePath()
        case .rect, .highlight, .blur, .crop:
            let rect = viewRect(from: dragCurrentRect)
            if currentTool == .rect, let currentFillColor {
                context.setFillColor(currentFillColor)
                context.fill(rect)
            } else if currentTool == .highlight {
                context.setFillColor(currentColor.copy(alpha: 0.3) ?? currentColor)
                context.fill(rect)
            }
            context.stroke(rect)
        case .text, .none:
            break
        }
        context.restoreGState()
    }

    private var previewLineWidth: CGFloat {
        guard let image, image.width > 0 else { return currentLineWidth }
        return max(currentLineWidth * imageDisplayRect.width / CGFloat(image.width), 0.5)
    }
}
