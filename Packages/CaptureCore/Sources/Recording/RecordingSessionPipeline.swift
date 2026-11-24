import AudioToolbox
import Foundation

public enum PublishedSegmentState: String, Codable, Sendable, Hashable {
    case recording
    case sealing
    case publishing
    case published
    case failedRecoverable
    case missing
    case requiresNewerVersion
}

public struct PublishedSegment: Codable, Sendable, Hashable {
    public let id: UUID
    public let index: Int
    public let files: [String: String]
    public let startSample: Int64
    public let sampleCount: Int64
    public let trackMap: [String: Int]
    public let missingRanges: [RecordingSampleRange]
    public let state: PublishedSegmentState
    public let videoURL: URL?
    public let videoTrackIndex: Int?
    /// Media that was adopted in place after an interrupted session.
    ///
    /// Normal publications resolve their product from the publish intent, so this
    /// stays `nil` for them. An adopted segment points at media that already
    /// existed on disk (for example an interrupted CAF), which lets preview and
    /// export read the original bytes instead of waiting for a sealed product.
    /// Optional so index records written before adoption still decode unchanged.
    public let materialURL: URL?

    public init(
        id: UUID,
        index: Int,
        files: [String: String],
        startSample: Int64,
        sampleCount: Int64,
        trackMap: [String: Int],
        missingRanges: [RecordingSampleRange],
        state: PublishedSegmentState,
        videoURL: URL? = nil,
        videoTrackIndex: Int? = nil,
        materialURL: URL? = nil
    ) {
        self.id = id
        self.index = index
        self.files = files
        self.startSample = startSample
        self.sampleCount = sampleCount
        self.trackMap = trackMap
        self.missingRanges = missingRanges
        self.state = state
        self.videoURL = videoURL
        self.videoTrackIndex = videoTrackIndex
        self.materialURL = materialURL
    }
}

public struct RecordingSessionRecord: Codable, Sendable, Hashable {
    public let id: UUID
    public let kind: RecordingKind
    public let layout: AudioOutputLayout
    public let startedAt: Date
    public let segments: [PublishedSegment]

    public init(
        id: UUID,
        kind: RecordingKind,
        layout: AudioOutputLayout,
        startedAt: Date,
        segments: [PublishedSegment]
    ) {
        self.id = id
        self.kind = kind
        self.layout = layout
        self.startedAt = startedAt
        self.segments = segments
    }

    private enum CodingKeys: String, CodingKey { case id, kind, layout, startedAt, segments }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        switch try values.decode(String.self, forKey: .kind) {
        case "audio": kind = .audio
        case "screen": kind = .screen
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: values, debugDescription: "Unknown recording kind")
        }
        switch try values.decode(String.self, forKey: .layout) {
        case "mixed": layout = .mixed
        case "separateTracks": layout = .separateTracks
        default: throw DecodingError.dataCorruptedError(forKey: .layout, in: values, debugDescription: "Unknown audio layout")
        }
        startedAt = try values.decode(Date.self, forKey: .startedAt)
        segments = try values.decode([PublishedSegment].self, forKey: .segments)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(kind == .audio ? "audio" : "screen", forKey: .kind)
        try values.encode(layout == .mixed ? "mixed" : "separateTracks", forKey: .layout)
        try values.encode(startedAt, forKey: .startedAt)
        try values.encode(segments, forKey: .segments)
    }
}

public struct RecoverableSession: Sendable, Hashable {
    public let sessionID: UUID
    public let segmentIndex: Int
    public let estimatedSeconds: Double
    public let state: PublishedSegmentState

    public init(sessionID: UUID, segmentIndex: Int, estimatedSeconds: Double, state: PublishedSegmentState) {
        self.sessionID = sessionID
        self.segmentIndex = segmentIndex
        self.estimatedSeconds = estimatedSeconds
        self.state = state
    }
}

public struct RecordingPublishIntent: Codable, Sendable, Hashable {
    public let segmentID: UUID
    public let segmentIndex: Int
    public let reservedFinalURL: URL
    public let stagingURL: URL
    public let isDirectory: Bool
    public let contentHashes: [String: String]
    public let effectiveRange: RecordingSampleRange
    public let coverage: RecordingSegmentCoverage

    public init(
        segmentID: UUID,
        segmentIndex: Int,
        reservedFinalURL: URL,
        stagingURL: URL,
        isDirectory: Bool,
        contentHashes: [String: String],
        effectiveRange: RecordingSampleRange,
        coverage: RecordingSegmentCoverage
    ) {
        self.segmentID = segmentID
        self.segmentIndex = segmentIndex
        self.reservedFinalURL = reservedFinalURL
        self.stagingURL = stagingURL
        self.isDirectory = isDirectory
        self.contentHashes = contentHashes
        self.effectiveRange = effectiveRange
        self.coverage = coverage
    }
}

public struct PreviewLease: Sendable, Hashable {
    public let id: UUID
    public let segmentID: UUID
    public let mediaURLs: [URL]
    public let expiresAt: Date

    public init(id: UUID, segmentID: UUID, mediaURLs: [URL], expiresAt: Date) {
        self.id = id
        self.segmentID = segmentID
        self.mediaURLs = mediaURLs
        self.expiresAt = expiresAt
    }
}

public enum PreviewTarget: Sendable, Hashable {
    case segment(UUID)
    case checkpoint(UUID)
}

public enum RecordingSpaceState: Sendable, Hashable { case ok, low, stopping, blocked }

public struct RecordingSpaceStatus: Sendable, Hashable {
    public let state: RecordingSpaceState
    public let requiredBytes: Int64
    public let availableBytes: Int64
    public let backlogBytes: Int64
    public let checkpointAgeSeconds: Double
    public let reason: String?

    public init(
        state: RecordingSpaceState,
        requiredBytes: Int64,
        availableBytes: Int64,
        backlogBytes: Int64,
        checkpointAgeSeconds: Double,
        reason: String?
    ) {
        self.state = state
        self.requiredBytes = requiredBytes
        self.availableBytes = availableBytes
        self.backlogBytes = backlogBytes
        self.checkpointAgeSeconds = checkpointAgeSeconds
        self.reason = reason
    }
}

public enum RecordingSealAdmission: Sendable, Hashable {
    case run
    case `defer`(reason: String)
    case stop(reason: String)
}

/// One role that actually receives recorded bytes.
///
/// A directory with no writer is not a write role and must not be added to a
/// budget or a preflight decision.
public enum RecordingWriteRole: String, Sendable, Hashable {
    /// The destination that receives checkpoints, final media, and recovery materials.
    case recording
}

