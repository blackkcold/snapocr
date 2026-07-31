import CoreGraphics
import Foundation
import SharedKit

/// 高亮标注工具——以半透明色填充矩形区域。
///
/// 使用 `points` 的前两个点或 `normalizedRect` 定义区域（归一化坐标）。
/// 默认颜色为黄色，透明度为 0.3。
public struct HighlightTool: Sendable {
    private let logger = Logger(category: "annotation.highlight")

    public init() {}

    /// 在图形上下文中渲染高亮标注。
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
            logger.warning("高亮工具需要至少 2 个点或有效的 normalizedRect")
            return
        }

        guard rect.width > 0, rect.height > 0 else { return }

        context.saveGState()
        defer { context.restoreGState() }

        // 使用 multiply 混合模式模拟高亮效果
        context.setBlendMode(.multiply)

        let highlightColor = node.color ?? CGColor(red: 1.0, green: 1.0, blue: 0.0, alpha: 1.0)
        context.setFillColor(highlightColor)
        context.setAlpha(node.opacity)

        context.fill(rect)
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
