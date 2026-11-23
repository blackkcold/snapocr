import AVFoundation
import AudioToolbox
import CaptureCore
import Combine
import Foundation

enum RecordingExportOutputMode: String, CaseIterable, Sendable, Equatable {
    case mp4Video
    case mixedAudio
    case separatedAudio

    var includesVideo: Bool { self == .mp4Video }

    var trackSelection: ExportTrackSelection {
        self == .separatedAudio ? .sourceSeparated : .mixed
    }
}

enum RecordingExportViewMessage: Sendable, Equatable {
    case listingFailed
    case sessionUnavailable
    case previewUnavailable
    case previewFailed
    case export(ExportError)
    case recoveryScanFailed
    case recoveryFailed
    case discardFailed
}

/// One-time feedback for a recovery action.
enum RecordingRecoveryNotice: Sendable, Equatable {
    /// The session was adopted and now appears in the normal list.
    case recovered
    /// The session folder was moved to the Trash.
    case discarded
}

@MainActor
final class RecordingExportViewModel: ObservableObject {
    @Published private(set) var publishedSessions: [RecordingSessionRecord] = []
    @Published private(set) var selectedSessionID: UUID?
    @Published private(set) var session: RecordingSessionRecord?
    @Published private(set) var selectedSegmentIDs: Set<UUID> = []
    @Published private(set) var assessment: ExportAssessment?
    @Published private(set) var summary: RecordingExportSummary?
    @Published private(set) var outputMode: RecordingExportOutputMode = .mixedAudio
    @Published private(set) var outputDirectory: URL
    @Published private(set) var outputStem: String
    @Published private(set) var audioGainDB: Double = 0
    @Published private(set) var previewGain: Double = 0.8
    @Published private(set) var isLoading = false
    @Published private(set) var isOpeningSession = false
    @Published private(set) var isAssessing = false
    @Published private(set) var isExporting = false
    @Published private(set) var exportProgress: Double = 0
    @Published private(set) var previewSegmentID: UUID?
    @Published private(set) var message: RecordingExportViewMessage?
    @Published private(set) var succeededOutputURL: URL?
    /// Interrupted sessions that still have media but no published entry.
    @Published private(set) var recoverableRecordings: [RecoverableRecording] = []
    /// Whether a recovery scan is running.
    @Published private(set) var isScanningRecoverable = false
    /// Session currently being adopted, so its row can show progress.
    @Published private(set) var recoveringRecordingID: UUID?
    /// Session currently being moved to the Trash.
    @Published private(set) var discardingRecordingID: UUID?
    /// One-time feedback for the last recovery action.
    @Published private(set) var recoveryNotice: RecordingRecoveryNotice?

    let roots: [RecordingExportRoot]
    private let primaryRoot: URL

    /// Root of the selected session, or the first configured folder.
    var recordingRoot: URL {
        selectedExportRoot?.root ?? primaryRoot
    }

    private let exporter = RecordingCompositionExporter()
    private var ledger: RecordingSessionLedger?
    private var previewService: RecordingPreviewService?
    private var exportRootBySessionID: [UUID: RecordingExportRoot] = [:]
    private var hasUserChosenOutputDirectory = false
    private var rangesBySegment: [UUID: SampleRange] = [:]
    private var assessmentGeneration = 0
    private var sessionGeneration = 0
    private var listGeneration = 0
    private var previewGeneration = 0
    private var assessmentTask: Task<RecordingExportEvaluation, Never>?
    private var previewTask: Task<Void, Never>?
    private var previewCleanupTask: Task<Void, Never>?
    private var previewReleaseTask: Task<Void, Never>?
    private var previewLease: PreviewLease?
    private var previewPlayer: RecordingExportAudioPreviewPlayer?
    private var selectedSourceLeases: RecordingExportLeaseBundle?
    private var cachedPlan: ExportPlan?
    private var validatedPlanGeneration: Int?
    private var activeExportTask: Task<ExportResult, Error>?
    private var activeExportID: UUID?
    private var exportGeneration = 0

