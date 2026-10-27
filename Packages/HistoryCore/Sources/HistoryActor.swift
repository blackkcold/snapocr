import CoreGraphics
import Foundation
import ImageIO
import SharedKit
import UniformTypeIdentifiers

/// 历史记录存储与管理 Actor
///
/// 使用 actor 模型序列化所有历史记录的读写操作，确保 CLI 与 GUI 并发访问安全（R8）。
/// 实现 `HistoryProtocol` 中定义的全部接口，提供加密持久化、内存缓存、
/// 自动清理和导出功能。
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

    /// 是否已把磁盘上的历史条目读入内存。
    ///
    /// 不在 `init` 中同步扫描：`HistoryActor.shared` 首次访问通常发生在主线程，
    /// 历史条目多时会在窗口打开前卡住 UI。改为首次真正的历史操作时由 actor
    /// 在后台执行，调用方异步等待。
    var hasLoadedFromDisk = false

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

        // 磁盘条目延迟到首次读取时加载，避免在 init 中阻塞调用线程。
        logger.info("HistoryActor 初始化完成，等待首次读取时加载磁盘条目")
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
    /// 全进程唯一的共享实例，供 UI 层使用。
    ///
    /// 历史记录的元数据、媒体文件与内存缓存必须只有一个所有者。若
    /// `shared` 与 `sharedResult()` 各自创建实例，陈旧实例会用编辑前的
    /// `imageRevision` 回写磁盘，导致「覆盖原记录」后无法还原原图。
    /// 初始化失败时不缓存失败结果，下次访问可重试。
    public static var shared: HistoryActor? {
        switch sharedResult() {
        case .success(let actor):
            return actor
        case .failure:
            return nil
        }
    }

    /// 共享实例的显式 Result 版本，调用方可获取具体错误信息。
    public static func sharedResult() -> Result<HistoryActor, any Error> {
        sharedProvider.instance()
    }

    /// 丢弃当前共享实例，下一次访问重新初始化。
    ///
    /// 仅在存储目录或密钥恢复后由「重试」路径调用，避免把永久性初始化
    /// 失败缓存成不可恢复状态。
    public static func resetSharedForRetry() {
        sharedProvider.reset()
    }

    private static var sharedProvider: HistorySharedProvider {
        HistorySharedProvider.shared
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

/// 线程安全的共享 actor 缓存。
///
/// 使用 `NSLock` 而非 actor，是为了让同步调用点（菜单栏、View 初始化）
/// 也能取得同一个实例。工厂注入让测试可以在临时目录上验证
/// 「同一进程只持有一个实例」这一不变量。
final class HistorySharedProvider: @unchecked Sendable {
    static let shared = HistorySharedProvider {
        try HistoryActor(cleanupPolicy: HistoryActor.configuredCleanupPolicy())
    }

    private let lock = NSLock()
    private let makeActor: @Sendable () throws -> HistoryActor
    private var cached: HistoryActor?

    init(makeActor: @escaping @Sendable () throws -> HistoryActor) {
        self.makeActor = makeActor
    }

    func instance() -> Result<HistoryActor, any Error> {
        lock.lock()
        defer { lock.unlock() }
        if let cached {
            return .success(cached)
        }
        do {
            let created = try makeActor()
            cached = created
            return .success(created)
        } catch {
            return .failure(error)
        }
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
    }
}