/// The measured state of one distinct write volume in a single preflight decision.
public struct RecordingVolumePlan: Sendable, Hashable {
    /// The write role that owns this volume.
    public let role: RecordingWriteRole
    /// One root on the volume, used for diagnostics.
    public let path: URL
    /// The volume identity read with the capacity snapshot.
    public let identity: RecordingVolumeIdentity?
    /// Bytes required by all write roots that share this volume.
    public let requiredBytes: Int64
    /// Free bytes, or `nil` when the volume could not be read.
    public let availableBytes: Int64?
    /// Whether the write location itself was confirmed.
    public let isLocationAvailable: Bool

    /// Creates one write-volume plan.
    public init(
        role: RecordingWriteRole,
        path: URL,
        identity: RecordingVolumeIdentity?,
        requiredBytes: Int64,
        availableBytes: Int64?,
        isLocationAvailable: Bool
    ) {
        self.role = role
        self.path = path
        self.identity = identity
        self.requiredBytes = requiredBytes
        self.availableBytes = availableBytes
        self.isLocationAvailable = isLocationAvailable
    }
}

/// Why a write-volume preflight denied the start.
public enum RecordingSpaceDenial: Sendable, Hashable {
    /// The write location is missing, not a directory, or not writable.
    case locationUnavailable(role: RecordingWriteRole, path: String)
    /// The write location exists but its free space could not be read.
    case capacityUnreadable(role: RecordingWriteRole)
    /// The volume has less free space than the recording requires.
    case insufficient(role: RecordingWriteRole, available: Int64, required: Int64)
}

/// The result of one start-time space decision.
public struct SpaceBudgetDecision: Sendable, Hashable {
    /// Whether every write volume meets its own requirement.
    public let allowed: Bool
    /// Requirement of the binding volume (the first failing volume, else the least slack).
    public let requiredBytes: Int64
    /// Available bytes of the binding volume.
    public let availableBytes: Int64
    /// A short diagnostic reason; the App layer maps `denial` to user text.
    public let reason: String?
    /// One entry per distinct write volume; unrelated directories never appear.
    public let volumes: [RecordingVolumePlan]
    /// A structured denial when `allowed` is false.
    public let denial: RecordingSpaceDenial?

    /// Creates a start-time space decision.
    ///
    /// - Parameters:
    ///   - allowed: Whether every write volume meets its requirement.
    ///   - requiredBytes: Requirement of the binding volume.
    ///   - availableBytes: Available bytes of the binding volume.
    ///   - reason: A short diagnostic reason.
    ///   - volumes: One plan per distinct write volume.
    ///   - denial: A structured denial when not allowed.
    public init(
        allowed: Bool,
        requiredBytes: Int64,
        availableBytes: Int64,
        reason: String?,
        volumes: [RecordingVolumePlan] = [],
        denial: RecordingSpaceDenial? = nil
    ) {
        self.allowed = allowed
        self.requiredBytes = requiredBytes
        self.availableBytes = availableBytes
        self.reason = reason
        self.volumes = volumes
        self.denial = denial
    }
}

public protocol RecordingSpaceGating: Sendable {
    func preflightStart() async throws -> SpaceBudgetDecision
    func checkpointCommitted(_ commit: CheckpointCommit, backlogBytes: Int64) async -> RecordingSpaceStatus
    func admitSeal(segmentIndex: Int, backlogBytes: Int64) async -> RecordingSealAdmission
    func sealFinished(segmentIndex: Int) async
    func makeStatusStream() -> AsyncStream<RecordingSpaceStatus>
}

public struct RecordingPipelineRoots: Sendable, Hashable {
    public let sessionRoot: URL
    public let indexURL: URL
    public let outputDirectory: URL

    public init(sessionRoot: URL, indexURL: URL, outputDirectory: URL) {
        self.sessionRoot = sessionRoot
        self.indexURL = indexURL
        self.outputDirectory = outputDirectory
    }
}

public enum RecordingPipelineError: Error, Equatable, Sendable {
    case alreadyStarted
    case invalidConfiguration
    case spacePreflightDenied(SpaceBudgetDecision)
    case journalUnavailable
    case engineUnavailable
}

public enum RecordingPipelineDiagnosticPhase: String, Sendable, Hashable {
    case sessionStarted
    case checkpointCommitted
    case sealStarted
    case sealFinished
    case published
    case recovered
    case spaceStateChanged
}

/// Low-cardinality lifecycle diagnostics; deliberately contains no media path or samples.
public struct RecordingPipelineDiagnosticEvent: Sendable, Hashable {
    public let phase: RecordingPipelineDiagnosticPhase
    public let sessionID: UUID
    public let segmentIndex: Int?
    public let range: RecordingSampleRange?
    public let durationSeconds: Double
    public let byteCount: Int64

    public init(
        phase: RecordingPipelineDiagnosticPhase,
        sessionID: UUID,
        segmentIndex: Int? = nil,
        range: RecordingSampleRange? = nil,
        durationSeconds: Double = 0,
        byteCount: Int64 = 0
    ) {
        self.phase = phase
        self.sessionID = sessionID
        self.segmentIndex = segmentIndex
        self.range = range
        self.durationSeconds = durationSeconds
        self.byteCount = byteCount
    }
}

private struct PendingTick {
    let range: SampleRange
    var blocks: [RecordingTrackRole: AudioPCMBlock]
    var deliveredRoles: Set<RecordingTrackRole> = []
}

