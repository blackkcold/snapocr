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
    @Published var publishedSessions: [RecordingSessionRecord] = []
    @Published var selectedSessionID: UUID?
    @Published var session: RecordingSessionRecord?
    @Published var selectedSegmentIDs: Set<UUID> = []
    @Published var assessment: ExportAssessment?
    @Published var summary: RecordingExportSummary?
    @Published var outputMode: RecordingExportOutputMode = .mixedAudio
    @Published var outputDirectory: URL
    @Published var outputStem: String
    @Published var audioGainDB: Double = 0
    @Published var previewGain: Double = 0.8
    @Published var isLoading = false
    @Published var isOpeningSession = false
    @Published var isAssessing = false
    @Published var isExporting = false
    @Published var exportProgress: Double = 0
    @Published var previewSegmentID: UUID?
    @Published var message: RecordingExportViewMessage?
    @Published var succeededOutputURL: URL?
    /// Interrupted sessions that still have media but no published entry.
    @Published var recoverableRecordings: [RecoverableRecording] = []
    /// Whether a recovery scan is running.
    @Published var isScanningRecoverable = false
    /// Session currently being adopted, so its row can show progress.
    @Published var recoveringRecordingID: UUID?
    /// Session currently being moved to the Trash.
    @Published var discardingRecordingID: UUID?
    /// One-time feedback for the last recovery action.
    @Published var recoveryNotice: RecordingRecoveryNotice?

    let roots: [RecordingExportRoot]
    private let primaryRoot: URL

    /// Root of the selected session, or the first configured folder.
    var recordingRoot: URL {
        selectedExportRoot?.root ?? primaryRoot
    }

    let exporter = RecordingCompositionExporter()
    var ledger: RecordingSessionLedger?
    var previewService: RecordingPreviewService?
    var exportRootBySessionID: [UUID: RecordingExportRoot] = [:]
    var hasUserChosenOutputDirectory = false
    var rangesBySegment: [UUID: SampleRange] = [:]
    var assessmentGeneration = 0
    var sessionGeneration = 0
    var listGeneration = 0
    var previewGeneration = 0
    var assessmentTask: Task<RecordingExportEvaluation, Never>?
    var previewTask: Task<Void, Never>?
    var previewCleanupTask: Task<Void, Never>?
    var previewReleaseTask: Task<Void, Never>?
    var previewLease: PreviewLease?
    var previewPlayer: RecordingExportAudioPreviewPlayer?
    var selectedSourceLeases: RecordingExportLeaseBundle?
    var cachedPlan: ExportPlan?
    var validatedPlanGeneration: Int?
    var activeExportTask: Task<ExportResult, Error>?
    var activeExportID: UUID?
    var exportGeneration = 0

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
            cachedPlan != nil
        else { return false }
        return true
    }

    var hasPreviewableSegment: Bool {
        session?.segments.contains(where: { $0.state == .published }) == true
    }

    var isPreviewPreparing: Bool { previewTask != nil }
    var isPreviewPlaying: Bool { previewPlayer?.isPlaying == true }
}

struct RecordingExportLeaseBundle: Sendable {
    let service: RecordingPreviewService
    let leases: [UUID: PreviewLease]
}

struct RecordingExportEvaluation: Sendable {
    let assessment: ExportAssessment
    let plan: ExportPlan?
    let leases: [UUID: PreviewLease]
}

enum RecordingExportWork {
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
                let isRecovered =
                    session.segments
                    .first(where: { $0.id == segmentID })?.materialURL != nil
                sources[segmentID] =
                    isRecovered
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
final class RecordingExportAudioPreviewPlayer {
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
