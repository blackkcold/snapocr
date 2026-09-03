import AnnotationCore
import AppKit
import OCRCore
import SharedKit
import SwiftUI

// MARK: - EditableAnnotationCanvasNSView Selection & Resize

extension EditableAnnotationCanvasNSView {
    func beginSelectionInteraction(at point: CGPoint, clickCount: Int) {
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
            ocrTextSelection = nil
            interaction = .none
            return
        }
        ocrTextSelection = nil
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

    func updateCreationPreview(to point: CGPoint) {
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

    func updateMove(to point: CGPoint) {
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

    func updateResize(
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

    func resizedTextNode(
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

    func proportionalBounds(_ oldBounds: CGRect, scale: CGFloat, handle: ResizeHandle) -> CGRect {
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

    func createNode(at endPoint: CGPoint) -> AnnotationNode? {
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
}