    init(roots: [RecordingExportRoot], defaultStem: String = "Recording") {
        self.roots = roots
        let fallback = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies", isDirectory: true)
            .appendingPathComponent("SnapGlass", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
        let primary = roots.first
        primaryRoot = primary?.root ?? fallback
        outputDirectory = primaryRoot
        outputStem = defaultStem
    }

    /// Single-folder convenience entry point retained for tests and older callers.
    convenience init(recordingRoot: URL, indexURL: URL, defaultStem: String = "Recording") {
        self.init(
            roots: [RecordingExportRoot(kind: .screen, root: recordingRoot, indexURL: indexURL)],
            defaultStem: defaultStem
        )
    }

    private var selectedExportRoot: RecordingExportRoot? {
        guard let selectedSessionID else { return nil }
        return exportRootBySessionID[selectedSessionID]
    }

    var availableOutputModes: [RecordingExportOutputMode] {
        guard let session else { return [] }
        if session.kind == .screen { return RecordingExportOutputMode.allCases }
        return [.mixedAudio, .separatedAudio]
    }

    var canExport: Bool {
        guard !isLoading, !isOpeningSession, !isAssessing, !isExporting,
              assessment?.disabledReason == nil,
              validatedPlanGeneration == assessmentGeneration,
              cachedPlan != nil else { return false }
        return true
    }

    var hasPreviewableSegment: Bool {
        session?.segments.contains(where: { $0.state == .published }) == true
    }

    var isPreviewPreparing: Bool { previewTask != nil }
    var isPreviewPlaying: Bool { previewPlayer?.isPlaying == true }

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
                guard FileManager.default.fileExists(
                    atPath: exportRoot.root.path,
                    isDirectory: &isDirectory
                ), isDirectory.boolValue else {
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

    func assess() -> ExportAssessment {
        if let assessment { return assessment }
        guard let session else { return Self.emptyAssessment(destination: currentDestination) }
        return RecordingExportPlanner.assess(
            session: session,
            selection: makeSelection(for: session),
            audioSourcesBySegment: [:]
        )
    }

    func validatedPlan() throws -> ExportPlan {
        guard validatedPlanGeneration == assessmentGeneration,
              let cachedPlan else {
            if let overage = assessment?.overageSeconds, overage > 0 {
                throw ExportError.overLimit(overageSeconds: overage)
            }
            throw assessment?.disabledReason.map(Self.exportError(for:)) ?? ExportError.emptySelection
        }
        let overage = max(0, cachedPlan.estimatedDuration - RecordingExportPlanner.maximumExportDuration)
        guard overage == 0 else { throw ExportError.overLimit(overageSeconds: overage) }
        return cachedPlan
    }

    func setSegmentSelected(_ segmentID: UUID, isSelected: Bool) {
        guard let segment = session?.segments.first(where: { $0.id == segmentID }),
              segment.state == .published else { return }
        if isSelected {
            selectedSegmentIDs.insert(segmentID)
        } else {
            selectedSegmentIDs.remove(segmentID)
            if previewSegmentID == segmentID { releasePreviewLease() }
        }
        succeededOutputURL = nil
        refreshAssessment()
    }

    func trimRange(for segment: PublishedSegment) -> SampleRange {
        rangesBySegment[segment.id]
            ?? SampleRange(startSample: segment.startSample, sampleCount: segment.sampleCount)
    }

    func setTrimRange(_ range: SampleRange, for segmentID: UUID) {
        guard let segment = session?.segments.first(where: { $0.id == segmentID }),
              segment.state == .published, segment.sampleCount > 0 else { return }
        let segmentEnd = segment.startSample + segment.sampleCount
        let start = max(segment.startSample, range.startSample)
        let end = min(segmentEnd, range.startSample + range.sampleCount)
        guard end > start else { return }
        if start == segment.startSample && end == segmentEnd {
            rangesBySegment[segmentID] = nil
        } else {
            rangesBySegment[segmentID] = SampleRange(startSample: start, sampleCount: end - start)
        }
        succeededOutputURL = nil
        if selectedSegmentIDs.contains(segmentID) { refreshAssessment() }
    }

    func setOutputMode(_ mode: RecordingExportOutputMode) {
        guard availableOutputModes.contains(mode), outputMode != mode else { return }
        outputMode = mode
        succeededOutputURL = nil
        refreshAssessment()
    }

    func setOutputDirectory(_ directory: URL) {
        guard directory.isFileURL else { return }
        hasUserChosenOutputDirectory = true
        outputDirectory = directory.standardizedFileURL
        succeededOutputURL = nil
        refreshAssessment()
    }

    func setOutputStem(_ stem: String) {
        guard outputStem != stem else { return }
        outputStem = stem
        succeededOutputURL = nil
        refreshAssessment()
    }

    func setAudioGainDB(_ value: Double) {
        guard value.isFinite else { return }
        let clamped = min(12, max(-24, value))
        guard audioGainDB != clamped else { return }
        audioGainDB = clamped
        refreshAssessment()
    }

    func setPreviewGain(_ value: Double) {
        guard value.isFinite else { return }
        previewGain = min(1, max(0, value))
        previewPlayer?.setGain(Float(previewGain))
    }

    func togglePreview(for segmentID: UUID) {
        if previewSegmentID == segmentID {
            releasePreviewLease()
            return
        }
        guard let previewService,
              session?.segments.contains(where: { $0.id == segmentID && $0.state == .published }) == true else {
            message = .previewUnavailable
            return
        }

        releasePreviewLease()
        let generation = previewGeneration
        message = nil
        let task = Task { @MainActor [weak self] in
            defer {
                if self?.previewGeneration == generation { self?.previewTask = nil }
            }
            do {
                let lease = try await previewService.leasePreview(for: segmentID, duration: 24 * 60 * 60)
                guard let self else {
                    await previewService.release(lease)
                    return
                }
                guard !Task.isCancelled, self.previewGeneration == generation else {
                    await previewService.release(lease)
                    return
                }

                let player = RecordingExportAudioPreviewPlayer()
                self.previewLease = lease
                self.previewSegmentID = segmentID
                self.previewPlayer = player
                try player.play(urls: lease.mediaURLs, gain: Float(self.previewGain)) { [weak self] in
                    Task { @MainActor [weak self] in
                        guard self?.previewLease?.id == lease.id else { return }
                        self?.releasePreviewLease()
                    }
                }
            } catch {
                guard let self, self.previewGeneration == generation else { return }
                self.message = .previewFailed
                self.releasePreviewLease()
            }
        }
        previewTask = task
    }

    func releasePreviewLease() {
        previewGeneration += 1
        let generation = previewGeneration
        previewTask?.cancel()
        let task = previewTask
        previewTask = nil

        let player = previewPlayer
        previewPlayer = nil
        player?.stop()
        previewSegmentID = nil

        let lease = previewLease
        previewLease = nil
        if let lease, let previewService {
            enqueuePreviewRelease(lease, using: previewService)
        }
        let releaseTask = previewReleaseTask
        previewCleanupTask = Task { @MainActor in
            await task?.value
            await releaseTask?.value
            if self.previewGeneration == generation { self.previewCleanupTask = nil }
        }
    }

    func export() async throws -> ExportResult {
        let plan = try validatedPlan()
        guard let service = selectedSourceLeases?.service else { throw ExportError.missingSource }
        guard !isExporting else { throw ExportError.exportInProgress }

        isExporting = true
        exportProgress = 0
        message = nil
        succeededOutputURL = nil
        exportGeneration += 1
        let generation = exportGeneration
        let exportID = UUID()
        activeExportID = exportID
        await releasePreviewLeaseAndWait()
        guard generation == exportGeneration, !Task.isCancelled else {
            await finishExportReleasingLeases(using: service, exportID: exportID)
            let error = ExportError.cancelled(stagingURL: nil)
            message = .export(error)
            throw error
        }
        let exporter = self.exporter
        let task = Task<ExportResult, Error> { [weak self] in
            try await exporter.export(plan) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.activeExportID == exportID else { return }
                    self.exportProgress = progress.fraction
                }
            }
        }
        activeExportTask = task

        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            succeededOutputURL = result.outputURL
            exportProgress = 1
            await finishExportReleasingLeases(using: service, exportID: exportID)
            return result
        } catch {
            let exportError = error as? ExportError
                ?? (Task.isCancelled ? ExportError.cancelled(stagingURL: nil) : ExportError.publishFailed(stagingURL: nil))
            message = .export(exportError)
            await finishExportReleasingLeases(using: service, exportID: exportID)
            throw exportError
        }
    }

    func cancel() {
        assessmentGeneration += 1
        assessmentTask?.cancel()
        assessmentTask = nil
        isAssessing = false
        cachedPlan = nil
        validatedPlanGeneration = nil
        previewTask?.cancel()
        releasePreviewLease()
        exportGeneration += 1
        activeExportTask?.cancel()
        if !isExporting { releaseSelectedSourceLeases() }
    }

    func windowDidClose() {
        sessionGeneration += 1
        isOpeningSession = false
        cancel()
    }

    private var currentDestination: ExportDestination {
        ExportDestination(directory: outputDirectory, stem: outputStem)
    }

    private func makeSelection(for session: RecordingSessionRecord) -> ExportSelection {
        let orderedIDs = session.segments
            .filter { selectedSegmentIDs.contains($0.id) && $0.state == .published }
            .sorted { $0.index < $1.index }
            .map(\.id)
        let selectedRanges = rangesBySegment.filter { orderedIDs.contains($0.key) }
        return ExportSelection(
            segmentIDs: orderedIDs,
            rangesBySegment: selectedRanges,
            trackSelection: outputMode.trackSelection,
            includeVideo: outputMode.includesVideo,
            audioGainDB: Float(audioGainDB),
            destination: currentDestination
        )
    }

    private func refreshAssessment() {
        guard let session, let service = previewService else {
            assessment = nil
            summary = nil
            isAssessing = false
            cachedPlan = nil
            validatedPlanGeneration = nil
            return
        }

        assessmentGeneration += 1
        let generation = assessmentGeneration
        assessmentTask?.cancel()
        let previousLeases = selectedSourceLeases
        selectedSourceLeases = nil
        let selection = makeSelection(for: session)
        assessment = nil
        summary = nil
        cachedPlan = nil
        validatedPlanGeneration = nil
        isAssessing = true

        let task = Task.detached(priority: .userInitiated) {
            if let previousLeases {
                await RecordingExportWork.release(previousLeases.leases, using: previousLeases.service)
            }
            return await RecordingExportWork.evaluate(
                session: session,
                selection: selection,
                service: service
            )
        }
        assessmentTask = task
        Task { @MainActor [weak self] in
            let result = await task.value
            guard let self else {
                await RecordingExportWork.release(result.leases, using: service)
                return
            }
            guard self.assessmentGeneration == generation,
                  self.selectedSessionID == session.id else {
                await RecordingExportWork.release(result.leases, using: service)
                return
            }
            self.assessmentTask = nil
            self.isAssessing = false
            self.assessment = result.assessment
            self.cachedPlan = result.plan
            self.validatedPlanGeneration = result.plan == nil ? nil : generation
            self.selectedSourceLeases = RecordingExportLeaseBundle(service: service, leases: result.leases)
            self.summary = Self.makeSummary(for: result.assessment, session: session)
        }
    }

    private func invalidateAssessment() {
        assessmentGeneration += 1
        assessmentTask?.cancel()
        assessmentTask = nil
        isAssessing = false
        cachedPlan = nil
        validatedPlanGeneration = nil
    }

    private func releaseSelectedSourceLeases() {
        guard let bundle = selectedSourceLeases else { return }
        selectedSourceLeases = nil
        Task.detached {
            await RecordingExportWork.release(bundle.leases, using: bundle.service)
        }
    }

    private func enqueuePreviewRelease(_ lease: PreviewLease, using service: RecordingPreviewService) {
        let previous = previewReleaseTask
        previewReleaseTask = Task { @MainActor in
            await previous?.value
            await service.release(lease)
        }
    }

    private func releasePreviewLeaseAndWait() async {
        releasePreviewLease()
        let cleanup = previewCleanupTask
        await cleanup?.value
        let release = previewReleaseTask
        await release?.value
    }

    private func finishExportReleasingLeases(
        using service: RecordingPreviewService,
        exportID: UUID
    ) async {
        let bundle = selectedSourceLeases
        selectedSourceLeases = nil
        if let bundle {
            await RecordingExportWork.release(bundle.leases, using: bundle.service)
        } else {
            _ = service
        }
        if activeExportID == exportID {
            activeExportTask = nil
            activeExportID = nil
            isExporting = false
        }
    }

    nonisolated private static func isCompleted(_ record: RecordingSessionRecord) -> Bool {
        guard record.segments.contains(where: { $0.state == .published || $0.state == .missing }) else {
            return false
        }
        return record.segments.allSatisfy { $0.state == .published || $0.state == .missing }
    }

    private static func defaultStem(for record: RecordingSessionRecord) -> String {
        "Recording-\(record.startedAt.formatted(.iso8601.year().month().day()))-\(record.id.uuidString.prefix(8))"
    }

    private static func makeSummary(
        for assessment: ExportAssessment,
        session: RecordingSessionRecord
    ) -> RecordingExportSummary {
        let videoLabel = assessment.videoPassthrough ? "Video passthrough" : "Audio only"
        let audioLabel: String
        switch assessment.audioOperation {
        case .passthrough: audioLabel = "Audio passthrough"
        case .reencodeAudio: audioLabel = "Audio re-encode"
        case .mixedFromPublished: audioLabel = "Mixed published audio"
        case .missingSilence: audioLabel = "Audio source unavailable"
        }
        let missingID = session.segments.first(where: { $0.state == .missing })?.id
        return RecordingExportSummary(
            selectedDuration: assessment.requestedDuration,
            maximumDuration: RecordingExportPlanner.maximumExportDuration,
            overage: assessment.overageSeconds,
            videoPassthroughLabel: videoLabel,
            audioOperationLabel: audioLabel,
            trackCount: assessment.trackMap.count + (assessment.videoPassthrough ? 1 : 0),
            missingState: missingID.map(MissingState.missing(segmentID:)) ?? .none
        )
    }

    private static func exportError(for reason: ExportDisabledReason) -> ExportError {
        switch reason {
        case .emptySelection: .emptySelection
        case .overLimit(let seconds): .overLimit(overageSeconds: seconds)
        case .incompatibleCodec: .incompatibleCodec
        case .missingSource: .missingSource
        case .destinationUnavailable: .destinationUnavailable
        case .passthroughUnsupported: .passthroughUnsupported
        }
    }

    private static func emptyAssessment(destination: ExportDestination) -> ExportAssessment {
        ExportAssessment(
            requestedRanges: [:],
            effectiveRanges: [:],
            requestedDuration: 0,
            effectiveDuration: 0,
            overageSeconds: 0,
            disabledReason: .emptySelection,
            outputSpec: ExportOutputSpec(
                destination: destination,
                shape: .singleFile(fileExtension: "m4a"),
                videoCodec: nil,
                audioFormat: ExportAudioFormat(codec: "aac", sampleRate: 48_000, channelCountByRole: [:])
            ),
            clips: [],
            trackMap: [:],
            audioOperation: .missingSilence,
            videoPassthrough: false,
            estimatedPeakBytes: 0
        )
    }
}

