import CaptureCore
import Foundation

/// Assertions attached to one agent scenario report.
struct AgentScenarioExpect: Codable, Equatable, Sendable {
    /// Requires at least one published artifact that AVFoundation can decode.
    var artifactPlayable: Bool = true
    /// Upper bound for the first visible HUD frame, measured from scenario start.
    var hudFirstVisibleUnderMs: Int?
    /// Exact number of `sizeThatFits` calls allowed before the first visible frame.
    var sizeThatFitsBeforeFirstVisible: Int?
    /// Required readiness outcome (first real captured sample promoted the session).
    var becameRecording: Bool?
    /// Lower bound proving an injected main-thread stall actually ran.
    var mainThreadMaxStallAtLeastMs: Int?
    /// Upper bound for window resizes during the session.
    var maxResizeCount: Int?
    /// Upper bound for window resizes between readiness and the stop request.
    var maxRecordingResizeCount: Int?
    /// Requires the settlement to finish while the injected stall was running.
    var settlementDuringStall: Bool?
    /// Exact number of real stop-closure invocations for the session.
    var supervisorStopCalls: Int?
    /// Requires every published artifact to be non-empty.
    var noZeroByteArtifacts: Bool?
    /// Requires at least this many durable checkpoints in the session journal.
    var minCheckpointCount: Int?

    init(
        artifactPlayable: Bool = true,
        hudFirstVisibleUnderMs: Int? = nil,
        sizeThatFitsBeforeFirstVisible: Int? = nil,
        becameRecording: Bool? = nil,
        mainThreadMaxStallAtLeastMs: Int? = nil,
        maxResizeCount: Int? = nil,
        maxRecordingResizeCount: Int? = nil,
        settlementDuringStall: Bool? = nil,
        supervisorStopCalls: Int? = nil,
        noZeroByteArtifacts: Bool? = nil,
        minCheckpointCount: Int? = nil
    ) {
        self.artifactPlayable = artifactPlayable
        self.hudFirstVisibleUnderMs = hudFirstVisibleUnderMs
        self.sizeThatFitsBeforeFirstVisible = sizeThatFitsBeforeFirstVisible
        self.becameRecording = becameRecording
        self.mainThreadMaxStallAtLeastMs = mainThreadMaxStallAtLeastMs
        self.maxResizeCount = maxResizeCount
        self.maxRecordingResizeCount = maxRecordingResizeCount
        self.settlementDuringStall = settlementDuringStall
        self.supervisorStopCalls = supervisorStopCalls
        self.noZeroByteArtifacts = noZeroByteArtifacts
        self.minCheckpointCount = minCheckpointCount
    }

    private enum CodingKeys: String, CodingKey {
        case artifactPlayable
        case hudFirstVisibleUnderMs
        case sizeThatFitsBeforeFirstVisible
        case becameRecording
        case mainThreadMaxStallAtLeastMs
        case maxResizeCount
        case maxRecordingResizeCount
        case settlementDuringStall
        case supervisorStopCalls
        case noZeroByteArtifacts
        case minCheckpointCount
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        artifactPlayable = try values.decodeIfPresent(Bool.self, forKey: .artifactPlayable) ?? true
        hudFirstVisibleUnderMs = try values.decodeIfPresent(Int.self, forKey: .hudFirstVisibleUnderMs)
        sizeThatFitsBeforeFirstVisible = try values.decodeIfPresent(
            Int.self,
            forKey: .sizeThatFitsBeforeFirstVisible
        )
        becameRecording = try values.decodeIfPresent(Bool.self, forKey: .becameRecording)
        mainThreadMaxStallAtLeastMs = try values.decodeIfPresent(
            Int.self,
            forKey: .mainThreadMaxStallAtLeastMs
        )
        maxResizeCount = try values.decodeIfPresent(Int.self, forKey: .maxResizeCount)
        maxRecordingResizeCount = try values.decodeIfPresent(Int.self, forKey: .maxRecordingResizeCount)
        settlementDuringStall = try values.decodeIfPresent(Bool.self, forKey: .settlementDuringStall)
        supervisorStopCalls = try values.decodeIfPresent(Int.self, forKey: .supervisorStopCalls)
        noZeroByteArtifacts = try values.decodeIfPresent(Bool.self, forKey: .noZeroByteArtifacts)
        minCheckpointCount = try values.decodeIfPresent(Int.self, forKey: .minCheckpointCount)
    }
}

