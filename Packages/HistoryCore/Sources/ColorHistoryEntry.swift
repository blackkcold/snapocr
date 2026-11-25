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

    /// Stable identifier used for list identity and removal.
    public let id: UUID
    /// The sampled sRGB color as 8-bit components.
    public let color: SampledColor
    /// When the color was sampled; sorting and retention use this value.
    public let timestamp: Date
    /// The picker that produced the sample.
    public let source: Source

    /// Creates a color history entry.
    ///
    /// - Parameters:
    ///   - id: Stable identifier; defaults to a new UUID.
    ///   - color: The sampled sRGB color.
    ///   - timestamp: Sampling time; defaults to now.
    ///   - source: The picker that produced the sample.
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

    /// The `#RRGGBB` representation of the sample, ignoring alpha.
    public var hexString: String { color.hexString }
    /// The `rgb(r, g, b)` representation of the sample, ignoring alpha.
    public var rgbString: String { color.rgbString }
}
