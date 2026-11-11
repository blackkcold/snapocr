import Foundation

// MARK: - HistoryActor Cleanup

extension HistoryActor {
    /// 驱逐最旧的条目
    ///
    /// - Parameter persistedEntries: 调用方已取得的持久化快照。`save` 的满额预检
    ///   与这里共用同一份快照，避免一次保存里重复合并磁盘缓存。
    func evictOldest(in persistedEntries: [UUID: HistoryEntry]) async throws {
        let sorted = persistedEntries.values.sorted { $0.timestamp < $1.timestamp }
        guard let oldest = sorted.first else { return }

        if oldest.isFavourite || oldest.isProtected {
            // 尝试找非收藏且非保护的最旧条目
            guard let nonFavourite = sorted.first(where: { !$0.isFavourite && !$0.isProtected }) else {
                throw HistoryError.storageFull(current: entries.count, max: maxEntries)
            }
            try await delete(id: nonFavourite.id)
        } else {
            try await delete(id: oldest.id)
        }
    }

    /// 执行清理策略
    func enforceCleanup() async throws {
        // One snapshot for the whole pass. `save` has just called
        // `invalidateDiskCache()`, so this equals a copy of `entries`; every
        // delete/strip below is mirrored into the local copy, so each phase sees
        // exactly what `allPersistedEntries()` would have returned at that point.
        //
        // Assumption: `delete(id:)` and `stripData(_:from:)` contain no
        // cross-actor await, so no other task can mutate `entries` mid-pass.
        var persisted = allPersistedEntries()

        persisted = try await enforceEntryLimits(persisted)

        // 按数据类别分别执行清理
        let categories: [DataCategory] = [.text, .image, .thumbnail]

        for category in categories {
            let categoryEntries = persisted.values
                .filter { hasData($0, category: category) }
                .sorted { $0.timestamp > $1.timestamp }
            let toEvict = cleanupPolicy.entriesToEvict(categoryEntries, category: category)
            for entry in toEvict {
                try stripData(category, from: entry.id)
                if let refreshed = entries[entry.id] {
                    persisted[entry.id] = refreshed
                }
            }
        }

        // 全局数量上限检查
        if persisted.count > maxEntries {
            let excess = persisted.values
                .sorted { $0.timestamp < $1.timestamp }
                .filter { !$0.isFavourite && !$0.isProtected }
                .prefix(persisted.count - maxEntries)
            for entry in excess {
                try await delete(id: entry.id)
                persisted.removeValue(forKey: entry.id)
            }
        }

        // 内存压力检查
        respondToMemoryPressure()

        // 检查磁盘总大小
        try await enforceDiskQuota()
    }

    /// Enforces whole-entry age and count limits before layered cleanup so a
    /// history row never survives without the image needed to reopen it.
    ///
    /// - Parameter persisted: 本轮清理开始时的持久化快照；返回值已移除被删条目。
    func enforceEntryLimits(_ persisted: [UUID: HistoryEntry]) async throws -> [UUID: HistoryEntry] {
        var remaining = persisted
        let retentionDays = cleanupPolicy.retentionDays(for: .image)
        let sorted = remaining.values.sorted { $0.timestamp > $1.timestamp }
        let expired = sorted.filter { entry in
            guard !entry.isFavourite, !entry.isProtected, retentionDays != Int.max else { return false }
            return Date().timeIntervalSince(entry.timestamp) / 86_400 > Double(retentionDays)
        }
        for entry in expired {
            try await delete(id: entry.id)
            remaining.removeValue(forKey: entry.id)
        }

        let survivors = remaining.values.sorted { $0.timestamp > $1.timestamp }
        let overflow = max(0, survivors.count - maxEntries)
        guard overflow > 0 else { return remaining }
        for entry in survivors.reversed().filter({ !$0.isFavourite && !$0.isProtected }).prefix(overflow) {
            try await delete(id: entry.id)
            remaining.removeValue(forKey: entry.id)
        }
        return remaining
    }

    /// 检查并执行磁盘配额限制
    ///
    /// 全量扫描三个存储目录的代价随历史规模线性增长，因此按
    /// `diskQuotaScanInterval` 节流；`save` 仍会在首次保存、间隔到期、
    /// 扫描失败（回滚时间戳）和策略变更（`lastDiskQuotaScan = nil`）时立即扫描。
    func enforceDiskQuota() async throws {
        let now = ContinuousClock().now
        if let last = lastDiskQuotaScan,
           last.duration(to: now) < Self.diskQuotaScanInterval {
            return
        }
        // 先记账再扫描：失败时回滚，保持「下次保存立即重试」的原语义。
        lastDiskQuotaScan = now

        do {
            try await scanAndEnforceDiskQuota()
        } catch {
            lastDiskQuotaScan = nil
            throw error
        }
    }

    /// 全量扫描 + 按需驱逐；逻辑与节流前逐字一致。
    private func scanAndEnforceDiskQuota() async throws {
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
            for entry in sorted where !entry.isFavourite && !entry.isProtected {
                guard totalSize > cleanupPolicy.maxTotalSizeBytes else { break }
                let entrySize = storedSize(for: entry.id)
                try await delete(id: entry.id)
                totalSize = totalSize > entrySize ? totalSize - entrySize : 0
            }
        }
    }
}
