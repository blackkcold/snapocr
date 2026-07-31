import CoreGraphics
import Foundation

/// 标注文档，管理标注状态、撤销/重做栈。
///
/// 撤销栈深度上限为 100（依据设计文档 §2.2 架构完整性核查）。
/// 所有坐标使用归一化值 (0-1)。
public struct AnnotationDocument: Sendable {

    /// 背景底图
    public private(set) var baseImage: CGImage

    /// 当前标注节点列表
    public var nodes: [AnnotationNode]

    /// 撤销栈，每次记录底图和节点的完整快照
    private var undoStack: [Snapshot]

    /// 重做栈，每次记录底图和节点的完整快照
    private var redoStack: [Snapshot]

    /// 撤销栈最大深度
    public let maxUndoDepth: Int

    private struct Snapshot: Sendable {
        let baseImage: CGImage
        let nodes: [AnnotationNode]
    }

    /// 创建一个新的标注文档。
    ///
    /// - Parameters:
    ///   - baseImage: 背景底图
    ///   - maxUndoDepth: 撤销栈最大深度，默认 100
    public init(baseImage: CGImage, maxUndoDepth: Int = 100) {
        self.baseImage = baseImage
        self.nodes = []
        self.undoStack = []
        self.redoStack = []
        self.maxUndoDepth = maxUndoDepth
    }

    /// 是否可以执行撤销操作
    public var canUndo: Bool { !undoStack.isEmpty }

    /// 是否可以执行重做操作
    public var canRedo: Bool { !redoStack.isEmpty }

    // MARK: - Node Management

    /// 将当前节点状态压入撤销栈（在修改之前调用）。
    public mutating func pushUndoState() {
        undoStack.append(snapshot)
        if undoStack.count > maxUndoDepth {
            undoStack.removeFirst(undoStack.count - maxUndoDepth)
        }
        redoStack.removeAll()
    }

    /// 添加标注节点。
    ///
    /// 自动将当前状态保存到撤销栈。
    /// - Parameter node: 要添加的标注节点
    public mutating func addNode(_ node: AnnotationNode) {
        pushUndoState()
        nodes.append(node)
    }

    /// 移除标注节点。
    ///
    /// 自动将当前状态保存到撤销栈。
    /// - Parameter id: 要移除的节点 ID
    public mutating func removeNode(by id: UUID) {
        guard nodes.contains(where: { $0.id == id }) else { return }
        pushUndoState()
        nodes.removeAll { $0.id == id }
    }

    /// 更新指定标注节点。
    ///
    /// 自动将当前状态保存到撤销栈。
    /// - Parameter node: 更新后的节点
    public mutating func updateNode(_ node: AnnotationNode) {
        guard let index = nodes.firstIndex(where: { $0.id == node.id }) else { return }
        pushUndoState()
        nodes[index] = node
    }

    /// Moves a node one step forward or backward in the drawing order.
    public mutating func moveNode(by id: UUID, offset: Int) {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else { return }
        let destination = min(max(index + offset, 0), nodes.count - 1)
        guard destination != index else { return }
        pushUndoState()
        let node = nodes.remove(at: index)
        nodes.insert(node, at: destination)
    }

    /// 清空所有标注节点。
    ///
    /// 自动将当前状态保存到撤销栈。
    public mutating func clearAllNodes() {
        guard !nodes.isEmpty else { return }
        pushUndoState()
        nodes.removeAll()
    }

    /// Replaces the base image and node list as one undoable operation.
    public mutating func replaceContent(baseImage: CGImage, nodes: [AnnotationNode]) {
        pushUndoState()
        self.baseImage = baseImage
        self.nodes = nodes
    }

    // MARK: - Undo / Redo

    /// 撤销上一步操作。
    ///
    /// - Throws: `AnnotationError.undoStackEmpty` 当撤销栈为空时。
    public mutating func undo() throws {
        guard !undoStack.isEmpty else {
            throw AnnotationError.undoStackEmpty
        }
        redoStack.append(snapshot)
        restore(undoStack.removeLast())
    }

    /// 重做被撤销的操作。
    ///
    /// - Throws: `AnnotationError.redoStackEmpty` 当重做栈为空时。
    public mutating func redo() throws {
        guard !redoStack.isEmpty else {
            throw AnnotationError.redoStackEmpty
        }
        undoStack.append(snapshot)
        if undoStack.count > maxUndoDepth {
            undoStack.removeFirst(undoStack.count - maxUndoDepth)
        }
        restore(redoStack.removeLast())
    }

    private var snapshot: Snapshot {
        Snapshot(baseImage: baseImage, nodes: nodes)
    }

    private mutating func restore(_ snapshot: Snapshot) {
        baseImage = snapshot.baseImage
        nodes = snapshot.nodes
    }

    // MARK: - Normalized Coordinate Helpers

    /// 将归一化坐标转换为图片实际像素坐标。
    ///
    /// - Parameter normalizedPoint: 归一化点 (x, y 均在 [0, 1])
    /// - Returns: 图片上的实际像素坐标
    public func denormalize(point: CGPoint) -> CGPoint {
        CGPoint(
            x: point.x * CGFloat(baseImage.width),
            y: point.y * CGFloat(baseImage.height)
        )
    }

    /// 将归一化矩形转换为图片实际像素矩形。
    ///
    /// - Parameter normalizedRect: 归一化矩形
    /// - Returns: 图片上的实际像素矩形
    public func denormalize(rect: CGRect) -> CGRect {
        CGRect(
            x: rect.origin.x * CGFloat(baseImage.width),
            y: rect.origin.y * CGFloat(baseImage.height),
            width: rect.size.width * CGFloat(baseImage.width),
            height: rect.size.height * CGFloat(baseImage.height)
        )
    }

    /// 将图片实际像素坐标转换为归一化坐标。
    ///
    /// - Parameter pixelPoint: 图片像素坐标
    /// - Returns: 归一化点
    public func normalize(point: CGPoint) -> CGPoint {
        CGPoint(
            x: point.x / CGFloat(baseImage.width),
            y: point.y / CGFloat(baseImage.height)
        )
    }
}
