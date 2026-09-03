import Foundation

// MARK: - HistoryActor Additional Public API

extension HistoryActor {
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
}
