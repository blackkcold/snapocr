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
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: values,
                debugDescription: "Unknown recording kind"
            )
        }
        switch try values.decode(String.self, forKey: .layout) {
        case "mixed": layout = .mixed
        case "separateTracks": layout = .separateTracks
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .layout,
                in: values,
                debugDescription: "Unknown audio layout"
            )
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
