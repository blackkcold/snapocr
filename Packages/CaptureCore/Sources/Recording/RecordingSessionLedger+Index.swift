import Darwin
import Foundation

/// Facts the pipeline publishes about journal progress, replacing an anonymous tuple.
struct LedgerProgressFacts: Sendable {
    let sampleEnd: Int64
    let committedAt: Date?
    let publishedCount: Int
}

extension RecordingSessionLedger {
    // MARK: Index persistence

    private var recordingRoot: URL {
        if sessionRoot.deletingLastPathComponent().lastPathComponent == ".SnapGlassSessions" {
            return sessionRoot.deletingLastPathComponent().deletingLastPathComponent()
        }
        return sessionRoot.deletingLastPathComponent()
    }

    func persistIndex(replacingAll allEntries: [RecordingIndexRecord.Entry]? = nil) throws {
        let record = try currentRecord()
        let safeRoot = recordingRoot.standardizedFileURL
        let relative: String
        do {
            relative = try RecordingLedgerFileSystem.validateChild(sessionRoot, under: safeRoot)
        } catch {
            throw Self.mapPathError(error)
        }
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

        var entriesByID = try Self.existingIndexEntries(
            allEntries: allEntries, indexURL: indexURL, fileManager: fileManager
        )
        entriesByID[sessionID] = currentEntry
        let index = RecordingIndexRecord(
            entries: entriesByID.values.sorted {
                $0.sessionID.uuidString < $1.sessionID.uuidString
            }, updatedAt: now())
        do {
            try RecordingLedgerFileSystem.atomicWrite(try Self.encode(index), to: indexURL)
        } catch {
            throw Self.mapPathError(error)
        }
    }

    /// Reads the existing index under the caller's lock; a bad cache is rebuilt from scratch.
    private static func existingIndexEntries(
        allEntries: [RecordingIndexRecord.Entry]?,
        indexURL: URL,
        fileManager: RecordingSendableFileManager
    ) throws -> [UUID: RecordingIndexRecord.Entry] {
        if let allEntries {
            return Dictionary(uniqueKeysWithValues: allEntries.map { ($0.sessionID, $0) })
        }
        guard fileManager.value.fileExists(atPath: indexURL.path) else { return [:] }
        do {
            try RecordingLedgerFileSystem.validateNoSymlink(indexURL)
            let cached = try JSONDecoder().decode(RecordingIndexRecord.self, from: Data(contentsOf: indexURL))
            guard cached.schemaVersion == RecordingIndexRecord.currentSchemaVersion else {
                throw RecordingSessionLedgerError.indexCorrupt
            }
            return Dictionary(uniqueKeysWithValues: cached.entries.map { ($0.sessionID, $0) })
        } catch let error as RecordingSessionLedgerError {
            throw error
        } catch {
            // A cache can be rebuilt from the registered session root; it is never journal authority.
            return [:]
        }
    }

    public func rebuildIndex() async throws {
        try ensureWritable()
        let entries = try await Self.allEntries(
            in: recordingRoot, indexURL: indexURL, fileManager: fileManager
        )
        try persistIndex(replacingAll: entries)
    }

    // MARK: Record projection

    func currentRecord() throws -> RecordingSessionRecord {
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
        var segments: [PublishedSegment] = []
        for index in Self.segmentIndices(in: state).sorted() {
            guard let id = state.segmentIDs[index] ?? state.closed[index]?.segmentID else { continue }
            if let adopted = state.adopted[id] {
                segments.append(adopted)
                continue
            }
            segments.append(segmentProjection(index: index, id: id))
        }
        return RecordingSessionRecord(
            id: base.id, kind: base.kind, layout: base.layout,
            startedAt: base.startedAt, segments: segments
        )
    }

    private static func segmentIndices(in state: LedgerState) -> Set<Int> {
        Set(state.segmentIDs.keys)
            .union(state.checkpoints.values.map(\.segmentIndex))
            .union(state.intents.values.map(\.segmentIndex))
            .union(state.closed.keys)
            .union(state.published.values.map(\.index))
            .union(state.adopted.values.map(\.index))
    }

    private func segmentProjection(index: Int, id: UUID) -> PublishedSegment {
        let checkpoints = state.checkpoints.values.filter { $0.segmentIndex == index }
        let start =
            state.closed[index]?.coverage.segmentStartSample
            ?? checkpoints.map(\.range.startSample).min() ?? 0
        let end =
            state.closed[index]?.coverage.segmentEndSample
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
        return PublishedSegment(
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
        )
    }

    // MARK: Progress

    func progressFacts() -> LedgerProgressFacts {
        let end = state.checkpoints.values.map(\.range.endSample).max() ?? 0
        let committedAt = state.checkpoints.values.map(\.committedAt).max()
        let publishedCount = state.published.values.filter { isPublishedProductValid($0) }.count
        return LedgerProgressFacts(sampleEnd: end, committedAt: committedAt, publishedCount: publishedCount)
    }

    // MARK: Session discovery

    public static func openExisting(
        sessionID: UUID,
        recordingRoot: URL,
        indexURL: URL,
        fileManager: FileManager = .default
    ) async throws -> RecordingSessionLedger {
        let root: URL
        do {
            root = try RecordingLedgerFileSystem.canonicalDirectory(recordingRoot, create: false)
        } catch {
            throw mapPathError(error)
        }
        let relative = ".SnapGlassSessions/\(sessionID.uuidString.lowercased())"
        let sessionRoot: URL
        do {
            sessionRoot = try RecordingLedgerFileSystem.resolve(relative, under: root)
        } catch {
            throw mapPathError(error)
        }
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
        return entries.map(\.record).filter {
            $0.segments.contains(where: { $0.state == .published || $0.state == .missing })
        }
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
            if $0.sessionID == $1.sessionID {
                return $0.segmentIndex < $1.segmentIndex
            }
            return $0.sessionID.uuidString < $1.sessionID.uuidString
        }
    }

    // MARK: Scan/read helpers

    private static func allEntries(
        in recordingRoot: URL,
        indexURL: URL,
        fileManager: RecordingSendableFileManager
    ) async throws -> [RecordingIndexRecord.Entry] {
        let root: URL
        do {
            root = try RecordingLedgerFileSystem.canonicalDirectory(recordingRoot, create: false)
        } catch {
            throw mapPathError(error)
        }
        let sessionsDirectory = root.appendingPathComponent(".SnapGlassSessions", isDirectory: true)
        guard fileManager.value.fileExists(atPath: sessionsDirectory.path) else { return [] }
        do { try RecordingLedgerFileSystem.validateNoSymlink(sessionsDirectory) } catch { throw mapPathError(error) }
        guard RecordingLedgerFileSystem.isDirectory(sessionsDirectory) else {
            throw RecordingSessionLedgerError.invalidPath
        }
        let children: [URL]
        do {
            children = try fileManager.value.contentsOfDirectory(
                at: sessionsDirectory, includingPropertiesForKeys: nil
            )
        } catch { throw RecordingSessionLedgerError.ioFailure }
        var result: [RecordingIndexRecord.Entry] = []
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            do { try RecordingLedgerFileSystem.validateNoSymlink(child) } catch { throw mapPathError(error) }
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
            do {
                relative = try RecordingLedgerFileSystem.validateChild(child, under: root)
            } catch {
                throw mapPathError(error)
            }
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
}
