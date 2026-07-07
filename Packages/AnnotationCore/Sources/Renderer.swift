import CoreGraphics
import Foundation
import SharedKit

/// 标注渲染器——将标注文档合成到背景图片上。
///
/// 使用 Core Graphics 进行矢量渲染，支持大图内存优化：
/// - 渲染时使用 `autoreleasepool` 逐帧释放临时对象
/// - 对于超大图片（> 4096px 任意边），先降采样再渲染
public struct Renderer: Sendable {
    private let logger = Logger(category: "annotation.renderer")

    /// 大图阈值：任意边超过此值即视为大图
    private static let largeImageThreshold: CGFloat = 4096

    public init() {}

    /// 渲染标注文档。
    ///
    /// 将 `document.nodes` 中的所有标注渲染到 `document.baseImage` 上，
    /// 返回合成后的 CGImage。
    ///
    /// - Parameter document: 标注文档
    /// - Returns: 带有标注的合成图片
    /// - Throws: `AnnotationError.renderFailed` 当渲染失败时
    public func render(_ document: AnnotationDocument) throws -> CGImage {
        let baseImage = document.baseImage
        let imageSize = CGSize(width: baseImage.width, height: baseImage.height)

        // 大图降采样检查
        let workingImage: CGImage
        let workingSize: CGSize
        if baseImage.width > Int(Self.largeImageThreshold) || baseImage.height > Int(Self.largeImageThreshold) {
            logger.info("检测到大图 (\(baseImage.width)x\(baseImage.height))，进行降采样处理")
            guard let downsampled = downsample(baseImage, maxDimension: Self.largeImageThreshold) else {
                throw AnnotationError.renderFailed(reason: "大图降采样失败")
            }
            workingImage = downsampled
            workingSize = CGSize(width: downsampled.width, height: downsampled.height)
        } else {
            workingImage = baseImage
            workingSize = imageSize
        }

        // 创建位图上下文
        guard let context = CGContext(
            data: nil,
            width: Int(workingSize.width),
            height: Int(workingSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            throw AnnotationError.renderFailed(reason: "无法创建 CGContext")
        }

        // 1. 绘制背景图片
        context.draw(workingImage, in: CGRect(origin: .zero, size: workingSize))

        // 2. 分离 blur/crop 节点和普通绘制节点
        //    blur/crop 需要先处理（它们影响底图），然后绘制其他标注
        let blurAndCropNodes = document.nodes.filter { $0.tool == .blur || $0.tool == .crop }
        let drawingNodes = document.nodes.filter { $0.tool != .blur && $0.tool != .crop }

        // 使用 autoreleasepool 管理内存
        for node in blurAndCropNodes {
            autoreleasepool {
                renderNode(node, in: context, imageSize: workingSize, document: document)
            }
        }

        for node in drawingNodes {
            autoreleasepool {
                renderNode(node, in: context, imageSize: workingSize, document: document)
            }
        }

        guard let result = context.makeImage() else {
            throw AnnotationError.renderFailed(reason: "CGContext.makeImage() 返回 nil")
        }

        logger.metric("annotation.render.nodeCount", value: Double(document.nodes.count), unit: "nodes")
        return result
    }

    /// 根据节点类型分派到对应工具进行渲染。
    private func renderNode(_ node: AnnotationNode, in context: CGContext, imageSize: CGSize, document: AnnotationDocument) {
        switch node.tool {
        case .arrow:
            ArrowTool().render(node: node, in: context, imageSize: imageSize)
        case .rect:
            RectTool().render(node: node, in: context, imageSize: imageSize)
        case .text:
            TextTool().render(node: node, in: context, imageSize: imageSize)
        case .pen:
            PenTool().render(node: node, in: context, imageSize: imageSize)
        case .highlight:
            HighlightTool().render(node: node, in: context, imageSize: imageSize)
        case .blur:
            BlurTool().render(node: node, in: context, imageSize: imageSize)
        case .crop:
            // 裁剪操作在此不执行，由上层调用 CropTool.crop() 处理
            logger.warning("裁剪节点应在文档级处理，而非渲染时处理: \(node.id)")
        }
    }

    /// 将大图降采样到安全尺寸以控制内存。
    private func downsample(_ image: CGImage, maxDimension: CGFloat) -> CGImage? {
        let scale: CGFloat
        if CGFloat(image.width) > CGFloat(image.height) {
            scale = maxDimension / CGFloat(image.width)
        } else {
            scale = maxDimension / CGFloat(image.height)
        }

        let newWidth = Int(CGFloat(image.width) * scale)
        let newHeight = Int(CGFloat(image.height) * scale)

        guard let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage()
    }
}
