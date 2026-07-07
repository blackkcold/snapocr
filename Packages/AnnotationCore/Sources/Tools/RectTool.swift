import CoreGraphics
import Foundation
import SharedKit

/// 矩形标注工具——绘制矩形框。
///
/// 使用 `points` 中的前两个点作为对角顶点（归一化坐标），
/// 或使用 `normalizedRect` 定义矩形区域。
public struct RectTool: Sendable {
    private let logger = Logger(category: "annotation.rect")

    public init() {}

    /// 在图形上下文中渲染矩形标注。
    ///
    /// - Parameters:
    ///   - node: 标注节点
    ///   - context: 目标绘图上下文
    ///   - imageSize: 背景图片的像素尺寸
    public func render(node: AnnotationNode, in context: CGContext, imageSize: CGSize) {
        let rect: CGRect
        if node.normalizedRect != .zero {
            rect = denormalize(rect: node.normalizedRect, to: imageSize)
        } else if node.points.count >= 2 {
            let p1 = denormalize(point: node.points[0], to: imageSize)
            let p2 = denormalize(point: node.points[1], to: imageSize)
            rect = CGRect(
                x: min(p1.x, p2.x),
                y: min(p1.y, p2.y),
                width: abs(p2.x - p1.x),
                height: abs(p2.y - p1.y)
            )
        } else {
            logger.warning("矩形工具需要至少 2 个点或有效的 normalizedRect")
            return
        }

        context.saveGState()
        defer { context.restoreGState() }

        if let color = node.color {
            context.setStrokeColor(color)
        }
        context.setLineWidth(node.lineWidth)
        context.setAlpha(node.opacity)

        context.stroke(rect)
    }

    private func denormalize(point: CGPoint, to size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: point.y * size.height)
    }

    private func denormalize(rect: CGRect, to size: CGSize) -> CGRect {
        CGRect(
            x: rect.origin.x * size.width,
            y: rect.origin.y * size.height,
            width: rect.size.width * size.width,
            height: rect.size.height * size.height
        )
    }
}
