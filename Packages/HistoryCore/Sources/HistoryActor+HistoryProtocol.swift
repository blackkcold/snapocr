import CoreGraphics
import Foundation
import SharedKit

// MARK: - HistoryProtocol Implementation

extension HistoryActor {
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

        // 处理截图原图与缩略图：复制到存储
        let stored = try storeMedia(for: entry, newlyCreatedFiles: &newlyCreatedFiles)
        mutableEntry = stored

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

    /// 将截图原图与缩略图复制到存储，返回更新后的条目。
    private func storeMedia(
        for entry: HistoryEntry,
        newlyCreatedFiles: inout [URL]
    ) throws -> HistoryEntry {
        var mutableEntry = entry

        // 处理截图原图：复制到加密存储
        if let sourcePath = entry.imagePath {
            let destURL = imageFileURL(for: entry.id)
            let destinationExisted = FileManager.default.fileExists(atPath: destURL.path)
            do {
                mutableEntry.imagePath = try storeEncryptedImage(from: sourcePath, for: entry.id)
                if !destinationExisted {
                    newlyCreatedFiles.append(destURL)
                }
                logger.debug("截图已加密存储: \(entry.id)")
            } catch {
                logger.error("截图加密存储失败", error: error)
                throw HistoryError.encryptionFailed(reason: error.localizedDescription)
            }
        }

        // 处理缩略图：复制到非加密存储
        if let sourcePath = entry.thumbnailPath {
            let destURL = thumbnailFileURL(for: entry.id)
            let destinationExisted = FileManager.default.fileExists(atPath: destURL.path)
            do {
                mutableEntry.thumbnailPath = try storeThumbnail(from: sourcePath, for: entry.id)
                if !destinationExisted {
                    newlyCreatedFiles.append(destURL)
                }
                logger.debug("缩略图已存储: \(entry.id)")
            } catch {
                logger.error("缩略图存储失败", error: error)
                throw HistoryError.fileIOError(path: sourcePath.path)
            }
        }

        return mutableEntry
    }

    /// 将截图原图加密复制到历史存储，返回目标 URL。
    private func storeEncryptedImage(from sourcePath: URL, for entryID: UUID) throws -> URL {
        let destURL = imageFileURL(for: entryID)
        guard FileManager.default.fileExists(atPath: sourcePath.path) else {
            throw HistoryError.fileIOError(path: sourcePath.path)
        }
        if sourcePath.standardizedFileURL != destURL.standardizedFileURL {
            let imageData = try Data(contentsOf: sourcePath)
            let encryptedImage = try cryptoService.encrypt(imageData)
            try encryptedImage.write(to: destURL, options: .atomic)
        }
        return destURL
    }

    /// 将缩略图复制到非加密存储，返回目标 URL。
    private func storeThumbnail(from sourcePath: URL, for entryID: UUID) throws -> URL {
        let destURL = thumbnailFileURL(for: entryID)
        guard FileManager.default.fileExists(atPath: sourcePath.path) else {
            throw HistoryError.fileIOError(path: sourcePath.path)
        }
        if sourcePath.standardizedFileURL != destURL.standardizedFileURL {
            let thumbData = try Data(contentsOf: sourcePath)
            try thumbData.write(to: destURL, options: .atomic)
        }
        return destURL
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
    @discardableResult
    public func saveCapture(
        image: CGImage,
        textContent: String,
        ocrConfidence: Float,
        captureMode: String,
        sourceType: HistorySourceType = .screenshot,
        sourceAppName: String? = nil,
        sourceWindowTitle: String? = nil
    ) async throws -> UUID {
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
        return entry.id
    }

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

    public func delete(id: UUID) async throws {
        let transactionDir = tempDir.appendingPathComponent("delete-\(UUID().uuidString)")
        try transactionDir.ensureDirectoryExists()
        let files = [entryFileURL(for: id)] + (try mediaFiles(for: id))
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

    public func recent(limit: Int) async throws -> [HistoryEntry] {
        guard limit > 0 else { return [] }
        return allPersistedEntries().values
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(limit)
            .map { $0 }
    }

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
}
