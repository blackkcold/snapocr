import AnnotationCore
import AppKit
import Foundation

// MARK: - EditorViewModel Node Operations

extension EditorViewModel {
    /// Duplicates the selected node with a small offset so the copy is visible.
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

    /// Moves the selected node up or down in the z-order.
    public func moveSelectedNodeInLayer(by offset: Int) {
        guard let selectedNodeID, var doc = document else { return }
        doc.moveNode(by: selectedNodeID, offset: offset)
        document = doc
        markChanged()
    }

    /// Nudges the selected node by a normalized delta, clamped to the canvas.
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
}
