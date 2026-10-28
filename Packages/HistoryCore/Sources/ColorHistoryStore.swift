import Foundation
import SharedKit

/// 取色历史存储 Actor
///
/// 以单个 AES-GCM 加密文件（`History/v2/colors/colors.enc`）持久化取色记录，
/// 复用与 `HistoryActor` 相同的 `history-v2.key` 密钥。
///
/// ## 设计要点
///
/// - actor 序列化读写，与 `HistoryActor` 同级独立，互不嵌套调用（R14）
/// - 单文件整存整取：记录量上限默认 100 条，无分片必要
/// - 启动加载失败（文件损坏/解密失败）时丢弃旧数据并记录日志，不崩溃
/// - `.atomic` 写入避免断电/崩溃导致文件截断
public actor ColorHistoryStore {

    /// 共享实例，供 UI 层使用；初始化失败时返回 `nil`，调用方优雅降级。
    ///
    /// 失败不缓存：目录或密钥恢复后，下一次访问（或「重试」入口）可重新初始化。
    public static var shared: ColorHistoryStore? {
        ColorHistorySharedProvider.shared.instance()
    }

    /// 丢弃当前共享实例，下一次访问重新初始化。
    ///
    /// 与 `HistoryActor.resetSharedForRetry()` 同源：供历史窗口的「重试」使用，
    /// 避免把一次初始化失败缓存成不可恢复状态。
    public static func resetSharedForRetry() {
        ColorHistorySharedProvider.shared.reset()
    }

    private let fileURL: URL
    private let cryptoService: CryptoService
    private let logger = Logger(category: "colorHistory")
    private var entries: [ColorHistoryEntry] = []

    /// 初始化取色历史存储
    ///
    /// - Parameter baseURL: 存储根目录，默认应用支持目录；测试注入临时目录隔离。
    public init(baseURL: URL = .appSupportDirectory) throws {
        let colorsDir = baseURL
            .appendingPathComponent("History")
            .appendingPathComponent("v2")
            .appendingPathComponent("colors")
        try colorsDir.ensureDirectoryExists()
        self.fileURL = colorsDir.appendingPathComponent("colors.enc")
        let keyURL = baseURL
            .appendingPathComponent("Security")
            .appendingPathComponent("history-v2.key")
        self.cryptoService = try CryptoService(keyURL: keyURL)
        self.entries = Self.loadEntries(from: fileURL, using: cryptoService)
        logger.info("ColorHistoryStore 初始化完成，已加载 \(entries.count) 条记录")
    }

    // MARK: - Public API

    /// 记录一次取色。
    ///
    /// 相同 hex 的既有记录会被移除并连同新时间戳/来源置顶（去重移前）；
    /// 超出上限时从最旧开始淘汰。
    public func save(_ color: SampledColor, source: ColorHistoryEntry.Source) async throws {
        let maxItems = Self.configuredMaxItems()
        entries.removeAll { $0.color == color }
        entries.insert(ColorHistoryEntry(color: color, source: source), at: 0)
        if entries.count > maxItems {
            entries.removeLast(entries.count - maxItems)
        }
        try persist()
    }

    /// 按时间倒序返回最近 `limit` 条记录。
    public func recent(limit: Int) -> [ColorHistoryEntry] {
        guard limit > 0 else { return [] }
        return Array(entries.prefix(limit))
    }

    /// 当前记录总数。
    public func count() -> Int {
        entries.count
    }

    /// 删除单条记录。
    public func delete(id: UUID) throws {
        entries.removeAll { $0.id == id }
        try persist()
    }

    /// 清空全部记录（内存与磁盘同步）。
    public func clear() throws {
        entries.removeAll()
        try persist()
    }

    // MARK: - Private

    /// 加密并原子化持久化当前记录。
    private func persist() throws {
        do {
            let jsonData = try JSONEncoder().encode(entries)
            let encryptedData = try cryptoService.encrypt(jsonData)
            try encryptedData.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("取色历史持久化失败", error: error)
            throw HistoryError.encryptionFailed(reason: error.localizedDescription)
        }
    }

    /// 从磁盘加载记录；文件损坏或解密失败时丢弃并返回空数组（不崩溃）。
    private static func loadEntries(from fileURL: URL, using cryptoService: CryptoService) -> [ColorHistoryEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let encryptedData = try Data(contentsOf: fileURL)
            let jsonData = try cryptoService.decrypt(encryptedData)
            return try JSONDecoder().decode([ColorHistoryEntry].self, from: jsonData)
        } catch {
            Logger(category: "colorHistory").error("取色历史文件损坏，已丢弃旧数据: \(fileURL.lastPathComponent)", error: error)
            return []
        }
    }

    /// 读取实时上限偏好（每次 save 时求值，UI 修改即时生效）。
    private static func configuredMaxItems() -> Int {
        let defaults = UserDefaults.standard
        let configured = defaults.object(forKey: PreferenceKeys.colorHistoryMaxItems) == nil
            ? PreferenceDefaults.colorHistoryMaxItems
            : defaults.integer(forKey: PreferenceKeys.colorHistoryMaxItems)
        return min(max(configured, 10), 5_000)
    }
}

/// 线程安全的共享 actor 缓存。
///
/// 与 `HistorySharedProvider` 同构：用 `NSLock` 而非 actor，让同步调用点
/// （菜单栏、View 初始化）也能取得同一实例；初始化失败不缓存，下一次访问可重试。
private final class ColorHistorySharedProvider: @unchecked Sendable {
    static let shared = ColorHistorySharedProvider { try ColorHistoryStore() }

    private let lock = NSLock()
    private let makeStore: @Sendable () throws -> ColorHistoryStore
    private var cached: ColorHistoryStore?

    init(makeStore: @escaping @Sendable () throws -> ColorHistoryStore) {
        self.makeStore = makeStore
    }

    func instance() -> ColorHistoryStore? {
        lock.lock()
        defer { lock.unlock() }
        if let cached {
            return cached
        }
        guard let created = try? makeStore() else { return nil }
        cached = created
        return created
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
    }
}
