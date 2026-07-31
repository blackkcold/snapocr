import Foundation

/// 数据类别，用于区分不同类型数据的清理策略
public enum DataCategory: String, Sendable, Codable, CaseIterable {
    /// 截图原图（加密存储）
    case image
    /// OCR 文本（加密存储）
    case text
    /// 缩略图（不加密）
    case thumbnail
}

/// 内存压力级别
public enum MemoryPressureLevel: Sendable, Comparable {
    /// 正常，无限制
    case normal
    /// 中等，缩减缓存
    case medium
    /// 高，强制降级
    case high
    /// 临界，释放所有非活跃资源
    case critical

    public static func < (lhs: MemoryPressureLevel, rhs: MemoryPressureLevel) -> Bool {
        let order: [MemoryPressureLevel: Int] = [.normal: 0, .medium: 1, .high: 2, .critical: 3]
        return order[lhs, default: 0] < order[rhs, default: 0]
    }
}

/// 历史数据自动清理策略
///
/// 实现分层清理逻辑，根据数据类别应用不同的保留期限和数量上限。
/// 同时集成内存压力监控，在高内存压力下主动缩减内存缓存。
///
/// ## 清理策略（来自设计文档 7.3 节）
///
/// | 数据类别 | 时间限制 | 数量限制 | 加密 |
/// |---------|---------|---------|------|
/// | image   | 7 天    | 100     | 是   |
/// | text    | 30 天   | 500     | 是   |
/// | thumbnail | 90 天 | 1000    | 否   |
///
/// ## 内存压力响应（来自设计文档 附录 E）
///
/// | 级别       | 阈值        | 响应措施 |
/// |-----------|------------|----------|
/// | normal    | < 150MB    | 无限制 |
/// | medium    | 150–200MB  | 内存缓存缩减至 50 条 |
/// | high      | > 200MB    | 缩减至 20 条，清理非活跃条目 |
/// | critical  | > 300MB    | 释放所有非收藏条目缓存 |
public struct CleanupPolicy: Sendable {

    // MARK: - 分层清理配置

    /// 各数据类别的保留天数
    private let retentionDays: [DataCategory: Int]

    /// 各数据类别的最大数量
    private let maxCount: [DataCategory: Int]

    /// 所有条目的数量上限（全局硬限制）
    public let maxEntries: Int

    /// 磁盘存储总大小上限（字节），默认 500MB
    public let maxTotalSizeBytes: UInt64

    // MARK: - 内存压力阈值

    /// 中等内存压力阈值（字节），默认 150MB
    public let mediumPressureThreshold: UInt64

    /// 高内存压力阈值（字节），默认 200MB
    public let highPressureThreshold: UInt64

    /// 临界内存压力阈值（字节），默认 300MB
    public let criticalPressureThreshold: UInt64

    // MARK: - 内存压力缓存限制

    /// 中等压力下的最大内存缓存条目数
    public let mediumCacheLimit: Int

    /// 高压力下的最大内存缓存条目数
    public let highCacheLimit: Int

    // MARK: - Initialization

    /// 创建清理策略
    ///
    /// - Parameters:
    ///   - maxEntries: 全局条目数量硬限制，默认 1000
    ///   - maxTotalSizeBytes: 磁盘总大小上限，默认 500MB
    ///   - retentionDays: 各数据类别的保留天数。默认: image 7天, text 30天, thumbnail 90天
    ///   - maxCount: 各数据类别的最大文件数。默认: image 100, text 500, thumbnail 1000
    ///   - mediumPressureThreshold: 中等压力阈值，默认 150MB
    ///   - highPressureThreshold: 高压力阈值，默认 200MB
    ///   - criticalPressureThreshold: 临界压力阈值，默认 300MB
    ///   - mediumCacheLimit: 中等压力缓存上限，默认 50
    ///   - highCacheLimit: 高压力缓存上限，默认 20
    public init(
        maxEntries: Int = 1000,
        maxTotalSizeBytes: UInt64 = 500 * 1024 * 1024,
        retentionDays: [DataCategory: Int] = [
            .image: 7,
            .text: 30,
            .thumbnail: 90,
        ],
        maxCount: [DataCategory: Int] = [
            .image: 100,
            .text: 500,
            .thumbnail: 1000,
        ],
        mediumPressureThreshold: UInt64 = 150 * 1024 * 1024,
        highPressureThreshold: UInt64 = 200 * 1024 * 1024,
        criticalPressureThreshold: UInt64 = 300 * 1024 * 1024,
        mediumCacheLimit: Int = 50,
        highCacheLimit: Int = 20
    ) {
        self.maxEntries = maxEntries
        self.maxTotalSizeBytes = maxTotalSizeBytes
        self.retentionDays = retentionDays
        self.maxCount = maxCount
        self.mediumPressureThreshold = mediumPressureThreshold
        self.highPressureThreshold = highPressureThreshold
        self.criticalPressureThreshold = criticalPressureThreshold
        self.mediumCacheLimit = mediumCacheLimit
        self.highCacheLimit = highCacheLimit
    }

    // MARK: - 数据类别查询

