import CryptoKit
import Darwin
import Foundation

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

private struct LedgerTrackFile: Codable, Sendable, Hashable {
    let relativePath: String
    let sha256: String
}

private struct LedgerCheckpoint: Codable, Sendable, Hashable {
    let checkpointID: UUID
    let segmentID: UUID
    let segmentIndex: Int
    let range: RecordingSampleRange
    let files: [String: LedgerTrackFile]
    let committedAt: Date
}

private struct LedgerClosedSegment: Codable, Sendable, Hashable {
    let segmentID: UUID
    let coverage: RecordingSegmentCoverage
}

private struct LedgerJournalPayload: Codable, Sendable, Hashable {
    let kind: String
    let record: RecordingSessionRecord?
    let checkpoint: LedgerCheckpoint?
    let screenCheckpoint: ScreenCheckpointRecord?
    let intent: RecordingPublishIntent?
    let published: PublishedSegment?
    let closed: LedgerClosedSegment?

    static func registered(_ record: RecordingSessionRecord) -> Self {
        Self(kind: "register", record: record, checkpoint: nil, screenCheckpoint: nil, intent: nil, published: nil, closed: nil)
    }

    static func committed(_ checkpoint: LedgerCheckpoint) -> Self {
        Self(kind: "checkpoint", record: nil, checkpoint: checkpoint, screenCheckpoint: nil, intent: nil, published: nil, closed: nil)
    }

    static func committedScreen(_ checkpoint: ScreenCheckpointRecord) -> Self {
        Self(kind: "screenCheckpoint", record: nil, checkpoint: nil, screenCheckpoint: checkpoint, intent: nil, published: nil, closed: nil)
    }

    static func publishIntent(_ intent: RecordingPublishIntent) -> Self {
        Self(kind: "publishIntent", record: nil, checkpoint: nil, screenCheckpoint: nil, intent: intent, published: nil, closed: nil)
    }

    static func published(_ segment: PublishedSegment) -> Self {
        Self(kind: "published", record: nil, checkpoint: nil, screenCheckpoint: nil, intent: nil, published: segment, closed: nil)
    }

    static func closed(_ segment: LedgerClosedSegment) -> Self {
        Self(kind: "segmentClosed", record: nil, checkpoint: nil, screenCheckpoint: nil, intent: nil, published: nil, closed: segment)
    }
}

private struct LedgerJournalCore: Codable, Sendable, Hashable {
    let schemaVersion: Int
    let sequence: UInt64
    let previousHash: String
    let payload: LedgerJournalPayload
}

private struct LedgerJournalLine: Codable, Sendable, Hashable {
    let core: LedgerJournalCore
    let hash: String
}

private struct LedgerState {
    var record: RecordingSessionRecord?
    var checkpoints: [UUID: LedgerCheckpoint] = [:]
    var screenCheckpoints: [Int: [Int: ScreenCheckpointRecord]] = [:]
    var segmentIDs: [Int: UUID] = [:]
    var intents: [UUID: RecordingPublishIntent] = [:]
    var closed: [Int: LedgerClosedSegment] = [:]
    var published: [UUID: PublishedSegment] = [:]
    var sequence: UInt64 = 0
    var lastHash = String(repeating: "0", count: 64)
    var requiresNewerVersion = false
    var cachedRecord: RecordingSessionRecord?
}

