import CoreGraphics
import Foundation
import ImageIO
import SharedKit

// MARK: - HistoryActor Disk I/O

extension HistoryActor {
    /// Merges the disk snapshot with the in-memory cache. Cached entries win because
    /// they may contain a more recent metadata update.
    func allPersistedEntries() -> [UUID: HistoryEntry] {
        var merged = diskCache
        for (id, entry) in entries {
            merged[id] = entry
        }
        return merged
    }

    /// Invalidates the disk snapshot cache so the next read reloads from disk.
    func invalidateDiskCache() {
        diskCache = [:]
    }

    /// Encrypts and atomically persists entry metadata.
    func persistEntry(_ entry: HistoryEntry) throws {
        let jsonData = try JSONEncoder().encode(entry)
        let encryptedData = try cryptoService.encrypt(jsonData)
        try encryptedData.write(to: entryFileURL(for: entry.id), options: .atomic)
    }

    func removeIfExists(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    func hasData(_ entry: HistoryEntry, category: DataCategory) -> Bool {
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
    func stripData(_ category: DataCategory, from id: UUID) throws {
        guard var entry = entries[id] ?? loadEntryFromDiskSync(id: id) else { return }

        if category == .text {
            try stripText(from: &entry, id: id)
            return
        }

        let transactionDir = tempDir.appendingPathComponent("strip-\(UUID().uuidString)")
        let staged = try stageFile(for: category, id: id, in: transactionDir)

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
            rollbackStagedFile(staged)
            throw error
        }

        if staged != nil {
            do {
                try FileManager.default.removeItem(at: transactionDir)
            } catch {
                logger.warning("分层清理已提交，但临时文件清理失败: \(transactionDir.lastPathComponent)")
            }
        }
    }

    /// 将暂存文件恢复到原位置。
    func rollbackStagedFile(_ staged: (sourceURL: URL, stagedURL: URL)?) {
        guard let staged else { return }
        do {
            try FileManager.default.moveItem(at: staged.stagedURL, to: staged.sourceURL)
        } catch {
            logger.error("恢复分层清理事务失败: \(staged.sourceURL.lastPathComponent)", error: error)
        }
    }

    /// 清空条目的文本内容并持久化。
    func stripText(from entry: inout HistoryEntry, id: UUID) throws {
        guard !entry.textContent.isEmpty else { return }
        entry.textContent = ""
        try persistEntry(entry)
        if entries[id] != nil {
            entries[id] = entry
        }
        invalidateDiskCache()
    }

    /// 将指定分类的存储文件暂存到事务目录，返回源 URL 与暂存 URL（若文件存在）。
    func stageFile(
        for category: DataCategory,
        id: UUID,
        in transactionDir: URL
    ) throws -> (sourceURL: URL, stagedURL: URL)? {
        let sourceURL: URL?
        switch category {
        case .image:
            sourceURL = imageFileURL(for: id)
        case .thumbnail:
            sourceURL = thumbnailFileURL(for: id)
        case .text:
            sourceURL = nil
        }
        guard let sourceURL, FileManager.default.fileExists(atPath: sourceURL.path) else { return nil }
        try transactionDir.ensureDirectoryExists()
        let destination = transactionDir.appendingPathComponent(sourceURL.lastPathComponent)
        try FileManager.default.moveItem(at: sourceURL, to: destination)
        return (sourceURL, destination)
    }

    func storedSize(for id: UUID) -> UInt64 {
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
    func entryFileURL(for id: UUID) -> URL {
        entriesDir.appendingPathComponent("\(id.uuidString).enc")
    }

    /// 获取加密图片文件路径
    func imageFileURL(for id: UUID) -> URL {
        imagesDir.appendingPathComponent("\(id.uuidString).enc")
    }

    /// 获取缩略图文件路径
    func thumbnailFileURL(for id: UUID) -> URL {
        thumbsDir.appendingPathComponent("\(id.uuidString).png")
    }

    /// 同步加载所有磁盘条目到内存
    /// 从指定文件路径同步加载单个条目
    func loadEntryFromFileSync(_ fileURL: URL) -> HistoryEntry? {
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
    func loadEntryFromDiskSync(id: UUID) -> HistoryEntry? {
        let fileURL = entryFileURL(for: id)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        return loadEntryFromFileSync(fileURL)
    }

    /// Generates a PNG thumbnail from an image file.
    static func writeThumbnail(from imageURL: URL, to thumbnailURL: URL, maxPixelSize: Int) throws {
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
}
