import Foundation
import SharedKit

/// 一条取色历史记录。
///
/// 记录用户通过取色器复制过的颜色（区域截图或编辑器），随 `ColorHistoryStore`
/// 以 AES-GCM 单文件加密持久化。
public struct ColorHistoryEntry: Identifiable, Equatable, Sendable, Codable {
    /// 取色来源。
    public enum Source: String, Sendable, Codable {
        /// 区域截图 overlay 的单点取色。
        case area
        /// 标注编辑器的取色器（单点 / 区域 / Inspector 色块）。
        case editor
    }

    public let id: UUID
    public let color: SampledColor
    public let timestamp: Date
    public let source: Source

    public init(
        id: UUID = UUID(),
        color: SampledColor,
        timestamp: Date = Date(),
        source: Source
    ) {
        self.id = id
        self.color = color
        self.timestamp = timestamp
        self.source = source
    }

    public var hexString: String { color.hexString }
    public var rgbString: String { color.rgbString }
}
