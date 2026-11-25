import Foundation
import os

/// User-owned metadata for the unified recording library.
///
/// The journal inside each recording session stays the single source of truth
/// for media. This file only stores presentation data (title, favourite, tags,
/// notes, manual grouping and tombstones) that the journal must never contain.
public struct RecordingLibraryMetadata: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var sessions: [String: RecordingMetadataEntry]
    public var groups: [String: RecordingManualGroup]

    public init(
        schemaVersion: Int = RecordingLibraryMetadata.currentSchemaVersion,
        sessions: [String: RecordingMetadataEntry] = [:],
        groups: [String: RecordingManualGroup] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.sessions = sessions
        self.groups = groups
    }

    public static var empty: RecordingLibraryMetadata { .init() }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case sessions
        case groups
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? RecordingLibraryMetadata.currentSchemaVersion
        sessions = try container.decodeIfPresent(
            [String: RecordingMetadataEntry].self,
            forKey: .sessions
        ) ?? [:]
        groups = try container.decodeIfPresent(
            [String: RecordingManualGroup].self,
            forKey: .groups
        ) ?? [:]
    }
}

/// Metadata for a single recording session (one automatic group).
public struct RecordingMetadataEntry: Codable, Sendable, Equatable {
    public var displayName: String?
    public var isFavourite: Bool
    public var tags: [String]
    public var note: String?
    /// Manual group that contains this session, if the user grouped several
    /// sessions together. The automatic session group is represented by the
    /// session ID itself and never needs an entry here.
    public var groupID: UUID?
    public var updatedAt: Date
    /// Set when the session was deleted. Kept for a grace period so that a
    /// session restored from the Trash gets its title and favourite back.
    public var deletedAt: Date?

    public init(
        displayName: String? = nil,
        isFavourite: Bool = false,
        tags: [String] = [],
        note: String? = nil,
        groupID: UUID? = nil,
        updatedAt: Date = Date(timeIntervalSince1970: 0),
        deletedAt: Date? = nil
    ) {
        self.displayName = displayName
        self.isFavourite = isFavourite
        self.tags = tags
        self.note = note
        self.groupID = groupID
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    private enum CodingKeys: String, CodingKey {
        case displayName
        case isFavourite
        case tags
        case note
        case groupID
        case updatedAt
        case deletedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        isFavourite = try container.decodeIfPresent(Bool.self, forKey: .isFavourite) ?? false
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        note = try container.decodeIfPresent(String.self, forKey: .note)
        groupID = try container.decodeIfPresent(UUID.self, forKey: .groupID)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
            ?? Date(timeIntervalSince1970: 0)
        deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
    }
}

/// A user-created group of recording sessions. This is deliberately separate
/// from the automatic "one session = one group" rule: a user may stop and
/// restart a recording and still want the pieces shown together.
public struct RecordingManualGroup: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String?
    public var sessionIDs: [UUID]
    public var isFavourite: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        title: String? = nil,
        sessionIDs: [UUID],
        isFavourite: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.sessionIDs = sessionIDs
        self.isFavourite = isFavourite
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case sessionIDs
        case isFavourite
        case createdAt
        case updatedAt
        case deletedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        sessionIDs = try container.decodeIfPresent([UUID].self, forKey: .sessionIDs) ?? []
        isFavourite = try container.decodeIfPresent(Bool.self, forKey: .isFavourite) ?? false
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
    }
}

