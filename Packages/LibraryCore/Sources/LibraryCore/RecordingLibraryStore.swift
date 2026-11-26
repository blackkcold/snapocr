import Foundation
import os

/// User-owned metadata for the unified recording library.
///
/// The journal inside each recording session stays the single source of truth
/// for media. This file only stores presentation data (title, favourite, tags,
/// notes, manual grouping and tombstones) that the journal must never contain.
public struct RecordingLibraryMetadata: Codable, Sendable, Equatable {
    /// Schema version written by this build.
    public static let currentSchemaVersion = 1

    /// Schema version that produced this metadata.
    public var schemaVersion: Int
    /// Session metadata keyed by the uppercase UUID string of the session.
    public var sessions: [String: RecordingMetadataEntry]
    /// Manual groups keyed by the uppercase UUID string of the group.
    public var groups: [String: RecordingManualGroup]

    /// Creates metadata with the given contents.
    ///
    /// - Parameters:
    ///   - schemaVersion: Schema version to record; defaults to `currentSchemaVersion`.
    ///   - sessions: Session metadata keyed by session UUID string.
    ///   - groups: Manual groups keyed by group UUID string.
    public init(
        schemaVersion: Int = RecordingLibraryMetadata.currentSchemaVersion,
        sessions: [String: RecordingMetadataEntry] = [:],
        groups: [String: RecordingManualGroup] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.sessions = sessions
        self.groups = groups
    }

    /// Metadata with no sessions and no groups.
    public static var empty: RecordingLibraryMetadata { .init() }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case sessions
        case groups
    }

    /// Decodes metadata, defaulting keys that are absent to the current schema
    /// version and empty collections.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: An error if the container cannot be read or a present value has
    ///   the wrong type.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion =
            try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? RecordingLibraryMetadata.currentSchemaVersion
        sessions =
            try container.decodeIfPresent(
                [String: RecordingMetadataEntry].self,
                forKey: .sessions
            ) ?? [:]
        groups =
            try container.decodeIfPresent(
                [String: RecordingManualGroup].self,
                forKey: .groups
            ) ?? [:]
    }
}

/// Metadata for a single recording session (one automatic group).
public struct RecordingMetadataEntry: Codable, Sendable, Equatable {
    /// User-visible title that overrides the generated recording name.
    public var displayName: String?
    /// Whether the user marked this session as a favourite.
    public var isFavourite: Bool
    /// Free-form tags, stored trimmed and without empty entries.
    public var tags: [String]
    /// Free-form note attached to the session.
    public var note: String?
    /// Manual group that contains this session, if the user grouped several
    /// sessions together. The automatic session group is represented by the
    /// session ID itself and never needs an entry here.
    public var groupID: UUID?
    /// Time of the last metadata change for this session.
    public var updatedAt: Date
    /// Set when the session was deleted. Kept for a grace period so that a
    /// session restored from the Trash gets its title and favourite back.
    public var deletedAt: Date?

    /// Creates a metadata entry with the given values.
    ///
    /// - Parameters:
    ///   - displayName: Custom title, or `nil` to use the generated name.
    ///   - isFavourite: Whether the session is a favourite.
    ///   - tags: Tags for the session.
    ///   - note: Note attached to the session.
    ///   - groupID: Manual group that contains the session.
    ///   - updatedAt: Time of the last change; defaults to the Unix epoch.
    ///   - deletedAt: Tombstone time when the session is deleted.
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

    /// Decodes an entry, substituting defaults for missing fields.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: An error if the container cannot be read or a present value has
    ///   the wrong type.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        isFavourite = try container.decodeIfPresent(Bool.self, forKey: .isFavourite) ?? false
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        note = try container.decodeIfPresent(String.self, forKey: .note)
        groupID = try container.decodeIfPresent(UUID.self, forKey: .groupID)
        updatedAt =
            try container.decodeIfPresent(Date.self, forKey: .updatedAt)
            ?? Date(timeIntervalSince1970: 0)
        deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
    }
}

/// A user-created group of recording sessions. This is deliberately separate
/// from the automatic "one session = one group" rule: a user may stop and
/// restart a recording and still want the pieces shown together.
public struct RecordingManualGroup: Codable, Sendable, Equatable, Identifiable {
    /// Stable identity of the group.
    public var id: UUID
    /// User-visible group title, or `nil` when the group uses a generated name.
    public var title: String?
    /// Member session IDs, sorted by UUID string and free of duplicates.
    public var sessionIDs: [UUID]
    /// Whether the user marked this group as a favourite.
    public var isFavourite: Bool
    /// Time the group was created.
    public var createdAt: Date
    /// Time of the last change to the group.
    public var updatedAt: Date
    /// Tombstone time when the group is deleted.
    public var deletedAt: Date?

