import Foundation

/// One window size applied by the recording HUD, in points.
struct AgentSize: Codable, Equatable, Sendable {
    var width: Double
    var height: Double
}

/// One applied HUD frame change with its before/after size and phase.
struct AgentResizeRecord: Codable, Equatable, Sendable {
    /// Milliseconds from the scenario's HUD origin.
    var t: Int  // swiftlint:disable:this identifier_name
    var from: AgentSize
    var to: AgentSize  // swiftlint:disable:this identifier_name
    /// Whether the resize happened between readiness and the stop request.
    var recordingPhase: Bool
}

/// Machine-readable result of one agent scenario.
///
/// Every field is produced by the real run: HUD counters come from
/// `RecordingControlPanel`, readiness from the production state machine, and the
/// stall measurement from the independent main-thread probe. Nothing here is
/// synthesized to make a run look better.
struct AgentReport: Codable, Equatable, Sendable {
    /// Facts about the process that produced this report.
    struct AppFacts: Codable, Equatable, Sendable {
        var pid: Int32
        var bundleID: String
        var signedIdentity: String
        /// Whether the process is the installed copy or a test build.
        var executablePath: String
    }

    /// Identity and outcome of the recording session.
    struct SessionFacts: Codable, Equatable, Sendable {
        var id: String?
        var kind: String
        var published: Bool
        /// The audio mode actually used after any permission fallback.
        var audioMode: String?
    }

    /// One published media file.
    struct Artifact: Codable, Equatable, Sendable {
        var path: String
        var bytes: Int64
        var duration: Double?
    }

    /// HUD counters collected without changing the production presentation path.
    struct HUDFacts: Codable, Equatable, Sendable {
        var firstVisibleMs: Int?
        var sizeThatFitsBeforeFirstVisible: Int
        var sizeThatFitsCount: Int
        var resizeCount: Int
        var applyCount: Int
        /// Resizes between readiness and the stop request (steady-state behavior).
        var resizeCountRecordingPhase: Int = 0
        /// Every applied resize with its before/after size.
        var resizes: [AgentResizeRecord] = []
        /// Corner requested with `--agent-hud-corner`, when one was passed.
        var corner: String? = nil  // swiftlint:disable:this implicit_optional_initialization
        /// Whether the harness warmed the HUD path before measuring.
        var warmedUp: Bool = false
    }

    /// Independent main-thread stall evidence.
    struct MainThreadFacts: Codable, Equatable, Sendable {
        var maxStallMs: Int
        var probeSamples: Int
    }

    /// Monotonic-clock facts about readiness settlement (S2).
    struct SupervisorFacts: Codable, Equatable, Sendable {
        /// Milliseconds from scenario start when the single stop finished.
        var settledAtMs: Int?
        /// Whether that stop finished while the injected main-thread stall ran.
        var settlementDuringStall: Bool
        /// `requested` or `deadline`.
        var reason: String?
        /// Real stop-closure invocations for the session.
        var stopCalls: Int
        /// Whether real media was observed before the deadline.
        var mediaStarted: Bool
    }

    /// Whether the session reached a real recording state.
    struct ReadinessFacts: Codable, Equatable, Sendable {
        var firstRealSampleAfterMs: Int?
        var becameRecording: Bool
    }

    /// One monotonic-clock event, in milliseconds from scenario start.
    struct TimelineEntry: Codable, Equatable, Sendable {
        var t: Int  // swiftlint:disable:this identifier_name
        var event: String
    }

    /// One interrupted session the catalog offered for recovery.
    struct RecoverableItem: Codable, Equatable, Sendable {
        var id: String
        var kind: String
        var condition: String
        var durationSec: Double
        var materials: [String]
    }