/// Actor-isolated, atomic, self-healing metadata store.
///
/// The file is intentionally stored under Application Support rather than next
/// to the recordings: recording folders may live on removable volumes, may be
/// duplicated across roots, and must never receive application metadata files.
public actor RecordingLibraryStore {
    public static let defaultFileName = "recording-library.json"

    private static let logger = Logger(
        subsystem: "com.snapglass.app",
        category: "RecordingLibraryStore"
    )

    private let fileURL: URL
    private let fileManager: FileManager
    private var metadata: RecordingLibraryMetadata
    private var saveTask: Task<Void, Never>?

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL.standardizedFileURL
        self.fileManager = fileManager
        self.metadata = Self.load(from: fileURL.standardizedFileURL, fileManager: fileManager)
        try? fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    deinit {
        saveTask?.cancel()
    }

    // MARK: - Reads

    public func snapshot() -> RecordingLibraryMetadata {
        metadata
    }

    public func entry(for sessionID: UUID) -> RecordingMetadataEntry {
        metadata.sessions[sessionID.uuidString] ?? RecordingMetadataEntry()
    }

    public func allGroups() -> [RecordingManualGroup] {
        metadata.groups.values
            .filter { $0.deletedAt == nil }
            .sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt { return lhs.id.uuidString < rhs.id.uuidString }
                return lhs.createdAt < rhs.createdAt
            }
    }

    public func group(id: UUID) -> RecordingManualGroup? {
        metadata.groups[id.uuidString]
    }

    // MARK: - Session writes

    public func setDisplayName(_ name: String?, for sessionID: UUID) {
        var entry = entry(for: sessionID)
        entry.displayName = Self.normalized(name)
        entry.updatedAt = Date()
        metadata.sessions[sessionID.uuidString] = entry
        scheduleSave()
    }

    public func setFavourite(_ isFavourite: Bool, for sessionID: UUID) {
        var entry = entry(for: sessionID)
        entry.isFavourite = isFavourite
        entry.updatedAt = Date()
        metadata.sessions[sessionID.uuidString] = entry
        scheduleSave()
    }

    public func setTags(_ tags: [String], for sessionID: UUID) {
        var entry = entry(for: sessionID)
        entry.tags = tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        entry.updatedAt = Date()
        metadata.sessions[sessionID.uuidString] = entry
        scheduleSave()
    }

    public func setNote(_ note: String?, for sessionID: UUID) {
        var entry = entry(for: sessionID)
        entry.note = Self.normalized(note)
        entry.updatedAt = Date()
        metadata.sessions[sessionID.uuidString] = entry
        scheduleSave()
    }

    public func markDeleted(sessionID: UUID, at date: Date = Date()) {
        var entry = entry(for: sessionID)
        entry.deletedAt = date
        entry.updatedAt = date
        metadata.sessions[sessionID.uuidString] = entry
        scheduleSave()
    }

    public func revive(sessionID: UUID) {
        guard var entry = metadata.sessions[sessionID.uuidString] else { return }
        entry.deletedAt = nil
        entry.updatedAt = Date()
        metadata.sessions[sessionID.uuidString] = entry
        scheduleSave()
    }

    // MARK: - Manual groups

    @discardableResult
    public func createGroup(title: String?, sessionIDs: [UUID]) -> RecordingManualGroup? {
        let uniqueIDs = Array(Set(sessionIDs)).sorted { $0.uuidString < $1.uuidString }
        guard uniqueIDs.count >= 2 else { return nil }
        let now = Date()
        let group = RecordingManualGroup(
            title: Self.normalized(title),
            sessionIDs: uniqueIDs,
            createdAt: now,
            updatedAt: now
        )
        metadata.groups[group.id.uuidString] = group
        for sessionID in uniqueIDs {
            var entry = entry(for: sessionID)
            entry.groupID = group.id
            entry.updatedAt = now
            metadata.sessions[sessionID.uuidString] = entry
        }
        scheduleSave()
        return group
    }

    @discardableResult
    public func updateGroup(id: UUID, title: String?) -> RecordingManualGroup? {
        guard var group = metadata.groups[id.uuidString] else { return nil }
        group.title = Self.normalized(title)
        group.updatedAt = Date()
        metadata.groups[id.uuidString] = group
        scheduleSave()
        return group
    }

    @discardableResult
    public func setGroupFavourite(id: UUID, isFavourite: Bool) -> RecordingManualGroup? {
        guard var group = metadata.groups[id.uuidString] else { return nil }
        group.isFavourite = isFavourite
        group.updatedAt = Date()
        metadata.groups[id.uuidString] = group
        for sessionID in group.sessionIDs {
            var entry = entry(for: sessionID)
            entry.isFavourite = isFavourite
            entry.updatedAt = group.updatedAt
            metadata.sessions[sessionID.uuidString] = entry
        }
        scheduleSave()
        return group
    }

    public func removeGroup(id: UUID) {
        guard let group = metadata.groups.removeValue(forKey: id.uuidString) else { return }
        let now = Date()
        for sessionID in group.sessionIDs {
            var entry = entry(for: sessionID)
            entry.groupID = nil
            entry.updatedAt = now
            metadata.sessions[sessionID.uuidString] = entry
        }
        scheduleSave()
    }

    // MARK: - Maintenance

    /// Tombstones are kept for 30 days so a session restored from the Trash
    /// gets its title and favourite back. After that, the metadata is removed.
    public func purgeTombstones(
        olderThan age: TimeInterval = 30 * 24 * 60 * 60,
        now: Date = Date()
    ) {
        let cutoff = now.addingTimeInterval(-age)
        var changed = false
        for (key, entry) in metadata.sessions {
            if let deletedAt = entry.deletedAt, deletedAt < cutoff {
                metadata.sessions.removeValue(forKey: key)
                changed = true
            }
        }
        for (key, group) in metadata.groups {
            if let deletedAt = group.deletedAt, deletedAt < cutoff {
                metadata.groups.removeValue(forKey: key)
                changed = true
            }
        }
        if changed { scheduleSave() }
    }

    public func saveNow() async {
        saveTask?.cancel()
        saveTask = nil
        writeToDisk()
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.saveNow()
        }
    }

    private func writeToDisk() {
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(metadata)

            if fileManager.fileExists(atPath: fileURL.path) {
                let backupURL = fileURL.appendingPathExtension("bak")
                try? fileManager.removeItem(at: backupURL)
                try? fileManager.copyItem(at: fileURL, to: backupURL)
            }
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            Self.logger.error("Failed to save recording library metadata: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func load(
        from fileURL: URL,
        fileManager: FileManager
    ) -> RecordingLibraryMetadata {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let candidates = [fileURL, fileURL.appendingPathExtension("bak")]

        for candidate in candidates {
            guard let data = try? Data(contentsOf: candidate) else { continue }
            if let decoded = try? decoder.decode(RecordingLibraryMetadata.self, from: data) {
                if candidate != fileURL {
                    logger.notice("Recovered recording library metadata from backup")
                }
                return decoded
            }
        }

        if fileManager.fileExists(atPath: fileURL.path) {
            let stamp = ISO8601DateFormatter()
                .string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let corruptURL = fileURL
                .deletingLastPathComponent()
                .appendingPathComponent("recording-library.corrupt-\(stamp).json")
            try? fileManager.moveItem(at: fileURL, to: corruptURL)
            logger.error("Recording library metadata was unreadable; moved to \(corruptURL.lastPathComponent, privacy: .public)")
        }
        return .empty
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(120))
    }
}
