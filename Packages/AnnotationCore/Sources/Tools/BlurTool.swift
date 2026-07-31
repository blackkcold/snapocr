import CoreGraphics
import CoreImage
import Foundation
import SharedKit

/// 模糊标注工具——对指定区域应用高斯模糊、像素化或马赛克。
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
    public func render(node: AnnotationNode, in context: CGContext, imageSize: CGSize, renderScale: CGFloat = 1) {
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

        // CGImage 裁剪坐标原点在左上角；标注和 CGContext 使用左下角。
        let cropRect = CGRect(
            x: rect.minX,
            y: imageSize.height - rect.maxY,
            width: rect.width,
            height: rect.height
        ).integral.intersection(CGRect(origin: .zero, size: imageSize))
        guard !cropRect.isEmpty, let cropped = currentImage.cropping(to: cropRect) else {
            logger.error("无法裁剪到模糊区域: \(rect)")
            return
        }

        guard let blurred = applyEffect(to: cropped, node: node, renderScale: renderScale) else {
            logger.error("模糊效果失败: \(node.blurMode.rawValue)")
            return
        }

        // 将模糊后的图像绘制回上下文
        context.saveGState()
        defer { context.restoreGState() }
        context.setAlpha(node.opacity)
        context.draw(blurred, in: rect)
    }

    private func applyEffect(to image: CGImage, node: AnnotationNode, renderScale: CGFloat) -> CGImage? {
        let ciImage = CIImage(cgImage: image)
        let strength = max(0, min(1, node.blurIntensity))
        let scale = max(renderScale, 0.01)
        let output: CIImage?

        switch node.blurMode {
        case .gaussian:
            let radius = (2 + strength * 48) * scale
            output = ciImage
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                .cropped(to: ciImage.extent)
        case .pixelate:
            let blockSize = (3 + strength * 45) * scale
            output = ciImage
                .applyingFilter("CIPixellate", parameters: [
                    kCIInputScaleKey: max(blockSize, 1),
                    kCIInputCenterKey: CIVector(x: ciImage.extent.midX, y: ciImage.extent.midY),
                ])
                .cropped(to: ciImage.extent)
        case .mosaic:
            let cellSize = (4 + strength * 42) * scale
            output = ciImage
                .applyingFilter("CICrystallize", parameters: [
                    kCIInputRadiusKey: max(cellSize, 1),
                    kCIInputCenterKey: CIVector(x: ciImage.extent.midX, y: ciImage.extent.midY),
                ])
                .cropped(to: ciImage.extent)
        }

        guard let output else { return nil }
        let ciContext = CIContext(options: [.useSoftwareRenderer: false])
        return ciContext.createCGImage(output, from: ciImage.extent)
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
