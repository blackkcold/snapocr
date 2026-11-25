import Foundation

/// The publication lifecycle recorded for one segment.
///
/// `recording` means material is still being appended, `sealing` and `publishing`
/// mean a durable product is on its way, `published` is a verified final product,
/// `failedRecoverable` can be retried from its publish intent, `missing` is a
/// published entry whose product no longer verifies, and `requiresNewerVersion`
/// marks a record written by a newer schema.
public enum PublishedSegmentState: String, Codable, Sendable, Hashable {
    case recording
    case sealing
    case publishing
    case published
    case failedRecoverable
    case missing
    case requiresNewerVersion
}

/// One segment of a recording session as journaled and mirrored into the index.
///
/// The segment carries its identity, publication order, per-role files, sample
/// coverage, and the state needed to preview, export, or recover it.
public struct PublishedSegment: Codable, Sendable, Hashable {
    /// Stable identity of the segment.
    public let id: UUID
    /// Zero-based publication index; exports follow this order.
    public let index: Int
    /// Published file per track role, stored relative to the output directory.
    public let files: [String: String]
    /// First sample of the segment on the 48 kHz session grid.
    public let startSample: Int64
    /// Number of samples the segment covers.
    public let sampleCount: Int64
    /// Zero-based track index inside the published product, per role name.
    public let trackMap: [String: Int]
    /// Segment-global sample ranges that the active tracks do not cover.
    public let missingRanges: [RecordingSampleRange]
    /// Current publication state of the segment.
    public let state: PublishedSegmentState
    /// Published video file for a screen segment, or `nil` for audio-only media.
    public let videoURL: URL?
    /// Index of the video track inside `videoURL`; export falls back to track 0.
    public let videoTrackIndex: Int?
    /// Media that was adopted in place after an interrupted session.
    ///
    /// Normal publications resolve their product from the publish intent, so this
    /// stays `nil` for them. An adopted segment points at media that already
    /// existed on disk (for example an interrupted CAF), which lets preview and
    /// export read the original bytes instead of waiting for a sealed product.
    /// Optional so index records written before adoption still decode unchanged.
    public let materialURL: URL?

    /// Creates a published segment.
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

/// The journal's durable description of one recording session.
///
/// The record holds the session's identity, kind, audio layout, start time, and
/// the segments discovered so far. The journal owns it; the index only mirrors it.
public struct RecordingSessionRecord: Codable, Sendable, Hashable {
    /// Stable identity of the session.
    public let id: UUID
    /// Whether the session recorded audio only or a screen with optional audio.
    public let kind: RecordingKind
    /// Audio layout the session was recorded with.
    public let layout: AudioOutputLayout
    /// Wall-clock time at which capture started.
    public let startedAt: Date
    /// Segments in publication order, one entry per visible segment.
    public let segments: [PublishedSegment]

    /// Creates a session record.
    ///
    /// - Parameters:
    ///   - id: Stable identity of the session.
    ///   - kind: The recorded media kind.
    ///   - layout: Audio layout used for the session.
    ///   - startedAt: Wall-clock capture start time.
    ///   - segments: Segments in publication order.
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

    /// Decodes the record, mapping the stored kind and layout strings.
    ///
    /// Unknown values are rejected instead of guessed so a corrupt journal cannot
    /// silently change a session's media kind.
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

    /// Encodes the record with stable kind and layout strings.
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(kind == .audio ? "audio" : "screen", forKey: .kind)
        try values.encode(layout == .mixed ? "mixed" : "separateTracks", forKey: .layout)
        try values.encode(startedAt, forKey: .startedAt)
        try values.encode(segments, forKey: .segments)
    }
}

/// One segment that can be recovered after an interrupted session.
public struct RecoverableSession: Sendable, Hashable {
    /// Identity of the interrupted session.
    public let sessionID: UUID
    /// Zero-based index of the segment that can be recovered.
    public let segmentIndex: Int
    /// Recoverable duration in seconds, derived from durable checkpoint coverage.
    public let estimatedSeconds: Double
    /// Publication state the recovery list should present.
    public let state: PublishedSegmentState

    /// Creates a recovery entry.
    public init(sessionID: UUID, segmentIndex: Int, estimatedSeconds: Double, state: PublishedSegmentState) {
        self.sessionID = sessionID
        self.segmentIndex = segmentIndex
        self.estimatedSeconds = estimatedSeconds
        self.state = state
    }
}

/// The durable intent recorded before a segment product is published.
///
/// Publication reserves a final URL, stages the product, then atomically
/// publishes it into place without overwriting. The intent records both URLs, the
/// content hashes the product must match, and the coverage it promises, so an
/// interrupted publish can be verified and retried instead of re-encoded.
public struct RecordingPublishIntent: Codable, Sendable, Hashable {
    /// Identity of the segment being published.
    public let segmentID: UUID
    /// Zero-based publication index of the segment.
    public let segmentIndex: Int
    /// Final product URL reserved for this segment.
    public let reservedFinalURL: URL
    /// Staging location the product is written to before publication.
    public let stagingURL: URL
    /// Whether the product is a directory (source-separated) or a single file.
    public let isDirectory: Bool
    /// Expected SHA-256 digest per published file name.
    public let contentHashes: [String: String]
    /// Effective sample range the published product covers.
    public let effectiveRange: RecordingSampleRange
    /// Per-track coverage recorded when the segment was closed.
    public let coverage: RecordingSegmentCoverage

