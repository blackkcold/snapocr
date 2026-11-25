import CryptoKit
import Darwin
import Foundation

// MARK: Journal wire format

struct LedgerTrackFile: Codable, Sendable, Hashable {
    let relativePath: String
    let sha256: String
}

struct LedgerCheckpoint: Codable, Sendable, Hashable {
    let checkpointID: UUID
    let segmentID: UUID
    let segmentIndex: Int
    let range: RecordingSampleRange
    let files: [String: LedgerTrackFile]
    let committedAt: Date
}

struct LedgerClosedSegment: Codable, Sendable, Hashable {
    let segmentID: UUID
    let coverage: RecordingSegmentCoverage
}

struct LedgerJournalPayload: Codable, Sendable, Hashable {
    let kind: String
    let record: RecordingSessionRecord?
    let checkpoint: LedgerCheckpoint?
    let screenCheckpoint: ScreenCheckpointRecord?
    let intent: RecordingPublishIntent?
    let published: PublishedSegment?
    let closed: LedgerClosedSegment?
    /// A segment adopted in place from an interrupted session.
    ///
    /// Added after the first shipping schema; optional so every line written
    /// before adoption still decodes with `adopted == nil`.
    let adopted: PublishedSegment?

    static func registered(_ record: RecordingSessionRecord) -> Self {
        Self(
            kind: "register", record: record, checkpoint: nil, screenCheckpoint: nil,
            intent: nil, published: nil, closed: nil, adopted: nil
        )
    }

    static func committed(_ checkpoint: LedgerCheckpoint) -> Self {
        Self(
            kind: "checkpoint", record: nil, checkpoint: checkpoint, screenCheckpoint: nil,
            intent: nil, published: nil, closed: nil, adopted: nil
        )
    }

    static func committedScreen(_ checkpoint: ScreenCheckpointRecord) -> Self {
        Self(
            kind: "screenCheckpoint", record: nil, checkpoint: nil, screenCheckpoint: checkpoint,
            intent: nil, published: nil, closed: nil, adopted: nil
        )
    }

    static func publishIntent(_ intent: RecordingPublishIntent) -> Self {
        Self(
            kind: "publishIntent", record: nil, checkpoint: nil, screenCheckpoint: nil,
            intent: intent, published: nil, closed: nil, adopted: nil
        )
    }

    static func published(_ segment: PublishedSegment) -> Self {
        Self(
            kind: "published", record: nil, checkpoint: nil, screenCheckpoint: nil,
            intent: nil, published: segment, closed: nil, adopted: nil
        )
    }

    static func closed(_ segment: LedgerClosedSegment) -> Self {
        Self(
            kind: "segmentClosed", record: nil, checkpoint: nil, screenCheckpoint: nil,
            intent: nil, published: nil, closed: segment, adopted: nil
        )
    }

    static func adopted(_ segment: PublishedSegment) -> Self {
        Self(
            kind: "adopted", record: nil, checkpoint: nil, screenCheckpoint: nil,
            intent: nil, published: nil, closed: nil, adopted: segment
        )
    }
}

struct LedgerJournalCore: Codable, Sendable, Hashable {
    let schemaVersion: Int
    let sequence: UInt64
    let previousHash: String
    let payload: LedgerJournalPayload
}

struct LedgerJournalLine: Codable, Sendable, Hashable {
    let core: LedgerJournalCore
    let hash: String
}

struct LedgerState {
    var record: RecordingSessionRecord?
    var checkpoints: [UUID: LedgerCheckpoint] = [:]
    var screenCheckpoints: [Int: [Int: ScreenCheckpointRecord]] = [:]
    var segmentIDs: [Int: UUID] = [:]
    var intents: [UUID: RecordingPublishIntent] = [:]
    var closed: [Int: LedgerClosedSegment] = [:]
    var published: [UUID: PublishedSegment] = [:]
    /// Segments recovered in place from an interrupted session, keyed by segment ID.
    var adopted: [UUID: PublishedSegment] = [:]
    var sequence: UInt64 = 0
    var lastHash = String(repeating: "0", count: 64)
    var requiresNewerVersion = false
    var cachedRecord: RecordingSessionRecord?
}

