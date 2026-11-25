import Foundation

/// Failures the ledger reports while opening, replaying, or writing a session.
///
/// Path errors are mapped onto these cases so callers see one vocabulary across
/// journal replay, index persistence, publication, and recovery.
public enum RecordingSessionLedgerError: Error, Equatable, Sendable {
    case invalidPath
    case pathEscapesRoot
    case symbolicLink
    case journalCorrupt
    case unsupportedSchema(Int)
    case missingSession
    case sessionMismatch
    case idempotencyConflict
    case invalidCheckpoint
    case invalidPublication
    case missingPublishIntent
    case readOnly
    case indexCorrupt
    case ioFailure
}

/// Durable, hash-chained journal for one recording session. The index is only a cache.
///
/// The actor itself owns the stored state and the durability entry points. Journal
/// replay lives in `RecordingSessionLedger+Journal.swift`, publication in
/// `RecordingSessionLedger+Publication.swift`, index persistence in
/// `RecordingSessionLedger+Index.swift`, recovery/preview in
/// `RecordingSessionLedger+Recovery.swift`, and shared validation in
/// `RecordingSessionLedger+Validation.swift`. Stored properties stay here so the
/// actor keeps a single source of truth.
public actor RecordingSessionLedger {
    /// Identity of the session this ledger owns.
    public nonisolated let sessionID: UUID
    /// Canonical session directory that holds the journal and checkpoint media.
    public nonisolated let sessionRoot: URL

    let indexURL: URL
    let fileManager: RecordingSendableFileManager
    let now: @Sendable () -> Date
    let readOnly: Bool
    var state = LedgerState()
    var leases: [UUID: PreviewLease] = [:]

    /// Opens a ledger, replaying the session journal when one exists.
    ///
    /// - Parameters:
    ///   - sessionRoot: Session directory; may be missing when the ledger only registers.
    ///   - indexURL: Rebuildable index shared by all sessions.
    ///   - sessionID: Identity the journal must match.
    ///   - fileManager: File manager used for every path operation.
    ///   - now: Clock used for journal and index timestamps.
    ///   - readOnly: Whether the ledger must refuse every write.
    /// - Throws: `RecordingSessionLedgerError.invalidPath` for unusable roots,
    ///   `.missingSession` when read-only and no journal exists, `.journalCorrupt`
    ///   when replay fails verification, and `.unsupportedSchema` when the journal
    ///   was written by a newer schema.
    public init(
        sessionRoot: URL,
        indexURL: URL,
        sessionID: UUID,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() },
        readOnly: Bool = false
    ) throws {
        let (resolvedRoot, canonicalIndex) = try Self.resolvePaths(
            sessionRoot: sessionRoot, indexURL: indexURL, fileManager: fileManager
        )
        self.sessionID = sessionID
        self.sessionRoot = resolvedRoot
        self.indexURL = canonicalIndex
        self.fileManager = RecordingSendableFileManager(fileManager)
        self.now = now
        self.readOnly = readOnly
        let journal = resolvedRoot.appendingPathComponent("journal.ndjson")
        if fileManager.fileExists(atPath: journal.path) {
            do {
                state = try Self.loadJournal(
                    at: journal, sessionRoot: resolvedRoot, sessionID: sessionID,
                    fileManager: fileManager, cachedRecord: nil
                )
            } catch { throw Self.mapPathError(error) }
        } else if readOnly {
            throw RecordingSessionLedgerError.missingSession
        }
        if state.requiresNewerVersion {
            throw RecordingSessionLedgerError.unsupportedSchema(2)
        }
    }

    init(
        sessionRoot: URL,
        indexURL: URL,
        sessionID: UUID,
        fileManager: RecordingSendableFileManager,
        now: @escaping @Sendable () -> Date = { Date() },
        readOnly: Bool = false
    ) throws {
        let (resolvedRoot, canonicalIndex) = try Self.resolvePaths(
            sessionRoot: sessionRoot, indexURL: indexURL, fileManager: fileManager.value
        )
        self.sessionID = sessionID
        self.sessionRoot = resolvedRoot
        self.indexURL = canonicalIndex
        self.fileManager = fileManager
        self.now = now
        self.readOnly = readOnly

        let journal = resolvedRoot.appendingPathComponent("journal.ndjson")
        if fileManager.value.fileExists(atPath: journal.path) {
            state = try Self.loadJournal(
                at: journal, sessionRoot: resolvedRoot, sessionID: sessionID,
                fileManager: fileManager.value, cachedRecord: nil
            )
        } else if readOnly {
            throw RecordingSessionLedgerError.missingSession
        }
        if state.requiresNewerVersion {
            throw RecordingSessionLedgerError.unsupportedSchema(2)
        }
    }

    init(
        sessionRoot: URL,
        indexURL: URL,
        sessionID: UUID,
        fileManager: RecordingSendableFileManager,
        now: @escaping @Sendable () -> Date,
        readOnly: Bool,
        cachedRecord: RecordingSessionRecord?
    ) throws {
        let (resolvedRoot, canonicalIndex) = try Self.resolvePaths(
            sessionRoot: sessionRoot, indexURL: indexURL, fileManager: fileManager.value
        )

        self.sessionID = sessionID
        self.sessionRoot = resolvedRoot
        self.indexURL = canonicalIndex
        self.fileManager = fileManager
        self.now = now
        self.readOnly = readOnly
        state.cachedRecord = cachedRecord

        let journal = resolvedRoot.appendingPathComponent("journal.ndjson")
        if fileManager.value.fileExists(atPath: journal.path) {
            do {
                state = try Self.loadJournal(
                    at: journal, sessionRoot: resolvedRoot, sessionID: sessionID,
                    fileManager: fileManager.value, cachedRecord: cachedRecord
                )
            } catch { throw Self.mapPathError(error) }
        } else if readOnly {
            throw RecordingSessionLedgerError.missingSession
        }
        if state.requiresNewerVersion {
            guard cachedRecord != nil else {
                throw RecordingSessionLedgerError.unsupportedSchema(2)
            }
        }
    }

    private static func resolvePaths(
        sessionRoot: URL,
        indexURL: URL,
        fileManager: FileManager
    ) throws -> (root: URL, index: URL) {
        guard sessionRoot.isFileURL, indexURL.isFileURL,
            !sessionRoot.path.contains("\0"), !indexURL.path.contains("\0")
        else { throw RecordingSessionLedgerError.invalidPath }
        let root: URL
        if fileManager.fileExists(atPath: sessionRoot.path) {
            do {
                root = try RecordingLedgerFileSystem.canonicalDirectory(sessionRoot, create: false)
            } catch {
                throw mapPathError(error)
            }
        } else {
            let parent = sessionRoot.deletingLastPathComponent()
            guard fileManager.fileExists(atPath: parent.path) else {
                throw RecordingSessionLedgerError.invalidPath
            }
            do {
                let canonicalParent = try RecordingLedgerFileSystem.canonicalDirectory(parent, create: false)
                root = canonicalParent.appendingPathComponent(sessionRoot.lastPathComponent).standardizedFileURL
            } catch { throw mapPathError(error) }
        }
        let indexParent: URL
        do {
            indexParent = try RecordingLedgerFileSystem.canonicalDirectory(
                indexURL.deletingLastPathComponent(), create: true
            )
        } catch { throw mapPathError(error) }
        let index = indexParent.appendingPathComponent(indexURL.lastPathComponent).standardizedFileURL
        do {
            try RecordingLedgerFileSystem.validateNoSymlink(index, allowingMissing: true)
        } catch {
            throw mapPathError(error)
        }
        return (root, index)
    }

    /// Journals the session record and mirrors it into the index.
    ///
    /// Registering the same session again is idempotent when its identity, kind,
    /// and layout match; a different record for the same session is rejected.
    ///
    /// - Parameter record: The session record to register.
    /// - Throws: `RecordingSessionLedgerError.sessionMismatch` when the record
    ///   belongs to another session, `.idempotencyConflict` when a different
    ///   record is already registered, `.readOnly` when the ledger cannot write,
    ///   and index or I/O errors when persistence fails.
    public func register(_ record: RecordingSessionRecord) async throws {
        try ensureWritable()
        guard record.id == sessionID else { throw RecordingSessionLedgerError.sessionMismatch }
        if let existing = state.record {
            guard existing.id == record.id, existing.kind == record.kind, existing.layout == record.layout else {
                throw RecordingSessionLedgerError.idempotencyConflict
            }
            try persistIndex()
            return
        }
        try append(.registered(record))
        try persistIndex()
    }

    /// Journals one durable checkpoint and mirrors it into the index.
    ///
    /// Each track file is hashed and stored relative to the session root, and the
    /// checkpoint's segment identity is fixed the first time its index is seen.
    /// Re-committing the same checkpoint is idempotent; a different checkpoint with
    /// the same identity or a competing segment identity is rejected.
    ///
    /// - Parameter checkpoint: The committed checkpoint to journal.
    /// - Throws: `RecordingSessionLedgerError.invalidCheckpoint` for an empty range
    ///   or missing tracks, `.missingSession` when no session is registered,
    ///   `.idempotencyConflict` for conflicting identity, `.readOnly` when the
    ///   ledger cannot write, and path or I/O errors for unusable media.
    public func commit(_ checkpoint: CheckpointCommit) async throws {
        try ensureWritable()
        guard checkpoint.segmentIndex >= 0, checkpoint.range.startSample >= 0,
            checkpoint.range.sampleCount > 0, !checkpoint.trackURLs.isEmpty
        else { throw RecordingSessionLedgerError.invalidCheckpoint }
        guard state.record != nil else { throw RecordingSessionLedgerError.missingSession }

        let segmentID = state.segmentIDs[checkpoint.segmentIndex] ?? UUID()
        var files: [String: LedgerTrackFile] = [:]
        for (role, url) in checkpoint.trackURLs {
            let roleName = Self.roleName(role)
            guard files[roleName] == nil else { throw RecordingSessionLedgerError.invalidCheckpoint }
            do {
                let relative = try RecordingLedgerFileSystem.validateChild(url, under: sessionRoot)
                guard RecordingLedgerFileSystem.isRegularFile(url) else {
                    throw RecordingSessionLedgerError.invalidCheckpoint
                }
                files[roleName] = LedgerTrackFile(
                    relativePath: relative,
                    sha256: try RecordingLedgerFileSystem.sha256(of: url)
                )
            } catch { throw Self.mapPathError(error) }
        }
        let entry = LedgerCheckpoint(
            checkpointID: checkpoint.checkpointID,
            segmentID: segmentID,
            segmentIndex: checkpoint.segmentIndex,
            range: RecordingSampleRange(
                startSample: checkpoint.range.startSample,
                sampleCount: checkpoint.range.sampleCount
            ),
            files: files,
            committedAt: checkpoint.committedAt
        )
        if let existing = state.checkpoints[checkpoint.checkpointID] {
            guard existing == entry else { throw RecordingSessionLedgerError.idempotencyConflict }
            try persistIndex()
            return
        }
        if let prior = state.segmentIDs[checkpoint.segmentIndex], prior != segmentID {
            throw RecordingSessionLedgerError.idempotencyConflict
        }
        try append(.committed(entry))
        try persistIndex()
    }

    /// Journals a durable screen-video checkpoint after its media files are synced.
    public func commitScreenCheckpoint(_ checkpoint: ScreenCheckpointRecord) async throws {
        try ensureWritable()
        guard state.record != nil,
            checkpoint.segmentIndex >= 0,
            checkpoint.chunkIndex >= 0,
            checkpoint.videoRange.startSample >= 0,
            checkpoint.videoRange.sampleCount > 0,
            checkpoint.coverage.segmentIndex == checkpoint.segmentIndex,
            checkpoint.coverage.segmentEndSample > checkpoint.coverage.segmentStartSample,
            !checkpoint.contentHashes.isEmpty
        else { throw RecordingSessionLedgerError.invalidCheckpoint }

        try validateScreenCheckpoint(checkpoint, allowMissing: false)
        if let existing = state.screenCheckpoints[checkpoint.segmentIndex]?[checkpoint.chunkIndex] {
            guard existing == checkpoint else { throw RecordingSessionLedgerError.idempotencyConflict }
            return
        }
        try append(.committedScreen(checkpoint))
        try persistIndex()
    }

    /// Reads screen checkpoints for this session in segment/chunk order.
    public func screenCheckpoints(sessionID requestedSessionID: UUID) async throws -> [ScreenCheckpointRecord] {
        guard requestedSessionID == sessionID else { throw RecordingSessionLedgerError.sessionMismatch }
        return state.screenCheckpoints.keys.sorted().flatMap { segmentIndex in
            (state.screenCheckpoints[segmentIndex] ?? [:]).keys.sorted().compactMap {
                state.screenCheckpoints[segmentIndex]?[$0]
            }
        }
    }

    /// Projects the current session record from journaled state.
    ///
    /// - Returns: The session record with every discovered segment.
    /// - Throws: `RecordingSessionLedgerError.missingSession` when no record is
    ///   journaled, and `.unsupportedSchema` when a newer journal has no cached
    ///   record to fall back to.
    public func snapshot() async throws -> RecordingSessionRecord {
        try currentRecord()
    }

    /// Creates a preview service bound to this ledger.
    ///
    /// - Returns: A service that issues preview leases over this ledger's media.
    public func makePreviewService() -> RecordingPreviewService {
        RecordingPreviewService(ledger: self, fileManager: fileManager, now: now)
    }

    // MARK: Shared plumbing

    func ensureWritable() throws {
        guard !readOnly, !state.requiresNewerVersion else { throw RecordingSessionLedgerError.readOnly }
    }

    static func mapPathError(_ error: any Error) -> RecordingSessionLedgerError {
        if let ledger = error as? RecordingSessionLedgerError { return ledger }
        return switch error as? RecordingLedgerFileError {
        case .invalidPath: .invalidPath
        case .pathEscapesRoot: .pathEscapesRoot
        case .symbolicLink: .symbolicLink
        case .hashMismatch: .journalCorrupt
        case .unexpectedFileType, .ioFailure, nil: .ioFailure
        }
    }
}