/// Assertions for the screen-recording scenarios (S5).
struct AgentScreenExpect: Codable, Equatable, Sendable {
    /// Requires the writer to have started writing (or not, when false).
    var writerStart: Bool?
    /// Requires the session to appear in the published list.
    var published: Bool?
    /// Requires the UI to have armed the first-frame wait (or not).
    var becameWaitingForFrame: Bool?
    /// Lower bound for the largest `chunk-*.mp4` written by the session.
    var minChunkBytes: Int64?
    /// Exact upper bound for `chunk-*.mp4` files left behind.
    var maxChunkCount: Int?
    /// Requires every `chunk-*.mp4` to be non-empty.
    var noZeroByteChunks: Bool?
    /// Allowed difference between the produced duration and `screenSeconds`.
    var durationToleranceSeconds: Double?
    /// Requires the presented failure to name the System Settings pane.
    var failureMentionsSystemSettings: Bool?
    /// Requires the published video to carry an audio track (or not, when false).
    var audioTrackPresent: Bool?
    /// Requires the session to report a failed audio start (or a successful one).
    var audioStartFailed: Bool?
    /// Requires the presented message to say the audio was not recorded.
    var failureMentionsMissingAudio: Bool?

    init(
        writerStart: Bool? = nil,
        published: Bool? = nil,
        becameWaitingForFrame: Bool? = nil,
        minChunkBytes: Int64? = nil,
        maxChunkCount: Int? = nil,
        noZeroByteChunks: Bool? = nil,
        durationToleranceSeconds: Double? = nil,
        failureMentionsSystemSettings: Bool? = nil,
        audioTrackPresent: Bool? = nil,
        audioStartFailed: Bool? = nil,
        failureMentionsMissingAudio: Bool? = nil
    ) {
        self.writerStart = writerStart
        self.published = published
        self.becameWaitingForFrame = becameWaitingForFrame
        self.minChunkBytes = minChunkBytes
        self.maxChunkCount = maxChunkCount
        self.noZeroByteChunks = noZeroByteChunks
        self.durationToleranceSeconds = durationToleranceSeconds
        self.failureMentionsSystemSettings = failureMentionsSystemSettings
        self.audioTrackPresent = audioTrackPresent
        self.audioStartFailed = audioStartFailed
        self.failureMentionsMissingAudio = failureMentionsMissingAudio
    }
}

/// Assertions for the `recover` scenario mode.
struct AgentRecoveryExpect: Codable, Equatable, Sendable {
    /// Minimum number of recoverable sessions the scan must find.
    var minRecoverable: Int?
    /// Requires the exported file to decode with a positive duration.
    var expectExportPlayable: Bool?
    /// Requires every zero-byte session to stay out of the recoverable list.
    var expectZeroByteHidden: Bool?
    /// Requires a second recovery of the same session to keep one list entry.
    var expectIdempotent: Bool?
    /// Allowed difference between catalog duration and exported duration.
    var maxDurationDeltaSeconds: Double?

    init(
        minRecoverable: Int? = nil,
        expectExportPlayable: Bool? = nil,
        expectZeroByteHidden: Bool? = nil,
        expectIdempotent: Bool? = nil,
        maxDurationDeltaSeconds: Double? = nil
    ) {
        self.minRecoverable = minRecoverable
        self.expectExportPlayable = expectExportPlayable
        self.expectZeroByteHidden = expectZeroByteHidden
        self.expectIdempotent = expectIdempotent
        self.maxDurationDeltaSeconds = maxDurationDeltaSeconds
    }
}

/// What one agent run does after launch.
enum AgentScenarioMode: String, CaseIterable, Sendable {
    /// Capture a real audio recording through the production controller.
    case record
    /// Capture a real screen recording, then stop it.
    case screen
    /// Scan for and adopt an interrupted recording, then export it.
    case recover
}

/// One reproducible recording scenario executed by the agent channel.
///
/// Scenarios are deliberately declarative: they select a real recording path and
/// optionally inject a failure (a main-thread block or a shorter readiness
/// deadline). They never replace production code with mocks.
struct AgentScenario: Codable, Equatable, Sendable {
    /// Assertions attached to the produced report.
    typealias Expect = AgentScenarioExpect