    /// Creates a manual group with the given values.
    ///
    /// - Parameters:
    ///   - id: Identity of the group; defaults to a new UUID.
    ///   - title: Group title, or `nil` to use a generated name.
    ///   - sessionIDs: Sessions that belong to the group.
    ///   - isFavourite: Whether the group is a favourite.
    ///   - createdAt: Creation time; defaults to now.
    ///   - updatedAt: Last change time; defaults to now.
    ///   - deletedAt: Tombstone time when the group is deleted.
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

    /// Decodes a group, substituting defaults for missing fields.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: An error if the container cannot be read, the required `id` is
    ///   missing, or a present value has the wrong type.
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
    /// Default name of the metadata file.
    public static let defaultFileName = "recording-library.json"

    private static let logger = Logger(
        subsystem: "com.snapglass.app",
        category: "RecordingLibraryStore"
    )

    private let fileURL: URL
    private let fileManager: FileManager
    private var metadata: RecordingLibraryMetadata
    private var saveTask: Task<Void, Never>?

    /// Creates a store backed by the given file and loads its current contents.
    ///
    /// Loading falls back to the `.bak` copy and then to an empty library; an
    /// unreadable file is moved aside under a `recording-library.corrupt-*.json`
    /// name instead of being overwritten in place.
    ///
    /// - Parameters:
    ///   - fileURL: Location of the JSON metadata file. It is standardized
    ///     before use, and its parent directory is created if needed.
    ///   - fileManager: File manager used for reads and writes.
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

    /// A copy of the in-memory metadata, including tombstones.
    ///
    /// - Returns: The metadata as currently held in memory.
    public func snapshot() -> RecordingLibraryMetadata {
        metadata
    }

    /// Metadata for a session.
    ///
    /// - Parameter sessionID: Identity of the recording session.
    /// - Returns: The stored entry, or a default empty entry when the session has
    ///   no metadata yet.
    public func entry(for sessionID: UUID) -> RecordingMetadataEntry {
        metadata.sessions[sessionID.uuidString] ?? RecordingMetadataEntry()
    }

