import CoreGraphics
import Foundation
import SharedKit

/// 画笔工具——自由绘制路径。
///
/// 使用 `points` 数组中的所有点按顺序绘制平滑曲线（归一化坐标）。
/// 点数量少于 2 时不绘制。
public struct PenTool: Sendable {
    private let logger = Logger(category: "annotation.pen")

    public init() {}

    /// 在图形上下文中渲染画笔标注。
    ///
    /// - Parameters:
    ///   - node: 标注节点，包含绘制路径点
    ///   - context: 目标绘图上下文
    ///   - imageSize: 背景图片的像素尺寸
    public func render(node: AnnotationNode, in context: CGContext, imageSize: CGSize) {
        guard node.points.count >= 2 else {
            logger.debug("画笔工具需要至少 2 个点，当前只有 \(node.points.count) 个")
            return
        }

        let denormalized = node.points.map { denormalize(point: $0, to: imageSize) }

        context.saveGState()
        defer { context.restoreGState() }

        if let color = node.color {
            context.setStrokeColor(color)
        }
        context.setLineWidth(node.lineWidth)
        context.setAlpha(node.opacity)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        context.beginPath()
        context.move(to: denormalized[0])

        // 如果有足够多的点，使用二次贝塞尔平滑；否则直接连线
        if denormalized.count >= 3 {
            for i in 1 ..< denormalized.count - 1 {
                let mid = CGPoint(
                    x: (denormalized[i].x + denormalized[i + 1].x) / 2,
                    y: (denormalized[i].y + denormalized[i + 1].y) / 2
                )
                context.addQuadCurve(to: mid, control: denormalized[i])
            }
            // 连接到最后一个点
            context.addLine(to: denormalized[denormalized.count - 1])
        } else {
            context.addLine(to: denormalized[1])
        }

        context.strokePath()
    }

    private func denormalize(point: CGPoint, to size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: point.y * size.height)
    }
}
