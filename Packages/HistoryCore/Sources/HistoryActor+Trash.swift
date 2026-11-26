import Foundation

/// One screenshot waiting in the persistent Trash.
///
/// The entry and its encrypted media stay inside `History/v2/trash/<uuid>/`.
/// Restoring moves them back to their original directories; nothing is
/// decrypted or re-encrypted, so the operation is cheap and lossless.
public struct HistoryTrashEntry: Sendable, Identifiable {
    /// Metadata of the trashed screenshot. Its files stay inside the Trash
    /// package until the entry is restored.
    public let entry: HistoryEntry

    /// When the entry was moved to the Trash.
    public let deletedAt: Date

    /// Identifier of the trashed entry, equal to `entry.id`.
    public var id: UUID { entry.id }

    /// Creates a Trash item description.
    ///
    /// - Parameters:
    ///   - entry: Metadata of the trashed entry.
    ///   - deletedAt: When the entry was moved to the Trash.
    public init(entry: HistoryEntry, deletedAt: Date) {
        self.entry = entry
        self.deletedAt = deletedAt
    }
}

extension HistoryActor {
    /// Directory holding deleted screenshot packages.
    var trashDirectory: URL {
        storageURL.appendingPathComponent("trash", isDirectory: true)
    }

    /// Moves one screenshot (entry + all revisions + thumbnails) into the
    /// persistent Trash. The original `delete(id:)` remains the permanent
    /// delete path for callers that really want it.
    public func moveToTrash(id: UUID) async throws {
        loadFromDiskIfNeeded()
        guard let entry = entries[id] ?? diskCache[id] ?? loadEntryFromDiskSync(id: id) else {
            throw HistoryError.entryNotFound(id: id)
        }

        let fileManager = FileManager.default
        let folder = trashDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: folder.path) {
            try? fileManager.removeItem(at: folder)
        }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        var moved: [(source: URL, destination: URL)] = []
        do {
            let entrySource = entryFileURL(for: entry.id)
            if fileManager.fileExists(atPath: entrySource.path) {
                let destination = folder.appendingPathComponent("entry.enc")
                try fileManager.moveItem(at: entrySource, to: destination)
                moved.append((entrySource, destination))
            }

            for source in try mediaFiles(for: entry.id) {
                let destination = folder.appendingPathComponent(source.lastPathComponent)
                try fileManager.moveItem(at: source, to: destination)
                moved.append((source, destination))
            }

            let stamp = ISO8601DateFormatter().string(from: Date())
            try Data(stamp.utf8).write(
                to: folder.appendingPathComponent("deletedAt"),
                options: .atomic
            )
        } catch {
            for item in moved.reversed() {
                try? fileManager.moveItem(at: item.destination, to: item.source)
            }
            try? fileManager.removeItem(at: folder)
            throw HistoryError.fileIOError(path: folder.path)
        }

        entries.removeValue(forKey: id)
        diskCache.removeValue(forKey: id)
        hasLoadedFromDisk = true
        logger.info("Screenshot moved to Trash: \(id)")
        NotificationCenter.default.post(name: Self.imagesDidChange, object: self)
    }

    /// Lists the persistent Trash, newest first.
    public func trashEntries() async throws -> [HistoryTrashEntry] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: trashDirectory.path) else { return [] }
        let folders =
            (try? fileManager.contentsOfDirectory(
                at: trashDirectory,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []

        var result: [HistoryTrashEntry] = []
        for folder in folders {
            let entryURL = folder.appendingPathComponent("entry.enc")
            guard let encrypted = try? Data(contentsOf: entryURL),
                let json = try? cryptoService.decrypt(encrypted),
                let entry = try? JSONDecoder().decode(HistoryEntry.self, from: json)
            else { continue }

            let stampURL = folder.appendingPathComponent("deletedAt")
            let stamp = (try? String(contentsOf: stampURL, encoding: .utf8))
                .flatMap { ISO8601DateFormatter().date(from: $0) }
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))
                .flatMap(\.contentModificationDate)
            result.append(
                HistoryTrashEntry(entry: entry, deletedAt: stamp ?? modified ?? Date())
            )
        }
        return result.sorted { $0.deletedAt > $1.deletedAt }
    }

    /// Restores one screenshot from the persistent Trash.
    @discardableResult
    public func restoreFromTrash(id: UUID) async throws -> HistoryEntry? {
        let fileManager = FileManager.default
        let folder = trashDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        guard fileManager.fileExists(atPath: folder.path) else { return nil }
        let entryURL = folder.appendingPathComponent("entry.enc")
        guard let encrypted = try? Data(contentsOf: entryURL),
            let json = try? cryptoService.decrypt(encrypted),
            let entry = try? JSONDecoder().decode(HistoryEntry.self, from: json)
        else {
            throw HistoryError.decryptionFailed(reason: "trash entry is unreadable")
        }

        try entriesDir.ensureDirectoryExists()
        try imagesDir.ensureDirectoryExists()
        try thumbsDir.ensureDirectoryExists()

        let files =
            (try? fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil
            )) ?? []
        for file in files {
            let name = file.lastPathComponent
            if name == "entry.enc" || name == "deletedAt" {
                continue
            }
            let destination =
                file.pathExtension.lowercased() == "png"
                ? thumbsDir.appendingPathComponent(name)
                : imagesDir.appendingPathComponent(name)
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: file, to: destination)
        }

        let entryDestination = entryFileURL(for: entry.id)
        try? fileManager.removeItem(at: entryDestination)
        try fileManager.moveItem(at: entryURL, to: entryDestination)
        try? fileManager.removeItem(at: folder)

        entries[entry.id] = entry
        diskCache[entry.id] = entry
        hasLoadedFromDisk = true
        logger.info("Screenshot restored from Trash: \(id)")
        NotificationCenter.default.post(name: Self.imagesDidChange, object: self)
        return entry
    }

    /// Permanently removes one Trash package.
    public func deleteTrashEntry(id: UUID) throws {
        let folder = trashDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.removeItem(at: folder)
        logger.info("Screenshot permanently removed from Trash: \(id)")
    }

    /// Permanently removes every item in the Trash.
    public func emptyTrash() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: trashDirectory.path) else { return }
        let folders =
            (try? fileManager.contentsOfDirectory(
                at: trashDirectory,
                includingPropertiesForKeys: nil
            )) ?? []
        for folder in folders {
            try? fileManager.removeItem(at: folder)
        }
        logger.info("Screenshot Trash emptied")
    }

    /// Removes Trash packages older than `age` (default 30 days).
    public func purgeTrash(olderThan age: TimeInterval = 30 * 24 * 60 * 60) {
        let cutoff = Date().addingTimeInterval(-age)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: trashDirectory.path) else { return }
        let folders =
            (try? fileManager.contentsOfDirectory(
                at: trashDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
        for folder in folders {
            let stampURL = folder.appendingPathComponent("deletedAt")
            let stamp = (try? String(contentsOf: stampURL, encoding: .utf8))
                .flatMap { ISO8601DateFormatter().date(from: $0) }
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))
                .flatMap(\.contentModificationDate)
            let date = stamp ?? modified ?? Date()
            if date < cutoff {
                try? fileManager.removeItem(at: folder)
            }
        }
    }
}