/// Bridges T1's append/commit sink to T7's segmented coordinator and T9's journal.
public actor LedgerCheckpointSink: AudioCheckpointSink {
    private let coordinator: SegmentedWriterCoordinator
    private let ledger: RecordingSessionLedger
    private let spaceGate: (any RecordingSpaceGating)?
    private let onSegmentClosed: @Sendable (Int, UUID?) -> Void
    private let onSpaceStatus: @Sendable (RecordingSpaceStatus) async -> Void
    private var pendingTick: PendingTick?
    private var pendingJournal: [CheckpointCommit] = []
    private var lastDurableCommit: CheckpointCommit?
    private var lastSampleEnd: Int64 = 0
    private var nextSegmentToClose = 0
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var sealBacklogBytesBySegment: [Int: Int64] = [:]

    public init(
        coordinator: SegmentedWriterCoordinator,
        ledger: RecordingSessionLedger,
        spaceGate: (any RecordingSpaceGating)? = nil
    ) {
        self.coordinator = coordinator
        self.ledger = ledger
        self.spaceGate = spaceGate
        self.onSegmentClosed = { _, _ in }
        self.onSpaceStatus = { _ in }
    }

    init(
        coordinator: SegmentedWriterCoordinator,
        ledger: RecordingSessionLedger,
        spaceGate: (any RecordingSpaceGating)?,
        onSegmentClosed: @escaping @Sendable (Int, UUID?) -> Void,
        onSpaceStatus: @escaping @Sendable (RecordingSpaceStatus) async -> Void
    ) {
        self.coordinator = coordinator
        self.ledger = ledger
        self.spaceGate = spaceGate
        self.onSegmentClosed = onSegmentClosed
        self.onSpaceStatus = onSpaceStatus
    }

    public func append(_ block: AudioPCMBlock) async throws {
        await acquire()
        defer { release() }
        guard block.frameCount > 0, block.range.sampleCount == Int64(block.frameCount),
              block.sampleRate == 48_000, block.channelCount == block.channels.count,
              block.channels.allSatisfy({ $0.count == block.frameCount }),
              block.role == .mixed || block.role == .system || block.role == .microphone
        else { throw RecordingCheckpointError.incompatibleFormat(role: block.role) }
        if var current = pendingTick {
            if current.range == block.range {
                guard current.blocks[block.role] == nil else {
                    throw RecordingCheckpointError.rangeOverlap(
                        expectedStart: block.range.startSample, actualStart: block.range.startSample
                    )
                }
                current.blocks[block.role] = block
                pendingTick = current
                return
            }
            let currentEnd = current.range.startSample + current.range.sampleCount
            guard block.range.startSample == currentEnd else {
                throw RecordingCheckpointError.nonContiguousRange(
                    expectedStart: currentEnd, actualStart: block.range.startSample
                )
            }
            pendingTick = current
            try await flushPendingTick()
        } else if block.range.startSample != lastSampleEnd {
            guard lastSampleEnd == 0, block.range.startSample == 0 else {
                throw RecordingCheckpointError.nonContiguousRange(
                    expectedStart: lastSampleEnd, actualStart: block.range.startSample
                )
            }
        }
        pendingTick = PendingTick(range: block.range, blocks: [block.role: block])
    }

    /// Engine stop path: flushes the final complete tick group and journals all commits.
    public func commitCheckpoint() async throws -> CheckpointCommit {
        await acquire()
        defer { release() }
        try await flushPendingTick()
        try await commitCoordinatorBatch()
        guard let lastDurableCommit else { throw RecordingCheckpointError.emptyCheckpoint }
        return lastDurableCommit
    }

    /// Monotonic T9 cadence path: commits only tick groups already closed by a later range.
    func commitReadyCheckpoints() async throws -> [CheckpointCommit] {
        await acquire()
        defer { release() }
        return try await commitCoordinatorBatch()
    }

    func finishTail() async throws {
        await acquire()
        defer { release() }
        try await flushPendingTick()
        try await commitCoordinatorBatch()
        guard lastSampleEnd > 0 else { return }
        let plan = AudioSegmentPlan()
        let index = Int((lastSampleEnd - 1) / plan.maximumSegmentSamples)
        guard index >= nextSegmentToClose else { return }
        let bundle = try await coordinator.closeSegmentBundle(at: index, isFinal: true)
        try await journal(bundle.checkpoints.checkpoints)
        try await ledger.recordClosedSegment(bundle)
        nextSegmentToClose = index + 1
        sealBacklogBytesBySegment[index] = Self.byteCount(bundle.checkpoints.checkpoints)
        onSegmentClosed(index, bundle.checkpoints.checkpoints.last?.checkpointID)
    }

    func retryPendingJournal() async throws {
        await acquire()
        defer { release() }
        try await drainPendingJournal()
    }

    func sealBacklogBytes() -> Int64 {
        sealBacklogBytesBySegment.values.reduce(0, +)
    }

    func sealFinished(segmentIndex: Int) async {
        await acquire()
        defer { release() }
        sealBacklogBytesBySegment[segmentIndex] = nil
        await spaceGate?.sealFinished(segmentIndex: segmentIndex)
    }

    func checkpointFacts() async -> (sampleEnd: Int64, committedAt: Date?, publishedCount: Int) {
        await ledger.progressFacts()
    }

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { continuation in waiters.append(continuation) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    private func flushPendingTick() async throws {
        guard var tick = pendingTick else { return }
        for role in [RecordingTrackRole.mixed, .system, .microphone] {
            guard let block = tick.blocks[role], !tick.deliveredRoles.contains(role) else { continue }
            try await coordinator.append(block)
            tick.deliveredRoles.insert(role)
            pendingTick = tick
        }
        pendingTick = nil
        lastSampleEnd = tick.range.startSample + tick.range.sampleCount
        try await closeCompletedSegments(through: lastSampleEnd)
    }

    private func closeCompletedSegments(through sampleEnd: Int64) async throws {
        let plan = AudioSegmentPlan()
        while nextSegmentToClose < Int.max {
            let start = Int64(nextSegmentToClose).multipliedReportingOverflow(by: plan.maximumSegmentSamples)
            guard !start.overflow else { throw RecordingCheckpointError.invalidConfiguration }
            let boundary = try plan.boundary(containing: start.partialValue)
            guard boundary.endSample <= sampleEnd else { return }
            let bundle = try await coordinator.closeSegmentBundle(at: boundary.index)
            try await journal(bundle.checkpoints.checkpoints)
            try await ledger.recordClosedSegment(bundle)
            sealBacklogBytesBySegment[boundary.index] = Self.byteCount(bundle.checkpoints.checkpoints)
            nextSegmentToClose = boundary.index + 1
            onSegmentClosed(boundary.index, bundle.checkpoints.checkpoints.last?.checkpointID)
        }
    }

    private func commitCoordinatorBatch() async throws -> [CheckpointCommit] {
        try await drainPendingJournal()
        let commits = try await coordinator.commitAvailableCheckpoints()
        pendingJournal.append(contentsOf: commits)
        try await drainPendingJournal()
        return commits
    }

    private func journal(_ commits: [CheckpointCommit]) async throws {
        pendingJournal.append(contentsOf: commits)
        try await drainPendingJournal()
    }

    private func drainPendingJournal() async throws {
        while let commit = pendingJournal.first {
            try await ledger.commit(commit)
            pendingJournal.removeFirst()
            lastDurableCommit = commit
            if let spaceGate {
                let status = await spaceGate.checkpointCommitted(commit, backlogBytes: sealBacklogBytes())
                await onSpaceStatus(status)
            }
        }
    }

    private static func byteCount(_ commits: [CheckpointCommit]) -> Int64 {
        commits.reduce(into: Int64(0)) { total, commit in
            for url in commit.trackURLs.values {
                if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber {
                    total += size.int64Value
                }
            }
        }
    }
}

public enum RecordingAudioPipelineFactory {
    public static func make(
        configuration: AudioRecordingConfiguration,
        roots: RecordingPipelineRoots,
        spaceGate: (any RecordingSpaceGating)? = nil,
        fileManager: FileManager = .default
    ) throws -> RecordingSessionPipeline {
        let recordingRoot: URL
        let outputDirectory: URL
        do {
            recordingRoot = try RecordingLedgerFileSystem.canonicalDirectory(roots.sessionRoot, create: true)
            outputDirectory = try RecordingLedgerFileSystem.canonicalDirectory(roots.outputDirectory, create: true)
        } catch { throw RecordingPipelineError.invalidConfiguration }
        guard configuration.kind == .audio, configuration.sampleRate == 48_000,
              !configuration.channelCountByRole.isEmpty,
              configuration.mode != .none,
              let roles = Self.roles(for: configuration)
        else { throw RecordingPipelineError.invalidConfiguration }

        let sessionID = UUID()
        let sendableFileManager = RecordingSendableFileManager(fileManager)
        let sessionsRoot = recordingRoot.appendingPathComponent(".SnapGlassSessions", isDirectory: true)
        let canonicalSessionsRoot: URL
        do {
            canonicalSessionsRoot = try RecordingLedgerFileSystem.canonicalDirectory(sessionsRoot, create: true)
        } catch { throw RecordingPipelineError.invalidConfiguration }
        let sessionRoot = canonicalSessionsRoot.appendingPathComponent(
            sessionID.uuidString.lowercased(), isDirectory: true
        )
        let ledger: RecordingSessionLedger
        do {
            ledger = try RecordingSessionLedger(
                sessionRoot: sessionRoot,
                indexURL: roots.indexURL,
                sessionID: sessionID,
                fileManager: sendableFileManager
            )
        } catch { throw RecordingPipelineError.invalidConfiguration }

        let coordinator: SegmentedWriterCoordinator
        do {
            coordinator = try SegmentedWriterCoordinator(plan: AudioSegmentPlan()) { boundary in
                let segmentRoot = sessionRoot.appendingPathComponent(
                    String(format: "segment-%08d", boundary.index), isDirectory: true
                )
                try sendableFileManager.value.createDirectory(
                    at: segmentRoot, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                return try RecordingCheckpointWriter(
                    directory: segmentRoot,
                    sessionRoot: sessionRoot,
                    segment: boundary,
                    sampleRate: configuration.sampleRate,
                    roles: roles
                )
            }
        } catch { throw RecordingPipelineError.invalidConfiguration }
        let sealService = RecordingSealService(
            publicationHooks: [LedgerPublicationHook(ledger: ledger)]
        )
        let pipelineRoots = RecordingPipelineRoots(
            sessionRoot: recordingRoot,
            indexURL: roots.indexURL,
            outputDirectory: outputDirectory
        )
        let engineFactory: @Sendable (
            AudioRecordingConfiguration,
            any AudioCheckpointSink & Sendable,
            AudioSampleClock
        ) throws -> any AudioRecordingControlling & Sendable = { config, sink, clock in
            try Self.makeNativeEngine(configuration: config, sink: sink, clock: clock)
        }
        return try RecordingSessionPipeline(
            roots: pipelineRoots,
            ledger: ledger,
            coordinator: coordinator,
            sealService: sealService,
            spaceGate: spaceGate,
            engineFactory: engineFactory,
            expectedConfiguration: configuration,
            fileManager: sendableFileManager
        )
    }

    private static func roles(for configuration: AudioRecordingConfiguration) -> Set<RecordingTrackRole>? {
        if configuration.layout == .mixed { return [.mixed] }
        switch configuration.mode {
        case .system: return [.system]
        case .microphone: return [.microphone]
        case .systemAndMicrophone: return [.system, .microphone]
        case .none: return nil
        }
    }

    private static func makeNativeEngine(
        configuration: AudioRecordingConfiguration,
        sink: any AudioCheckpointSink & Sendable,
        clock: AudioSampleClock
    ) throws -> any AudioRecordingControlling & Sendable {
        let ticksPerSecond = AudioSourceTimestampMapper.nativeHostTicksPerSecond()
        let system = try SystemAudioSource(
            format: AudioSourceFormat(sampleRate: 48_000, channelCount: 2),
            hostTicksPerSecond: ticksPerSecond,
            factory: SCKSystemAudioStreamFactory(),
            deviceMonitor: CoreAudioDeviceChangeMonitor()
        )
        let authorizer = SendableMicrophoneAuthorizer(AVMicrophoneAuthorizer())
        let microphone = try LazyMicrophoneSource(
            authorizer: authorizer,
            hostTicksPerSecond: ticksPerSecond,
            channelCount: configuration.channelCountByRole[.microphone] ?? 1
        )
        let routeController = AudioRouteController(
            authorizer: authorizer,
            sources: [.system: system, .microphone: microphone]
        )
        let pump = AudioMixPump(
            clock: clock,
            policy: AudioMixPolicy(sampleRate: configuration.sampleRate),
            layout: configuration.layout,
            blockFrames: 480,
            channelCountByRole: configuration.channelCountByRole
        )
        return AudioRecordingEngine(
            sink: sink,
            clock: clock,
            sources: [.system: system, .microphone: microphone],
            routeController: routeController,
            pump: pump
        )
    }
}

/// Defers all native microphone input-node access until an authorized route starts.
private actor LazyMicrophoneSource: AudioFrameSource, AudioSourceReconfigurationCancelling {
    nonisolated let role: RecordingTrackRole = .microphone
    private let authorizer: SendableMicrophoneAuthorizer
    private let hostTicksPerSecond: UInt64
    private let channelCount: Int
    private let placeholderGeneration: AudioSourceGeneration
    private var source: MicrophoneSource?

    init(authorizer: SendableMicrophoneAuthorizer, hostTicksPerSecond: UInt64, channelCount: Int) throws {
        let safeChannels = (1...2).contains(channelCount) ? channelCount : 1
        self.authorizer = authorizer
        self.hostTicksPerSecond = hostTicksPerSecond
        self.channelCount = safeChannels
        placeholderGeneration = try AudioSourceGeneration(
            role: .microphone,
            format: AudioSourceFormat(sampleRate: 48_000, channelCount: safeChannels),
            hostTicksPerSecond: hostTicksPerSecond
        )
    }

    func currentGeneration() async -> AudioSourceGeneration {
        if let source { return await source.currentGeneration() }
        return placeholderGeneration
    }

    func start() async throws {
        if let source {
            try await source.start()
            return
        }
        guard authorizer.currentState() == .authorized else {
            throw AudioSourceError.microphoneNotAuthorized(authorizer.currentState())
        }
        let capture = AVAudioEngineMicrophoneCaptureEngine()
        guard let format = capture.currentFormat,
              format.commonFormat == .pcmFormatFloat32,
              format.channelCount == 1 || format.channelCount == 2,
              format.sampleRate > 0
        else { throw AudioSourceError.invalidFormat }
        let sourceFormat = AudioSourceFormat(
            sampleRate: Int(format.sampleRate.rounded()),
            channelCount: Int(format.channelCount)
        )
        let ring = try AudioSourceRingBuffer(
            role: .microphone,
            sampleRate: sourceFormat.sampleRate,
            channelCount: sourceFormat.channelCount,
            hostTicksPerSecond: hostTicksPerSecond,
            capacitySeconds: 2.0
        )
        let nativeSource = MicrophoneSource(
            ringBuffer: ring,
            authorizer: authorizer,
            engine: capture,
            deviceMonitor: CoreAudioDeviceChangeMonitor(),
            format: sourceFormat,
            hostTicksPerSecond: hostTicksPerSecond
        )
        source = nativeSource
        try await nativeSource.start()
    }

    func isRunning() async -> Bool { await source?.isRunning() ?? false }

    func stop() async { await source?.stop() }

    func isProducerJoined() async -> Bool { await source?.isProducerJoined() ?? true }

    func prepareReconfiguration(_ event: AudioDeviceChangeEvent) async -> AudioSourcePreparation {
        guard let source else { return .unchangedOnFailure(reason: "microphone is not active") }
        return await source.prepareReconfiguration(event)
    }

    func commitReconfiguration(_ generation: AudioSourceGeneration) async -> Bool {
        guard let source else { return false }
        return await source.commitReconfiguration(generation)
    }

    func cancelReconfiguration(_ generationID: UUID) async {
        await source?.cancelReconfiguration(generationID)
    }
}

private struct SendableMicrophoneAuthorizer: MicrophoneAuthorizing, @unchecked Sendable {
    private let base: any MicrophoneAuthorizing

    init(_ base: any MicrophoneAuthorizing) { self.base = base }

    func currentState() -> MicrophoneAuthorizationState { base.currentState() }

    func requestAccess() async -> MicrophoneAuthorizationState { await base.requestAccess() }
}

public struct LedgerPublicationHook: SegmentPublicationHooking {
    private let ledger: RecordingSessionLedger

    public init(ledger: RecordingSessionLedger) { self.ledger = ledger }

    public func beforePublish(_ candidate: SegmentPublicationCandidate) async throws {
        let intent = RecordingPublishIntent(
            segmentID: candidate.segmentID,
            segmentIndex: candidate.segmentIndex,
            reservedFinalURL: candidate.reservedFinalURL,
            stagingURL: candidate.stagingURL,
            isDirectory: candidate.isDirectory,
            contentHashes: candidate.contentHashes,
            effectiveRange: candidate.effectiveRange,
            coverage: candidate.coverage
        )
        try await ledger.recordPublishIntent(intent)
    }
}

private enum SealSignal: Sendable { case closed(Int); case retry }

/// The production session composition root: real T5/T6 engine, T7 CAF writer, T8 seal, T9 journal.
public actor RecordingSessionPipeline: AudioRecordingControlling {
    public nonisolated let ledger: RecordingSessionLedger

    private let roots: RecordingPipelineRoots
    private let coordinator: SegmentedWriterCoordinator
    private let sealService: RecordingSealService
    private let spaceGate: (any RecordingSpaceGating)?
    private let engineFactory: @Sendable (
        AudioRecordingConfiguration,
        any AudioCheckpointSink & Sendable,
        AudioSampleClock
    ) throws -> any AudioRecordingControlling & Sendable
    private let expectedConfiguration: AudioRecordingConfiguration?
    private let fileManager: RecordingSendableFileManager
    private var activeConfiguration: AudioRecordingConfiguration?
    private let diagnosticBroadcaster = RecordingDiagnosticBroadcaster()
    private let progressBroadcaster = RecordingProgressBroadcaster()
    private let previewReadyBroadcaster = RecordingPreviewReadyBroadcaster()

    private var engine: (any AudioRecordingControlling & Sendable)?
    private var checkpointSink: LedgerCheckpointSink?
    private var timerTask: Task<Void, Never>?
    private var sealWorkerTask: Task<Void, Never>?
    private var spaceStatusTask: Task<Void, Never>?
    private var engineProgressTask: Task<Void, Never>?
    private var sealContinuation: AsyncStream<SealSignal>.Continuation?
    private var sealQueue: [Int] = []
    private var deferredSealIndices: Set<Int> = []
    private var processingSeal = false
    private var engineProgress: RecordingProgress?
    private var lastProgressPublishedAt: ContinuousClock.Instant?
    private var startedAt: Date?
    private var started = false
    private var starting = false
    private var stopping = false
    private var spaceSafeStopRequested = false
    private var lastSpaceState: RecordingSpaceState?
    private var pipelineFailure: String?
    private var stopTask: Task<AudioRecordingResult, Never>?
    private var lastResult: AudioRecordingResult?

    public init(
        roots: RecordingPipelineRoots,
        ledger: RecordingSessionLedger,
        coordinator: SegmentedWriterCoordinator,
        sealService: RecordingSealService,
        spaceGate: (any RecordingSpaceGating)? = nil,
        engineFactory: @escaping @Sendable (
            AudioRecordingConfiguration,
            any AudioCheckpointSink & Sendable,
            AudioSampleClock
        ) throws -> any AudioRecordingControlling & Sendable
    ) throws {
        guard roots.sessionRoot.isFileURL, roots.outputDirectory.isFileURL,
              roots.indexURL.isFileURL else { throw RecordingPipelineError.invalidConfiguration }
        self.roots = roots
        self.ledger = ledger
        self.coordinator = coordinator
        self.sealService = sealService
        self.spaceGate = spaceGate
        self.engineFactory = engineFactory
        self.expectedConfiguration = nil
        self.fileManager = RecordingSendableFileManager(.default)
    }

    init(
        roots: RecordingPipelineRoots,
        ledger: RecordingSessionLedger,
        coordinator: SegmentedWriterCoordinator,
        sealService: RecordingSealService,
        spaceGate: (any RecordingSpaceGating)?,
        engineFactory: @escaping @Sendable (
            AudioRecordingConfiguration,
            any AudioCheckpointSink & Sendable,
            AudioSampleClock
        ) throws -> any AudioRecordingControlling & Sendable,
        expectedConfiguration: AudioRecordingConfiguration?,
        fileManager: RecordingSendableFileManager
    ) throws {
        guard roots.sessionRoot.isFileURL, roots.outputDirectory.isFileURL,
              roots.indexURL.isFileURL else { throw RecordingPipelineError.invalidConfiguration }
        self.roots = roots
        self.ledger = ledger
        self.coordinator = coordinator
        self.sealService = sealService
        self.spaceGate = spaceGate
        self.engineFactory = engineFactory
        self.expectedConfiguration = expectedConfiguration
        self.fileManager = fileManager
    }

    public func start(_ configuration: AudioRecordingConfiguration) async throws {
        guard !started, stopTask == nil else { throw RecordingPipelineError.alreadyStarted }
        guard configuration.kind == .audio, configuration.sampleRate == 48_000,
              configuration.mode != .none,
              expectedConfiguration == nil || expectedConfiguration == configuration
        else { throw RecordingPipelineError.invalidConfiguration }
        if let spaceGate {
            let decision = try await spaceGate.preflightStart()
            guard decision.allowed else {
                throw RecordingPipelineError.spacePreflightDenied(decision)
            }
        }
        try prepareSessionRoot()
        activeConfiguration = configuration
        let startDate = Date()
        try await ledger.register(RecordingSessionRecord(
            id: ledger.sessionID,
            kind: configuration.kind,
            layout: configuration.layout,
            startedAt: startDate,
            segments: []
        ))
        startedAt = startDate
        lastProgressPublishedAt = nil
        starting = true

        let (stream, continuation) = AsyncStream.makeStream(
            of: SealSignal.self,
            bufferingPolicy: .bufferingNewest(64)
        )
        sealContinuation = continuation
        let previewReadyBroadcaster = self.previewReadyBroadcaster
        let sink = LedgerCheckpointSink(
            coordinator: coordinator,
            ledger: ledger,
            spaceGate: spaceGate,
            onSegmentClosed: { index, checkpointID in
                continuation.yield(.closed(index))
                if let checkpointID { previewReadyBroadcaster.yield(.checkpoint(checkpointID)) }
            },
            onSpaceStatus: { [weak self] status in await self?.receiveSpaceStatus(status) }
        )
        checkpointSink = sink
        sealWorkerTask = Task(priority: .utility) { [weak self] in
            await self?.consumeSealSignals(stream)
        }
        if let spaceGate {
            let statuses = spaceGate.makeStatusStream()
            spaceStatusTask = Task(priority: .utility) { [weak self] in
                for await status in statuses {
                    guard !Task.isCancelled else { break }
                    await self?.receiveSpaceStatus(status)
                }
            }
        }
        let ticksPerSecond = AudioSourceTimestampMapper.nativeHostTicksPerSecond()
        let clock = AudioSampleClock(
            epochHostTime: AudioGetCurrentHostTime(),
            hostTicksPerSecond: ticksPerSecond,
            sampleRate: configuration.sampleRate
        )
        do {
            let newEngine = try engineFactory(configuration, sink, clock)
            try await newEngine.start(configuration)
            engine = newEngine
            started = true
            starting = false
            diagnosticBroadcaster.yield(.init(phase: .sessionStarted, sessionID: ledger.sessionID))
            let progress = newEngine.makeProgressStream()
            engineProgressTask = Task { [weak self] in
                for await value in progress {
                    guard !Task.isCancelled else { break }
                    await self?.acceptEngineProgress(value)
                }
            }
            startCheckpointTimer()
            scheduleSpaceSafeStopIfNeeded()
            await publishProgress()
        } catch {
            starting = false
            spaceSafeStopRequested = false
            continuation.finish()
            await sealWorkerTask?.value
            sealWorkerTask = nil
            spaceStatusTask?.cancel()
            spaceStatusTask = nil
            throw error
        }
    }

    public func stop() async -> AudioRecordingResult {
        if let result = lastResult { return result }
        if let stopTask { return await stopTask.value }
        let task = Task { [weak self] in
            guard let self else {
                return AudioRecordingResult(
                    sessionID: UUID(), kind: .audio, layout: .mixed,
                    segmentCount: 0, droppedRanges: [], checkpointAge: 0,
                    failure: "recording pipeline was released"
                )
            }
            return await self.performStop()
        }
        stopTask = task
        return await task.value
    }

    public func applyRoute(_ event: RouteEvent) async -> RouteCommitResult {
        guard let engine else { return .unchanged(reason: "recording pipeline is not active") }
        return await engine.applyRoute(event)
    }

    public nonisolated func makeProgressStream() -> AsyncStream<RecordingProgress> {
        progressBroadcaster.makeStream()
    }

    public nonisolated func makePreviewReadyStream() -> AsyncStream<PreviewTarget> {
        previewReadyBroadcaster.makeStream()
    }

    public func makeDiagnosticsStream() -> AsyncStream<RecordingPipelineDiagnosticEvent> {
        diagnosticBroadcaster.makeStream()
    }

    public func snapshot() async throws -> RecordingSessionRecord { try await ledger.snapshot() }

    public func makePreviewService() -> RecordingPreviewService {
        RecordingPreviewService(ledger: ledger, fileManager: fileManager)
    }

    /// Returns the most recent published audio file for the completion HUD.
    public func latestPublishedFileURL() async -> URL? {
        guard let record = try? await ledger.snapshot(),
              let segment = record.segments
                .filter({ $0.state == .published })
                .max(by: { $0.index < $1.index }),
              let relativePath = segment.files.values.sorted().first
        else { return nil }
        return try? RecordingLedgerFileSystem.resolve(relativePath, under: roots.outputDirectory)
    }

    public func resumePublish(segmentID: UUID) async throws -> SealedSegment {
        let intent = try await ledger.publishIntent(segmentID: segmentID)
        let candidate = try await ledger.segmentPublicationCandidate(segmentID: segmentID)
        let result = try await sealService.publishPrepared(candidate)
        try await ledger.markPublished(try makePublishedRecord(result, intent: intent, coverage: candidate.coverage))
        diagnosticBroadcaster.yield(.init(
            phase: .recovered, sessionID: ledger.sessionID,
            segmentIndex: result.index, range: RecordingSampleRange(
                startSample: result.effectiveRange.startSample,
                sampleCount: result.effectiveRange.sampleCount
            )
        ))
        await publishProgress()
        return result
    }

    /// Explicit retry entry point for commits retained after a journal failure.
    public func retryPendingJournal() async throws {
        try await checkpointSink?.retryPendingJournal()
        await publishProgress()
    }

    private func performStop() async -> AudioRecordingResult {
        stopping = true
        timerTask?.cancel()
        await timerTask?.value
        timerTask = nil
        let engineResult: AudioRecordingResult
        if let engine {
            engineResult = await engine.stop()
        } else {
            engineResult = AudioRecordingResult(
                sessionID: ledger.sessionID, kind: .audio, layout: .mixed,
                segmentCount: 0, droppedRanges: [], checkpointAge: 0,
                failure: started ? "engine unavailable" : "recording pipeline was not started"
            )
        }
        do {
            try await checkpointSink?.finishTail()
        } catch {
            pipelineFailure = pipelineFailure ?? "final journal/segment close failed: \(error)"
        }
        sealContinuation?.finish()
        sealContinuation = nil
        await sealWorkerTask?.value
        sealWorkerTask = nil
        spaceStatusTask?.cancel()
        spaceStatusTask = nil
        engineProgressTask?.cancel()
        engineProgressTask = nil

        let record = (try? await ledger.snapshot())
        let publishedCount = record?.segments.filter { $0.state == .published }.count ?? 0
        let facts = await checkpointSink?.checkpointFacts()
        let age = facts?.committedAt.map { max(0, Date().timeIntervalSince($0)) } ?? 0
        let failure = pipelineFailure ?? engineResult.failure
        let result = AudioRecordingResult(
            sessionID: ledger.sessionID,
            kind: engineResult.kind,
            layout: engineResult.layout,
            segmentCount: publishedCount,
            droppedRanges: engineResult.droppedRanges,
            checkpointAge: age,
            failure: failure
        )
        lastResult = result
        stopping = false
        await publishProgress()
        previewReadyBroadcaster.finish()
        return result
    }

    private func prepareSessionRoot() throws {
        let sessionRoot = ledger.sessionRoot
        let sessionsRoot = sessionRoot.deletingLastPathComponent()
        do {
            let canonicalParent = try RecordingLedgerFileSystem.canonicalDirectory(sessionsRoot, create: false)
            guard canonicalParent.path == sessionsRoot.standardizedFileURL.path else {
                throw RecordingPipelineError.invalidConfiguration
            }
            _ = try RecordingLedgerFileSystem.validateChild(
                sessionRoot, under: sessionsRoot, allowingMissing: true
            )
            if !fileManager.value.fileExists(atPath: sessionRoot.path) {
                try fileManager.value.createDirectory(
                    at: sessionRoot, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            _ = try RecordingLedgerFileSystem.validateChild(sessionRoot, under: sessionsRoot)
            guard RecordingLedgerFileSystem.isDirectory(sessionRoot) else {
                throw RecordingPipelineError.invalidConfiguration
            }
        } catch {
            throw RecordingPipelineError.invalidConfiguration
        }
    }

    private func receiveSpaceStatus(_ status: RecordingSpaceStatus) {
        if lastSpaceState != status.state {
            lastSpaceState = status.state
            diagnosticBroadcaster.yield(.init(
                phase: .spaceStateChanged,
                sessionID: ledger.sessionID
            ))
        }
        switch status.state {
        case .stopping:
            requestSpaceSafeStop(reason: status.reason ?? "recording space is no longer safe")
        case .blocked where started || starting:
            requestSpaceSafeStop(reason: status.reason ?? "recording space gate blocked the active session")
        case .ok, .low, .blocked:
            break
        }
        signalSealRetry()
    }

    private func requestSpaceSafeStop(reason: String) {
        guard !spaceSafeStopRequested, lastResult == nil else { return }
        spaceSafeStopRequested = true
        pipelineFailure = pipelineFailure ?? "recording space gate requested safe stop: \(reason)"
        scheduleSpaceSafeStopIfNeeded()
    }

    private func scheduleSpaceSafeStopIfNeeded() {
        guard spaceSafeStopRequested, started, !starting, stopTask == nil, lastResult == nil else { return }
        Task { [weak self] in _ = await self?.stop() }
    }

    /// How often the pipeline journals a durable audio checkpoint.
    ///
    /// Ten seconds bounds how much audio an interrupted session can lose, which is
    /// what makes the recovery list worth showing. It is deliberately independent
    /// of `RecordingSegmentPolicy.maximumCheckpointAge` (300 s): that value is the
    /// target coverage a segment must reach before the seal step may close it,
    /// while this interval only decides how often a recovery point becomes
    /// durable. Shortening this interval changes no seal, planner, or space-gate
    /// constant.
    public static let checkpointIntervalSeconds: Int64 = 10

    private func startCheckpointTimer() {
        timerTask = Task(priority: .utility) { [weak self] in
            let clock = ContinuousClock()
            while !Task.isCancelled {
                do { try await clock.sleep(for: .seconds(Self.checkpointIntervalSeconds)) } catch { break }
                guard !Task.isCancelled else { break }
                await self?.checkpointTimerFired()
            }
        }
    }

    private func checkpointTimerFired() async {
        guard let checkpointSink, !stopping else { return }
        do {
            let commits = try await checkpointSink.commitReadyCheckpoints()
            for commit in commits {
                diagnosticBroadcaster.yield(.init(
                    phase: .checkpointCommitted,
                    sessionID: ledger.sessionID,
                    segmentIndex: commit.segmentIndex,
                    range: RecordingSampleRange(
                        startSample: commit.range.startSample,
                        sampleCount: commit.range.sampleCount
                    )
                ))
            }
            await publishProgress()
        } catch {
            pipelineFailure = pipelineFailure ?? "checkpoint journal deferred: \(error)"
        }
        sealContinuation?.yield(.retry)
    }

    private func acceptEngineProgress(_ value: RecordingProgress) async {
        engineProgress = value
        await publishProgress()
    }

    private func publishProgress() async {
        guard let startDate = startedAt else { return }
        let facts = await ledger.progressFacts()
        let now = ContinuousClock.now
        if let last = lastProgressPublishedAt,
           last.duration(to: now) < .milliseconds(100) {
            return
        }
        lastProgressPublishedAt = now
        let elapsed = max(
            Double(facts.sampleEnd) / 48_000,
            engineProgress?.elapsedSeconds ?? 0,
            max(0, Date().timeIntervalSince(startDate))
        )
        let checkpointAge = facts.committedAt.map { max(0, Date().timeIntervalSince($0)) } ?? 0
        progressBroadcaster.yield(RecordingProgress(
            sessionID: ledger.sessionID,
            elapsedSeconds: elapsed,
            savedSegments: facts.publishedCount,
            checkpointAgeSeconds: checkpointAge,
            droppedSamples: engineProgress?.droppedSamples ?? 0,
            systemLevel: engineProgress?.systemLevel ?? 0,
            micLevel: engineProgress?.micLevel ?? 0,
            capturedSamples: engineProgress?.capturedSamples ?? 0
        ))
    }

    private func consumeSealSignals(_ stream: AsyncStream<SealSignal>) async {
        for await signal in stream {
            switch signal {
            case .closed(let index):
                if !sealQueue.contains(index) { sealQueue.append(index) }
                await processSealQueue(retryDeferred: false)
            case .retry:
                await processSealQueue(retryDeferred: true)
            }
        }
        await processSealQueue(retryDeferred: false)
        if !deferredSealIndices.isEmpty {
            pipelineFailure = pipelineFailure ?? "seal deferred by space gate"
        }
    }

    private func signalSealRetry() { sealContinuation?.yield(.retry) }

    private func processSealQueue(retryDeferred: Bool) async {
        guard !processingSeal else { return }
        processingSeal = true
        defer { processingSeal = false }
        while let index = sealQueue.first {
            if deferredSealIndices.contains(index), !retryDeferred { return }
            sealQueue.removeFirst()
            deferredSealIndices.remove(index)
            let backlog = await checkpointSink?.sealBacklogBytes() ?? 0
            if let spaceGate {
                switch await spaceGate.admitSeal(segmentIndex: index, backlogBytes: backlog) {
                case .run: break
                case .defer:
                    deferredSealIndices.insert(index)
                    sealQueue.insert(index, at: 0)
                    return
                case .stop(let reason):
                    requestSpaceSafeStop(reason: "space gate stopped sealing: \(reason)")
                    return
                }
            }
            await seal(index)
        }
    }

    private func seal(_ index: Int) async {
        let started = ContinuousClock.now
        do {
            let bundle = try await coordinator.closeSegmentBundle(at: index, isFinal: true)
            let segmentID = await ledger.segmentID(for: index)
            let sessionRecord = try await ledger.snapshot()
            diagnosticBroadcaster.yield(.init(
                phase: .sealStarted,
                sessionID: ledger.sessionID,
                segmentIndex: index,
                range: RecordingSampleRange(
                    startSample: bundle.coverage.segmentStartSample,
                    sampleCount: bundle.coverage.segmentEndSample - bundle.coverage.segmentStartSample
                ),
                byteCount: Self.byteCount(bundle.checkpoints.checkpoints)
            ))
            let context = RecordingSealContext(
                sessionID: ledger.sessionID,
                kind: .audio,
                layout: sessionRecord.layout,
                sampleRate: 48_000,
                outputStem: "Recording-\(ledger.sessionID.uuidString.lowercased())",
                destinationDirectory: roots.outputDirectory,
                bitRate: activeConfiguration?.bitRate
            )
            let sealed = try await sealService.seal(
                bundle, videoChunks: [], segmentID: segmentID, context: context
            )
            let intent = try await ledger.publishIntent(segmentID: segmentID)
            try await ledger.markPublished(try makePublishedRecord(sealed, intent: intent, coverage: bundle.coverage))
            await checkpointSink?.sealFinished(segmentIndex: index)
            let duration = started.duration(to: .now).components
            let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
            diagnosticBroadcaster.yield(.init(
                phase: .sealFinished,
                sessionID: ledger.sessionID,
                segmentIndex: index,
                range: RecordingSampleRange(
                    startSample: sealed.effectiveRange.startSample,
                    sampleCount: sealed.effectiveRange.sampleCount
                ),
                durationSeconds: seconds
            ))
            diagnosticBroadcaster.yield(.init(
                phase: .published,
                sessionID: ledger.sessionID,
                segmentIndex: index,
                range: RecordingSampleRange(
                    startSample: sealed.effectiveRange.startSample,
                    sampleCount: sealed.effectiveRange.sampleCount
                )
            ))
            await publishProgress()
        } catch {
            pipelineFailure = pipelineFailure ?? "segment seal/publish failed: \(error)"
        }
    }

    private func makePublishedRecord(
        _ sealed: SealedSegment,
        intent: RecordingPublishIntent,
        coverage: RecordingSegmentCoverage
    ) throws -> PublishedSegment {
        guard sealed.segmentID == intent.segmentID, sealed.index == intent.segmentIndex,
              sealed.effectiveRange.startSample == intent.effectiveRange.startSample,
              sealed.effectiveRange.sampleCount == intent.effectiveRange.sampleCount
        else { throw RecordingSessionLedgerError.invalidPublication }
        var files: [String: String] = [:]
        var trackMap: [String: Int] = [:]
        for (role, url) in sealed.files {
            let name = Self.roleName(role)
            files[name] = try RecordingLedgerFileSystem.validateChild(url, under: roots.outputDirectory)
            guard let trackIndex = sealed.trackMap[role] else { throw RecordingSessionLedgerError.invalidPublication }
            trackMap[name] = trackIndex
        }
        return PublishedSegment(
            id: sealed.segmentID,
            index: sealed.index,
            files: files,
            startSample: sealed.effectiveRange.startSample,
            sampleCount: sealed.effectiveRange.sampleCount,
            trackMap: trackMap,
            missingRanges: coverage.tracks.filter(\.wasActive).flatMap(\.missingRanges),
            state: .published,
            videoURL: sealed.videoURL,
            videoTrackIndex: sealed.videoTrackIndex
        )
    }

    private static func roleName(_ role: RecordingTrackRole) -> String {
        switch role {
        case .mixed: "mixed"
        case .system: "system"
        case .microphone: "microphone"
        }
    }

    private static func byteCount(_ commits: [CheckpointCommit]) -> Int64 {
        commits.reduce(into: Int64(0)) { total, commit in
            for url in commit.trackURLs.values {
                if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber {
                    total += size.int64Value
                }
            }
        }
    }
}

private final class RecordingProgressBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<RecordingProgress>.Continuation] = [:]
    private var latest: RecordingProgress?

    func makeStream() -> AsyncStream<RecordingProgress> {
        lock.lock()
        defer { lock.unlock() }
        guard continuations.count < 32 else {
            return AsyncStream { $0.finish() }
        }
        let id = UUID()
        let stream = AsyncStream<RecordingProgress>(bufferingPolicy: .bufferingNewest(8)) { continuation in
            continuations[id] = continuation
            if let latest { continuation.yield(latest) }
            continuation.onTermination = { [weak self] _ in self?.remove(id) }
        }
        return stream
    }

    func yield(_ value: RecordingProgress) {
        lock.lock()
        latest = value
        let targets = Array(continuations.values)
        lock.unlock()
        targets.forEach { $0.yield(value) }
    }

    private func remove(_ id: UUID) {
        lock.lock()
        continuations[id] = nil
        lock.unlock()
    }
}

private final class RecordingPreviewReadyBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<PreviewTarget>.Continuation] = [:]
    private var latest: PreviewTarget?
    private var finished = false

    func makeStream() -> AsyncStream<PreviewTarget> {
        lock.lock()
        defer { lock.unlock() }
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: PreviewTarget.self,
            bufferingPolicy: .bufferingNewest(8)
        )
        if let latest { continuation.yield(latest) }
        guard !finished else {
            continuation.finish()
            return stream
        }
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in self?.remove(id) }
        return stream
    }

    func yield(_ target: PreviewTarget) {
        lock.lock()
        latest = target
        let targets = Array(continuations.values)
        lock.unlock()
        targets.forEach { $0.yield(target) }
    }

    func finish() {
        lock.lock()
        finished = true
        let targets = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        targets.forEach { $0.finish() }
    }

    private func remove(_ id: UUID) {
        lock.lock()
        continuations[id] = nil
        lock.unlock()
    }
}

private final class RecordingDiagnosticBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<RecordingPipelineDiagnosticEvent>.Continuation] = [:]

    func makeStream() -> AsyncStream<RecordingPipelineDiagnosticEvent> {
        lock.lock()
        defer { lock.unlock() }
        guard continuations.count < 16 else { return AsyncStream { $0.finish() } }
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in self?.remove(id) }
        }
    }

    func yield(_ event: RecordingPipelineDiagnosticEvent) {
        lock.lock()
        let targets = Array(continuations.values)
        lock.unlock()
        targets.forEach { $0.yield(event) }
    }

    private func remove(_ id: UUID) {
        lock.lock()
        continuations[id] = nil
        lock.unlock()
    }
}
