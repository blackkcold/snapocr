import Foundation

// MARK: - HistoryActor Cleanup Preview

extension HistoryActor {
    /// 预估按给定上限执行清理会删除多少条记录，不修改任何数据。
    ///
    /// 设置界面在用户调整保留期限或容量上限后、真正应用策略之前调用，用于把
    /// “将删除 N 条”摆在用户面前。它镜像 `enforceEntryLimits()` 与
    /// `enforceDiskQuota()` 的整条目删除部分，只做只读计算，不读写磁盘内容。
    ///
    /// - Parameters:
    ///   - maxItems: 拟应用的全局条目上限。
    ///   - retentionDays: 拟应用的保留天数；`Int.max` 表示永久保留。
    ///   - maxTotalSizeBytes: 拟应用的磁盘总大小上限（字节）。
    /// - Returns: 预计会被删除的条目数量（收藏与受保护条目不计入）。
    public func entriesPendingDeletion(
        maxItems: Int,
        retentionDays: Int,
        maxTotalSizeBytes: UInt64
    ) -> Int {
        let persisted = allPersistedEntries().values
        let now = Date()
        var doomed: Set<UUID> = []

        if retentionDays != Int.max {
            for entry in persisted where !entry.isFavourite && !entry.isProtected {
                if now.timeIntervalSince(entry.timestamp) / 86_400 > Double(retentionDays) {
                    doomed.insert(entry.id)
                }
            }
        }

        var survivors = persisted
            .filter { !doomed.contains($0.id) }
            .sorted { $0.timestamp > $1.timestamp }
        let overflow = max(0, survivors.count - maxItems)
        if overflow > 0 {
            let evicted = survivors.reversed()
                .filter { !$0.isFavourite && !$0.isProtected }
                .prefix(overflow)
            for entry in evicted {
                doomed.insert(entry.id)
            }
            survivors = survivors.filter { !doomed.contains($0.id) }
        }

        var totalSize = directoryTotalSize()
        if totalSize > maxTotalSizeBytes {
            for entry in survivors.sorted(by: { $0.timestamp < $1.timestamp })
            where !entry.isFavourite && !entry.isProtected {
                guard totalSize > maxTotalSizeBytes else { break }
                let size = storedSize(for: entry.id)
                doomed.insert(entry.id)
                totalSize = totalSize > size ? totalSize - size : 0
            }
        }

        return doomed.count
    }

    /// 已存储数据占用的总字节数，与 `enforceDiskQuota()` 的口径一致。
    private func directoryTotalSize() -> UInt64 {
        var totalSize: UInt64 = 0
        for directory in [entriesDir, imagesDir, thumbsDir] {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.fileSizeKey]
            ) else { continue }
            for file in files {
                if let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                   size > 0 {
                    totalSize += UInt64(size)
                }
            }
        }
        return totalSize
    }
}