    /// Facts proving recovery reads and reuses the bytes already on disk.
    struct RecoveryFacts: Codable, Equatable, Sendable {
        /// Sessions the catalog returned.
        var scanned: Int
        /// Every recoverable session the scan reported.
        var recoverable: [RecoverableItem]
        /// Sessions adopted during the run (two recover calls ⇒ one adoption).
        var adopted: Int
        /// Entries `publishedSessions` reports after recovery.
        var publishedAfterRecovery: Int
        /// Duration the catalog probed for the recovered session.
        var catalogDuration: Double?
        /// Exported file, when the run exported the adopted session.
        var exportedPath: String?
        /// Playable duration of the exported file.
        var exportedDuration: Double?
        /// Sessions whose media is entirely zero bytes.
        var zeroByteSessions: Int
        /// Whether a zero-byte session appeared in the recoverable list.
        var zeroByteVisible: Bool
        /// Whether a second recovery kept a single index entry.
        var idempotent: Bool
    }

    /// Privacy-safe writer facts for one screen session (S5).
    ///
    /// Only counters and error text are recorded: never a window title, an
    /// application name, or anything read from the captured pixels.
    struct ScreenFacts: Codable, Equatable, Sendable {
        /// Whether the writer reached `startWriting()` successfully.
        var writerStart: Bool
        /// Sync frames the writer could not accept (must stay 0 in a healthy run).
        var syncDropCount: Int64
        /// Non-sync frames dropped under backpressure.
        var nonSyncDropCount: Int64
        /// Writer append rejections.
        var appendFailureCount: Int64
        /// Last writer error, when one was reported.
        var lastError: String?
        /// Whether the session produced a published segment.
        var published: Bool
        /// Whether the first-frame wait was ever armed.
        var becameWaitingForFrame: Bool
        /// Number of `chunk-*.mp4` files left in the session directory.
        var chunkCount: Int
        /// Number of `chunk-*.mp4` files of exactly zero bytes.
        var zeroByteChunkCount: Int
        /// Largest `chunk-*.mp4` size in bytes.
        var chunkBytes: Int64
        /// The last user-facing message the controller presented, if any.
        var failureMessage: String?
        /// Playable duration of the published video, when one exists.
        var artifactDuration: Double?
        /// Whether the published video carries an audio track.
        var audioTrackPresent: Bool
        /// Whether the session's audio track failed to start.
        var audioStartFailed: Bool
        /// Why the audio track could not start, when it could not.
        var audioFailureReason: String?
    }

    /// Durable checkpoints found in the session journal.
    struct JournalFacts: Codable, Equatable, Sendable {
        var path: String?
        var checkpointCount: Int
        var checkpointIntervalSeconds: Int64
    }

    var ok: Bool  // swiftlint:disable:this identifier_name
    var scenario: String
    var app: AppFacts
    var session: SessionFacts
    var artifacts: [Artifact]
    var hud: HUDFacts
    var mainThread: MainThreadFacts
    var supervisor: SupervisorFacts
    var readiness: ReadinessFacts
    var screen: ScreenFacts? = nil  // swiftlint:disable:this implicit_optional_initialization
    var recovery: RecoveryFacts? = nil  // swiftlint:disable:this implicit_optional_initialization
    var journal: JournalFacts? = nil  // swiftlint:disable:this implicit_optional_initialization
    var timeline: [TimelineEntry]
    var errors: [String]

    private enum CodingKeys: String, CodingKey {
        case ok  // swiftlint:disable:this identifier_name
        case scenario
        case app
        case session
        case artifacts
        case hud
        case mainThread
        case supervisor
        case readiness
        case screen
        case recovery
        case journal
        case timeline
        case errors
    }

    /// Encodes the report as stable, human-readable JSON.
    ///
    /// - Returns: Pretty-printed JSON with sorted keys.
    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Writes `report.json` atomically so a partial read is never mistaken for a result.
    ///
    /// - Parameter directory: Output directory created by the launcher.
    func write(to directory: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("report.json")
        try jsonData().write(to: destination, options: .atomic)
    }
}
