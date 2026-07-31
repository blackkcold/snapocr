import CoreGraphics
import CoreText
import Foundation
import SharedKit

/// 文本标注工具——在截图上添加文字。
///
/// 使用 `points[0]` 作为文本起始位置（归一化坐标），`text` 属性为显示内容。
/// Text styling is stored directly on `AnnotationNode` so it remains editable.
public struct TextTool: Sendable {
    private let logger = Logger(category: "annotation.text")

    public init() {}

    /// Returns the tight rendered size, including the tool's visual padding.
    public func suggestedSize(for node: AnnotationNode) -> CGSize {
        guard let text = node.text, !text.isEmpty else { return .zero }
        let attributes = textAttributes(for: node)
        let attributedString = NSAttributedString(string: text, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(attributedString)
        var fittedRange = CFRange()
        let measured = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: attributedString.length),
            nil,
            CGSize(width: 100_000, height: 100_000),
            &fittedRange
        )

        return CGSize(
            width: ceil(measured.width * node.textHorizontalScale) + 8,
            height: ceil(measured.height) + 8
        )
    }

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
        let fontSize = node.fontSize

        context.saveGState()
        defer { context.restoreGState() }

        if let color = node.color {
            context.setFillColor(color)
        }
        context.setAlpha(node.opacity)
        context.setTextDrawingMode(.fill)

        let attributes = textAttributes(for: node)
        let attributedString = NSAttributedString(string: text, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(attributedString)
        let suggestedSize = suggestedSize(for: node)
        let textRect = node.normalizedRect == .zero
            ? CGRect(
                x: position.x,
                y: position.y,
                width: max(suggestedSize.width, fontSize * 2),
                height: max(suggestedSize.height, fontSize * 1.3)
            )
            : denormalize(rect: node.normalizedRect, to: imageSize)

        if let fillColor = node.fillColor {
            context.setFillColor(fillColor)
            context.fill(textRect)
        }

        let horizontalScale = max(node.textHorizontalScale, 0.1)
        context.translateBy(x: textRect.minX, y: textRect.minY)
        context.scaleBy(x: horizontalScale, y: 1)
        let insetRect = CGRect(
            x: 4 / horizontalScale,
            y: 4,
            width: max((textRect.width - 8) / horizontalScale, 1),
            height: max(textRect.height - 8, 1)
        )
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: attributedString.length),
            CGPath(rect: insetRect, transform: nil),
            nil
        )
        CTFrameDraw(frame, context)
    }

    private func textAttributes(for node: AnnotationNode) -> [NSAttributedString.Key: Any] {
        var alignment: CTTextAlignment = switch node.textAlignment {
        case .leading: .left
        case .center: .center
        case .trailing: .right
        }
        let paragraphStyle = withUnsafePointer(to: &alignment) { pointer in
            CTParagraphStyleCreate([
                CTParagraphStyleSetting(
                    spec: .alignment,
                    valueSize: MemoryLayout<CTTextAlignment>.size,
                    value: pointer
                )
            ], 1)
        }
        return [
            .font: CTFontCreateWithName(node.fontName as CFString, node.fontSize, nil) as CTFont,
            .foregroundColor: node.color ?? CGColor(gray: 1.0, alpha: 1.0),
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraphStyle,
        ]
    }

    private func denormalize(point: CGPoint, to size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: point.y * size.height)
    }

    private func denormalize(rect: CGRect, to size: CGSize) -> CGRect {
        CGRect(
            x: rect.origin.x * size.width,
            y: rect.origin.y * size.height,
            width: rect.width * size.width,
            height: rect.height * size.height
        )
    }
}