private struct RecordingExportLeaseBundle: Sendable {
    let service: RecordingPreviewService
    let leases: [UUID: PreviewLease]
}

private struct RecordingExportEvaluation: Sendable {
    let assessment: ExportAssessment
    let plan: ExportPlan?
    let leases: [UUID: PreviewLease]
}

private enum RecordingExportWork {
    static func evaluate(
        session: RecordingSessionRecord,
        selection: ExportSelection,
        service: RecordingPreviewService
    ) async -> RecordingExportEvaluation {
        var leases: [UUID: PreviewLease] = [:]
        var sources: [UUID: ExportAudioSource] = [:]

        for segmentID in selection.segmentIDs {
            guard !Task.isCancelled else { break }
            do {
                let lease = try await service.leasePreview(for: segmentID, duration: 24 * 60 * 60)
                leases[segmentID] = lease
                // Adopted segments reference the recorder's original media, which
                // has no sealed-product metadata: read the file itself instead.
                let isRecovered = session.segments
                    .first(where: { $0.id == segmentID })?.materialURL != nil
                sources[segmentID] = isRecovered
                    ? .recoveredMedia(lease.mediaURLs)
                    : .publishedMedia(lease.mediaURLs)
            } catch {
                // The planner reports the real missing-source disabled reason.
            }
        }

        if Task.isCancelled {
            return RecordingExportEvaluation(
                assessment: RecordingExportPlanner.assess(
                    session: session,
                    selection: selection,
                    audioSourcesBySegment: [:]
                ),
                plan: nil,
                leases: leases
            )
        }

        let assessment = RecordingExportPlanner.assess(
            session: session,
            selection: selection,
            audioSourcesBySegment: sources
        )
        guard assessment.disabledReason == nil else {
            return RecordingExportEvaluation(assessment: assessment, plan: nil, leases: leases)
        }
        do {
            let plan = try RecordingExportPlanner.plan(
                session: session,
                selection: selection,
                audioSourcesBySegment: sources
            )
            return RecordingExportEvaluation(assessment: assessment, plan: plan, leases: leases)
        } catch {
            let refreshed = RecordingExportPlanner.assess(
                session: session,
                selection: selection,
                audioSourcesBySegment: sources
            )
            return RecordingExportEvaluation(assessment: refreshed, plan: nil, leases: leases)
        }
    }

