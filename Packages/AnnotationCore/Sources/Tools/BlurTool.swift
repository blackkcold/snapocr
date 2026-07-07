import CoreGraphics
import CoreImage
import Foundation
import SharedKit

/// 模糊标注工具——对指定区域应用高斯模糊。
///
/// 用于遮盖敏感信息。使用 `points` 的前两个点或 `normalizedRect` 定义区域。
/// 模糊半径根据 `lineWidth` 缩放，默认 `lineWidth * 10`。
public struct BlurTool: Sendable {
    private let logger = Logger(category: "annotation.blur")

    public init() {}

    /// 在图形上下文中渲染模糊标注。
    ///
    /// 注意：此方法需要接收完整的图片上下文，因为它会对底图区域进行采样后模糊。
    ///
    /// - Parameters:
    ///   - node: 标注节点
    ///   - context: 目标绘图上下文（应包含已绘制的底图）
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
            logger.warning("模糊工具需要至少 2 个点或有效的 normalizedRect")
            return
        }

        guard rect.width > 0, rect.height > 0 else { return }

        // 从上下文中获取当前图像
        guard let currentImage = context.makeImage() else {
            logger.error("无法从上下文中获取当前图像", error: AnnotationError.renderFailed(reason: "makeImage failed"))
            return
        }

        // 裁剪到模糊区域
        guard let cropped = currentImage.cropping(to: rect) else {
            logger.error("无法裁剪到模糊区域: \(rect)")
            return
        }

        // 对裁剪区域应用高斯模糊
        let blurRadius = max(node.lineWidth * 10.0, 1.0)
        guard let blurred = applyGaussianBlur(to: cropped, radius: Float(blurRadius)) else {
            logger.error("高斯模糊失败")
            return
        }

        // 将模糊后的图像绘制回上下文
        context.saveGState()
        defer { context.restoreGState() }
        context.setAlpha(node.opacity)
        context.draw(blurred, in: rect)
    }

    /// 对 CGImage 应用高斯模糊滤镜。
    private func applyGaussianBlur(to image: CGImage, radius: Float) -> CGImage? {
        let ciImage = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)

        guard let output = filter.outputImage else { return nil }

        let context = CIContext(options: [.useSoftwareRenderer: false])
        return context.createCGImage(output, from: output.extent)
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
