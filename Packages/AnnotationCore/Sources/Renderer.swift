import CoreGraphics
import Foundation
import SharedKit

/// 标注渲染器——将标注文档合成到背景图片上。
///
/// 使用 Core Graphics 进行矢量渲染。导出默认保持原始分辨率；调用方可为预览
/// 显式提供最大边长，以减少交互时的内存和 CPU 开销。
public struct Renderer: Sendable {
    private let logger = Logger(category: "annotation.renderer")

    public init() {}

    /// 渲染标注文档。
    ///
    /// 将 `document.nodes` 中的所有标注渲染到 `document.baseImage` 上，
    /// 返回合成后的 CGImage。
    ///
    /// - Parameters:
    ///   - document: 标注文档
    ///   - maximumDimension: 预览最大边长；为 `nil` 时保持原始分辨率
    /// - Returns: 带有标注的合成图片
    /// - Throws: `AnnotationError.renderFailed` 当渲染失败时
    public func render(
        _ document: AnnotationDocument,
        maximumDimension: CGFloat? = nil
    ) throws -> CGImage {
        let baseImage = document.baseImage
        let imageSize = CGSize(width: baseImage.width, height: baseImage.height)

        let workingImage: CGImage
        let workingSize: CGSize
        if let maximumDimension,
           maximumDimension > 0,
           max(imageSize.width, imageSize.height) > maximumDimension {
            guard let previewImage = downsample(baseImage, maxDimension: maximumDimension) else {
                throw AnnotationError.renderFailed(reason: "预览图降采样失败")
            }
            workingImage = previewImage
            workingSize = CGSize(width: previewImage.width, height: previewImage.height)
        } else {
            workingImage = baseImage
            workingSize = imageSize
        }
        let styleScale = workingSize.width / max(imageSize.width, 1)

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
                renderNode(
                    node,
                    in: context,
                    imageSize: workingSize,
                    styleScale: styleScale
                )
            }
        }

        for node in drawingNodes {
            autoreleasepool {
                renderNode(
                    node,
                    in: context,
                    imageSize: workingSize,
                    styleScale: styleScale
                )
            }
        }

        guard let result = context.makeImage() else {
            throw AnnotationError.renderFailed(reason: "CGContext.makeImage() 返回 nil")
        }

        logger.metric("annotation.render.nodeCount", value: Double(document.nodes.count), unit: "nodes")
        return result
    }

    /// 根据节点类型分派到对应工具进行渲染。
    private func renderNode(
        _ node: AnnotationNode,
        in context: CGContext,
        imageSize: CGSize,
        styleScale: CGFloat
    ) {
        var scaledNode = node
        scaledNode.lineWidth = max(node.lineWidth * styleScale, 0.5)
        scaledNode.cornerRadius = node.cornerRadius * styleScale
        scaledNode.fontSize = max(node.fontSize * styleScale, 1)

        switch scaledNode.tool {
        case .arrow:
            ArrowTool().render(node: scaledNode, in: context, imageSize: imageSize)
        case .rect:
            RectTool().render(node: scaledNode, in: context, imageSize: imageSize)
        case .text:
            TextTool().render(node: scaledNode, in: context, imageSize: imageSize)
        case .pen:
            PenTool().render(node: scaledNode, in: context, imageSize: imageSize)
        case .highlight:
            HighlightTool().render(node: scaledNode, in: context, imageSize: imageSize)
        case .blur:
            BlurTool().render(node: scaledNode, in: context, imageSize: imageSize, renderScale: styleScale)
        case .crop:
            // 裁剪操作在此不执行，由上层调用 CropTool.crop() 处理
            logger.warning("裁剪节点应在文档级处理，而非渲染时处理: \(scaledNode.id)")
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