    static func release(_ leases: [UUID: PreviewLease], using service: RecordingPreviewService) async {
        for lease in leases.values { await service.release(lease) }
    }
}

@MainActor
private final class RecordingExportAudioPreviewPlayer {
    private var engine: AVAudioEngine?
    private var nodes: [AVAudioPlayerNode] = []
    private var files: [AVAudioFile] = []
    private var unfinishedTracks = 0
    private var onFinished: (() -> Void)?

    var isPlaying: Bool { engine != nil }

    func play(urls: [URL], gain: Float, onFinished: @escaping () -> Void) throws {
        stop()
        guard !urls.isEmpty else { throw RecordingPreviewError.notPreviewable }

        let engine = AVAudioEngine()
        var files: [AVAudioFile] = []
        var nodes: [AVAudioPlayerNode] = []
        for url in urls {
            let file = try AVAudioFile(forReading: url)
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
            node.scheduleFile(file, at: nil) { [weak self] in
                Task { @MainActor [weak self] in self?.trackFinished() }
            }
            files.append(file)
            nodes.append(node)
        }

        engine.mainMixerNode.outputVolume = Self.clampedGain(gain)
        try engine.start()
        self.engine = engine
        self.files = files
        self.nodes = nodes
        unfinishedTracks = nodes.count
        self.onFinished = onFinished

        let hostTime = AudioGetCurrentHostTime() + AVAudioTime.hostTime(forSeconds: 0.08)
        let startTime = AVAudioTime(hostTime: hostTime)
        nodes.forEach { $0.play(at: startTime) }
    }

    func setGain(_ gain: Float) {
        engine?.mainMixerNode.outputVolume = Self.clampedGain(gain)
    }

    func stop() {
        let engine = self.engine
        let nodes = self.nodes
        self.engine = nil
        self.nodes = []
        files = []
        unfinishedTracks = 0
        onFinished = nil
        nodes.forEach { $0.stop() }
        engine?.stop()
    }

    private func trackFinished() {
        guard engine != nil else { return }
        unfinishedTracks -= 1
        guard unfinishedTracks == 0 else { return }
        let completion = onFinished
        stop()
        completion?()
    }

    private static func clampedGain(_ gain: Float) -> Float {
        gain.isFinite ? min(1, max(0, gain)) : 0
    }
}
