import Foundation

extension RecordingSessionLedger {
    // MARK: Recovery

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

    // MARK: Segment bookkeeping

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

    // MARK: Preview leases

    func addLease(_ lease: PreviewLease) {
        leases[lease.id] = lease
    }

    func removeLease(_ lease: PreviewLease) {
        leases[lease.id] = nil
    }

    func previewURLs(for target: PreviewTarget) throws -> (UUID, [URL]) {
        switch target {
        case .checkpoint(let checkpointID):
            return try checkpointPreviewURLs(checkpointID)
        case .segment(let segmentID):
            return try segmentPreviewURLs(segmentID)
        }
    }

    private func checkpointPreviewURLs(_ checkpointID: UUID) throws -> (UUID, [URL]) {
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
    }

    private func segmentPreviewURLs(_ segmentID: UUID) throws -> (UUID, [URL]) {
        if let adopted = state.adopted[segmentID] {
            let urls = try Self.adoptedMaterialURLs(adopted, sessionRoot: sessionRoot)
            guard !urls.isEmpty else { throw RecordingPreviewError.notPreviewable }
            return (segmentID, urls)
        }
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

    // MARK: Checkpoint collection

    func collectableCheckpointFiles(now date: Date) throws -> [URL] {
        let activeLeases = leases.values.filter { $0.expiresAt > date }
        leases = Dictionary(uniqueKeysWithValues: activeLeases.map { ($0.id, $0) })
        let leasedPaths = Set(activeLeases.flatMap { $0.mediaURLs.map(\.standardizedFileURL.path) })
        var removed: [URL] = []
        for checkpoint in state.checkpoints.values where state.published[checkpoint.segmentID] != nil {
            for item in checkpoint.files.values {
                let url: URL
                do {
                    url = try RecordingLedgerFileSystem.resolve(
                        item.relativePath,
                        under: sessionRoot,
                        allowingMissing: true
                    )
                } catch {
                    throw Self.mapPathError(error)
                }
                guard !leasedPaths.contains(url.standardizedFileURL.path),
                      RecordingLedgerFileSystem.isRegularFile(url),
                      (try? RecordingLedgerFileSystem.sha256(of: url)) == item.sha256
                else { continue }
                removed.append(contentsOf: try removeCollectedCheckpoint(url, checkpointID: checkpoint.checkpointID))
            }
        }
        return removed
    }

    /// Deletes one collected media file plus its checkpoint sidecar, returning what it removed.
    private func removeCollectedCheckpoint(_ url: URL, checkpointID: UUID) throws -> [URL] {
        do {
            try fileManager.value.removeItem(at: url)
            var removed = [url]
            let sidecar = url.deletingLastPathComponent()
                .appendingPathComponent("checkpoint-\(checkpointID.uuidString.lowercased()).json")
            if RecordingLedgerFileSystem.isRegularFile(sidecar) {
                try fileManager.value.removeItem(at: sidecar)
                removed.append(sidecar)
            }
            try RecordingLedgerFileSystem.syncDirectory(url.deletingLastPathComponent())
            return removed
        } catch { throw RecordingSessionLedgerError.ioFailure }
    }
}
