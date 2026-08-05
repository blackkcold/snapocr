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

    /// 内存缓存（热缓存，可被内存压力驱逐）
    private var entries: [UUID: HistoryEntry] = [:]

    /// 磁盘快照缓存（权威磁盘状态，仅在磁盘写入/删除时失效）。
    ///
    /// 避免每次 `allPersistedEntries()` 都全量重读并解密所有 `.enc` 文件，
    /// 将历史操作从 O(n) 磁盘+解密降为 O(1) 内存合并。单进程内保持与磁盘一致；
    /// 跨进程（CLI）写入需重启进程后才会反映到本缓存。
    private var diskCache: [UUID: HistoryEntry] = [:]

    /// 加密服务（struct，避免 actor 嵌套死锁 R14）
    private let cryptoService: CryptoService

    /// 清理策略
    private var cleanupPolicy: CleanupPolicy

    /// 日志记录器
    private let logger = Logger(category: "history")

    /// 文本脱敏器
    private let anonymizer = TextAnonymizer()

    /// 全局条目数量硬限制
    private var maxEntries: Int

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

    public func save(_ entry: HistoryEntry) async throws {
        if allPersistedEntries().count >= maxEntries, entries[entry.id] == nil {
            try await evictOldest()
        }

        var mutableEntry = entry
        var newlyCreatedFiles: [URL] = []
        var committed = false

        defer {
            if !committed {
                for file in newlyCreatedFiles {
                    do {
                        try removeIfExists(file)
                    } catch {
                        logger.error("回滚新建历史文件失败: \(file.lastPathComponent)", error: error)
                    }
                }
            }
        }

        // 处理截图原图：复制到加密存储
        if let sourcePath = entry.imagePath {
            let destURL = imageFileURL(for: entry.id)
            guard FileManager.default.fileExists(atPath: sourcePath.path) else {
                throw HistoryError.fileIOError(path: sourcePath.path)
            }

            do {
                if sourcePath.standardizedFileURL != destURL.standardizedFileURL {
                    let destinationExisted = FileManager.default.fileExists(atPath: destURL.path)
                    let imageData = try Data(contentsOf: sourcePath)
                    let encryptedImage = try cryptoService.encrypt(imageData)
                    try encryptedImage.write(to: destURL, options: .atomic)
                    if !destinationExisted {
                        newlyCreatedFiles.append(destURL)
                    }
                }
                mutableEntry.imagePath = destURL
                logger.debug("截图已加密存储: \(entry.id)")
            } catch {
                logger.error("截图加密存储失败", error: error)
                throw HistoryError.encryptionFailed(reason: error.localizedDescription)
            }
        }

        // 处理缩略图：复制到非加密存储
        if let sourcePath = entry.thumbnailPath {
            let destURL = thumbnailFileURL(for: entry.id)
            guard FileManager.default.fileExists(atPath: sourcePath.path) else {
                throw HistoryError.fileIOError(path: sourcePath.path)
            }

            do {
                if sourcePath.standardizedFileURL != destURL.standardizedFileURL {
                    let destinationExisted = FileManager.default.fileExists(atPath: destURL.path)
                    let thumbData = try Data(contentsOf: sourcePath)
                    try thumbData.write(to: destURL, options: .atomic)
                    if !destinationExisted {
                        newlyCreatedFiles.append(destURL)
                    }
                }
                mutableEntry.thumbnailPath = destURL
                logger.debug("缩略图已存储: \(entry.id)")
            } catch {
                logger.error("缩略图存储失败", error: error)
                throw HistoryError.fileIOError(path: sourcePath.path)
            }
        }

        // 加密持久化条目 JSON
        do {
            let fileURL = entryFileURL(for: entry.id)
            let destinationExisted = FileManager.default.fileExists(atPath: fileURL.path)
            try persistEntry(mutableEntry)
            if !destinationExisted {
                newlyCreatedFiles.append(fileURL)
            }
        } catch {
            logger.error("条目加密持久化失败", error: error)
            throw HistoryError.encryptionFailed(reason: error.localizedDescription)
        }

        entries[entry.id] = mutableEntry
        invalidateDiskCache()
        committed = true
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
        let defaults = UserDefaults.standard
        let configuredFormat = ImageFileFormat(
            rawValue: defaults.string(forKey: PreferenceKeys.captureImageFormat)
                ?? PreferenceDefaults.captureImageFormat
        ) ?? .png
        let format = ImageEncoder.containsTransparency(image) ? ImageFileFormat.png : configuredFormat
        let jpegQuality = defaults.object(forKey: PreferenceKeys.captureJPEGQuality) == nil
            ? PreferenceDefaults.captureJPEGQuality
            : defaults.double(forKey: PreferenceKeys.captureJPEGQuality)
        let imageURL = tempDir.appendingPathComponent("\(tempID)-capture.\(format.fileExtension)")
        let thumbnailURL = tempDir.appendingPathComponent("\(tempID)-thumb.png")

        defer {
            try? FileManager.default.removeItem(at: imageURL)
            try? FileManager.default.removeItem(at: thumbnailURL)
        }

        try ImageEncoder.write(image, to: imageURL, format: format, jpegQuality: jpegQuality)
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
        // 合并内存缓存与磁盘快照，确保搜索覆盖所有已持久化的数据
        let merged = allPersistedEntries()

        let results = merged.values.filter { entry in
            entry.textContent.localizedCaseInsensitiveContains(query)
                || entry.tags.contains(where: { $0.localizedCaseInsensitiveContains(query) })
                || (entry.sourceAppName?.localizedCaseInsensitiveContains(query) ?? false)
                || (entry.sourceWindowTitle?.localizedCaseInsensitiveContains(query) ?? false)
        }
        return results.sorted { $0.timestamp > $1.timestamp }
    }

    // MARK: - HistoryProtocol: Delete

    public func delete(id: UUID) async throws {
        let transactionDir = tempDir.appendingPathComponent("delete-\(UUID().uuidString)")
        try transactionDir.ensureDirectoryExists()
        let files = [
            entryFileURL(for: id),
            imageFileURL(for: id),
            thumbnailFileURL(for: id),
        ]
        var staged: [(original: URL, staged: URL)] = []

        do {
            for file in files where FileManager.default.fileExists(atPath: file.path) {
                let stagedName = "\(file.deletingLastPathComponent().lastPathComponent)-\(file.lastPathComponent)"
                let stagedURL = transactionDir.appendingPathComponent(stagedName)
                try FileManager.default.moveItem(at: file, to: stagedURL)
                staged.append((file, stagedURL))
            }
        } catch {
            for item in staged.reversed() {
                do {
                    try FileManager.default.moveItem(at: item.staged, to: item.original)
                } catch {
                    logger.error("恢复删除事务失败: \(item.original.lastPathComponent)", error: error)
                }
            }
            throw HistoryError.fileIOError(path: transactionDir.path)
        }

        entries.removeValue(forKey: id)
        invalidateDiskCache()
        do {
            try FileManager.default.removeItem(at: transactionDir)
        } catch {
            logger.warning("删除事务已提交，但临时文件清理失败: \(transactionDir.lastPathComponent)")
        }

        logger.info("历史条目已删除: \(id)")
    }

    // MARK: - HistoryProtocol: Clear

    public func clear() async throws {
        let transactionDir = tempDir.appendingPathComponent("clear-\(UUID().uuidString)")
        try transactionDir.ensureDirectoryExists()
        let directories = [entriesDir, imagesDir, thumbsDir]
        var staged: [(original: URL, staged: URL)] = []

        do {
            for directory in directories {
                let stagedURL = transactionDir.appendingPathComponent(directory.lastPathComponent)
                try FileManager.default.moveItem(at: directory, to: stagedURL)
                staged.append((directory, stagedURL))
                try directory.ensureDirectoryExists()
            }
        } catch {
            for item in staged.reversed() {
                do {
                    try removeIfExists(item.original)
                    try FileManager.default.moveItem(at: item.staged, to: item.original)
                } catch {
                    logger.error("恢复清空事务失败: \(item.original.lastPathComponent)", error: error)
                }
            }
            throw HistoryError.fileIOError(path: transactionDir.path)
        }

        entries.removeAll()
        invalidateDiskCache()
        do {
            try FileManager.default.removeItem(at: transactionDir)
        } catch {
            logger.warning("清空事务已提交，但临时文件清理失败: \(transactionDir.lastPathComponent)")
        }

        logger.warning("所有历史记录已清空")
    }

    // MARK: - HistoryProtocol: Recent

    public func recent(limit: Int) async throws -> [HistoryEntry] {
        guard limit > 0 else { return [] }
        return allPersistedEntries().values
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - HistoryProtocol: Export

    public func export(ids: [UUID], format: HistoryExportFormat) async throws -> Data {
        let exportEntries: [HistoryEntry]
        let persistedEntries = allPersistedEntries()
        if ids.isEmpty {
            exportEntries = persistedEntries.values.sorted { $0.timestamp > $1.timestamp }
        } else {
            exportEntries = ids.compactMap { persistedEntries[$0] }
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
        Array(allPersistedEntries().values)
    }

    /// 获取当前条目总数
    ///
    /// - Returns: 缓存中的条目数量
    public func count() -> Int {
        allPersistedEntries().count
    }

    /// 获取所有已收藏的条目
    ///
    /// - Returns: 已收藏条目数组，按时间戳降序
    public func favouriteEntries() -> [HistoryEntry] {
        allPersistedEntries().values
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

    /// Reloads user-configured history limits and immediately applies them.
    /// Favourite entries remain protected from age/count cleanup.
    public func stats() async throws -> HistoryStats {
    let persisted = allPersistedEntries().values
    let totalCount = persisted.count

    var modeDistribution: [String: Int] = [:]
    for entry in persisted {
      let mode = entry.captureMode.isEmpty ? "unknown" : entry.captureMode
      modeDistribution[mode, default: 0] += 1
    }

    let favouriteCount = persisted.filter(\.isFavourite).count

    let totalConfidence = persisted.reduce(Float(0)) { $0 + $1.ocrConfidence }
    let averageConfidence = totalCount > 0 ? totalConfidence / Float(totalCount) : 0

    var totalSize: UInt64 = 0
    for directory in [entriesDir, imagesDir, thumbsDir] {
      if let files = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.fileSizeKey]
      ) {
        for file in files {
          let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
          totalSize += UInt64(size)
        }
      }
    }

    return HistoryStats(
      totalCount: totalCount,
      favouriteCount: favouriteCount,
      captureModeDistribution: modeDistribution,
      totalSizeBytes: totalSize,
      averageConfidence: averageConfidence
    )
  }

  public func reloadConfiguredPolicyAndCleanup() async throws {
        let policy = Self.configuredCleanupPolicy()
        cleanupPolicy = policy
        maxEntries = policy.maxEntries
        try await enforceCleanup()
    }

    // MARK: - Private: Disk I/O

    /// Merges the disk snapshot with the in-memory cache. Cached entries win because
    /// they may contain a more recent metadata update.
    private func allPersistedEntries() -> [UUID: HistoryEntry] {
        var merged = diskCache
        for (id, entry) in entries {
            merged[id] = entry
        }
        return merged
    }

    /// Invalidates the disk snapshot cache so the next read reloads from disk.
    private func invalidateDiskCache() {
        diskCache = [:]
    }

    /// Encrypts and atomically persists entry metadata.
    private func persistEntry(_ entry: HistoryEntry) throws {
        let jsonData = try JSONEncoder().encode(entry)
        let encryptedData = try cryptoService.encrypt(jsonData)
        try encryptedData.write(to: entryFileURL(for: entry.id), options: .atomic)
    }

    private func removeIfExists(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func hasData(_ entry: HistoryEntry, category: DataCategory) -> Bool {
        switch category {
        case .image:
            return entry.imagePath != nil
        case .text:
            return !entry.textContent.isEmpty
        case .thumbnail:
            return entry.thumbnailPath != nil
        }
    }

    /// Removes only one storage layer while keeping the remaining history entry.
    private func stripData(_ category: DataCategory, from id: UUID) throws {
        guard var entry = entries[id] ?? loadEntryFromDiskSync(id: id) else { return }

        if category == .text {
            guard !entry.textContent.isEmpty else { return }
            entry.textContent = ""
            try persistEntry(entry)
            if entries[id] != nil {
                entries[id] = entry
            }
            invalidateDiskCache()
            return
        }

        let sourceURL: URL?
        switch category {
        case .image:
            sourceURL = imageFileURL(for: id)
        case .thumbnail:
            sourceURL = thumbnailFileURL(for: id)
        case .text:
            sourceURL = nil
        }

        let transactionDir = tempDir.appendingPathComponent("strip-\(UUID().uuidString)")
        var stagedURL: URL?

        if let sourceURL, FileManager.default.fileExists(atPath: sourceURL.path) {
            try transactionDir.ensureDirectoryExists()
            let destination = transactionDir.appendingPathComponent(sourceURL.lastPathComponent)
            try FileManager.default.moveItem(at: sourceURL, to: destination)
            stagedURL = destination
        }

        switch category {
        case .image:
            entry.imagePath = nil
        case .thumbnail:
            entry.thumbnailPath = nil
        case .text:
            break
        }

        do {
            try persistEntry(entry)
            if entries[id] != nil {
                entries[id] = entry
            }
            invalidateDiskCache()
        } catch {
            if let sourceURL, let stagedURL {
                do {
                    try FileManager.default.moveItem(at: stagedURL, to: sourceURL)
                } catch {
                    logger.error("恢复分层清理事务失败: \(sourceURL.lastPathComponent)", error: error)
                }
            }
            throw error
        }

        if stagedURL != nil {
            do {
                try FileManager.default.removeItem(at: transactionDir)
            } catch {
                logger.warning("分层清理已提交，但临时文件清理失败: \(transactionDir.lastPathComponent)")
            }
        }
    }

    private func storedSize(for id: UUID) -> UInt64 {
        let files = [entryFileURL(for: id), imageFileURL(for: id), thumbnailFileURL(for: id)]
        return files.reduce(into: 0) { total, file in
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey]),
                  let size = values.fileSize,
                  size > 0
            else { return }
            total += UInt64(size)
        }
    }

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

        try ImageEncoder.write(thumbnail, to: thumbnailURL, format: .png)
    }

    // MARK: - Private: Cleanup

    /// 驱逐最旧的条目
    private func evictOldest() async throws {
        let persistedEntries = allPersistedEntries()
        let sorted = persistedEntries.values.sorted { $0.timestamp < $1.timestamp }
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
        try await enforceEntryLimits()

        // 按数据类别分别执行清理
        let categories: [DataCategory] = [.text, .image, .thumbnail]

        for category in categories {
            let categoryEntries = allPersistedEntries().values
                .filter { hasData($0, category: category) }
                .sorted { $0.timestamp > $1.timestamp }
            let toEvict = cleanupPolicy.entriesToEvict(categoryEntries, category: category)
            for entry in toEvict {
                try stripData(category, from: entry.id)
            }
        }

        // 全局数量上限检查
        let persistedEntries = allPersistedEntries()
        if persistedEntries.count > maxEntries {
            let excess = persistedEntries.values
                .sorted { $0.timestamp < $1.timestamp }
                .filter { !$0.isFavourite }
                .prefix(persistedEntries.count - maxEntries)
            for entry in excess {
                try await delete(id: entry.id)
            }
        }

        // 内存压力检查
        respondToMemoryPressure()

        // 检查磁盘总大小
        try await enforceDiskQuota()
    }

    /// Enforces whole-entry age and count limits before layered cleanup so a
    /// history row never survives without the image needed to reopen it.
    private func enforceEntryLimits() async throws {
        let retentionDays = cleanupPolicy.retentionDays(for: .image)
        let sorted = allPersistedEntries().values.sorted { $0.timestamp > $1.timestamp }
        let expired = sorted.filter { entry in
            guard !entry.isFavourite, retentionDays != Int.max else { return false }
            return Date().timeIntervalSince(entry.timestamp) / 86_400 > Double(retentionDays)
        }
        for entry in expired {
            try await delete(id: entry.id)
        }

        let survivors = allPersistedEntries().values.sorted { $0.timestamp > $1.timestamp }
        let overflow = max(0, survivors.count - maxEntries)
        guard overflow > 0 else { return }
        for entry in survivors.reversed().filter({ !$0.isFavourite }).prefix(overflow) {
            try await delete(id: entry.id)
        }
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
            let sorted = allPersistedEntries().values.sorted { $0.timestamp < $1.timestamp }
            for entry in sorted where !entry.isFavourite {
                guard totalSize > cleanupPolicy.maxTotalSizeBytes else { break }
                let entrySize = storedSize(for: entry.id)
                try await delete(id: entry.id)
                totalSize = totalSize > entrySize ? totalSize - entrySize : 0
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
    ///
    /// 初始化失败时返回 `nil` 而非崩溃，调用方应优雅降级。
    public static let shared: HistoryActor? = {
        try? HistoryActor(cleanupPolicy: configuredCleanupPolicy())
    }()

    /// 共享实例的显式 Result 版本，调用方可获取具体错误信息
    public static func sharedResult() -> Result<HistoryActor, any Error> {
        Result { try HistoryActor(cleanupPolicy: configuredCleanupPolicy()) }
    }

    private static func configuredCleanupPolicy() -> CleanupPolicy {
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
