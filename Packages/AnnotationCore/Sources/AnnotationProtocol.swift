import CoreGraphics
import Foundation
import SharedKit

/// 标注工具类型枚举。
///
/// 定义了所有支持的标注工具，用于标注节点的类型标识和渲染分派。
public enum AnnotationToolType: String, Sendable, CaseIterable {
    case arrow
    case rect
    case text
    case pen
    case highlight
    case blur
    case crop
}

/// 标注协议——定义标注文档的创建、操作、渲染接口。
///
/// 遵循面向协议设计原则，所有标注操作通过协议抽象，
/// 为未来的跨平台实现预留接口。
public protocol AnnotationProtocol: Sendable {

    /// 基于图片创建标注文档。
    ///
    /// - Parameter image: 背景底图
    /// - Returns: 新创建的标注文档
    func createDocument(from image: CGImage) -> AnnotationDocument

    /// 向文档中应用标注。
    ///
    /// - Parameters:
    ///   - tool: 标注工具类型
    ///   - document: 标注文档（inout）
    ///   - node: 标注节点
    /// - Throws: `AnnotationError.invalidNode` 当节点数据无效时
    func apply(_ tool: AnnotationToolType, to document: inout AnnotationDocument, node: AnnotationNode) throws

    /// 渲染标注文档为图片。
    ///
    /// - Parameter document: 标注文档
    /// - Returns: 渲染后的合成图片
    /// - Throws: `AnnotationError.renderFailed` 当渲染失败时
    func render(_ document: AnnotationDocument) throws -> CGImage

    /// 撤销上一次标注操作。
    ///
    /// - Parameter document: 标注文档（inout）
    /// - Throws: `AnnotationError.undoStackEmpty` 当无可撤销操作时
    func undo(_ document: inout AnnotationDocument) throws

    /// 重做被撤销的操作。
    ///
    /// - Parameter document: 标注文档（inout）
    /// - Throws: `AnnotationError.redoStackEmpty` 当无可重做操作时
    func redo(_ document: inout AnnotationDocument) throws
}

/// 标注错误类型。
public enum AnnotationError: Error, Sendable {
    /// 撤销栈为空
    case undoStackEmpty

    /// 重做栈为空
    case redoStackEmpty

    /// 渲染失败，附带原因描述
    case renderFailed(reason: String)

    /// 标注节点数据无效
    case invalidNode
}

/// 标注交互器——`AnnotationProtocol` 的默认实现。
///
/// 协调标注文档、渲染器和各个工具，提供统一的标注操作接口。
public struct AnnotationInteractor: AnnotationProtocol {
    private let renderer: Renderer
    private let logger = Logger(category: "annotation")

    /// 创建标注交互器。
    ///
    /// - Parameter renderer: 渲染器实例，默认使用 `Renderer()`
    public init(renderer: Renderer = Renderer()) {
        self.renderer = renderer
    }

    // MARK: - AnnotationProtocol

    public func createDocument(from image: CGImage) -> AnnotationDocument {
        logger.info("创建标注文档: \(image.width)x\(image.height)")
        return AnnotationDocument(baseImage: image, maxUndoDepth: 100)
    }

    public func apply(_ tool: AnnotationToolType, to document: inout AnnotationDocument, node: AnnotationNode) throws {
        // 验证节点类型与工具匹配
        guard node.tool == tool else {
            logger.error("节点工具类型 \(node.tool.rawValue) 与指定工具 \(tool.rawValue) 不匹配")
            throw AnnotationError.invalidNode
        }

        // 验证节点数据
        switch tool {
        case .arrow, .rect, .highlight, .blur:
            guard node.points.count >= 2 || node.normalizedRect != .zero else {
                logger.error("\(tool.rawValue) 工具需要至少 2 个点或有效的 normalizedRect")
                throw AnnotationError.invalidNode
            }
        case .text:
            guard let text = node.text, !text.isEmpty else {
                logger.error("text 工具需要非空文本内容")
                throw AnnotationError.invalidNode
            }
        case .pen:
            guard node.points.count >= 2 else {
                logger.error("pen 工具需要至少 2 个点")
                throw AnnotationError.invalidNode
            }
        case .crop:
            guard node.points.count >= 2 || node.normalizedRect != .zero else {
                logger.error("crop 工具需要至少 2 个点或有效的 normalizedRect")
                throw AnnotationError.invalidNode
            }
        }

        logger.debug("应用标注: \(tool.rawValue), id=\(node.id)")

        if tool == .crop {
            // 裁剪操作：替换底图
            let cropTool = CropTool()
            let croppedImage = try cropTool.crop(node: node, from: document.baseImage)
            var newDocument = AnnotationDocument(baseImage: croppedImage, maxUndoDepth: document.maxUndoDepth)
            // 保留裁剪前的节点（防止数据丢失）
            newDocument.nodes = document.nodes
            document = newDocument
        } else {
            document.addNode(node)
        }
    }

    public func render(_ document: AnnotationDocument) throws -> CGImage {
        logger.info("开始渲染: \(document.nodes.count) 个标注节点")
        return try renderer.render(document)
    }

    public func undo(_ document: inout AnnotationDocument) throws {
        logger.debug("执行撤销")
        try document.undo()
    }

    public func redo(_ document: inout AnnotationDocument) throws {
        logger.debug("执行重做")
        try document.redo()
    }
}

// MARK: - AnnotationError 扩展

extension AnnotationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .undoStackEmpty:
            return "没有可撤销的操作"
        case .redoStackEmpty:
            return "没有可重做的操作"
        case .renderFailed(let reason):
            return "渲染失败: \(reason)"
        case .invalidNode:
            return "标注节点数据无效"
        }
    }
}