/// Durable, hash-chained journal for one recording session. The index is only a cache.
public actor RecordingSessionLedger {
    public nonisolated let sessionID: UUID
    public nonisolated let sessionRoot: URL

    private let indexURL: URL
    private let fileManager: RecordingSendableFileManager
    private let now: @Sendable () -> Date
    private let readOnly: Bool
    private var state = LedgerState()
    private var leases: [UUID: PreviewLease] = [:]

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
            }
            catch { throw Self.mapPathError(error) }
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

    private init(
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
            }
            catch { throw Self.mapPathError(error) }
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
            do { root = try RecordingLedgerFileSystem.canonicalDirectory(sessionRoot, create: false) }
            catch { throw mapPathError(error) }
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
        do { try RecordingLedgerFileSystem.validateNoSymlink(index, allowingMissing: true) }
        catch { throw mapPathError(error) }
        return (root, index)
    }

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

    public func recordPublishIntent(_ intent: RecordingPublishIntent) async throws {
        try ensureWritable()
        guard state.record != nil else { throw RecordingSessionLedgerError.missingSession }
        try validate(intent)
        if let existing = state.intents[intent.segmentID] {
            guard existing == intent else { throw RecordingSessionLedgerError.idempotencyConflict }
            try persistIndex()
            return
        }
        if let existing = state.intents.values.first(where: { $0.segmentIndex == intent.segmentIndex }),
           existing.segmentID != intent.segmentID {
            throw RecordingSessionLedgerError.idempotencyConflict
        }
        try append(.publishIntent(intent))
        try persistIndex()
    }

    public func markPublished(_ segment: PublishedSegment) async throws {
        try ensureWritable()
        guard let intent = state.intents[segment.id] else {
            throw RecordingSessionLedgerError.missingPublishIntent
        }
        try validate(segment, against: intent)
        if let existing = state.published[segment.id] {
            guard existing == segment else { throw RecordingSessionLedgerError.idempotencyConflict }
            try persistIndex()
            return
        }
        try append(.published(segment))
        try persistIndex()
    }

    public func rebuildIndex() async throws {
        try ensureWritable()
        let entries = try await Self.allEntries(
            in: recordingRoot, indexURL: indexURL, fileManager: fileManager
        )
        try persistIndex(replacingAll: entries)
    }

    public func snapshot() async throws -> RecordingSessionRecord {
        try currentRecord()
    }

    public func makePreviewService() -> RecordingPreviewService {
        RecordingPreviewService(ledger: self, fileManager: fileManager, now: now)
    }

    public static func openExisting(
        sessionID: UUID,
        recordingRoot: URL,
        indexURL: URL,
        fileManager: FileManager = .default
    ) async throws -> RecordingSessionLedger {
        let root: URL
        do { root = try RecordingLedgerFileSystem.canonicalDirectory(recordingRoot, create: false) }
        catch { throw mapPathError(error) }
        let relative = ".SnapGlassSessions/\(sessionID.uuidString.lowercased())"
        let sessionRoot: URL
        do { sessionRoot = try RecordingLedgerFileSystem.resolve(relative, under: root) }
        catch { throw mapPathError(error) }
        let cached = try cachedRecord(sessionID: sessionID, indexURL: indexURL, fileManager: fileManager)
        do {
            return try RecordingSessionLedger(
                sessionRoot: sessionRoot,
                indexURL: indexURL,
                sessionID: sessionID,
                fileManager: RecordingSendableFileManager(fileManager),
                now: { Date() },
                readOnly: true,
                cachedRecord: cached
            )
        } catch { throw error }
    }

    public static func publishedSessions(
        in recordingRoot: URL,
        indexURL: URL,
        fileManager: FileManager = .default
    ) async throws -> [RecordingSessionRecord] {
        let entries = try await allEntries(
            in: recordingRoot, indexURL: indexURL, fileManager: RecordingSendableFileManager(fileManager)
        )
        return entries.map(\.record).filter { $0.segments.contains(where: { $0.state == .published || $0.state == .missing }) }
    }

    public static func recoverableSessions(
        in recordingRoot: URL,
        indexURL: URL,
        fileManager: FileManager = .default
    ) async throws -> [RecoverableSession] {
        let entries = try await allEntries(
            in: recordingRoot, indexURL: indexURL, fileManager: RecordingSendableFileManager(fileManager)
        )
        var recoverable: [RecoverableSession] = []
        for entry in entries {
            let sessionRoot = try RecordingLedgerFileSystem.resolve(entry.sessionRootRelativePath, under: recordingRoot)
            let ledger = try RecordingSessionLedger(
                sessionRoot: sessionRoot, indexURL: indexURL, sessionID: entry.sessionID,
                fileManager: RecordingSendableFileManager(fileManager),
                now: { Date() }, readOnly: true, cachedRecord: entry.record
            )
            let details = await ledger.recoveryDetails()
            recoverable.append(contentsOf: details)
        }
        return recoverable.sorted {
            $0.sessionID == $1.sessionID ? $0.segmentIndex < $1.segmentIndex : $0.sessionID.uuidString < $1.sessionID.uuidString
        }
    }

    // MARK: Pipeline/preview support

    func recordClosedSegment(_ bundle: RecordingSegmentCheckpointBundle) async throws {
        try ensureWritable()
        let index = bundle.checkpoints.segmentIndex
        guard index >= 0, bundle.coverage.segmentIndex == index,
              bundle.coverage.segmentEndSample > bundle.coverage.segmentStartSample,
              bundle.checkpoints.checkpoints.allSatisfy({ $0.segmentIndex == index })
        else { throw RecordingSessionLedgerError.invalidCheckpoint }
        let segmentID = state.segmentIDs[index] ?? UUID()
        let closed = LedgerClosedSegment(segmentID: segmentID, coverage: bundle.coverage)
        if let existing = state.closed[index] {
            guard existing == closed else { throw RecordingSessionLedgerError.idempotencyConflict }
            return
        }
        try append(.closed(closed))
        try persistIndex()
    }

    func segmentID(for index: Int) -> UUID {
        state.segmentIDs[index] ?? state.closed[index]?.segmentID ?? UUID()
    }

    func publishIntent(segmentID: UUID) throws -> RecordingPublishIntent {
        guard let intent = state.intents[segmentID] else { throw RecordingSessionLedgerError.missingPublishIntent }
        return intent
    }

    func segmentPublicationCandidate(segmentID: UUID) async throws -> SegmentPublicationCandidate {
        let intent = try publishIntent(segmentID: segmentID)
        let productURL = fileManager.value.fileExists(atPath: intent.stagingURL.path)
            ? intent.stagingURL
            : intent.reservedFinalURL
        let record: SegmentPortableRecord
        if intent.isDirectory {
            let manifestURL = productURL.appendingPathComponent("manifest.json")
            guard RecordingLedgerFileSystem.isRegularFile(manifestURL) else {
                throw RecordingSessionLedgerError.invalidPublication
            }
            do { record = try JSONDecoder().decode(SegmentPortableRecord.self, from: Data(contentsOf: manifestURL)) }
            catch { throw RecordingSessionLedgerError.invalidPublication }
        } else {
            do { record = try await RecordingPortableMetadata.read(from: productURL) }
            catch { throw RecordingSessionLedgerError.invalidPublication }
        }
        guard record.segmentID == intent.segmentID, record.segmentIndex == intent.segmentIndex,
              record.startSample == intent.effectiveRange.startSample,
              record.sampleCount == intent.effectiveRange.sampleCount
        else { throw RecordingSessionLedgerError.invalidPublication }
        let files = Dictionary(uniqueKeysWithValues: try record.tracks.map { track -> (RecordingTrackRole, URL) in
            guard let role = Self.role(from: track.role) else { throw RecordingSessionLedgerError.invalidPublication }
            let url = intent.isDirectory
                ? intent.stagingURL.appendingPathComponent(track.fileName)
                : intent.stagingURL
            return (role, url)
        })
        return SegmentPublicationCandidate(
            segmentID: intent.segmentID,
            segmentIndex: intent.segmentIndex,
            stagingURL: intent.stagingURL,
            reservedFinalURL: intent.reservedFinalURL,
            isDirectory: intent.isDirectory,
            stagedFileURLs: files,
            contentHashes: intent.contentHashes,
            manifestURL: intent.isDirectory ? intent.stagingURL.appendingPathComponent("manifest.json") : nil,
            effectiveRange: intent.effectiveRange,
            coverage: intent.coverage
        )
    }

    func addLease(_ lease: PreviewLease) {
        leases[lease.id] = lease
    }

    func removeLease(_ lease: PreviewLease) {
        leases[lease.id] = nil
    }

    func previewURLs(for target: PreviewTarget) throws -> (UUID, [URL]) {
        switch target {
        case .checkpoint(let checkpointID):
            guard let checkpoint = state.checkpoints[checkpointID],
                  state.closed[checkpoint.segmentIndex] != nil
            else { throw RecordingPreviewError.notPreviewable }
            let urls = try checkpoint.files.values.map { item -> URL in
                let url = try RecordingLedgerFileSystem.resolve(item.relativePath, under: sessionRoot)
                guard RecordingLedgerFileSystem.isRegularFile(url),
                      try RecordingLedgerFileSystem.sha256(of: url) == item.sha256
                else { throw RecordingPreviewError.materialUnavailable }
                return url
            }
            return (checkpoint.segmentID, urls)
        case .segment(let segmentID):
            guard let segment = state.published[segmentID],
                  let intent = state.intents[segmentID]
            else { throw RecordingPreviewError.notPreviewable }
            let outputRoot = intent.reservedFinalURL.deletingLastPathComponent()
            let urls = try segment.files.values.map { relative -> URL in
                let url = try RecordingLedgerFileSystem.resolve(relative, under: outputRoot)
                guard RecordingLedgerFileSystem.isRegularFile(url) else {
                    throw RecordingPreviewError.materialUnavailable
                }
                return url
            }
            guard !urls.isEmpty else { throw RecordingPreviewError.notPreviewable }
            return (segmentID, urls)
        }
    }

    func collectableCheckpointFiles(now date: Date) throws -> [URL] {
        let activeLeases = leases.values.filter { $0.expiresAt > date }
        leases = Dictionary(uniqueKeysWithValues: activeLeases.map { ($0.id, $0) })
        let leasedPaths = Set(activeLeases.flatMap { $0.mediaURLs.map(\.standardizedFileURL.path) })
        var removed: [URL] = []
        for checkpoint in state.checkpoints.values where state.published[checkpoint.segmentID] != nil {
            for item in checkpoint.files.values {
                let url: URL
                do { url = try RecordingLedgerFileSystem.resolve(item.relativePath, under: sessionRoot, allowingMissing: true) }
                catch { throw Self.mapPathError(error) }
                guard !leasedPaths.contains(url.standardizedFileURL.path),
                      RecordingLedgerFileSystem.isRegularFile(url),
                      (try? RecordingLedgerFileSystem.sha256(of: url)) == item.sha256
                else { continue }
                do {
                    try fileManager.value.removeItem(at: url)
                    removed.append(url)
                    let sidecar = url.deletingLastPathComponent()
                        .appendingPathComponent("checkpoint-\(checkpoint.checkpointID.uuidString.lowercased()).json")
                    if RecordingLedgerFileSystem.isRegularFile(sidecar) {
                        try fileManager.value.removeItem(at: sidecar)
                        removed.append(sidecar)
                    }
                    try RecordingLedgerFileSystem.syncDirectory(url.deletingLastPathComponent())
                } catch { throw RecordingSessionLedgerError.ioFailure }
            }
        }
        return removed
    }

    func progressFacts() -> (sampleEnd: Int64, committedAt: Date?, publishedCount: Int) {
        let end = state.checkpoints.values.map(\.range.endSample).max() ?? 0
        let committedAt = state.checkpoints.values.map(\.committedAt).max()
        let publishedCount = state.published.values.filter { isPublishedProductValid($0) }.count
        return (end, committedAt, publishedCount)
    }

    func recoveryDetails() -> [RecoverableSession] {
        guard let record = try? currentRecord() else { return [] }
        let indexes = Set(state.checkpoints.values.map(\.segmentIndex))
            .union(state.intents.values.map(\.segmentIndex))
            .union(state.closed.keys)
        return indexes.sorted().compactMap { index in
            let segment = record.segments.first(where: { $0.index == index })
            guard segment?.state != .published else { return nil }
            let count = state.checkpoints.values
                .filter { $0.segmentIndex == index }
                .map(\.range.endSample).max() ?? 0
            let start = state.checkpoints.values
                .filter { $0.segmentIndex == index }
                .map(\.range.startSample).min() ?? 0
            let seconds = max(0, Double(count - start) / 48_000)
            return RecoverableSession(
                sessionID: sessionID,
                segmentIndex: index,
                estimatedSeconds: seconds,
                state: segment?.state ?? .failedRecoverable
            )
        }
    }

    // MARK: Journal

    private func append(_ payload: LedgerJournalPayload) throws {
        try ensureWritable()
        let core = LedgerJournalCore(
            schemaVersion: 1,
            sequence: state.sequence + 1,
            previousHash: state.lastHash,
            payload: payload
        )
        let coreData = try Self.encode(core)
        let hash = Self.hash(coreData)
        let lineData = try Self.encode(LedgerJournalLine(core: core, hash: hash)) + Data([0x0A])
        do {
            if !fileManager.value.fileExists(atPath: sessionRoot.path) {
                try fileManager.value.createDirectory(
                    at: sessionRoot, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            try RecordingLedgerFileSystem.validateNoSymlink(sessionRoot)
            let journal = sessionRoot.appendingPathComponent("journal.ndjson")
            let fd = journal.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else { return -1 }
                return Darwin.open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
            }
            guard fd >= 0 else { throw RecordingSessionLedgerError.ioFailure }
            var writeError = false
            lineData.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { writeError = true; return }
                var remaining = rawBuffer.count
                var cursor = base
                while remaining > 0 {
                    let written = Darwin.write(fd, cursor, remaining)
                    if written < 0 {
                        if errno == EINTR { continue }
                        writeError = true
                        break
                    }
                    guard written > 0 else { writeError = true; break }
                    remaining -= written
                    cursor = cursor.advanced(by: written)
                }
            }
            if writeError || Darwin.fsync(fd) != 0 {
                _ = Darwin.close(fd)
                try? reloadJournal()
                throw RecordingSessionLedgerError.ioFailure
            }
            guard Darwin.close(fd) == 0 else {
                try? reloadJournal()
                throw RecordingSessionLedgerError.ioFailure
            }
            try RecordingLedgerFileSystem.syncDirectory(sessionRoot)
            try apply(payload, replay: false)
            state.sequence = core.sequence
            state.lastHash = hash
        } catch {
            if let error = error as? RecordingSessionLedgerError { throw error }
            try? reloadJournal()
            throw Self.mapPathError(error)
        }
    }

    private static func loadJournal(
        at journal: URL,
        sessionRoot: URL,
        sessionID: UUID,
        fileManager: FileManager,
        cachedRecord: RecordingSessionRecord?
    ) throws -> LedgerState {
        do { try RecordingLedgerFileSystem.validateNoSymlink(journal) }
        catch { throw mapPathError(error) }
        guard RecordingLedgerFileSystem.isRegularFile(journal) else {
            throw RecordingSessionLedgerError.journalCorrupt
        }
        let data: Data
        do { data = try Data(contentsOf: journal) } catch { throw RecordingSessionLedgerError.ioFailure }
        guard data.isEmpty || data.last == 0x0A else { throw RecordingSessionLedgerError.journalCorrupt }
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        var loaded = LedgerState(cachedRecord: cachedRecord)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for bytes in lines {
            let lineData = Data(bytes)
            let schema: Int
            do {
                guard let object = try JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let core = object["core"] as? [String: Any],
                      let value = core["schemaVersion"] as? Int
                else { throw RecordingSessionLedgerError.journalCorrupt }
                schema = value
            } catch { throw RecordingSessionLedgerError.journalCorrupt }
            if schema > 1 {
                loaded.requiresNewerVersion = true
                return loaded
            }
            guard schema == 1 else { throw RecordingSessionLedgerError.journalCorrupt }
            let line: LedgerJournalLine
            do { line = try JSONDecoder().decode(LedgerJournalLine.self, from: lineData) }
            catch { throw RecordingSessionLedgerError.journalCorrupt }
            let encodedCore: Data
            do { encodedCore = try encoder.encode(line.core) } catch { throw RecordingSessionLedgerError.journalCorrupt }
            guard line.core.sequence == loaded.sequence + 1,
                  line.core.previousHash == loaded.lastHash,
                  Self.hash(encodedCore) == line.hash
            else { throw RecordingSessionLedgerError.journalCorrupt }
            try Self.apply(
                line.core.payload, to: &loaded, root: sessionRoot,
                sessionID: sessionID, fileManager: fileManager, replay: true
            )
            loaded.sequence = line.core.sequence
            loaded.lastHash = line.hash
        }
        return loaded
    }

    private func reloadJournal() throws {
        let cachedRecord = state.cachedRecord
        state = LedgerState(cachedRecord: cachedRecord)
        let journal = sessionRoot.appendingPathComponent("journal.ndjson")
        if fileManager.value.fileExists(atPath: journal.path) {
            state = try Self.loadJournal(
                at: journal, sessionRoot: sessionRoot, sessionID: sessionID,
                fileManager: fileManager.value, cachedRecord: cachedRecord
            )
        }
    }

    private func apply(_ payload: LedgerJournalPayload, replay: Bool) throws {
        try Self.apply(
            payload, to: &state, root: sessionRoot, sessionID: sessionID,
            fileManager: fileManager.value, replay: replay
        )
    }

    private static func apply(
        _ payload: LedgerJournalPayload,
        to state: inout LedgerState,
        root: URL,
        sessionID: UUID,
        fileManager: FileManager,
        replay: Bool
    ) throws {
        switch payload.kind {
        case "register":
            guard let record = payload.record, record.id == sessionID,
                  payload.checkpoint == nil, payload.intent == nil, payload.published == nil, payload.closed == nil
            else { throw RecordingSessionLedgerError.journalCorrupt }
            if let prior = state.record {
                guard prior.id == record.id, prior.kind == record.kind, prior.layout == record.layout else {
                    throw RecordingSessionLedgerError.journalCorrupt
                }
            } else {
                state.record = record
            }
        case "checkpoint":
            guard let checkpoint = payload.checkpoint, payload.record == nil, payload.intent == nil,
                  payload.published == nil, payload.closed == nil, checkpoint.segmentIndex >= 0,
                  checkpoint.range.startSample >= 0, checkpoint.range.sampleCount > 0,
                  !checkpoint.files.isEmpty
            else { throw RecordingSessionLedgerError.journalCorrupt }
            if let prior = state.checkpoints[checkpoint.checkpointID] {
                guard prior == checkpoint else { throw RecordingSessionLedgerError.journalCorrupt }
                return
            }
            if let prior = state.segmentIDs[checkpoint.segmentIndex], prior != checkpoint.segmentID {
                throw RecordingSessionLedgerError.journalCorrupt
            }
            for file in checkpoint.files.values {
                let url = try RecordingLedgerFileSystem.resolve(file.relativePath, under: root, allowingMissing: true)
                if RecordingLedgerFileSystem.isRegularFile(url) {
                    guard try RecordingLedgerFileSystem.sha256(of: url) == file.sha256 else {
                        throw RecordingSessionLedgerError.journalCorrupt
                    }
                }
            }
            state.segmentIDs[checkpoint.segmentIndex] = checkpoint.segmentID
            state.checkpoints[checkpoint.checkpointID] = checkpoint
        case "screenCheckpoint":
            guard let checkpoint = payload.screenCheckpoint,
                  payload.record == nil, payload.checkpoint == nil,
                  payload.intent == nil, payload.published == nil, payload.closed == nil,
                  checkpoint.segmentIndex >= 0, checkpoint.chunkIndex >= 0,
                  checkpoint.videoRange.startSample >= 0, checkpoint.videoRange.sampleCount > 0,
                  checkpoint.coverage.segmentIndex == checkpoint.segmentIndex,
                  checkpoint.coverage.segmentEndSample > checkpoint.coverage.segmentStartSample,
                  !checkpoint.contentHashes.isEmpty
            else { throw RecordingSessionLedgerError.journalCorrupt }
            try validateScreenCheckpoint(
                checkpoint, root: root, fileManager: fileManager, allowMissing: replay
            )
            var chunks = state.screenCheckpoints[checkpoint.segmentIndex] ?? [:]
            if let prior = chunks[checkpoint.chunkIndex], prior != checkpoint {
                throw RecordingSessionLedgerError.journalCorrupt
            }
            chunks[checkpoint.chunkIndex] = checkpoint
            state.screenCheckpoints[checkpoint.segmentIndex] = chunks
        case "publishIntent":
            guard let intent = payload.intent, payload.record == nil, payload.checkpoint == nil,
                  payload.published == nil, payload.closed == nil
            else { throw RecordingSessionLedgerError.journalCorrupt }
            try validateIntent(intent, fileManager: fileManager, replay: replay)
            if let prior = state.intents[intent.segmentID], prior != intent {
                throw RecordingSessionLedgerError.journalCorrupt
            }
            state.intents[intent.segmentID] = intent
            state.segmentIDs[intent.segmentIndex] = intent.segmentID
        case "published":
            guard let segment = payload.published, payload.record == nil, payload.checkpoint == nil,
                  payload.intent == nil, payload.closed == nil,
                  let intent = state.intents[segment.id]
            else { throw RecordingSessionLedgerError.journalCorrupt }
            try validatePublishedSegment(
                segment, against: intent, verifyFiles: true, allowMissingFiles: replay
            )
            if let prior = state.published[segment.id], prior != segment {
                throw RecordingSessionLedgerError.journalCorrupt
            }
            state.published[segment.id] = segment
        case "segmentClosed":
            guard let closed = payload.closed, payload.record == nil, payload.checkpoint == nil,
                  payload.intent == nil, payload.published == nil,
                  closed.coverage.segmentIndex >= 0,
                  closed.coverage.segmentEndSample > closed.coverage.segmentStartSample
            else { throw RecordingSessionLedgerError.journalCorrupt }
            let index = closed.coverage.segmentIndex
            if let prior = state.closed[index], prior != closed {
                throw RecordingSessionLedgerError.journalCorrupt
            }
            if let prior = state.segmentIDs[index], prior != closed.segmentID {
                throw RecordingSessionLedgerError.journalCorrupt
            }
            state.segmentIDs[index] = closed.segmentID
            state.closed[index] = closed
        default:
            throw RecordingSessionLedgerError.journalCorrupt
        }
    }

    // MARK: Index and record projections

    private var recordingRoot: URL {
        if sessionRoot.deletingLastPathComponent().lastPathComponent == ".SnapGlassSessions" {
            return sessionRoot.deletingLastPathComponent().deletingLastPathComponent()
        }
        return sessionRoot.deletingLastPathComponent()
    }

    private func currentRecord() throws -> RecordingSessionRecord {
        if state.requiresNewerVersion {
            guard let cached = state.cachedRecord else { throw RecordingSessionLedgerError.unsupportedSchema(2) }
            let segments = cached.segments.map { segment in
                PublishedSegment(
                    id: segment.id, index: segment.index, files: segment.files,
                    startSample: segment.startSample, sampleCount: segment.sampleCount,
                    trackMap: segment.trackMap, missingRanges: segment.missingRanges,
                    state: .requiresNewerVersion, videoURL: segment.videoURL,
                    videoTrackIndex: segment.videoTrackIndex
                )
            }
            return RecordingSessionRecord(
                id: cached.id, kind: cached.kind, layout: cached.layout,
                startedAt: cached.startedAt, segments: segments
            )
        }
        guard let base = state.record else { throw RecordingSessionLedgerError.missingSession }
        let indices = Set(state.segmentIDs.keys)
            .union(state.checkpoints.values.map(\.segmentIndex))
            .union(state.intents.values.map(\.segmentIndex))
            .union(state.closed.keys)
            .union(state.published.values.map(\.index))
        var segments: [PublishedSegment] = []
        for index in indices.sorted() {
            guard let id = state.segmentIDs[index] ?? state.closed[index]?.segmentID else { continue }
            let checkpoints = state.checkpoints.values.filter { $0.segmentIndex == index }
            let start = state.closed[index]?.coverage.segmentStartSample
                ?? checkpoints.map(\.range.startSample).min() ?? 0
            let end = state.closed[index]?.coverage.segmentEndSample
                ?? checkpoints.map(\.range.endSample).max() ?? start
            let intent = state.intents[id]
            let published = state.published[id]
            let stateValue: PublishedSegmentState
            if let published {
                stateValue = isPublishedProductValid(published) ? .published : .missing
            } else if let intent {
                stateValue = isIntentRecoverable(intent) ? .publishing : .failedRecoverable
            } else {
                stateValue = .recording
            }
            let coverage = state.closed[index]?.coverage ?? intent?.coverage
            segments.append(PublishedSegment(
                id: id,
                index: index,
                files: published?.files ?? [:],
                startSample: intent?.effectiveRange.startSample ?? start,
                sampleCount: intent?.effectiveRange.sampleCount ?? max(0, end - start),
                trackMap: published?.trackMap ?? [:],
                missingRanges: coverage?.tracks.flatMap(\.missingRanges) ?? [],
                state: stateValue,
                videoURL: published?.videoURL,
                videoTrackIndex: published?.videoTrackIndex
            ))
        }
        return RecordingSessionRecord(
            id: base.id, kind: base.kind, layout: base.layout,
            startedAt: base.startedAt, segments: segments
        )
    }

    private func isIntentRecoverable(_ intent: RecordingPublishIntent) -> Bool {
        do {
            let useFinal = !fileManager.value.fileExists(atPath: intent.stagingURL.path)
            let candidate = try candidateProductURLs(intent, useFinal: useFinal)
            for (name, expected) in intent.contentHashes {
                guard let url = candidate[name], RecordingLedgerFileSystem.isRegularFile(url),
                      try RecordingLedgerFileSystem.sha256(of: url) == expected
                else { return false }
            }
            return true
        } catch { return false }
    }

    private func isPublishedProductValid(_ segment: PublishedSegment) -> Bool {
        guard let intent = state.intents[segment.id] else { return false }
        return isFinalProductValid(intent)
    }

    private func isFinalProductValid(_ intent: RecordingPublishIntent) -> Bool {
        do {
            let urls: [String: URL]
            if intent.isDirectory {
                var values: [String: URL] = [:]
                for name in intent.contentHashes.keys {
                    values[name] = intent.reservedFinalURL.appendingPathComponent(name)
                }
                urls = values
            } else {
                urls = [intent.reservedFinalURL.lastPathComponent: intent.reservedFinalURL]
            }
            guard urls.count == intent.contentHashes.count else { return false }
            for (name, expected) in intent.contentHashes {
                guard let url = urls[name], RecordingLedgerFileSystem.isRegularFile(url),
                      try RecordingLedgerFileSystem.sha256(of: url) == expected
                else { return false }
            }
            return true
        } catch { return false }
    }

    private func candidateProductURLs(_ intent: RecordingPublishIntent, useFinal: Bool = false) throws -> [String: URL] {
        if intent.isDirectory {
            let product = useFinal ? intent.reservedFinalURL : intent.stagingURL
            return Dictionary(uniqueKeysWithValues: intent.contentHashes.keys.map {
                ($0, product.appendingPathComponent($0))
            })
        }
        return [intent.reservedFinalURL.lastPathComponent: useFinal ? intent.reservedFinalURL : intent.stagingURL]
    }

    private func persistIndex(replacingAll allEntries: [RecordingIndexRecord.Entry]? = nil) throws {
        let record = try currentRecord()
        let safeRoot = recordingRoot.standardizedFileURL
        let relative: String
        do { relative = try RecordingLedgerFileSystem.validateChild(sessionRoot, under: safeRoot) }
        catch { throw Self.mapPathError(error) }
        let currentEntry = RecordingIndexRecord.Entry(
            sessionID: sessionID, sessionRootRelativePath: relative, record: record
        )
        let lockURL = indexURL.appendingPathExtension("lock")
        let lockFD = lockURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        }
        guard lockFD >= 0 else { throw RecordingSessionLedgerError.ioFailure }
        var fileLock = Darwin.flock()
        fileLock.l_type = Int16(F_WRLCK)
        fileLock.l_whence = Int16(SEEK_SET)
        fileLock.l_start = 0
        fileLock.l_len = 0
        guard Darwin.fcntl(lockFD, F_SETLKW, &fileLock) == 0 else {
            _ = Darwin.close(lockFD)
            throw RecordingSessionLedgerError.ioFailure
        }
        defer {
            fileLock.l_type = Int16(F_UNLCK)
            _ = Darwin.fcntl(lockFD, F_SETLK, &fileLock)
            _ = Darwin.close(lockFD)
        }

        var entriesByID: [UUID: RecordingIndexRecord.Entry] = [:]
        if let allEntries {
            entriesByID = Dictionary(uniqueKeysWithValues: allEntries.map { ($0.sessionID, $0) })
        } else if fileManager.value.fileExists(atPath: indexURL.path) {
            do {
                try RecordingLedgerFileSystem.validateNoSymlink(indexURL)
                let cached = try JSONDecoder().decode(RecordingIndexRecord.self, from: Data(contentsOf: indexURL))
                guard cached.schemaVersion == RecordingIndexRecord.currentSchemaVersion else {
                    throw RecordingSessionLedgerError.indexCorrupt
                }
                entriesByID = Dictionary(uniqueKeysWithValues: cached.entries.map { ($0.sessionID, $0) })
            } catch let error as RecordingSessionLedgerError {
                throw error
            } catch {
                // A cache can be rebuilt from the registered session root; it is never journal authority.
                entriesByID = [:]
            }
        }
        entriesByID[sessionID] = currentEntry
        let index = RecordingIndexRecord(entries: entriesByID.values.sorted {
            $0.sessionID.uuidString < $1.sessionID.uuidString
        }, updatedAt: now())
        do { try RecordingLedgerFileSystem.atomicWrite(try Self.encode(index), to: indexURL) }
        catch { throw Self.mapPathError(error) }
    }

    private func ensureWritable() throws {
        guard !readOnly, !state.requiresNewerVersion else { throw RecordingSessionLedgerError.readOnly }
    }

    private func validateScreenCheckpoint(_ checkpoint: ScreenCheckpointRecord, allowMissing: Bool) throws {
        try Self.validateScreenCheckpoint(
            checkpoint, root: sessionRoot, fileManager: fileManager.value, allowMissing: allowMissing
        )
    }

    private static func validateScreenCheckpoint(
        _ checkpoint: ScreenCheckpointRecord,
        root: URL,
        fileManager: FileManager,
        allowMissing: Bool
    ) throws {
        do {
            let videoPath = try RecordingLedgerFileSystem.validateChild(
                checkpoint.videoURL, under: root, allowingMissing: allowMissing
            )
            guard let expectedVideoHash = checkpoint.contentHashes[videoPath],
                  expectedVideoHash.count == 64,
                  expectedVideoHash.allSatisfy(\.isHexDigit)
            else { throw RecordingSessionLedgerError.invalidCheckpoint }

            var referencedPaths: Set<String> = [videoPath]
            if let audio = checkpoint.audioCheckpoint {
                guard audio.segmentIndex == checkpoint.segmentIndex,
                      audio.startSample >= 0, audio.sampleCount > 0,
                      !audio.trackFiles.isEmpty
                else { throw RecordingSessionLedgerError.invalidCheckpoint }
                for path in audio.trackFiles.values {
                    try RecordingLedgerFileSystem.validateRelativePath(path)
                    let url = try RecordingLedgerFileSystem.resolve(path, under: root, allowingMissing: allowMissing)
                    let relative = try RecordingLedgerFileSystem.validateChild(
                        url, under: root, allowingMissing: allowMissing
                    )
                    referencedPaths.insert(relative)
                }
            }
            guard referencedPaths == Set(checkpoint.contentHashes.keys) else {
                throw RecordingSessionLedgerError.invalidCheckpoint
            }
            for (relativePath, expectedHash) in checkpoint.contentHashes {
                try RecordingLedgerFileSystem.validateRelativePath(relativePath)
                guard expectedHash.count == 64, expectedHash.allSatisfy(\.isHexDigit) else {
                    throw RecordingSessionLedgerError.invalidCheckpoint
                }
                let url = try RecordingLedgerFileSystem.resolve(
                    relativePath, under: root, allowingMissing: allowMissing
                )
                if RecordingLedgerFileSystem.isRegularFile(url) {
                    guard try RecordingLedgerFileSystem.sha256(of: url) == expectedHash else {
                        throw RecordingSessionLedgerError.journalCorrupt
                    }
                } else if !allowMissing || fileManager.fileExists(atPath: url.path) {
                    throw RecordingSessionLedgerError.invalidCheckpoint
                }
            }
        } catch let error as RecordingSessionLedgerError {
            throw error
        } catch {
            throw Self.mapPathError(error)
        }
    }

    // MARK: Validations

    private func validate(_ intent: RecordingPublishIntent) throws {
        try Self.validateIntent(intent, fileManager: fileManager.value, replay: false)
    }

    private static func validateIntent(
        _ intent: RecordingPublishIntent,
        fileManager: FileManager,
        replay: Bool
    ) throws {
        guard intent.segmentIndex >= 0, intent.effectiveRange.startSample >= 0,
              intent.effectiveRange.sampleCount > 0, intent.coverage.segmentIndex == intent.segmentIndex,
              intent.coverage.segmentStartSample == intent.effectiveRange.startSample,
              intent.coverage.segmentEndSample == intent.effectiveRange.endSample,
              !intent.contentHashes.isEmpty, intent.stagingURL.isFileURL, intent.reservedFinalURL.isFileURL,
              intent.stagingURL.standardizedFileURL.path != intent.reservedFinalURL.standardizedFileURL.path,
              intent.stagingURL.deletingLastPathComponent().standardizedFileURL
                == intent.reservedFinalURL.deletingLastPathComponent().standardizedFileURL
        else { throw RecordingSessionLedgerError.invalidPublication }
        do {
            try RecordingLedgerFileSystem.validateNoSymlink(intent.stagingURL.deletingLastPathComponent())
            try RecordingLedgerFileSystem.validateNoSymlink(intent.stagingURL, allowingMissing: replay)
            try RecordingLedgerFileSystem.validateNoSymlink(intent.reservedFinalURL, allowingMissing: true)
            for (name, hash) in intent.contentHashes {
                try RecordingLedgerFileSystem.validateRelativePath(name)
                guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else {
                    throw RecordingSessionLedgerError.invalidPublication
                }
            }
            guard intent.isDirectory || intent.contentHashes.count == 1,
                  intent.isDirectory || intent.contentHashes[intent.reservedFinalURL.lastPathComponent] != nil
            else { throw RecordingSessionLedgerError.invalidPublication }

            let stageExists = fileManager.fileExists(atPath: intent.stagingURL.path)
            let finalExists = fileManager.fileExists(atPath: intent.reservedFinalURL.path)
            if stageExists {
                try verifyIntentProduct(intent, at: intent.stagingURL, fileManager: fileManager)
            } else if !replay {
                throw RecordingSessionLedgerError.invalidPublication
            }
            if finalExists {
                try verifyIntentProduct(intent, at: intent.reservedFinalURL, fileManager: fileManager)
            } else if !replay && !stageExists {
                throw RecordingSessionLedgerError.invalidPublication
            }
        } catch { throw Self.mapPathError(error) }
    }

    private static func verifyIntentProduct(
        _ intent: RecordingPublishIntent,
        at productURL: URL,
        fileManager: FileManager
    ) throws {
        if intent.isDirectory {
            guard RecordingLedgerFileSystem.isDirectory(productURL) else {
                throw RecordingSessionLedgerError.invalidPublication
            }
            let visible = try fileManager.contentsOfDirectory(atPath: productURL.path)
                .filter { !$0.hasPrefix(".") }
            guard Set(visible) == Set(intent.contentHashes.keys) else {
                throw RecordingSessionLedgerError.invalidPublication
            }
            for (name, expected) in intent.contentHashes {
                let file = try RecordingLedgerFileSystem.resolve(name, under: productURL)
                guard RecordingLedgerFileSystem.isRegularFile(file),
                      try RecordingLedgerFileSystem.sha256(of: file) == expected
                else { throw RecordingSessionLedgerError.invalidPublication }
            }
        } else {
            guard RecordingLedgerFileSystem.isRegularFile(productURL),
                  let expected = intent.contentHashes[intent.reservedFinalURL.lastPathComponent],
                  try RecordingLedgerFileSystem.sha256(of: productURL) == expected
            else { throw RecordingSessionLedgerError.invalidPublication }
        }
    }

    private func validate(
        _ segment: PublishedSegment,
        against intent: RecordingPublishIntent,
        verifyFiles: Bool = true
    ) throws {
        try Self.validatePublishedSegment(segment, against: intent, verifyFiles: verifyFiles)
    }

    private static func validatePublishedSegment(
        _ segment: PublishedSegment,
        against intent: RecordingPublishIntent,
        verifyFiles: Bool = true,
        allowMissingFiles: Bool = false
    ) throws {
        guard segment.id == intent.segmentID, segment.index == intent.segmentIndex,
              segment.startSample == intent.effectiveRange.startSample,
              segment.sampleCount == intent.effectiveRange.sampleCount,
              segment.state == .published,
              (segment.videoURL != nil || !segment.files.isEmpty),
              Set(segment.files.keys).isSubset(of: ["mixed", "system", "microphone"]),
              Set(segment.trackMap.keys) == Set(segment.files.keys)
        else { throw RecordingSessionLedgerError.invalidPublication }
        if let videoURL = segment.videoURL {
            guard !intent.isDirectory,
                  videoURL.standardizedFileURL == intent.reservedFinalURL.standardizedFileURL,
                  let videoTrackIndex = segment.videoTrackIndex, videoTrackIndex >= 0,
                  segment.files.values.allSatisfy({
                      URL(fileURLWithPath: $0).lastPathComponent == videoURL.lastPathComponent
                  })
            else { throw RecordingSessionLedgerError.invalidPublication }
            if verifyFiles {
                let expectedHash = intent.contentHashes[intent.reservedFinalURL.lastPathComponent]
                guard let expectedHash else { throw RecordingSessionLedgerError.invalidPublication }
                let videoHashMatches: Bool
                if allowMissingFiles && !RecordingLedgerFileSystem.isRegularFile(videoURL) {
                    videoHashMatches = true
                } else {
                    videoHashMatches = try RecordingLedgerFileSystem.sha256(of: videoURL) == expectedHash
                }
                guard videoHashMatches else { throw RecordingSessionLedgerError.invalidPublication }
            }
        } else if segment.videoTrackIndex != nil {
            throw RecordingSessionLedgerError.invalidPublication
        }
        let outputRoot = intent.reservedFinalURL.deletingLastPathComponent()
        do {
            var seen: Set<String> = []
            for (role, relative) in segment.files {
                try RecordingLedgerFileSystem.validateRelativePath(relative)
                let resolved = try RecordingLedgerFileSystem.resolve(relative, under: outputRoot, allowingMissing: allowMissingFiles)
                let expected = intent.isDirectory
                    ? intent.reservedFinalURL.appendingPathComponent(URL(fileURLWithPath: relative).lastPathComponent)
                    : intent.reservedFinalURL
                guard resolved.standardizedFileURL == expected.standardizedFileURL,
                      seen.insert(relative).inserted
                else { throw RecordingSessionLedgerError.invalidPublication }
                if verifyFiles {
                    if RecordingLedgerFileSystem.isRegularFile(resolved) {
                        let expectedHash = intent.isDirectory
                            ? intent.contentHashes[resolved.lastPathComponent]
                            : intent.contentHashes[intent.reservedFinalURL.lastPathComponent]
                        guard let expectedHash, try RecordingLedgerFileSystem.sha256(of: resolved) == expectedHash else {
                            throw RecordingSessionLedgerError.invalidPublication
                        }
                    } else if !allowMissingFiles || RecordingLedgerFileSystem.mode(at: resolved) != nil {
                        throw RecordingSessionLedgerError.invalidPublication
                    }
                }
                _ = role
            }
        } catch { throw Self.mapPathError(error) }
    }

    // MARK: Scan/read helpers

    private static func allEntries(
        in recordingRoot: URL,
        indexURL: URL,
        fileManager: RecordingSendableFileManager
    ) async throws -> [RecordingIndexRecord.Entry] {
        let root: URL
        do { root = try RecordingLedgerFileSystem.canonicalDirectory(recordingRoot, create: false) }
        catch { throw mapPathError(error) }
        let sessionsDirectory = root.appendingPathComponent(".SnapGlassSessions", isDirectory: true)
        guard fileManager.value.fileExists(atPath: sessionsDirectory.path) else { return [] }
        do { try RecordingLedgerFileSystem.validateNoSymlink(sessionsDirectory) }
        catch { throw mapPathError(error) }
        guard RecordingLedgerFileSystem.isDirectory(sessionsDirectory) else {
            throw RecordingSessionLedgerError.invalidPath
        }
        let children: [URL]
        do {
            children = try fileManager.value.contentsOfDirectory(
                at: sessionsDirectory, includingPropertiesForKeys: nil
            )
        }
        catch { throw RecordingSessionLedgerError.ioFailure }
        var result: [RecordingIndexRecord.Entry] = []
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            do { try RecordingLedgerFileSystem.validateNoSymlink(child) }
            catch { throw mapPathError(error) }
            guard RecordingLedgerFileSystem.isDirectory(child),
                  let id = UUID(uuidString: child.lastPathComponent)
            else { continue }
            let cached = try cachedRecord(
                sessionID: id, indexURL: indexURL, fileManager: fileManager.value
            )
            let ledger: RecordingSessionLedger
            do {
                ledger = try RecordingSessionLedger(
                    sessionRoot: child,
                    indexURL: indexURL,
                    sessionID: id,
                    fileManager: fileManager,
                    now: { Date() },
                    readOnly: true,
                    cachedRecord: cached
                )
            } catch RecordingSessionLedgerError.missingSession {
                continue
            }
            let record = try await ledger.snapshot()
            let relative: String
            do { relative = try RecordingLedgerFileSystem.validateChild(child, under: root) }
            catch { throw mapPathError(error) }
            result.append(.init(sessionID: id, sessionRootRelativePath: relative, record: record))
        }
        return result
    }

    private static func cachedRecord(
        sessionID: UUID,
        indexURL: URL,
        fileManager: FileManager
    ) throws -> RecordingSessionRecord? {
        let parent = indexURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let canonicalIndex = parent.appendingPathComponent(indexURL.lastPathComponent).standardizedFileURL
        guard fileManager.fileExists(atPath: canonicalIndex.path) else { return nil }
        do {
            try RecordingLedgerFileSystem.validateNoSymlink(canonicalIndex)
            let index = try JSONDecoder().decode(RecordingIndexRecord.self, from: Data(contentsOf: canonicalIndex))
            guard index.schemaVersion <= RecordingIndexRecord.currentSchemaVersion else {
                return index.entries.first(where: { $0.sessionID == sessionID })?.record
            }
            return index.entries.first(where: { $0.sessionID == sessionID })?.record
        } catch { return nil }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do { return try encoder.encode(value) } catch { throw RecordingSessionLedgerError.ioFailure }
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func roleName(_ role: RecordingTrackRole) -> String {
        switch role {
        case .mixed: "mixed"
        case .system: "system"
        case .microphone: "microphone"
        }
    }

    private static func role(from name: String) -> RecordingTrackRole? {
        switch name {
        case "mixed": .mixed
        case "system": .system
        case "microphone": .microphone
        default: nil
        }
    }

    private static func mapPathError(_ error: any Error) -> RecordingSessionLedgerError {
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
