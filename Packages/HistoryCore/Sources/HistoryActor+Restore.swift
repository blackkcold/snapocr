import Foundation
import SharedKit

// MARK: - HistoryActor Restore

extension HistoryActor {
    /// 把一条刚被删除的记录原样写回存储，用于“撤销删除”。
    ///
    /// 保留原 `id`、时间戳、收藏状态与标签，图片重新加密写回原路径。
    /// 调用方负责在删除前读出图片与缩略图数据。
    ///
    /// - Parameters:
    ///   - entry: 被删除的条目元数据。
    ///   - imageData: 删除前解密的截图数据；`nil` 表示该条目本就没有图片。
    ///   - thumbnailData: 删除前的缩略图数据；缺失时条目仍可恢复，只是没有预览图。
    public func restore(
        _ entry: HistoryEntry,
        imageData: Data?,
        thumbnailData: Data?
    ) async throws {
        var restored = entry
        var createdFiles: [URL] = []

        // 让 revision 感知的路径解析到本条目的媒体文件。
        entries[restored.id] = restored
        defer { invalidateDiskCache() }

        do {
            if let imageData {
                let imageURL = imageFileURL(for: restored.id)
                let encrypted = try cryptoService.encrypt(imageData)
                try encrypted.write(to: imageURL, options: .atomic)
                createdFiles.append(imageURL)
                restored.imagePath = imageURL
            } else {
                restored.imagePath = nil
            }

            if let thumbnailData {
                let thumbnailURL = thumbnailFileURL(for: restored.id)
                try thumbnailData.write(to: thumbnailURL, options: .atomic)
                createdFiles.append(thumbnailURL)
                restored.thumbnailPath = thumbnailURL
            } else {
                restored.thumbnailPath = nil
            }

            try persistEntry(restored)
            createdFiles.append(entryFileURL(for: restored.id))
            entries[restored.id] = restored
            logger.info("历史条目已恢复: \(restored.id)")
        } catch {
            for file in createdFiles {
                try? removeIfExists(file)
            }
            entries.removeValue(forKey: restored.id)
            throw error
        }
    }
}
