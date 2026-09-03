import Foundation

// MARK: - HistoryActor Cleanup

extension HistoryActor {
    /// 驱逐最旧的条目
    func evictOldest() async throws {
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
    func enforceCleanup() async throws {
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
    func enforceEntryLimits() async throws {
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
    func enforceDiskQuota() async throws {
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
}
