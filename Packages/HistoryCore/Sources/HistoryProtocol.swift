import Foundation

/// 历史数据来源类型
///
/// 标识一次截图/OCR 捕获的触发途径。
public enum HistorySourceType: String, Sendable, Codable {
    /// 通过截图功能触发
    case screenshot
    /// 从剪贴板读取
    case clipboard
    /// 从文件导入
    case fileImport
    /// 通过 URL Scheme 触发
    case urlScheme
    /// 通过 Shortcuts 触发
    case shortcut
}

/// 历史记录存取协议
///
/// 定义历史记录的增删改查、搜索和导出能力。
/// 所有方法均为 `async throws`，由 `HistoryActor` 实现线程安全。
public protocol HistoryProtocol: Sendable {
    /// 保存历史条目
    ///
    /// 条目会被加密后持久化到磁盘。
    /// 如果存储数量超过上限，会自动触发清理策略。
    ///
    /// - Parameter entry: 要保存的历史条目
    func save(_ entry: HistoryEntry) async throws

    /// 加载指定历史条目
    ///
    /// 从磁盘解密并反序列化条目数据。
    ///
    /// - Parameter id: 条目唯一标识符
    /// - Returns: 历史条目，若不存在则返回 `nil`
    func load(id: UUID) async throws -> HistoryEntry?

    /// 搜索历史条目
    ///
    /// 在已缓存的条目中执行不区分大小写的文本搜索。
    ///
    /// - Parameter query: 搜索关键词
    /// - Returns: 匹配的条目列表
    func search(query: String) async throws -> [HistoryEntry]

    /// 删除指定历史条目
    ///
    /// 同时从内存缓存和磁盘中移除条目及其关联的图片和缩略图文件。
    ///
    /// - Parameter id: 要删除的条目标识符
    func delete(id: UUID) async throws

    /// 清空所有历史记录
    ///
    /// 移除所有内存缓存条目，删除磁盘上的所有加密文件和缩略图。
    func clear() async throws

    /// 获取最近的历史条目
    ///
    /// 按时间戳降序排列，返回指定数量的条目。
    ///
    /// - Parameter limit: 最大返回数量
    /// - Returns: 最近的条目列表
    func recent(limit: Int) async throws -> [HistoryEntry]

    /// 导出指定条目的数据
    ///
    /// 支持多种导出格式，可选择对敏感文本进行脱敏处理。
    ///
    /// - Parameters:
    ///   - ids: 要导出的条目 ID 列表
    ///   - format: 导出格式
    /// - Returns: 导出数据
    func export(ids: [UUID], format: HistoryExportFormat) async throws -> Data

    /// 获取历史记录统计快照
    ///
    /// 返回条目总数、收藏数、截图模式分布、磁盘占用与平均置信度，
    /// 供设置界面绘制存储用量图表。
    ///
    /// - Returns: 当前历史记录的统计快照
    func stats() async throws -> HistoryStats
}

/// 历史记录统计快照
///
/// 用于设置界面展示存储用量与条目分布的可视化信息。
public struct HistoryStats: Sendable, Equatable {
    /// 条目总数
    public let totalCount: Int
    /// 收藏条目数
    public let favouriteCount: Int
    /// 各截图模式的条目数
    public let captureModeDistribution: [String: Int]
    /// 磁盘占用总字节数（entries + images + thumbs）
    public let totalSizeBytes: UInt64
    /// 平均 OCR 置信度（0–1），无条目时为 0
    public let averageConfidence: Float

    public init(
        totalCount: Int,
        favouriteCount: Int,
        captureModeDistribution: [String: Int],
        totalSizeBytes: UInt64,
        averageConfidence: Float
    ) {
        self.totalCount = totalCount
        self.favouriteCount = favouriteCount
        self.captureModeDistribution = captureModeDistribution
        self.totalSizeBytes = totalSizeBytes
        self.averageConfidence = averageConfidence
    }
}

/// 历史导出格式
public enum HistoryExportFormat: Sendable {
    /// JSON 格式，包含完整元数据
    case json
    /// CSV 格式，仅包含关键字段
    case csv
    /// 纯文本格式，仅包含识别文本
    case plainText
}

/// 历史模块错误类型
public enum HistoryError: Error, Sendable {
    /// 存储空间已满
    case storageFull(current: Int, max: Int)
    /// 指定条目不存在
    case entryNotFound(id: UUID)
    /// 加密失败
    case encryptionFailed(reason: String)
    /// 解密失败
    case decryptionFailed(reason: String)
    /// 文件读写错误
    case fileIOError(path: String)
}