    /// 获取指定数据类别的保留天数
    ///
    /// - Parameter category: 数据类别
    /// - Returns: 保留天数
    public func retentionDays(for category: DataCategory) -> Int {
        retentionDays[category] ?? 7
    }

    /// 获取指定数据类别的最大文件数
    ///
    /// - Parameter category: 数据类别
    /// - Returns: 最大文件数
    public func maxCount(for category: DataCategory) -> Int {
        maxCount[category] ?? 100
    }

    // MARK: - 清理判断

    /// 判断条目是否应该被清理（基于时间）
    ///
    /// 检查条目的时间戳是否超过了对应数据类别的保留期限。
    ///
    /// - Parameters:
    ///   - entry: 要检查的历史条目
    ///   - category: 数据类别（默认 `.text`）
    /// - Returns: 如果条目已过期返回 `true`
    public func shouldEvict(_ entry: HistoryEntry, category: DataCategory = .text) -> Bool {
        let age = Date().timeIntervalSince(entry.timestamp)
        let ageDays = age / 86_400
        let limit = retentionDays(for: category)
        return ageDays > Double(limit)
    }

    /// 判断是否超过数量限制
    ///
    /// - Parameters:
    ///   - currentCount: 当前数量
    ///   - category: 数据类别
    /// - Returns: 如果超过限制返回 `true`
    public func isOverCount(_ currentCount: Int, category: DataCategory) -> Bool {
        currentCount > maxCount(for: category)
    }

    /// 获取需要清理的条目列表
    ///
    /// 综合时间和数量两个维度，返回最应该被清理的条目。
    /// 优先保留已收藏的条目。清理优先级: 过期 > 最旧 > 非收藏。
    ///
    /// - Parameters:
    ///   - entries: 所有条目的排序列表（按时间降序）
    ///   - category: 数据类别
    /// - Returns: 应被清理的条目数组
    public func entriesToEvict(
        _ entries: [HistoryEntry],
        category: DataCategory
    ) -> [HistoryEntry] {
        let limit = maxCount(for: category)
        let sorted = entries.sorted { $0.timestamp > $1.timestamp }
        let expired = sorted.filter {
            !$0.isFavourite && shouldEvict($0, category: category)
        }
        let expiredIDs = Set(expired.map(\.id))
        let survivors = sorted.filter { !expiredIDs.contains($0.id) }
        let overflow = max(0, survivors.count - limit)
        let oldestNonFavourites = survivors.reversed().filter { !$0.isFavourite }
        return expired + Array(oldestNonFavourites.prefix(overflow))
    }

    // MARK: - 内存压力响应

    /// 获取当前内存压力级别
    ///
    /// 通过 `task_info` 获取当前进程驻留内存大小，与阈值比较后返回对应级别。
    ///
    /// - Returns: 当前内存压力级别
    public func currentMemoryPressure() -> MemoryPressureLevel {
        let residentSize = Self.residentMemorySize()
        switch residentSize {
        case ..<mediumPressureThreshold:
            return .normal
        case ..<highPressureThreshold:
            return .medium
        case ..<criticalPressureThreshold:
            return .high
        default:
            return .critical
        }
    }

    /// 获取当前内存压力下的内存缓存条目上限
    ///
    /// - Returns: 缓存条目数上限，`nil` 表示无限制
    public func cacheLimit() -> Int? {
        switch currentMemoryPressure() {
        case .normal:
            return nil
        case .medium:
            return mediumCacheLimit
        case .high:
            return highCacheLimit
        case .critical:
            return 0
        }
    }

    /// 判断在指定内存压力下条目是否应从缓存中清除
    ///
    /// 临界压力时清除所有非收藏条目，较低压力时仅清除最旧的条目。
    ///
    /// - Parameters:
    ///   - entry: 要检查的条目
    ///   - entries: 当前所有缓存条目（按时间降序）
    /// - Returns: 如果应从缓存移除返回 `true`
    public func shouldEvictFromCache(
        _ entry: HistoryEntry,
        among entries: [HistoryEntry]
    ) -> Bool {
        let pressure = currentMemoryPressure()

        switch pressure {
        case .normal:
            return false
        case .critical:
            return !entry.isFavourite
        case .high:
            guard let limit = cacheLimit() else { return false }
            let sorted = entries.sorted { $0.timestamp > $1.timestamp }
            if let index = sorted.firstIndex(where: { $0.id == entry.id }), index >= limit {
                return !entry.isFavourite
            }
            return false
        case .medium:
            guard let limit = cacheLimit() else { return false }
            let sorted = entries.sorted { $0.timestamp > $1.timestamp }
            if let index = sorted.firstIndex(where: { $0.id == entry.id }), index >= limit {
                return true
            }
            return false
        }
    }

    // MARK: - 工具方法

    /// 获取当前进程驻留内存大小
    ///
    /// 使用 `task_info(MACH_TASK_BASIC_INFO)` 查询。
    ///
    /// - Returns: 驻留内存字节数，查询失败返回 0
    public static func residentMemorySize() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size
        ) / 4

        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS else { return 0 }
        return info.resident_size
    }
}
