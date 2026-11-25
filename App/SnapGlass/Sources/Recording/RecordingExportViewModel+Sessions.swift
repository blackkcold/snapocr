import CaptureCore
import Foundation

extension RecordingExportViewModel {
    func loadPublishedSessions() async {
        listGeneration += 1
        let generation = listGeneration
        isLoading = true
        message = nil

        let roots = self.roots
        let task = Task.detached(priority: .utility) {
            var records: [RecordingSessionRecord] = []
            var indexByID: [UUID: Int] = [:]
            var rootByID: [UUID: RecordingExportRoot] = [:]
            var failedRoot = false

            for exportRoot in roots {
                var isDirectory = ObjCBool(false)
                guard
                    FileManager.default.fileExists(
                        atPath: exportRoot.root.path,
                        isDirectory: &isDirectory
                    ), isDirectory.boolValue
                else {
                    continue
                }
                do {
                    let found = try await RecordingSessionLedger.publishedSessions(
                        in: exportRoot.root,
                        indexURL: exportRoot.indexURL
                    )
                    for record in found where Self.isCompleted(record) {
                        if let index = indexByID[record.id] {
                            // The same session can exist in two scanned folders; keep the newest copy.
                            if record.startedAt > records[index].startedAt {
                                records[index] = record
                                rootByID[record.id] = exportRoot
                            }
                        } else {
                            indexByID[record.id] = records.count
                            records.append(record)
                            rootByID[record.id] = exportRoot
                        }
                    }
                } catch {
                    // One unreadable folder must not hide sessions from the others.
                    failedRoot = true
                }
            }

            records.sort { $0.startedAt > $1.startedAt }
            return (records, rootByID, failedRoot)
        }

        let (records, rootByID, failedRoot) = await task.value
        guard generation == listGeneration else { return }
        publishedSessions = records
        exportRootBySessionID = rootByID
        isLoading = false
        if let selectedSessionID, !records.contains(where: { $0.id == selectedSessionID }) {
            clearSelectedSession()
        }
        // Only surface the listing error when no folder produced a usable list.
        if failedRoot, records.isEmpty {
            message = .listingFailed
        }
    }

    // MARK: Recovery

    /// Scans for interrupted sessions that still have media on disk.
    ///
    /// Scanning never writes: adoption only happens through ``recoverRecording(_:)``.
    func scanRecoverableRecordings() async {
        guard !isScanningRecoverable else { return }
        isScanningRecoverable = true
        if message == .recoveryScanFailed { message = nil }
        let roots = self.roots
        let found = await RecordingRecoveryService.shared.scan(roots: roots)
        recoverableRecordings = found
        isScanningRecoverable = false
    }

    /// Adopts one interrupted session so the normal list, preview, and export use it.
    ///
    /// - Parameter sessionID: Session chosen in the recoverable group.
    func recoverRecording(_ sessionID: UUID) async {
        guard recoveringRecordingID == nil,
            let recording = recoverableRecordings.first(where: { $0.id == sessionID })
        else { return }
        recoveringRecordingID = sessionID
        recoveryNotice = nil
        message = nil
        do {
            _ = try await RecordingRecoveryService.shared.recover(recording)
            recoverableRecordings.removeAll { $0.id == sessionID }
            recoveringRecordingID = nil
            recoveryNotice = .recovered
            // The adopted session is an ordinary entry now: reload so selection,
            // preview, and export all use the existing list path.
            await loadPublishedSessions()
            await selectSession(sessionID)
        } catch {
            recoveringRecordingID = nil
            message = .recoveryFailed
        }
    }

    /// Moves one interrupted session folder to the Trash.
    ///
    /// - Parameter sessionID: Session chosen in the recoverable group.
    func discardRecording(_ sessionID: UUID) async {
        guard discardingRecordingID == nil,
            let recording = recoverableRecordings.first(where: { $0.id == sessionID })
        else { return }
        discardingRecordingID = sessionID
        recoveryNotice = nil
        message = nil
        do {
            try await RecordingRecoveryService.shared.discard(recording)
            recoverableRecordings.removeAll { $0.id == sessionID }
            discardingRecordingID = nil
            recoveryNotice = .discarded
        } catch {
            discardingRecordingID = nil
            message = .discardFailed
        }
    }

    /// Clears the one-time recovery notice after the view showed it.
    func clearRecoveryNotice() {
        recoveryNotice = nil
    }

    func selectSession(_ sessionID: UUID) async {
        guard publishedSessions.contains(where: { $0.id == sessionID }) else { return }
        guard selectedSessionID != sessionID || session == nil else { return }
        guard let exportRoot = exportRootBySessionID[sessionID] else {
            message = .sessionUnavailable
            return
        }

        sessionGeneration += 1
        let generation = sessionGeneration
        releasePreviewLease()
        releaseSelectedSourceLeases()
        selectedSessionID = sessionID
        session = nil
        ledger = nil
        previewService = nil
        selectedSegmentIDs = []
        rangesBySegment = [:]
        assessment = nil
        summary = nil
        succeededOutputURL = nil
        message = nil
        isOpeningSession = true
        invalidateAssessment()

        let root = exportRoot.root
        let index = exportRoot.indexURL
        let task = Task.detached(priority: .utility) {
            let ledger = try await RecordingSessionLedger.openExisting(
                sessionID: sessionID,
                recordingRoot: root,
                indexURL: index
            )
            let record = try await ledger.snapshot()
            let service = await ledger.makePreviewService()
            return (ledger, record, service)
        }

        do {
            let (openedLedger, record, service) = try await task.value
            guard generation == sessionGeneration else { return }
            guard Self.isCompleted(record) else {
                isOpeningSession = false
                message = .sessionUnavailable
                return
            }
            ledger = openedLedger
            session = record
            previewService = service
            outputMode = record.kind == .screen ? .mp4Video : .mixedAudio
            outputStem = Self.defaultStem(for: record)
            if !hasUserChosenOutputDirectory {
                outputDirectory = exportRoot.root
            }
            isOpeningSession = false
            refreshAssessment()
        } catch {
            guard generation == sessionGeneration else { return }
            isOpeningSession = false
            message = .sessionUnavailable
        }
    }

    func clearSelectedSession() {
        sessionGeneration += 1
        releasePreviewLease()
        releaseSelectedSourceLeases()
        session = nil
        selectedSessionID = nil
        hasUserChosenOutputDirectory = false
        ledger = nil
        previewService = nil
        selectedSegmentIDs = []
        rangesBySegment = [:]
        assessment = nil
        summary = nil
        succeededOutputURL = nil
        message = nil
        isOpeningSession = false
        invalidateAssessment()
    }

    nonisolated static func isCompleted(_ record: RecordingSessionRecord) -> Bool {
        guard record.segments.contains(where: { $0.state == .published || $0.state == .missing }) else {
            return false
        }
        return record.segments.allSatisfy { $0.state == .published || $0.state == .missing }
    }

    static func defaultStem(for record: RecordingSessionRecord) -> String {
        "Recording-\(record.startedAt.formatted(.iso8601.year().month().day()))-\(record.id.uuidString.prefix(8))"
    }
}