    /// Stable scenario name used in reports and logs.
    var name: String
    /// Seconds of audio to capture, counted from the first real sample.
    var audioSeconds: Double
    /// Seconds of screen video to capture, counted from the writer's first frame.
    var screenSeconds: Double
    /// How long to wait for the first captured sample before giving up.
    var firstSampleDeadlineSeconds: Double
    /// Injected main-thread block in milliseconds (0 disables it).
    var simulateMainStallMs: Int
    /// Whether the injected block runs immediately after readiness.
    var simulateStallAfterStart: Bool
    /// Audio source mode: `system`, `microphone`, or `systemAndMicrophone`.
    var audioMode: String
    /// Whether the harness warms the HUD window path before measuring.
    ///
    /// Defaults to `false`: a plain scenario measures the process's real cold start.
    var hudWarmup: Bool
    /// Whether to suppress the readiness observation so the deadline path runs.
    ///
    /// Harness-only failure injection: capture still runs for real, but the
    /// supervisor is told that no first sample arrived. Used to prove the deadline
    /// stops and saves while the main thread is blocked.
    var suppressFirstSample: Bool
    /// Whether to inject a denied screen-permission probe for this run.
    ///
    /// Harness-only injection: the system TCC state is never changed, but the
    /// controller's gate answers "denied" exactly as it would on a revoked grant.
    var simulateScreenPermissionDenied: Bool
    /// Whether to inject a failing screen audio engine factory for this run.
    ///
    /// Harness-only injection: the video path still runs for real, so the run
    /// proves a missing audio track never truncates the recording.
    var simulateScreenAudioFailure: Bool
    /// What the run does: record audio, record screen, or recover an interrupted session.
    var mode: String
    /// Assertions for `recover` mode.
    var recoveryExpect: AgentRecoveryExpect?
    /// Assertions for `screen` mode.
    var screenExpect: AgentScreenExpect?
    /// Assertions evaluated against the run.
    var expect: Expect

    init(
        name: String,
        audioSeconds: Double = 5,
        screenSeconds: Double = 0,
        firstSampleDeadlineSeconds: Double = 15,
        simulateMainStallMs: Int = 0,
        simulateStallAfterStart: Bool = true,
        audioMode: String = "system",
        hudWarmup: Bool = false,
        suppressFirstSample: Bool = false,
        simulateScreenPermissionDenied: Bool = false,
        simulateScreenAudioFailure: Bool = false,
        mode: String = AgentScenarioMode.record.rawValue,
        recoveryExpect: AgentRecoveryExpect? = nil,
        screenExpect: AgentScreenExpect? = nil,
        expect: Expect = Expect()
    ) {
        self.name = name
        self.audioSeconds = audioSeconds
        self.screenSeconds = screenSeconds
        self.firstSampleDeadlineSeconds = firstSampleDeadlineSeconds
        self.simulateMainStallMs = simulateMainStallMs
        self.simulateStallAfterStart = simulateStallAfterStart
        self.audioMode = audioMode
        self.hudWarmup = hudWarmup
        self.suppressFirstSample = suppressFirstSample
        self.simulateScreenPermissionDenied = simulateScreenPermissionDenied
        self.simulateScreenAudioFailure = simulateScreenAudioFailure
        self.mode = mode
        self.recoveryExpect = recoveryExpect
        self.screenExpect = screenExpect
        self.expect = expect
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case audioSeconds
        case screenSeconds
        case firstSampleDeadlineSeconds
        case simulateMainStallMs
        case simulateStallAfterStart
        case audioMode
        case hudWarmup
        case suppressFirstSample
        case simulateScreenPermissionDenied
        case simulateScreenAudioFailure
        case mode
        case recoveryExpect
        case screenExpect
        case expect
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        audioSeconds = try values.decodeIfPresent(Double.self, forKey: .audioSeconds) ?? 5
        screenSeconds = try values.decodeIfPresent(Double.self, forKey: .screenSeconds) ?? 0
        firstSampleDeadlineSeconds =
            try values.decodeIfPresent(Double.self, forKey: .firstSampleDeadlineSeconds) ?? 15
        simulateMainStallMs = try values.decodeIfPresent(Int.self, forKey: .simulateMainStallMs) ?? 0
        simulateStallAfterStart =
            try values.decodeIfPresent(Bool.self, forKey: .simulateStallAfterStart) ?? true
        audioMode = try values.decodeIfPresent(String.self, forKey: .audioMode) ?? "system"
        hudWarmup = try values.decodeIfPresent(Bool.self, forKey: .hudWarmup) ?? false
        suppressFirstSample = try values.decodeIfPresent(Bool.self, forKey: .suppressFirstSample) ?? false
        simulateScreenPermissionDenied =
            try values.decodeIfPresent(Bool.self, forKey: .simulateScreenPermissionDenied) ?? false
        simulateScreenAudioFailure =
            try values.decodeIfPresent(Bool.self, forKey: .simulateScreenAudioFailure) ?? false
        mode = try values.decodeIfPresent(String.self, forKey: .mode)
            ?? AgentScenarioMode.record.rawValue
        recoveryExpect = try values.decodeIfPresent(AgentRecoveryExpect.self, forKey: .recoveryExpect)
        screenExpect = try values.decodeIfPresent(AgentScreenExpect.self, forKey: .screenExpect)
        expect = try values.decodeIfPresent(Expect.self, forKey: .expect) ?? Expect()
    }

