import CoreGraphics
import Foundation
import SharedKit

/// 箭头标注工具——绘制从起点到终点的带箭头线段。
///
/// 使用 `points` 中的前两个点：第一个为起点，第二个为终点（归一化坐标）。
/// 箭头大小根据 `lineWidth` 自动缩放。
public struct ArrowTool: Sendable {
    private let logger = Logger(category: "annotation.arrow")

    public init() {}

    /// 在图形上下文中渲染箭头标注。
    ///
    /// - Parameters:
    ///   - node: 标注节点，须包含至少 2 个点
    ///   - context: 目标绘图上下文
    ///   - imageSize: 背景图片的像素尺寸
    public func render(node: AnnotationNode, in context: CGContext, imageSize: CGSize) {
        guard node.points.count >= 2 else {
            logger.warning("箭头工具需要至少 2 个点，当前只有 \(node.points.count) 个")
            return
        }

        let start = denormalize(point: node.points[0], to: imageSize)
        let end = denormalize(point: node.points[1], to: imageSize)

        context.saveGState()
        defer { context.restoreGState() }

        applyStyle(node: node, to: context)

        // 绘制主线
        context.beginPath()
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()

        // 绘制箭头
        drawArrowhead(from: start, to: end, in: context, node: node)
    }

    /// 在终点处绘制箭头三角形。
    private func drawArrowhead(from start: CGPoint, to end: CGPoint, in context: CGContext, node: AnnotationNode) {
        let arrowLength: CGFloat = node.lineWidth * 5.0
        let arrowAngle: CGFloat = .pi / 6

        let dx = end.x - start.x
        let dy = end.y - start.y
        let lineLength = hypot(dx, dy)
        guard lineLength > 0 else { return }

        let unitX = dx / lineLength
        let unitY = dy / lineLength

        let tip = end
        let left = CGPoint(
            x: tip.x - arrowLength * (unitX * cos(arrowAngle) + unitY * sin(arrowAngle)),
            y: tip.y - arrowLength * (unitY * cos(arrowAngle) - unitX * sin(arrowAngle))
        )
        let right = CGPoint(
            x: tip.x - arrowLength * (unitX * cos(arrowAngle) - unitY * sin(arrowAngle)),
            y: tip.y - arrowLength * (unitY * cos(arrowAngle) + unitX * sin(arrowAngle))
        )

        context.beginPath()
        context.move(to: tip)
        context.addLine(to: left)
        switch node.arrowStyle {
        case .filled:
            context.addLine(to: right)
            context.closePath()
            context.fillPath()
        case .open:
            context.move(to: tip)
            context.addLine(to: right)
            context.strokePath()
        case .line:
            context.addLine(to: right)
            context.strokePath()
        }
    }

    /// 应用颜色、线宽、透明度等样式到上下文。
    private func applyStyle(node: AnnotationNode, to context: CGContext) {
        if let color = node.color {
            context.setStrokeColor(color)
            context.setFillColor(color)
        }
        context.setLineWidth(node.lineWidth)
        context.setAlpha(node.opacity)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        switch node.strokeStyle {
        case .solid:
            context.setLineDash(phase: 0, lengths: [])
        case .dashed:
            context.setLineDash(phase: 0, lengths: [node.lineWidth * 4, node.lineWidth * 2])
        case .dotted:
            context.setLineDash(phase: 0, lengths: [0, node.lineWidth * 2.5])
        }
    }

    /// 将归一化坐标转换为图片像素坐标。
    private func denormalize(point: CGPoint, to size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: point.y * size.height)
    }
}