    /// Manual groups that are not deleted.
    ///
    /// - Returns: Visible groups ordered by creation time, with UUID order as the
    ///   tie-breaker.
    public func allGroups() -> [RecordingManualGroup] {
        metadata.groups.values
            .filter { $0.deletedAt == nil }
            .sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt { return lhs.id.uuidString < rhs.id.uuidString }
                return lhs.createdAt < rhs.createdAt
            }
    }

    /// Looks up a manual group by identity.
    ///
    /// - Parameter id: Identity of the group.
    /// - Returns: The group, including one that has a tombstone, or `nil` when no
    ///   group with that ID exists.
    public func group(id: UUID) -> RecordingManualGroup? {
        metadata.groups[id.uuidString]
    }

    // MARK: - Session writes

    /// Stores a custom title for a session.
    ///
    /// The value is trimmed and truncated to 120 characters; a blank value
    /// clears the title. The change is written after a short debounce.
    ///
    /// - Parameters:
    ///   - name: New title, or `nil` to fall back to the generated name.
    ///   - sessionID: Identity of the recording session.
    public func setDisplayName(_ name: String?, for sessionID: UUID) {
        var entry = entry(for: sessionID)
        entry.displayName = Self.normalized(name)
        entry.updatedAt = Date()
        metadata.sessions[sessionID.uuidString] = entry
        scheduleSave()
    }

    /// Marks a session as a favourite or removes it from favourites.
    ///
    /// - Parameters:
    ///   - isFavourite: Whether the session is a favourite.
    ///   - sessionID: Identity of the recording session.
    public func setFavourite(_ isFavourite: Bool, for sessionID: UUID) {
        var entry = entry(for: sessionID)
        entry.isFavourite = isFavourite
        entry.updatedAt = Date()
        metadata.sessions[sessionID.uuidString] = entry
        scheduleSave()
    }

    /// Replaces the tags of a session.
    ///
    /// Each tag is trimmed and empty tags are dropped.
    ///
    /// - Parameters:
    ///   - tags: New tags for the session.
    ///   - sessionID: Identity of the recording session.
    public func setTags(_ tags: [String], for sessionID: UUID) {
        var entry = entry(for: sessionID)
        entry.tags =
            tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        entry.updatedAt = Date()
        metadata.sessions[sessionID.uuidString] = entry
        scheduleSave()
    }

    /// Stores a note for a session.
    ///
    /// The value is trimmed and truncated to 120 characters; a blank value
    /// clears the note.
    ///
    /// - Parameters:
    ///   - note: New note, or `nil` to clear it.
    ///   - sessionID: Identity of the recording session.
    public func setNote(_ note: String?, for sessionID: UUID) {
        var entry = entry(for: sessionID)
        entry.note = Self.normalized(note)
        entry.updatedAt = Date()
        metadata.sessions[sessionID.uuidString] = entry
        scheduleSave()
    }

    /// Records a tombstone for a deleted session.
    ///
    /// The metadata is retained so that a session restored from the Trash keeps
    /// its title, favourite flag, tags and note until it is purged.
    ///
    /// - Parameters:
    ///   - sessionID: Identity of the recording session.
    ///   - date: Time of deletion; defaults to now.
    public func markDeleted(sessionID: UUID, at date: Date = Date()) {
        var entry = entry(for: sessionID)
        entry.deletedAt = date
        entry.updatedAt = date
        metadata.sessions[sessionID.uuidString] = entry
        scheduleSave()
    }

    /// Clears the tombstone of a session restored from the Trash.
    ///
    /// Does nothing when the session has no stored metadata.
    ///
    /// - Parameter sessionID: Identity of the recording session.
    public func revive(sessionID: UUID) {
        guard var entry = metadata.sessions[sessionID.uuidString] else { return }
        entry.deletedAt = nil
        entry.updatedAt = Date()
        metadata.sessions[sessionID.uuidString] = entry
        scheduleSave()
    }

    // MARK: - Manual groups

    /// Creates a manual group from two or more distinct sessions.
    ///
    /// Duplicate session IDs are dropped and the rest are stored in UUID order.
    /// Every member session is associated with the new group, replacing any
    /// previous manual group association.
    ///
    /// - Parameters:
    ///   - title: Group title, or `nil` to use a generated name.
    ///   - sessionIDs: Sessions to group together.
    /// - Returns: The new group, or `nil` when fewer than two distinct sessions
    ///   were supplied.
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

    /// Renames a manual group.
    ///
    /// - Parameters:
    ///   - id: Identity of the group.
    ///   - title: New title, or `nil` to fall back to a generated name.
    /// - Returns: The updated group, or `nil` when no group with that ID exists.
    @discardableResult
    public func updateGroup(id: UUID, title: String?) -> RecordingManualGroup? {
        guard var group = metadata.groups[id.uuidString] else { return nil }
        group.title = Self.normalized(title)
        group.updatedAt = Date()
        metadata.groups[id.uuidString] = group
        scheduleSave()
        return group
    }

    /// Sets the favourite flag on a manual group and on all of its members.
    ///
    /// - Parameters:
    ///   - id: Identity of the group.
    ///   - isFavourite: Whether the group and its sessions are favourites.
    /// - Returns: The updated group, or `nil` when no group with that ID exists.
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

    /// Removes a manual group immediately and clears the group reference from
    /// its member sessions.
    ///
    /// Unlike session deletion this leaves no tombstone: the group itself is
    /// dropped, while the sessions keep their own metadata.
    ///
    /// - Parameter id: Identity of the group. The call does nothing when no group
    ///   with that ID exists.
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

    /// Cancels a pending debounced save and writes the metadata immediately.
    ///
    /// Writes are atomic, and the previous file is copied to a `.bak` companion
    /// first. Write failures are logged rather than thrown.
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
            Self.logger.error(
                "Failed to save recording library metadata: \(error.localizedDescription, privacy: .public)")
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
            let corruptURL =
                fileURL
                .deletingLastPathComponent()
                .appendingPathComponent("recording-library.corrupt-\(stamp).json")
            try? fileManager.moveItem(at: fileURL, to: corruptURL)
            logger.error(
                "Recording library metadata was unreadable; moved to \(corruptURL.lastPathComponent, privacy: .public)")
        }
        return .empty
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(120))
    }
}