/// Everything a journal line needs from the session to be applied on write or replay.
struct LedgerApplyContext {
    let root: URL
    let sessionID: UUID
    let fileManager: FileManager
    let replay: Bool
}

// MARK: Journal append, replay and event application

extension RecordingSessionLedger {
    func append(_ payload: LedgerJournalPayload) throws {
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
            let fileDescriptor = Self.openJournalForAppend(journal)
            guard fileDescriptor >= 0 else { throw RecordingSessionLedgerError.ioFailure }
            let writeError = Self.writeAll(lineData, to: fileDescriptor)
            if writeError || Darwin.fsync(fileDescriptor) != 0 {
                _ = Darwin.close(fileDescriptor)
                try? reloadJournal()
                throw RecordingSessionLedgerError.ioFailure
            }
            guard Darwin.close(fileDescriptor) == 0 else {
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

    private static func openJournalForAppend(_ journal: URL) -> Int32 {
        journal.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
        }
    }

    /// Writes the whole buffer, retrying on `EINTR`. Returns `true` on any failure.
    private static func writeAll(_ lineData: Data, to fileDescriptor: Int32) -> Bool {
        var writeError = false
        lineData.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else {
                writeError = true
                return
            }
            var remaining = rawBuffer.count
            var cursor = base
            while remaining > 0 {
                let written = Darwin.write(fileDescriptor, cursor, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    writeError = true
                    break
                }
                guard written > 0 else {
                    writeError = true
                    break
                }
                remaining -= written
                cursor = cursor.advanced(by: written)
            }
        }
        return writeError
    }

    static func loadJournal(
        at journal: URL,
        sessionRoot: URL,
        sessionID: UUID,
        fileManager: FileManager,
        cachedRecord: RecordingSessionRecord?
    ) throws -> LedgerState {
        do { try RecordingLedgerFileSystem.validateNoSymlink(journal) } catch { throw mapPathError(error) }
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
        let context = LedgerApplyContext(
            root: sessionRoot, sessionID: sessionID, fileManager: fileManager, replay: true
        )
        for bytes in lines {
            let lineData = Data(bytes)
            let schema = try Self.schemaVersion(of: lineData)
            if schema > 1 {
                loaded.requiresNewerVersion = true
                return loaded
            }
            guard schema == 1 else { throw RecordingSessionLedgerError.journalCorrupt }
            let line: LedgerJournalLine
            do {
                line = try JSONDecoder().decode(LedgerJournalLine.self, from: lineData)
            } catch {
                throw RecordingSessionLedgerError.journalCorrupt
            }
            let encodedCore: Data
            do {
                encodedCore = try encoder.encode(line.core)
            } catch {
                throw RecordingSessionLedgerError.journalCorrupt
            }
            guard line.core.sequence == loaded.sequence + 1,
                line.core.previousHash == loaded.lastHash,
                Self.hash(encodedCore) == line.hash
            else { throw RecordingSessionLedgerError.journalCorrupt }
            try Self.apply(line.core.payload, to: &loaded, context: context)
            loaded.sequence = line.core.sequence
            loaded.lastHash = line.hash
        }
        return loaded
    }

