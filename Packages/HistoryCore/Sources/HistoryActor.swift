import CoreGraphics
import Foundation
import ImageIO
import SharedKit
import UniformTypeIdentifiers

/// 历史记录存储与管理 Actor
///
/// 使用 actor 模型序列化所有历史记录的读写操作，确保 CLI 与 GUI 并发访问安全（R8）。
/// 实现 `HistoryProtocol` 中定义的全部接口，提供加密持久化、内存缓存、自动清理和导出功能。
///
/// ## 存储架构
///
/// ```
/// ~/Library/Application Support/SnapGlass/History/
/// ├── entries/     ← AES-GCM 加密的条目 JSON
/// ├── images/      ← AES-GCM 加密的截图原图
/// └── thumbs/      ← 未加密的 PNG 缩略图
/// ```
///
/// ## 并发安全 (R8, R14)
///
/// - Actor 序列化所有读写，消除 CLI/GUI 竞争
/// - `CryptoService` 为 struct + 同步方法，避免嵌套 actor 死锁
/// - 加解密操作在 actor 边界内顺序执行
public actor HistoryActor: HistoryProtocol {

    // MARK: - Storage paths

    let storageURL: URL
    let entriesDir: URL
    let imagesDir: URL
    let thumbsDir: URL
    let tempDir: URL

    // MARK: - State

    /// 内存缓存（热缓存，可被内存压力驱逐）
    var entries: [UUID: HistoryEntry] = [:]

    /// 磁盘快照缓存（权威磁盘状态，仅在磁盘写入/删除时失效）。
    ///
    /// 避免每次 `allPersistedEntries()` 都全量重读并解密所有 `.enc` 文件，
    /// 将历史操作从 O(n) 磁盘+解密降为 O(1) 内存合并。单进程内保持与磁盘一致；
    /// 跨进程（CLI）写入需重启进程后才会反映到本缓存。
    var diskCache: [UUID: HistoryEntry] = [:]

    /// 加密服务（struct，避免 actor 嵌套死锁 R14）
    let cryptoService: CryptoService

    /// 清理策略
    var cleanupPolicy: CleanupPolicy

    /// 日志记录器
    let logger = Logger(category: "history")

    /// 文本脱敏器
    let anonymizer = TextAnonymizer()

    /// 全局条目数量硬限制
    var maxEntries: Int

    // MARK: - Initialization

    /// 初始化历史存储 Actor
    ///
    /// 创建必要的目录结构，初始化加密服务，并从磁盘加载已有条目到内存缓存。
    ///
    /// - Throws: 当 CryptoService 初始化失败或目录创建失败时
    public init(
        cleanupPolicy: CleanupPolicy = CleanupPolicy(),
        baseURL: URL = URL.appSupportDirectory
    ) throws {
        self.storageURL = baseURL.appendingPathComponent("History").appendingPathComponent("v2")
        self.entriesDir = storageURL.appendingPathComponent("entries")
        self.imagesDir = storageURL.appendingPathComponent("images")
        self.thumbsDir = storageURL.appendingPathComponent("thumbs")
        self.tempDir = storageURL.appendingPathComponent("tmp")

        let keyURL = baseURL
            .appendingPathComponent("Security")
            .appendingPathComponent("history-v2.key")
        self.cryptoService = try CryptoService(keyURL: keyURL)
        self.cleanupPolicy = cleanupPolicy
        self.maxEntries = cleanupPolicy.maxEntries

        try entriesDir.ensureDirectoryExists()
        try imagesDir.ensureDirectoryExists()
        try thumbsDir.ensureDirectoryExists()
        try tempDir.ensureDirectoryExists()

        // 同步加载磁盘条目（在 init 中内联以避免 actor isolation 问题）
        var loaded: [UUID: HistoryEntry] = [:]
        if let files = try? FileManager.default.contentsOfDirectory(
            at: entriesDir, includingPropertiesForKeys: [.fileSizeKey]
        ) {
            let encFiles = files.filter { $0.pathExtension == "enc" }
            for file in encFiles {
                do {
                    let encryptedData = try Data(contentsOf: file)
                    let jsonData = try cryptoService.decrypt(encryptedData)
                    let entry = try JSONDecoder().decode(HistoryEntry.self, from: jsonData)
                    loaded[entry.id] = entry
                } catch {
                    logger.error("加载条目失败: \(file.lastPathComponent)", error: error)
                }
            }
        }
        self.entries = loaded
        self.diskCache = loaded
        logger.info("HistoryActor 初始化完成，已加载 \(entries.count) 条记录")
    }

    // MARK: - HistoryProtocol: Save

    // MARK: - HistoryProtocol: Load

    // MARK: - HistoryProtocol: Search

    // MARK: - HistoryProtocol: Delete

    // MARK: - HistoryProtocol: Clear

    // MARK: - HistoryProtocol: Recent

    // MARK: - HistoryProtocol: Export

    // MARK: - Additional public API

}

// MARK: - Shared singleton alias

extension HistoryActor {
    /// 共享实例，供 UI 层使用
    ///
    /// 初始化失败时返回 `nil` 而非崩溃，调用方应优雅降级。
    public static let shared: HistoryActor? = {
        try? HistoryActor(cleanupPolicy: configuredCleanupPolicy())
    }()

    /// 共享实例的显式 Result 版本，调用方可获取具体错误信息
    public static func sharedResult() -> Result<HistoryActor, any Error> {
        Result { try HistoryActor(cleanupPolicy: configuredCleanupPolicy()) }
    }

    static func configuredCleanupPolicy() -> CleanupPolicy {
        let defaults = UserDefaults.standard
        let retentionDays: Int
        if defaults.object(forKey: PreferenceKeys.historyRetentionDays) != nil {
            let configured = defaults.integer(forKey: PreferenceKeys.historyRetentionDays)
            retentionDays = configured == 0 ? Int.max : min(max(configured, 1), 3_650)
        } else {
            let legacyValue = defaults.string(forKey: PreferenceKeys.historyRetentionPolicy)
                ?? PreferenceDefaults.historyRetentionPolicy
            retentionDays = switch legacyValue {
            case "7days": 7
            case "90days": 90
            case "forever": Int.max
            default: 30
            }
        }

        let configuredMaxItems = defaults.object(forKey: PreferenceKeys.historyMaxItems) == nil
            ? PreferenceDefaults.historyMaxItems
            : defaults.integer(forKey: PreferenceKeys.historyMaxItems)
        let maxItems = min(max(configuredMaxItems, 10), 5_000)

        let configuredStorageSize = defaults.object(forKey: PreferenceKeys.historyStorageSize) == nil
            ? PreferenceDefaults.historyStorageSize
            : defaults.double(forKey: PreferenceKeys.historyStorageSize)
        let storageSizeGB = min(max(configuredStorageSize, 0.1), 10)
        let maxTotalSizeBytes = UInt64(storageSizeGB * 1024 * 1024 * 1024)

        return CleanupPolicy(
            maxEntries: maxItems,
            maxTotalSizeBytes: maxTotalSizeBytes,
            retentionDays: [
                .image: retentionDays,
                .text: retentionDays,
                .thumbnail: retentionDays,
            ],
            maxCount: [
                .image: maxItems,
                .text: maxItems,
                .thumbnail: maxItems,
            ]
        )
    }
}
