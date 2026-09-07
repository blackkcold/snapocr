import AnnotationCore
import AppKit
import OCRCore
import SharedKit
import SwiftUI

// MARK: - EditableAnnotationCanvasNSView Selection & Coordinates

extension EditableAnnotationCanvasNSView {
    func drawSelection(in context: CGContext) {
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

    var selectedNode: AnnotationNode? {
        guard let selectedNodeID else { return nil }
        return nodes.first { $0.id == selectedNodeID }
    }

    func hitNode(at point: CGPoint) -> AnnotationNode? {
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

    func normalizedBounds(for node: AnnotationNode) -> CGRect {
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

    func resizeHandle(at point: CGPoint, for node: AnnotationNode) -> ResizeHandle? {
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

    func contentHandlePoint(_ handle: ResizeHandle, for node: AnnotationNode) -> CGPoint {
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

    func resizedBounds(_ bounds: CGRect, handle: ResizeHandle, point: CGPoint) -> CGRect {
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

    func scaledPoints(_ points: [CGPoint], from old: CGRect, to new: CGRect) -> [CGPoint] {
        guard old.width > 0, old.height > 0 else { return points }
        return points.map { point in
            CGPoint(
                x: new.minX + ((point.x - old.minX) / old.width) * new.width,
                y: new.minY + ((point.y - old.minY) / old.height) * new.height
            )
        }
    }

    func nudgeSelection(keyCode: UInt16, multiplier: CGFloat) {
        guard var node = selectedNode, let image else { return }
        let deltaX = multiplier / CGFloat(max(image.width, 1))
        let deltaY = multiplier / CGFloat(max(image.height, 1))
        let offset: CGPoint = switch keyCode {
        case 123: CGPoint(x: -deltaX, y: 0)
        case 124: CGPoint(x: deltaX, y: 0)
        case 125: CGPoint(x: 0, y: -deltaY)
        default: CGPoint(x: 0, y: deltaY)
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
        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        let lengthSquared = deltaX * deltaX + deltaY * deltaY
        guard lengthSquared > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let parameter = min(max(((point.x - start.x) * deltaX + (point.y - start.y) * deltaY) / lengthSquared, 0), 1)
        let projection = CGPoint(x: start.x + parameter * deltaX, y: start.y + parameter * deltaY)
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
        layoutTextEntry()
    }

    func previewImage(for image: CGImage) -> CGImage? {
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

    func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(spanning: normalizedPoint(start), and: normalizedPoint(end))
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
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    func clampedViewPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, imageDisplayRect.minX), imageDisplayRect.maxX),
            y: min(max(point.y, imageDisplayRect.minY), imageDisplayRect.maxY)
        )
    }

    func aspectFitRect(imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}