    private static func schemaVersion(of lineData: Data) throws -> Int {
        do {
            guard let object = try JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                let core = object["core"] as? [String: Any],
                let value = core["schemaVersion"] as? Int
            else { throw RecordingSessionLedgerError.journalCorrupt }
            return value
        } catch { throw RecordingSessionLedgerError.journalCorrupt }
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
            payload, to: &state,
            context: LedgerApplyContext(
                root: sessionRoot, sessionID: sessionID,
                fileManager: fileManager.value, replay: replay
            )
        )
    }

    /// Applies one journaled event. Each kind validates its own payload shape first,
    /// so corrupt lines fail before any state is written.
    private static func apply(
        _ payload: LedgerJournalPayload,
        to state: inout LedgerState,
        context: LedgerApplyContext
    ) throws {
        switch payload.kind {
        case "register":
            try applyRegister(payload, to: &state, sessionID: context.sessionID)
        case "checkpoint":
            try applyCheckpoint(payload, to: &state, root: context.root)
        case "screenCheckpoint":
            try applyScreenCheckpoint(payload, to: &state, context: context)
        case "publishIntent":
            try applyPublishIntent(payload, to: &state, context: context)
        case "published":
            try applyPublished(payload, to: &state, replay: context.replay)
        case "segmentClosed":
            try applySegmentClosed(payload, to: &state)
        case "adopted":
            try applyAdopted(payload, to: &state, root: context.root)
        default:
            throw RecordingSessionLedgerError.journalCorrupt
        }
    }

    private static func applyRegister(
        _ payload: LedgerJournalPayload,
        to state: inout LedgerState,
        sessionID: UUID
    ) throws {
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
    }

    private static func applyCheckpoint(
        _ payload: LedgerJournalPayload,
        to state: inout LedgerState,
        root: URL
    ) throws {
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
        try verifyCheckpointFiles(checkpoint, root: root)
        state.segmentIDs[checkpoint.segmentIndex] = checkpoint.segmentID
        state.checkpoints[checkpoint.checkpointID] = checkpoint
    }

    /// Re-checks every committed track file that is still present on disk.
    private static func verifyCheckpointFiles(_ checkpoint: LedgerCheckpoint, root: URL) throws {
        for file in checkpoint.files.values {
            let url = try RecordingLedgerFileSystem.resolve(file.relativePath, under: root, allowingMissing: true)
            if RecordingLedgerFileSystem.isRegularFile(url) {
                guard try RecordingLedgerFileSystem.sha256(of: url) == file.sha256 else {
                    throw RecordingSessionLedgerError.journalCorrupt
                }
            }
        }
    }

    private static func applyScreenCheckpoint(
        _ payload: LedgerJournalPayload,
        to state: inout LedgerState,
        context: LedgerApplyContext
    ) throws {
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
            checkpoint, root: context.root, fileManager: context.fileManager, allowMissing: context.replay
        )
        var chunks = state.screenCheckpoints[checkpoint.segmentIndex] ?? [:]
        if let prior = chunks[checkpoint.chunkIndex], prior != checkpoint {
            throw RecordingSessionLedgerError.journalCorrupt
        }
        chunks[checkpoint.chunkIndex] = checkpoint
        state.screenCheckpoints[checkpoint.segmentIndex] = chunks
    }

    private static func applyPublishIntent(
        _ payload: LedgerJournalPayload,
        to state: inout LedgerState,
        context: LedgerApplyContext
    ) throws {
        guard let intent = payload.intent, payload.record == nil, payload.checkpoint == nil,
            payload.published == nil, payload.closed == nil
        else { throw RecordingSessionLedgerError.journalCorrupt }
        try validateIntent(intent, fileManager: context.fileManager, replay: context.replay)
        if let prior = state.intents[intent.segmentID], prior != intent {
            throw RecordingSessionLedgerError.journalCorrupt
        }
        state.intents[intent.segmentID] = intent
        state.segmentIDs[intent.segmentIndex] = intent.segmentID
    }

    private static func applyPublished(
        _ payload: LedgerJournalPayload,
        to state: inout LedgerState,
        replay: Bool
    ) throws {
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
    }

    private static func applySegmentClosed(
        _ payload: LedgerJournalPayload,
        to state: inout LedgerState
    ) throws {
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
    }

    private static func applyAdopted(
        _ payload: LedgerJournalPayload,
        to state: inout LedgerState,
        root: URL
    ) throws {
        guard let segment = payload.adopted, payload.record == nil, payload.checkpoint == nil,
            payload.screenCheckpoint == nil, payload.intent == nil, payload.published == nil,
            payload.closed == nil
        else { throw RecordingSessionLedgerError.journalCorrupt }
        try validateAdoptedSegment(segment, sessionRoot: root)
        if let prior = state.adopted[segment.id] {
            guard prior == segment else { throw RecordingSessionLedgerError.journalCorrupt }
            return
        }
        if let other = state.adopted.values.first(where: { $0.index == segment.index }) {
            guard other.id == segment.id else { throw RecordingSessionLedgerError.journalCorrupt }
            return
        }
        if let prior = state.segmentIDs[segment.index], prior != segment.id {
            throw RecordingSessionLedgerError.journalCorrupt
        }
        state.adopted[segment.id] = segment
        state.segmentIDs[segment.index] = segment.id
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do { return try encoder.encode(value) } catch { throw RecordingSessionLedgerError.ioFailure }
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
