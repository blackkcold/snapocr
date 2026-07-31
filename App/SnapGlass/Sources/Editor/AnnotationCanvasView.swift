import SwiftUI
import AppKit
import AnnotationCore

/// An `NSViewRepresentable` wrapping a custom `NSView` that renders annotation nodes
/// and captures mouse input for creating new annotations.
struct AnnotationCanvasView: NSViewRepresentable {
    let image: CGImage
    let nodes: [AnnotationNode]
    let tool: AnnotationToolType
    let color: CGColor
    let lineWidth: CGFloat
    var onNodeCreated: ((AnnotationNode) -> Void)?
    var onTextRequested: ((CGPoint) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AnnotationCanvasNSView {
        let view = AnnotationCanvasNSView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: AnnotationCanvasNSView, context: Context) {
        nsView.image = image
        nsView.nodes = nodes
        nsView.currentTool = tool
        nsView.currentColor = color
        nsView.currentLineWidth = lineWidth
        nsView.onNodeCreated = onNodeCreated
        nsView.onTextRequested = onTextRequested
        nsView.invalidateRenderedPreview()
        nsView.needsDisplay = true
    }

    final class Coordinator: NSObject {}
}

// MARK: - AnnotationCanvasNSView

final class AnnotationCanvasNSView: NSView {
    var image: CGImage?
    var nodes: [AnnotationNode] = []
    var currentTool: AnnotationToolType = .rect
    var currentColor: CGColor = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
    var currentLineWidth: CGFloat = 3.0
    var onNodeCreated: ((AnnotationNode) -> Void)?
    var onTextRequested: ((CGPoint) -> Void)?
    weak var coordinator: AnnotationCanvasView.Coordinator?

    // Drawing state
    private var imageDisplayRect: CGRect = .zero
    private var isDrawing = false
    private var dragStartPoint: CGPoint = .zero
    private var dragCurrentPoints: [CGPoint] = []
    private var dragCurrentRect: CGRect = .zero
    private var renderedPreview: CGImage?

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let bounds = self.bounds

        // Background
        context.setFillColor(CGColor(gray: 0.12, alpha: 1))
        context.fill(bounds)

        // Render existing nodes through AnnotationCore so preview and export match.
        if let image = image {
            let displayImage = previewImage(for: image) ?? image
            imageDisplayRect = aspectFitRect(
                imageSize: CGSize(width: displayImage.width, height: displayImage.height),
                in: bounds
            )
            context.draw(displayImage, in: imageDisplayRect)
        } else {
            imageDisplayRect = bounds
        }

        // Draw in-progress annotation preview
        if isDrawing {
            drawPreview(in: context)
        }
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard imageDisplayRect.contains(point) else { return }
        isDrawing = true
        dragStartPoint = point
        dragCurrentPoints = [normalizedPoint(point)]
        dragCurrentRect = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDrawing else { return }
        let point = convert(event.locationInWindow, from: nil)
        let norm = normalizedPoint(point)

        switch currentTool {
        case .pen:
            dragCurrentPoints.append(norm)
        case .arrow:
            dragCurrentPoints = [normalizedPoint(dragStartPoint), norm]
        case .rect, .highlight, .blur, .crop:
            let a = normalizedPoint(dragStartPoint)
            let b = norm
            dragCurrentRect = CGRect(
                x: min(a.x, b.x), y: min(a.y, b.y),
                width: abs(b.x - a.x), height: abs(b.y - a.y)
            )
        case .text:
            dragCurrentPoints = [norm]
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isDrawing else { return }
        isDrawing = false
        defer { needsDisplay = true }

        let point = convert(event.locationInWindow, from: nil)
        let norm = normalizedPoint(point)
        if currentTool == .text {
            onTextRequested?(norm)
        } else if let node = createNode(at: norm) {
            onNodeCreated?(node)
        }
    }

    // MARK: - Node Creation

    private func createNode(at endPoint: CGPoint) -> AnnotationNode? {
        let startPoint = normalizedPoint(dragStartPoint)

        switch currentTool {
        case .pen:
            let pts = dragCurrentPoints
            return AnnotationNode(
                tool: .pen, color: currentColor,
                lineWidth: currentLineWidth, points: pts
            )

        case .arrow:
            return AnnotationNode(
                tool: .arrow, color: currentColor,
                lineWidth: currentLineWidth, points: [startPoint, endPoint]
            )

        case .rect:
            let r = normalizedRect(from: startPoint, to: endPoint)
            return AnnotationNode(
                tool: .rect, color: currentColor,
                lineWidth: currentLineWidth, normalizedRect: r
            )

        case .highlight:
            let r = normalizedRect(from: startPoint, to: endPoint)
            return AnnotationNode(
                tool: .highlight, color: currentColor,
                lineWidth: currentLineWidth, opacity: 0.3, normalizedRect: r
            )

        case .blur:
            let r = normalizedRect(from: startPoint, to: endPoint)
            return AnnotationNode(
                tool: .blur, lineWidth: currentLineWidth,
                normalizedRect: r
            )

        case .crop:
            let r = normalizedRect(from: startPoint, to: endPoint)
            return AnnotationNode(
                tool: .crop, lineWidth: currentLineWidth,
                normalizedRect: r
            )

        case .text:
            return nil
        }
    }

