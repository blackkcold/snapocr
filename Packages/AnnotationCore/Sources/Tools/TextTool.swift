import CoreGraphics
import CoreText
import Foundation
import SharedKit

/// 文本标注工具——在截图上添加文字。
///
/// 使用 `points[0]` 作为文本起始位置（归一化坐标），`text` 属性为显示内容。
/// 文本大小根据 `lineWidth` 缩放，默认字号为 `lineWidth * 8`。
public struct TextTool: Sendable {
    private let logger = Logger(category: "annotation.text")

    public init() {}

    /// 在图形上下文中渲染文本标注。
    ///
    /// - Parameters:
    ///   - node: 标注节点，须包含非空 `text` 和至少 1 个点
    ///   - context: 目标绘图上下文
    ///   - imageSize: 背景图片的像素尺寸
    public func render(node: AnnotationNode, in context: CGContext, imageSize: CGSize) {
        guard let text = node.text, !text.isEmpty else {
            logger.warning("文本工具需要非空文本内容")
            return
        }

        guard let point = node.points.first else {
            logger.warning("文本工具需要至少 1 个点作为位置")
            return
        }

        let position = denormalize(point: point, to: imageSize)
        let fontSize = node.lineWidth * 8.0

        context.saveGState()
        defer { context.restoreGState() }

        if let color = node.color {
            context.setFillColor(color)
        }
        context.setAlpha(node.opacity)
        context.setTextDrawingMode(.fill)

        // 使用 CoreText 绘制以获得更好的文本渲染
        let attributes: [NSAttributedString.Key: Any] = [
            .font: CTFontCreateWithName("Helvetica" as CFString, fontSize, nil) as CTFont,
            .foregroundColor: node.color ?? CGColor(gray: 1.0, alpha: 1.0),
        ]

        let attributedString = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributedString)

        context.textPosition = position
        CTLineDraw(line, context)
    }

    private func denormalize(point: CGPoint, to size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: point.y * size.height)
    }
}
