import CoreGraphics
import Foundation

/// 标注节点，使用归一化坐标 (0-1) 实现分辨率无关。
///
/// 所有坐标值均为相对于图片宽高的比例，确保标注在不同分辨率下保持一致。
/// 例如：
/// - `normalizedRect` 的 origin 和 size 均在 [0, 1] 范围内
/// - `points` 中的每个 CGPoint 的 x 和 y 也在 [0, 1] 范围内
public struct AnnotationNode: Sendable, Identifiable {

    /// 唯一标识符
    public let id: UUID

    /// 标注工具类型
    public var tool: AnnotationToolType

    /// 标注颜色，nil 表示使用工具默认颜色
    public var color: CGColor?

    /// 线条宽度（以图片实际像素为单位）
    public var lineWidth: CGFloat

    /// 不透明度 (0.0 - 1.0)，默认 1.0
    public var opacity: CGFloat

    /// 控制点数组，使用归一化坐标
    public var points: [CGPoint]

    /// 文本内容（仅 text 工具有效）
    public var text: String?

    /// 标注区域，使用归一化坐标
    public var normalizedRect: CGRect

    /// 创建时间戳
    public let timestamp: Date

    /// 创建一个新的标注节点。
    ///
    /// - Parameters:
    ///   - id: 唯一标识符，默认自动生成
    ///   - tool: 标注工具类型
    ///   - color: 标注颜色
    ///   - lineWidth: 线条宽度
    ///   - opacity: 不透明度 (0.0 - 1.0)
    ///   - points: 归一化坐标点数组
    ///   - text: 文本内容
    ///   - normalizedRect: 归一化矩形区域
    public init(
        id: UUID = UUID(),
        tool: AnnotationToolType,
        color: CGColor? = nil,
        lineWidth: CGFloat = 2.0,
        opacity: CGFloat = 1.0,
        points: [CGPoint] = [],
        text: String? = nil,
        normalizedRect: CGRect = .zero
    ) {
        self.id = id
        self.tool = tool
        self.color = color
        self.lineWidth = lineWidth
        self.opacity = max(0.0, min(1.0, opacity))
        self.points = points
        self.text = text
        self.normalizedRect = normalizedRect
        self.timestamp = Date()
    }
}
