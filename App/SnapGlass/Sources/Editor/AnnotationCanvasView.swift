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
    weak var coordinator: AnnotationCanvasView.Coordinator?

    // Drawing state
    private var imageDisplayRect: CGRect = .zero
    private var isDrawing = false
    private var dragStartPoint: CGPoint = .zero
    private var dragCurrentPoints: [CGPoint] = []
    private var dragCurrentRect: CGRect = .zero

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let bounds = self.bounds

        // Background
        context.setFillColor(CGColor(gray: 0.12, alpha: 1))
        context.fill(bounds)

        // Draw image centered with aspect-fit
        if let image = image {
            imageDisplayRect = aspectFitRect(
                imageSize: CGSize(width: image.width, height: image.height),
                in: bounds
            )
            context.draw(image, in: imageDisplayRect)
        } else {
            imageDisplayRect = bounds
        }

        // Draw existing annotation nodes
        for node in nodes {
            drawNode(node, in: context)
        }

        // Draw in-progress annotation preview
        if isDrawing {
            drawPreview(in: context)
        }
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
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
        let node = createNode(at: norm)
        onNodeCreated?(node)
    }

    // MARK: - Node Creation

    private func createNode(at endPoint: CGPoint) -> AnnotationNode {
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
            return AnnotationNode(
                tool: .text, color: currentColor,
                lineWidth: currentLineWidth, points: [endPoint], text: "Text"
            )
        }
    }

    // MARK: - Drawing Helpers

    private func drawNode(_ node: AnnotationNode, in context: CGContext) {
        context.saveGState()

        let clr = node.color ?? CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.setStrokeColor(clr)
        context.setLineWidth(node.lineWidth)
        context.setAlpha(node.opacity)

        switch node.tool {
        case .arrow:
            guard node.points.count >= 2 else { break }
            let p0 = viewPoint(from: node.points[0])
            let p1 = viewPoint(from: node.points[1])
            context.move(to: p0)
            context.addLine(to: p1)
            context.strokePath()
            drawArrowhead(at: p1, from: p0, in: context)

        case .rect:
            let r = viewRect(from: node.normalizedRect)
            context.stroke(r)

        case .pen:
            guard node.points.count >= 2 else { break }
            context.beginPath()
            context.move(to: viewPoint(from: node.points[0]))
            for i in 1..<node.points.count {
                context.addLine(to: viewPoint(from: node.points[i]))
            }
            context.strokePath()

        case .highlight:
            let r = viewRect(from: node.normalizedRect)
            context.setFillColor(clr.copy(alpha: 0.25)!)
            context.fill(r)

        case .blur:
            let r = viewRect(from: node.normalizedRect)
            context.setFillColor(CGColor(gray: 0.5, alpha: 0.3))
            context.fill(r)
            context.stroke(r)

        case .crop:
            let r = viewRect(from: node.normalizedRect)
            let full = imageDisplayRect
            // Dim areas outside crop region
            context.setFillColor(CGColor(gray: 0, alpha: 0.55))
            context.fill(CGRect(x: full.minX, y: r.maxY, width: full.width, height: full.maxY - r.maxY))
            context.fill(CGRect(x: full.minX, y: full.minY, width: full.width, height: r.minY - full.minY))
            context.fill(CGRect(x: full.minX, y: r.minY, width: r.minX - full.minX, height: r.height))
            context.fill(CGRect(x: r.maxX, y: r.minY, width: full.maxX - r.maxX, height: r.height))
            context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.setLineWidth(1)
            context.stroke(r)

        case .text:
            guard let pt = node.points.first else { break }
            let p = viewPoint(from: pt)
            let nsColor = NSColor(cgColor: clr) ?? .red
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: nsColor,
                .font: NSFont.systemFont(ofSize: 14)
            ]
            (node.text ?? "Text").draw(at: p, withAttributes: attrs)
        }

        context.restoreGState()
    }

    private func drawPreview(in context: CGContext) {
        context.saveGState()
        context.setStrokeColor(currentColor)
        context.setLineWidth(currentLineWidth)
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
                context.setFillColor(currentColor.copy(alpha: 0.25)!)
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
        let len: CGFloat = 10
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
            x: (viewCoord.x - imageDisplayRect.origin.x) / imageDisplayRect.width,
            y: (viewCoord.y - imageDisplayRect.origin.y) / imageDisplayRect.height
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
}
