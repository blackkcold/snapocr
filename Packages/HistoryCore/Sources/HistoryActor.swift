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

    private let storageURL: URL
    private let entriesDir: URL
    private let imagesDir: URL
    private let thumbsDir: URL
    private let tempDir: URL

    // MARK: - State

    /// 内存缓存
    private var entries: [UUID: HistoryEntry] = [:]

    /// 加密服务（struct，避免 actor 嵌套死锁 R14）
    private let cryptoService: CryptoService

    /// 清理策略
    private let cleanupPolicy: CleanupPolicy

    /// 日志记录器
    private let logger = Logger(category: "history")

    /// 文本脱敏器
    private let anonymizer = TextAnonymizer()

    /// 全局条目数量硬限制
    private let maxEntries: Int

    // MARK: - Initialization

    /// 初始化历史存储 Actor
    ///
    /// 创建必要的目录结构，初始化加密服务，并从磁盘加载已有条目到内存缓存。
    ///
    /// - Throws: 当 CryptoService 初始化失败或目录创建失败时
    public init() throws {
        let base = URL.appSupportDirectory
        self.storageURL = base.appendingPathComponent("History")
        self.entriesDir = storageURL.appendingPathComponent("entries")
        self.imagesDir = storageURL.appendingPathComponent("images")
        self.thumbsDir = storageURL.appendingPathComponent("thumbs")
        self.tempDir = storageURL.appendingPathComponent("tmp")

        self.cryptoService = try CryptoService()
        self.cleanupPolicy = CleanupPolicy()
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
        logger.info("HistoryActor 初始化完成，已加载 \(entries.count) 条记录")
    }

    // MARK: - HistoryProtocol: Save

    public func save(_ entry: HistoryEntry) async throws {
        if entries.count >= maxEntries {
            try await evictOldest()
        }

        var mutableEntry = entry

        // 处理截图原图：复制到加密存储
        if let sourcePath = entry.imagePath,
           FileManager.default.fileExists(atPath: sourcePath.path) {
            do {
                let imageData = try Data(contentsOf: sourcePath)
                let encryptedImage = try cryptoService.encrypt(imageData)
                let destURL = imageFileURL(for: entry.id)
                try encryptedImage.write(to: destURL, options: .atomic)
                mutableEntry.imagePath = destURL
                logger.debug("截图已加密存储: \(entry.id)")
            } catch {
                logger.error("截图加密存储失败", error: error)
                throw HistoryError.encryptionFailed(reason: error.localizedDescription)
            }
        }

        // 处理缩略图：复制到非加密存储
        if let sourcePath = entry.thumbnailPath,
           FileManager.default.fileExists(atPath: sourcePath.path) {
            do {
                let thumbData = try Data(contentsOf: sourcePath)
                let destURL = thumbnailFileURL(for: entry.id)
                try thumbData.write(to: destURL, options: .atomic)
                mutableEntry.thumbnailPath = destURL
                logger.debug("缩略图已存储: \(entry.id)")
            } catch {
                logger.error("缩略图存储失败", error: error)
                throw HistoryError.fileIOError(path: sourcePath.path)
            }
        }

        // 加密持久化条目 JSON
        do {
            let jsonData = try JSONEncoder().encode(mutableEntry)
            let encryptedData = try cryptoService.encrypt(jsonData)
            let fileURL = entryFileURL(for: entry.id)
            try encryptedData.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("条目加密持久化失败", error: error)
            throw HistoryError.encryptionFailed(reason: error.localizedDescription)
        }

        entries[entry.id] = mutableEntry
        logger.info("历史条目已保存: \(entry.id)")

        // 检查并执行清理
        try await enforceCleanup()
    }

    /// Saves a captured image and its metadata into encrypted history storage.
    ///
    /// The method writes temporary PNG files into SnapGlass' private history temp
    /// directory, calls `save(_:)` so existing encryption/copy logic remains the
    /// single persistence path, then removes temporary files with `defer`.
    ///
    /// - Parameters:
    ///   - image: Captured screenshot image.
    ///   - textContent: OCR text to persist. Pass an empty string when full-text
    ///     persistence is disabled by privacy preferences.
    ///   - ocrConfidence: OCR confidence score.
    ///   - captureMode: Capture mode description stored in history.
    ///   - sourceType: Source type for the history entry.
    ///   - sourceAppName: Optional source application name.
    ///   - sourceWindowTitle: Optional source window title.
    public func saveCapture(
        image: CGImage,
        textContent: String,
        ocrConfidence: Float,
        captureMode: String,
        sourceType: HistorySourceType = .screenshot,
        sourceAppName: String? = nil,
        sourceWindowTitle: String? = nil
    ) async throws {
        try tempDir.ensureDirectoryExists()

        let tempID = UUID()
        let imageURL = tempDir.appendingPathComponent("\(tempID)-capture.png")
        let thumbnailURL = tempDir.appendingPathComponent("\(tempID)-thumb.png")

        defer {
            try? FileManager.default.removeItem(at: imageURL)
            try? FileManager.default.removeItem(at: thumbnailURL)
        }

        try Self.writePNG(image, to: imageURL)
        try Self.writeThumbnail(from: imageURL, to: thumbnailURL, maxPixelSize: 200)

        let entry = HistoryEntry(
            textContent: textContent,
            ocrConfidence: ocrConfidence,
            captureMode: captureMode,
            sourceType: sourceType,
            sourceAppName: sourceAppName,
            sourceWindowTitle: sourceWindowTitle,
            imagePath: imageURL,
            thumbnailPath: thumbnailURL
        )

        try await save(entry)
    }

    // MARK: - HistoryProtocol: Load

    public func load(id: UUID) async throws -> HistoryEntry? {
        // 先从内存缓存查找
        if let cached = entries[id] {
            return cached
        }

        // 从磁盘加载
        guard let entry = loadEntryFromDiskSync(id: id) else {
            return nil
        }

        // 检查内存压力后决定是否加入缓存
        if !cleanupPolicy.shouldEvictFromCache(entry, among: Array(entries.values)) {
            entries[id] = entry
        }

        return entry
    }

    // MARK: - HistoryProtocol: Search

    public func search(query: String) async throws -> [HistoryEntry] {
        let results = entries.values.filter { entry in
            entry.textContent.localizedCaseInsensitiveContains(query)
                || entry.tags.contains(where: { $0.localizedCaseInsensitiveContains(query) })
                || (entry.sourceAppName?.localizedCaseInsensitiveContains(query) ?? false)
                || (entry.sourceWindowTitle?.localizedCaseInsensitiveContains(query) ?? false)
        }
        return results.sorted { $0.timestamp > $1.timestamp }
    }

    // MARK: - HistoryProtocol: Delete

    public func delete(id: UUID) async throws {
        entries.removeValue(forKey: id)

        // 删除磁盘文件
        try? FileManager.default.removeItem(at: entryFileURL(for: id))
        try? FileManager.default.removeItem(at: imageFileURL(for: id))
        try? FileManager.default.removeItem(at: thumbnailFileURL(for: id))

        logger.info("历史条目已删除: \(id)")
    }

    // MARK: - HistoryProtocol: Clear

    public func clear() async throws {
        entries.removeAll()

        // 批量删除目录内容
        let removeContents: (URL) -> Void = { dir in
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil
            ) else { return }
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
        }

        removeContents(entriesDir)
        removeContents(imagesDir)
        removeContents(thumbsDir)

        logger.warning("所有历史记录已清空")
    }

    // MARK: - HistoryProtocol: Recent

    public func recent(limit: Int) async throws -> [HistoryEntry] {
        return entries.values
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - HistoryProtocol: Export

    public func export(ids: [UUID], format: HistoryExportFormat) async throws -> Data {
        let exportEntries: [HistoryEntry]
        if ids.isEmpty {
            exportEntries = entries.values.sorted { $0.timestamp > $1.timestamp }
        } else {
            exportEntries = ids.compactMap { entries[$0] }
            if exportEntries.isEmpty && !ids.isEmpty {
                throw HistoryError.entryNotFound(id: ids[0])
            }
        }

        let anonymizedEntries = anonymizer.anonymizeEntries(exportEntries, level: .partial)

        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(anonymizedEntries)

        case .csv:
            return Self.buildCSV(from: anonymizedEntries)

        case .plainText:
            let texts = anonymizedEntries.map { entry in
                "[\(Self.dateFormatter.string(from: entry.timestamp))] \(entry.textContent)"
            }
            return texts.joined(separator: "\n\n---\n\n").data(using: .utf8) ?? Data()
        }
    }

    // MARK: - Additional public API

    /// 获取所有内存缓存的条目
    ///
    /// 不触发磁盘读取，仅返回当前在内存中的条目。
    ///
    /// - Returns: 所有缓存条目数组
    public func allEntries() -> [HistoryEntry] {
        Array(entries.values)
    }

    /// 获取当前条目总数
    ///
    /// - Returns: 缓存中的条目数量
    public func count() -> Int {
        entries.count
    }

    /// 获取所有已收藏的条目
    ///
    /// - Returns: 已收藏条目数组，按时间戳降序
    public func favouriteEntries() -> [HistoryEntry] {
        entries.values
            .filter { $0.isFavourite }
            .sorted { $0.timestamp > $1.timestamp }
    }

    /// 获取指定 ID 条目的解密截图数据
    ///
    /// - Parameter id: 条目标识符
    /// - Returns: 解密的图片数据，若无则返回 `nil`
    public func imageData(for id: UUID) async throws -> Data? {
        let imageURL = imageFileURL(for: id)
        guard FileManager.default.fileExists(atPath: imageURL.path) else {
            return nil
        }
        do {
            let encryptedData = try Data(contentsOf: imageURL)
            return try cryptoService.decrypt(encryptedData)
        } catch {
            logger.error("截图解密失败: \(id)", error: error)
            throw HistoryError.decryptionFailed(reason: error.localizedDescription)
        }
    }

    /// 获取指定 ID 条目的缩略图数据
    ///
    /// - Parameter id: 条目标识符
    /// - Returns: 缩略图数据（未加密），若无则返回 `nil`
    public func thumbnailData(for id: UUID) async throws -> Data? {
        let thumbURL = thumbnailFileURL(for: id)
        guard FileManager.default.fileExists(atPath: thumbURL.path) else {
            return nil
        }
        do {
            return try Data(contentsOf: thumbURL)
        } catch {
            logger.error("缩略图读取失败: \(id)", error: error)
            throw HistoryError.fileIOError(path: thumbURL.path)
        }
    }

    /// 获取当前内存压力级别
    ///
    /// - Returns: 当前内存压力级别
    public func memoryPressureLevel() -> MemoryPressureLevel {
        cleanupPolicy.currentMemoryPressure()
    }

    /// 响应内存压力，缩减内存缓存
    ///
    /// 根据当前内存压力级别，从缓存中移除不活跃的条目（数据仍在磁盘上）。
    /// 在高压力/临界压力下会被 `save` 和定期检查自动调用。
    public func respondToMemoryPressure() {
        let pressure = cleanupPolicy.currentMemoryPressure()
        guard pressure > .normal else { return }

        let sortedEntries = entries.values.sorted { $0.timestamp > $1.timestamp }
        let toEvict = sortedEntries.filter { entry in
            cleanupPolicy.shouldEvictFromCache(entry, among: sortedEntries)
        }

        for entry in toEvict {
            entries.removeValue(forKey: entry.id)
        }

        if !toEvict.isEmpty {
            logger.warning("内存压力响应 (\(pressure)): 已从缓存移除 \(toEvict.count) 条记录")
        }
    }

    // MARK: - Private: Disk I/O

    /// 获取条目加密文件路径
    private func entryFileURL(for id: UUID) -> URL {
        entriesDir.appendingPathComponent("\(id.uuidString).enc")
    }

    /// 获取加密图片文件路径
    private func imageFileURL(for id: UUID) -> URL {
        imagesDir.appendingPathComponent("\(id.uuidString).enc")
    }

    /// 获取缩略图文件路径
    private func thumbnailFileURL(for id: UUID) -> URL {
        thumbsDir.appendingPathComponent("\(id.uuidString).png")
    }

    /// 同步加载所有磁盘条目到内存
    private func loadAllEntriesSync() -> [UUID: HistoryEntry] {
        var loaded: [UUID: HistoryEntry] = [:]

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: entriesDir, includingPropertiesForKeys: [.fileSizeKey]
        ) else {
            return loaded
        }

        let encFiles = files.filter { $0.pathExtension == "enc" }

        for file in encFiles {
            guard let entry = loadEntryFromFileSync(file) else { continue }
            loaded[entry.id] = entry
        }

        return loaded
    }

    /// 从指定文件路径同步加载单个条目
    private func loadEntryFromFileSync(_ fileURL: URL) -> HistoryEntry? {
        do {
            let encryptedData = try Data(contentsOf: fileURL)
            let jsonData = try cryptoService.decrypt(encryptedData)
            let entry = try JSONDecoder().decode(HistoryEntry.self, from: jsonData)
            return entry
        } catch {
            logger.error("加载条目失败: \(fileURL.lastPathComponent)", error: error)
            return nil
        }
    }

    /// 从磁盘同步加载指定 ID 的条目
    private func loadEntryFromDiskSync(id: UUID) -> HistoryEntry? {
        let fileURL = entryFileURL(for: id)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        return loadEntryFromFileSync(fileURL)
    }

    // MARK: - Private: Image Encoding

    /// Writes a `CGImage` to disk as PNG.
    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw HistoryError.fileIOError(path: url.path)
        }

        CGImageDestinationAddImage(destination, image, nil)

        guard CGImageDestinationFinalize(destination) else {
            throw HistoryError.fileIOError(path: url.path)
        }
    }

    /// Generates a PNG thumbnail from an image file.
    private static func writeThumbnail(from imageURL: URL, to thumbnailURL: URL, maxPixelSize: Int) throws {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, sourceOptions) else {
            throw HistoryError.fileIOError(path: imageURL.path)
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            throw HistoryError.fileIOError(path: imageURL.path)
        }

        try writePNG(thumbnail, to: thumbnailURL)
    }

    // MARK: - Private: Cleanup

    /// 驱逐最旧的条目
    private func evictOldest() async throws {
        let sorted = entries.values.sorted { $0.timestamp < $1.timestamp }
        guard let oldest = sorted.first else { return }

        if oldest.isFavourite {
            // 尝试找非收藏的最旧条目
            guard let nonFavourite = sorted.first(where: { !$0.isFavourite }) else {
                throw HistoryError.storageFull(current: entries.count, max: maxEntries)
            }
            try await delete(id: nonFavourite.id)
        } else {
            try await delete(id: oldest.id)
        }
    }

    /// 执行清理策略
    private func enforceCleanup() async throws {
        let sortedEntries = entries.values.sorted { $0.timestamp > $1.timestamp }

        // 按数据类别分别执行清理
        let categories: [DataCategory] = [.text, .image, .thumbnail]

        for category in categories {
            let toEvict = cleanupPolicy.entriesToEvict(sortedEntries, category: category)
            for entry in toEvict {
                try await delete(id: entry.id)
            }
        }

        // 全局数量上限检查
        if entries.count > maxEntries {
            let excess = entries.values
                .sorted { $0.timestamp < $1.timestamp }
                .filter { !$0.isFavourite }
                .prefix(entries.count - maxEntries)
            for entry in excess {
                try await delete(id: entry.id)
            }
        }

        // 内存压力检查
        respondToMemoryPressure()

        // 检查磁盘总大小
        try await enforceDiskQuota()
    }

    /// 检查并执行磁盘配额限制
    private func enforceDiskQuota() async throws {
        var totalSize: UInt64 = 0

        let directories = [entriesDir, imagesDir, thumbsDir]
        for dir in directories {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.fileSizeKey]
            ) else { continue }

            for file in files {
                let attrs = try? file.resourceValues(forKeys: [.fileSizeKey])
                if let size = attrs?.fileSize, size > 0 {
                    totalSize += UInt64(size)
                }
            }
        }

        if totalSize > cleanupPolicy.maxTotalSizeBytes {
            logger.warning("磁盘用量超过限制: \(totalSize) > \(cleanupPolicy.maxTotalSizeBytes)")
            // 清理最旧的条目直到低于限制
            let sorted = entries.values.sorted { $0.timestamp < $1.timestamp }
            for entry in sorted where !entry.isFavourite {
                guard totalSize > cleanupPolicy.maxTotalSizeBytes else { break }
                try await delete(id: entry.id)
                totalSize = max(0, totalSize - 1024 * 100) // 估算每条约 100KB
            }
        }
    }

    // MARK: - Private: CSV Export

    /// 日期格式化器 (CSV/纯文本导出用)
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// 从条目数组构建 CSV 数据
    private static func buildCSV(from entries: [HistoryEntry]) -> Data {
        let header = "ID,Timestamp,Text,Confidence,CaptureMode,SourceType,SourceApp,WindowTitle,Favourite,Tags\n"
        let rows = entries.map { entry -> String in
            let id = entry.id.uuidString
            let ts = dateFormatter.string(from: entry.timestamp)
            let text = csvEscape(entry.textContent)
            let confidence = String(format: "%.4f", entry.ocrConfidence)
            let mode = csvEscape(entry.captureMode)
            let sourceType = entry.sourceType.rawValue
            let app = csvEscape(entry.sourceAppName ?? "")
            let window = csvEscape(entry.sourceWindowTitle ?? "")
            let fav = entry.isFavourite ? "Yes" : "No"
            let tags = csvEscape(entry.tags.joined(separator: ";"))
            return "\(id),\(ts),\(text),\(confidence),\(mode),\(sourceType),\(app),\(window),\(fav),\(tags)"
        }

        let csv = header + rows.joined(separator: "\n")
        return csv.data(using: .utf8) ?? Data()
    }

    /// CSV 字段转义
    private static func csvEscape(_ text: String) -> String {
        if text.contains(",") || text.contains("\"") || text.contains("\n") {
            let escaped = text.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return text
    }
}

// MARK: - Shared singleton alias

extension HistoryActor {
    /// 共享实例，供 UI 层使用
    public static let shared: HistoryActor = {
        do {
            return try HistoryActor()
        } catch {
            fatalError("Failed to initialize HistoryActor: \(error)")
        }
    }()
}