    // MARK: - Drawing Helpers

    private func drawPreview(in context: CGContext) {
        context.saveGState()
        context.setStrokeColor(currentColor)
        context.setLineWidth(previewLineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch currentTool {
        case .pen:
            guard dragCurrentPoints.count >= 2 else { break }
            context.beginPath()
            context.move(to: viewPoint(from: dragCurrentPoints[0]))
            for i in 1..<dragCurrentPoints.count {
                context.addLine(to: viewPoint(from: dragCurrentPoints[i]))
            }
            context.strokePath()

        case .arrow:
            guard dragCurrentPoints.count >= 2 else { break }
            let p0 = viewPoint(from: dragCurrentPoints[0])
            let p1 = viewPoint(from: dragCurrentPoints[1])
            context.move(to: p0)
            context.addLine(to: p1)
            context.strokePath()
            drawArrowhead(at: p1, from: p0, in: context)

        case .rect, .highlight, .blur, .crop:
            guard dragCurrentRect != .zero else { break }
            let r = viewRect(from: dragCurrentRect)
            if currentTool == .highlight {
                context.setFillColor(currentColor.copy(alpha: 0.3) ?? currentColor)
                context.fill(r)
            } else if currentTool == .blur {
                context.setFillColor(CGColor(gray: 0.5, alpha: 0.2))
                context.fill(r)
            }
            context.stroke(r)

        case .text:
            break
        }

        context.restoreGState()
    }

    private func drawArrowhead(at tip: CGPoint, from base: CGPoint, in context: CGContext) {
        let angle = atan2(tip.y - base.y, tip.x - base.x)
        let len = previewLineWidth * 5
        let spread: CGFloat = .pi / 7

        let p1 = CGPoint(x: tip.x - len * cos(angle - spread), y: tip.y - len * sin(angle - spread))
        let p2 = CGPoint(x: tip.x - len * cos(angle + spread), y: tip.y - len * sin(angle + spread))

        context.move(to: tip)
        context.addLine(to: p1)
        context.move(to: tip)
        context.addLine(to: p2)
        context.strokePath()
    }

    // MARK: - Coordinate Conversions

    private func normalizedPoint(_ viewCoord: CGPoint) -> CGPoint {
        guard imageDisplayRect.width > 0, imageDisplayRect.height > 0 else { return .zero }
        return CGPoint(
            x: min(max((viewCoord.x - imageDisplayRect.origin.x) / imageDisplayRect.width, 0), 1),
            y: min(max((viewCoord.y - imageDisplayRect.origin.y) / imageDisplayRect.height, 0), 1)
        )
    }

    private func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        let a = normalizedPoint(start)
        let b = normalizedPoint(end)
        return CGRect(
            x: min(a.x, b.x), y: min(a.y, b.y),
            width: abs(b.x - a.x), height: abs(b.y - a.y)
        )
    }

    private func viewPoint(from normalized: CGPoint) -> CGPoint {
        CGPoint(
            x: imageDisplayRect.origin.x + normalized.x * imageDisplayRect.width,
            y: imageDisplayRect.origin.y + normalized.y * imageDisplayRect.height
        )
    }

    private func viewRect(from normalized: CGRect) -> CGRect {
        let o = viewPoint(from: normalized.origin)
        return CGRect(
            x: o.x, y: o.y,
            width: normalized.width * imageDisplayRect.width,
            height: normalized.height * imageDisplayRect.height
        )
    }

    private func aspectFitRect(imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        return CGRect(
            x: bounds.midX - w / 2,
            y: bounds.midY - h / 2,
            width: w, height: h
        )
    }

    func invalidateRenderedPreview() {
        renderedPreview = nil
    }

    override func setFrameSize(_ newSize: NSSize) {
        if frame.size != newSize {
            invalidateRenderedPreview()
        }
        super.setFrameSize(newSize)
    }

    private var previewLineWidth: CGFloat {
        guard let image, image.width > 0 else { return currentLineWidth }
        let scale = imageDisplayRect.width / CGFloat(image.width)
        return max(currentLineWidth * scale, 0.5)
    }

    private func previewImage(for image: CGImage) -> CGImage? {
        if nodes.isEmpty { return image }
        if let renderedPreview { return renderedPreview }

        var document = AnnotationDocument(baseImage: image)
        document.nodes = nodes
        let backingScale = window?.backingScaleFactor ?? 2
        let maximumDimension = max(bounds.width, bounds.height) * backingScale
        renderedPreview = try? Renderer().render(
            document,
            maximumDimension: maximumDimension
        )
        return renderedPreview
    }
}