    /// Loads and validates one scenario file.
    ///
    /// - Parameter url: Scenario JSON on disk.
    /// - Returns: The decoded, validated scenario.
    /// - Throws: Decoding errors or ``ValidationError`` for unusable values.
    static func load(from url: URL, data: Data? = nil) throws -> AgentScenario {
        let contents = try data ?? Data(contentsOf: url)
        let scenario = try JSONDecoder().decode(AgentScenario.self, from: contents)
        try scenario.validate()
        return scenario
    }

    /// Rejects values that would make a run unbounded or meaningless.
    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.emptyName
        }
        guard let scenarioMode = AgentScenarioMode(rawValue: mode) else {
            throw ValidationError.unknownMode(mode)
        }
        switch scenarioMode {
        case .recover:
            try validateRecovery()
        case .screen:
            try validateScreen()
        case .record:
            try validateAudio()
        }
    }

    private func validateRecovery() throws {
        if let minimum = recoveryExpect?.minRecoverable, minimum < 0 {
            throw ValidationError.invalidExpectation("minRecoverable must not be negative")
        }
        if let delta = recoveryExpect?.maxDurationDeltaSeconds, !delta.isFinite || delta <= 0 {
            throw ValidationError.invalidExpectation("maxDurationDeltaSeconds must be positive")
        }
    }

    private func validateScreen() throws {
        guard screenSeconds.isFinite, screenSeconds > 0, screenSeconds <= 3_600 else {
            throw ValidationError.invalidScreenSeconds(screenSeconds)
        }
        if let tolerance = screenExpect?.durationToleranceSeconds,
           !tolerance.isFinite || tolerance <= 0 {
            throw ValidationError.invalidExpectation("durationToleranceSeconds must be positive")
        }
        if let minimum = screenExpect?.minChunkBytes, minimum < 0 {
            throw ValidationError.invalidExpectation("minChunkBytes must not be negative")
        }
        if let maximum = screenExpect?.maxChunkCount, maximum < 0 {
            throw ValidationError.invalidExpectation("maxChunkCount must not be negative")
        }
    }

    private func validateAudio() throws {
        guard audioSeconds.isFinite, audioSeconds > 0, audioSeconds <= 3_600 else {
            throw ValidationError.invalidAudioSeconds(audioSeconds)
        }
        guard firstSampleDeadlineSeconds.isFinite, firstSampleDeadlineSeconds > 0,
              firstSampleDeadlineSeconds <= 600 else {
            throw ValidationError.invalidDeadline(firstSampleDeadlineSeconds)
        }
        guard simulateMainStallMs >= 0, simulateMainStallMs <= 60_000 else {
            throw ValidationError.invalidStall(simulateMainStallMs)
        }
        guard AgentScenarioAudioMode(rawValue: audioMode) != nil else {
            throw ValidationError.unknownAudioMode(audioMode)
        }
        if let limit = expect.hudFirstVisibleUnderMs, limit <= 0 {
            throw ValidationError.invalidExpectation("hudFirstVisibleUnderMs must be positive")
        }
        if let minimum = expect.minCheckpointCount, minimum < 0 {
            throw ValidationError.invalidExpectation("minCheckpointCount must not be negative")
        }
    }

    /// Value-level validation failures with readable descriptions.
    enum ValidationError: Error, Equatable, CustomStringConvertible {
        case emptyName
        case invalidAudioSeconds(Double)
        case invalidScreenSeconds(Double)
        case invalidDeadline(Double)
        case invalidStall(Int)
        case unknownAudioMode(String)
        case unknownMode(String)
        case invalidExpectation(String)

        var description: String {
            switch self {
            case .emptyName:
                return "scenario name is empty"
            case let .invalidAudioSeconds(value):
                return "audioSeconds must be within (0, 3600]: \(value)"
            case let .invalidScreenSeconds(value):
                return "screenSeconds must be within (0, 3600]: \(value)"
            case let .invalidDeadline(value):
                return "firstSampleDeadlineSeconds must be within (0, 600]: \(value)"
            case let .invalidStall(value):
                return "simulateMainStallMs must be within [0, 60000]: \(value)"
            case let .unknownAudioMode(value):
                return "unknown audioMode: \(value)"
            case let .unknownMode(value):
                return "unknown mode: \(value)"
            case let .invalidExpectation(message):
                return message
            }
        }
    }
}

/// Audio source modes accepted by a scenario file.
enum AgentScenarioAudioMode: String, CaseIterable, Sendable {
    case system
    case microphone
    case systemAndMicrophone
    /// No audio track; used to isolate the screen-video path.
    case none

    /// The screen-recording audio mode this scenario asks for, or `nil` to keep
    /// the user's preference (audio scenarios never use this).
    var screenMode: AudioSourceMode? {
        switch self {
        case .system: AudioSourceMode.system
        case .microphone: AudioSourceMode.microphone
        case .systemAndMicrophone: AudioSourceMode.systemAndMicrophone
        case .none: AudioSourceMode.none
        }
    }
}