    /// Creates a publish intent.
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

/// A time-limited, read-only claim on the media backing a preview.
///
/// Live leases keep checkpoint files available to the player, and garbage
/// collection skips media that an unexpired lease still references.
public struct PreviewLease: Sendable, Hashable {
    /// Stable identity of this lease.
    public let id: UUID
    /// Segment whose media the lease covers.
    public let segmentID: UUID
    /// Files the preview may read while the lease is held.
    public let mediaURLs: [URL]
    /// Wall-clock time after which the lease no longer protects its files.
    public let expiresAt: Date

    /// Creates a preview lease.
    public init(id: UUID, segmentID: UUID, mediaURLs: [URL], expiresAt: Date) {
        self.id = id
        self.segmentID = segmentID
        self.mediaURLs = mediaURLs
        self.expiresAt = expiresAt
    }
}

/// The media a preview request should open.
public enum PreviewTarget: Sendable, Hashable {
    case segment(UUID)
    case checkpoint(UUID)
}

/// The space gate's state for an active session.
///
/// `ok` and `low` allow writing to continue with their normal warnings,
/// `stopping` asks the pipeline to end the session safely, and `blocked` means
/// the start-time volume check denied the session.
public enum RecordingSpaceState: Sendable, Hashable { case ok, low, stopping, blocked }

/// A point-in-time space reading for an active recording.
public struct RecordingSpaceStatus: Sendable, Hashable {
    /// Gate state derived from this reading.
    public let state: RecordingSpaceState
    /// Bytes the recording still needs to finish safely.
    public let requiredBytes: Int64
    /// Bytes currently free on the write volume.
    public let availableBytes: Int64
    /// Bytes written but not yet sealed, awaiting publication.
    public let backlogBytes: Int64
    /// Age in seconds of the newest durable checkpoint.
    public let checkpointAgeSeconds: Double
    /// Diagnostic explanation for a non-`ok` state, or `nil` when healthy.
    public let reason: String?

    /// Creates a space status.
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

/// The space gate's answer to a request to seal a segment.
///
/// `run` seals now, `defer` retries after more backlog drains, and `stop` ends the
/// session because space is no longer safe.
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

/// The start-time and ongoing space policy for a recording session.
///
/// A gate answers five questions: whether a session may start, what the space
/// state is after each durable checkpoint, whether a segment may seal now, when a
/// seal has finished, and which state changes the UI should observe.
public protocol RecordingSpaceGating: Sendable {
    func preflightStart() async throws -> SpaceBudgetDecision
    func checkpointCommitted(_ commit: CheckpointCommit, backlogBytes: Int64) async -> RecordingSpaceStatus
    func admitSeal(segmentIndex: Int, backlogBytes: Int64) async -> RecordingSealAdmission
    func sealFinished(segmentIndex: Int) async
    func makeStatusStream() -> AsyncStream<RecordingSpaceStatus>
}

/// The file-system roots one recording pipeline writes to.
public struct RecordingPipelineRoots: Sendable, Hashable {
    /// Session directory that holds the journal and checkpoint material.
    public let sessionRoot: URL
    /// Rebuildable session index shared by all sessions.
    public let indexURL: URL
    /// Directory that receives sealed and published products.
    public let outputDirectory: URL

    /// Creates the roots for one session.
    public init(sessionRoot: URL, indexURL: URL, outputDirectory: URL) {
        self.sessionRoot = sessionRoot
        self.indexURL = indexURL
        self.outputDirectory = outputDirectory
    }
}

/// Failures a recording pipeline reports before or during a session.
public enum RecordingPipelineError: Error, Equatable, Sendable {
    case alreadyStarted
    case invalidConfiguration
    /// The start-time space decision denied the session; carries the full decision.
    case spacePreflightDenied(SpaceBudgetDecision)
    case journalUnavailable
    case engineUnavailable
}

/// The lifecycle points a pipeline emits diagnostics for.
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
    /// Lifecycle point this event describes.
    public let phase: RecordingPipelineDiagnosticPhase
    /// Session the event belongs to.
    public let sessionID: UUID
    /// Segment index, when the phase is segment-specific.
    public let segmentIndex: Int?
    /// Sample range covered by the reported checkpoint, seal, or publication, when applicable.
    public let range: RecordingSampleRange?
    /// Measured duration in seconds for phases that time a stage, else zero.
    public let durationSeconds: Double
    /// Reported byte count for phases that measure one, else zero.
    public let byteCount: Int64

    /// Creates a diagnostic event.
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
