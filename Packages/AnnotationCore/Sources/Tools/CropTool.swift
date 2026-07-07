import CoreGraphics
import Foundation
import SharedKit

/// 裁剪工具——根据标注区域裁剪图片。
///
/// 使用 `points` 的前两个点或 `normalizedRect` 定义裁剪区域（归一化坐标）。
/// 裁剪是文档级操作，调用后会替换 `baseImage`。
public struct CropTool: Sendable {
    private let logger = Logger(category: "annotation.crop")

    public init() {}

    /// 对图片执行裁剪操作。
    ///
    /// - Parameters:
    ///   - node: 标注节点，定义裁剪区域
    ///   - image: 要裁剪的图片
    /// - Returns: 裁剪后的新图片
    /// - Throws: `AnnotationError.invalidNode` 当裁剪区域无效时
    public func crop(node: AnnotationNode, from image: CGImage) throws -> CGImage {
        let rect: CGRect
        if node.normalizedRect != .zero {
            rect = denormalize(rect: node.normalizedRect, to: image)
        } else if node.points.count >= 2 {
            let p1 = denormalize(point: node.points[0], to: image)
            let p2 = denormalize(point: node.points[1], to: image)
            rect = CGRect(
                x: min(p1.x, p2.x),
                y: min(p1.y, p2.y),
                width: abs(p2.x - p1.x),
                height: abs(p2.y - p1.y)
            )
        } else {
            logger.error("裁剪工具需要至少 2 个点或有效的 normalizedRect")
            throw AnnotationError.invalidNode
        }

        guard rect.width > 0, rect.height > 0 else {
            logger.error("裁剪矩形无效: \(rect)")
            throw AnnotationError.invalidNode
        }

        // 确保裁剪区域在图片范围内
        let clampedRect = rect.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard clampedRect.width > 0, clampedRect.height > 0 else {
            logger.error("裁剪区域与图片无交集")
            throw AnnotationError.invalidNode
        }

        guard let cropped = image.cropping(to: clampedRect) else {
            logger.error("CGImage cropping 失败")
            throw AnnotationError.renderFailed(reason: "裁剪操作失败")
        }

        return cropped
    }

    private func denormalize(point: CGPoint, to image: CGImage) -> CGPoint {
        CGPoint(x: point.x * CGFloat(image.width), y: point.y * CGFloat(image.height))
    }

    private func denormalize(rect: CGRect, to image: CGImage) -> CGRect {
        CGRect(
            x: rect.origin.x * CGFloat(image.width),
            y: rect.origin.y * CGFloat(image.height),
            width: rect.size.width * CGFloat(image.width),
            height: rect.size.height * CGFloat(image.height)
        )
    }
}
