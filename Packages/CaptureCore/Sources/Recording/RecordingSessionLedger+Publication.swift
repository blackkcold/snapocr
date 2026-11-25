import Foundation

extension RecordingSessionLedger {
    // MARK: Publishing

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
            existing.segmentID != intent.segmentID
        {
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

    /// Journals an interrupted segment that references existing media in place.
    ///
    /// Recovery never copies or re-encodes captured media: the segment records the
    /// media that is already inside the session root, so preview and export read the
    /// original bytes. The result is an ordinary index entry, which means
    /// `publishedSessions(in:indexURL:)`, `isCompleted`, preview and export all use
    /// their existing paths.
    ///
    /// A session that already journaled checkpoints keeps its segment identity: the
    /// adopted segment reuses the checkpoint's segment ID, so replay stays valid and
    /// the checkpoint files remain untouched on disk.
    ///
    /// Idempotent: adopting the same segment index twice returns the segment that
    /// is already journaled and appends nothing.
    ///
    /// - Parameter segment: Segment whose media already exists in the session root.
    /// - Returns: The journaled segment (the existing one on a repeat adoption).
    /// - Throws: ``RecordingSessionLedgerError/readOnly`` when the ledger cannot be
    ///   written, ``RecordingSessionLedgerError/missingSession`` when no session is
    ///   loaded, ``RecordingSessionLedgerError/invalidPublication`` or a path error
    ///   when the segment references media outside the session root or of the wrong
    ///   shape, and ``RecordingSessionLedgerError/idempotencyConflict`` when the
    ///   index already holds a different segment at that position.
    @discardableResult
    public func adoptPublishedSegment(_ segment: PublishedSegment) async throws -> PublishedSegment {
        try ensureWritable()
        guard state.record != nil else { throw RecordingSessionLedgerError.missingSession }
        try Self.validateAdoptedSegment(segment, sessionRoot: sessionRoot)

        let effective = Self.reidentifying(
            segment,
            as: state.segmentIDs[segment.index] ?? segment.id
        )
        if let existing = state.adopted[effective.id] {
            guard existing == effective else { throw RecordingSessionLedgerError.idempotencyConflict }
            try persistIndex()
            return existing
        }
        if let other = state.adopted.values.first(where: { $0.index == effective.index }) {
            try persistIndex()
            return other
        }
        if state.intents.values.contains(where: { $0.segmentIndex == effective.index })
            || state.published.values.contains(where: { $0.index == effective.index })
        {
            throw RecordingSessionLedgerError.idempotencyConflict
        }
        try append(.adopted(effective))
        try persistIndex()
        return effective
    }

    /// Copies an adopted segment onto the segment ID the index already uses.
    private static func reidentifying(_ segment: PublishedSegment, as id: UUID) -> PublishedSegment {
        guard segment.id != id else { return segment }
        return PublishedSegment(
            id: id,
            index: segment.index,
            files: segment.files,
            startSample: segment.startSample,
            sampleCount: segment.sampleCount,
            trackMap: segment.trackMap,
            missingRanges: segment.missingRanges,
            state: segment.state,
            videoURL: segment.videoURL,
            videoTrackIndex: segment.videoTrackIndex,
            materialURL: segment.materialURL
        )
    }

    // MARK: Publication candidates

    func publishIntent(segmentID: UUID) throws -> RecordingPublishIntent {
        guard let intent = state.intents[segmentID] else { throw RecordingSessionLedgerError.missingPublishIntent }
        return intent
    }

    func segmentPublicationCandidate(segmentID: UUID) async throws -> SegmentPublicationCandidate {
        let intent = try publishIntent(segmentID: segmentID)
        let productURL =
            fileManager.value.fileExists(atPath: intent.stagingURL.path)
            ? intent.stagingURL
            : intent.reservedFinalURL
        let record = try await Self.portableRecord(for: intent, productURL: productURL)
        guard record.segmentID == intent.segmentID, record.segmentIndex == intent.segmentIndex,
            record.startSample == intent.effectiveRange.startSample,
            record.sampleCount == intent.effectiveRange.sampleCount
        else { throw RecordingSessionLedgerError.invalidPublication }
        let files = Dictionary(
            uniqueKeysWithValues: try record.tracks.map { track -> (RecordingTrackRole, URL) in
                guard let role = Self.role(from: track.role) else {
                    throw RecordingSessionLedgerError.invalidPublication
                }
                let url =
                    intent.isDirectory
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

    private static func portableRecord(
        for intent: RecordingPublishIntent,
        productURL: URL
    ) async throws -> SegmentPortableRecord {
        if intent.isDirectory {
            let manifestURL = productURL.appendingPathComponent("manifest.json")
            guard RecordingLedgerFileSystem.isRegularFile(manifestURL) else {
                throw RecordingSessionLedgerError.invalidPublication
            }
            do {
                return try JSONDecoder().decode(
                    SegmentPortableRecord.self,
                    from: Data(contentsOf: manifestURL)
                )
            } catch {
                throw RecordingSessionLedgerError.invalidPublication
            }
        }
        do {
            return try await RecordingPortableMetadata.read(from: productURL)
        } catch {
            throw RecordingSessionLedgerError.invalidPublication
        }
    }

    // MARK: Product validity

    func isIntentRecoverable(_ intent: RecordingPublishIntent) -> Bool {
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

    func isPublishedProductValid(_ segment: PublishedSegment) -> Bool {
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

    private func candidateProductURLs(
        _ intent: RecordingPublishIntent,
        useFinal: Bool = false
    ) throws -> [String: URL] {
        if intent.isDirectory {
            let product = useFinal ? intent.reservedFinalURL : intent.stagingURL
            return Dictionary(
                uniqueKeysWithValues: intent.contentHashes.keys.map {
                    ($0, product.appendingPathComponent($0))
                })
        }
        return [intent.reservedFinalURL.lastPathComponent: useFinal ? intent.reservedFinalURL : intent.stagingURL]
    }

    // MARK: Track roles

    static func roleName(_ role: RecordingTrackRole) -> String {
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
}
