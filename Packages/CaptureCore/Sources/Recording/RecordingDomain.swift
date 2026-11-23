import Foundation

/// The media kind produced by a recording session.
public enum RecordingKind: Sendable, Hashable {
    /// Audio-only capture with no video track.
    case audio
    /// Screen capture, optionally accompanied by audio.
    case screen
}

/// The audio sources captured by a recording session.
public enum AudioSourceMode: Sendable, Hashable {
    /// Captures system audio only.
    case system
    /// Captures microphone audio only.
    case microphone
    /// Captures system audio and microphone audio together.
    case systemAndMicrophone
    /// Captures no audio.
    case none
}

/// The file layout used for a recording's audio output.
public enum AudioOutputLayout: Sendable, Hashable {
    /// Mixes every active source into one output track.
    case mixed
    /// Writes one output track per active source role.
    case separateTracks
}

/// A logical audio track role in a recording.
public enum RecordingTrackRole: Sendable, Hashable {
    /// The single mixed output track.
    case mixed
    /// The system-audio source track.
    case system
    /// The microphone source track.
    case microphone
}

/// The authorization state for microphone capture.
public enum MicrophoneAuthorizationState: Sendable, Hashable {
    /// The user has not been asked for microphone access yet.
    case unknown
    /// The user explicitly denied microphone access.
    case denied
    /// System policy prevents microphone access for this process.
    case restricted
    /// Microphone access is granted.
    case authorized
}

/// A half-open range on the recording's integer sample grid.
public struct SampleRange: Sendable, Hashable {
    /// Index of the first sample in the range.
    public let startSample: Int64
    /// Number of samples covered by the range.
    public let sampleCount: Int64

    /// Creates a sample range.
    ///
    /// - Parameters:
    ///   - startSample: Index of the first sample; may be negative before the epoch.
    ///   - sampleCount: Number of samples covered by the range.
    public init(startSample: Int64, sampleCount: Int64) {
        self.startSample = startSample
        self.sampleCount = sampleCount
    }
}

/// The sample extent of one visible recording segment.
public struct SegmentBoundary: Sendable, Hashable {
    /// Zero-based index of the segment.
    public let index: Int
    /// Index of the segment's first sample.
    public let startSample: Int64
    /// Index one past the segment's last sample.
    public let endSample: Int64

    /// Creates a segment boundary.
    ///
    /// - Parameters:
    ///   - index: Zero-based segment index.
    ///   - startSample: Index of the segment's first sample.
    ///   - endSample: Index one past the segment's last sample.
    public init(index: Int, startSample: Int64, endSample: Int64) {
        self.index = index
        self.startSample = startSample
        self.endSample = endSample
    }
}

/// The externally observable lifecycle of a recording session.
public enum RecordingLifecycle: Sendable, Hashable {
    /// No session is active.
    case idle
    /// The session is validating configuration and preparing resources.
    case preparing
    /// Capture is starting and the first timestamps are being established.
    case starting
    /// Capture is active and media is being written.
    case recording
    /// Capture has stopped and remaining media is being drained.
    case stopping
    /// Segments are being sealed, published, and indexed.
    case finalizing
    /// The session completed and all published work is durable.
    case finished
    /// The session failed but recoverable material may still be salvaged.
    case failedRecoverable
}

/// The immutable settings chosen when an audio recording session starts.
public struct AudioRecordingConfiguration: Sendable, Hashable {
    /// The recording kind; audio-only sessions never start video capture.
    public let kind: RecordingKind
    /// The audio sources captured by the session.
    public let mode: AudioSourceMode
    /// The output layout used for audio tracks.
    public let layout: AudioOutputLayout
    /// The session sample rate in hertz.
    public let sampleRate: Int
    /// Channel count for each active track role.
    public let channelCountByRole: [RecordingTrackRole: Int]
    /// Target encoded audio bitrate in bits per second.
    public let bitRate: Int

    /// Creates an audio recording configuration.
    ///
    /// - Parameters:
    ///   - kind: The recording kind.
    ///   - mode: The audio sources captured by the session.
    ///   - layout: The output layout used for audio tracks.
    ///   - sampleRate: The session sample rate in hertz.
    ///   - channelCountByRole: Channel count for each active track role.
    ///   - bitRate: Target encoded audio bitrate in bits per second.
    public init(
        kind: RecordingKind,
        mode: AudioSourceMode,
        layout: AudioOutputLayout,
        sampleRate: Int,
        channelCountByRole: [RecordingTrackRole: Int],
        bitRate: Int
    ) {
        self.kind = kind
        self.mode = mode
        self.layout = layout
        self.sampleRate = sampleRate
        self.channelCountByRole = channelCountByRole
        self.bitRate = bitRate
    }
}

/// A durable commit of one sample range across every active track.
public struct CheckpointCommit: Sendable, Hashable {
    /// Stable identity of the committed checkpoint.
    public let checkpointID: UUID
    /// Zero-based index of the segment that owns the checkpoint.
    public let segmentIndex: Int
    /// Sample range covered by the committed media.
    public let range: SampleRange
    /// Written checkpoint file for each active track role.
    public let trackURLs: [RecordingTrackRole: URL]
    /// Wall-clock time at which the checkpoint became durable.
    public let committedAt: Date

    /// Creates a checkpoint commit.
    ///
    /// - Parameters:
    ///   - checkpointID: Stable identity of the committed checkpoint.
    ///   - segmentIndex: Zero-based index of the segment that owns the checkpoint.
    ///   - range: Sample range covered by the committed media.
    ///   - trackURLs: Written checkpoint file for each active track role.
    ///   - committedAt: Wall-clock time at which the checkpoint became durable.
    public init(
        checkpointID: UUID,
        segmentIndex: Int,
        range: SampleRange,
        trackURLs: [RecordingTrackRole: URL],
        committedAt: Date
    ) {
        self.checkpointID = checkpointID
        self.segmentIndex = segmentIndex
        self.range = range
        self.trackURLs = trackURLs
        self.committedAt = committedAt
    }
}

/// The committed checkpoints that together cover one segment.
public struct SegmentCheckpointSet: Sendable, Hashable {
    /// Zero-based index of the segment described by this set.
    public let segmentIndex: Int
    /// Committed checkpoints for the segment, in append order.
    public let checkpoints: [CheckpointCommit]

    /// Creates a segment checkpoint set.
    ///
    /// - Parameters:
    ///   - segmentIndex: Zero-based index of the segment described by this set.
    ///   - checkpoints: Committed checkpoints for the segment, in append order.
    public init(segmentIndex: Int, checkpoints: [CheckpointCommit]) {
        self.segmentIndex = segmentIndex
        self.checkpoints = checkpoints
    }
}

/// A source routing change committed at an integer sample position.
public struct RouteEvent: Sendable, Hashable {
    /// Sample position at which the new routing takes effect.
    public let atSample: Int64
    /// Audio sources active from this position onward.
    public let mode: AudioSourceMode
    /// Stable device identifier when the event selects a specific input device.
    public let deviceID: String?

    /// Creates a route event.
    ///
    /// - Parameters:
    ///   - atSample: Sample position at which the new routing takes effect.
    ///   - mode: Audio sources active from this position onward.
    ///   - deviceID: Stable device identifier, or `nil` to use the default device.
    public init(atSample: Int64, mode: AudioSourceMode, deviceID: String?) {
        self.atSample = atSample
        self.mode = mode
        self.deviceID = deviceID
    }
}

/// The result of preparing a route change without committing it.
public enum RoutePreparationResult: Sendable, Hashable {
    /// The new sources are ready and the change may be committed.
    case prepared
    /// Preparation failed; the previous route remains active.
    case unchangedOnFailure(reason: String)
}

/// The result of committing a route change at a sample position.
public enum RouteCommitResult: Sendable, Hashable {
    /// The route change takes effect at the given sample position.
    case committed(atSample: Int64)
    /// The route change was not applied; the previous route remains active.
    case unchanged(reason: String)
}

/// A point-in-time progress snapshot for a recording session.
public struct RecordingProgress: Sendable, Hashable {
    /// Identity of the recording session.
    public let sessionID: UUID
    /// Elapsed recording time in seconds.
    public let elapsedSeconds: Double
    /// Number of segments that have been fully published.
    public let savedSegments: Int
    /// Age in seconds of the newest durable checkpoint.
    public let checkpointAgeSeconds: Double
    /// Number of samples known to be missing from the recording.
    public let droppedSamples: Int64
    /// RMS level from the system-audio input, clamped to `0...1`.
    public let systemLevel: Float
    /// RMS level from the microphone input, clamped to `0...1`.
    public let micLevel: Float
    /// Real captured source samples observed so far.
    ///
    /// This counts PCM frames actually read from a capture source. Synthetic
    /// silence and clock-advanced ticks do not increment it, so a non-zero value
    /// means at least one real sample (including an all-zero captured sample) was
    /// received. It is not derived from `systemLevel` or `micLevel`, and the
    /// pipeline forwards only the engine's counter: checkpoint coverage,
    /// including writer-synthesized silence, never raises it.
    public let capturedSamples: Int64

    /// Creates a recording progress snapshot.
    ///
    /// - Parameters:
    ///   - sessionID: Identity of the recording session.
    ///   - elapsedSeconds: Elapsed recording time in seconds.
    ///   - savedSegments: Number of segments that have been fully published.
    ///   - checkpointAgeSeconds: Age in seconds of the newest durable checkpoint.
    ///   - droppedSamples: Number of samples known to be missing from the recording.
    ///   - systemLevel: System-audio input RMS, clamped to `0...1`.
    ///   - micLevel: Microphone input RMS, clamped to `0...1`.
    ///   - capturedSamples: Real captured source samples observed so far.
    public init(
        sessionID: UUID,
        elapsedSeconds: Double,
        savedSegments: Int,
        checkpointAgeSeconds: Double,
        droppedSamples: Int64,
        systemLevel: Float = 0,
        micLevel: Float = 0,
        capturedSamples: Int64 = 0
    ) {
        self.sessionID = sessionID
        self.elapsedSeconds = elapsedSeconds
        self.savedSegments = savedSegments
        self.checkpointAgeSeconds = checkpointAgeSeconds
        self.droppedSamples = droppedSamples
        self.systemLevel = Self.clampedLevel(systemLevel)
        self.micLevel = Self.clampedLevel(micLevel)
        self.capturedSamples = max(0, capturedSamples)
    }

    private static func clampedLevel(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

/// The final outcome of an audio recording session.
public struct AudioRecordingResult: Sendable, Hashable {
    /// Identity of the recording session.
    public let sessionID: UUID
    /// The recording kind that was requested.
    public let kind: RecordingKind
    /// The audio output layout that was requested.
    public let layout: AudioOutputLayout
    /// Number of segments that were fully published.
    public let segmentCount: Int
    /// Sample ranges that could not be captured.
    public let droppedRanges: [SampleRange]
    /// Age in seconds of the newest durable checkpoint at finish time.
    public let checkpointAge: Double
    /// A human-readable failure summary, or `nil` on success.
    public let failure: String?

    /// Creates an audio recording result.
    ///
    /// - Parameters:
    ///   - sessionID: Identity of the recording session.
    ///   - kind: The recording kind that was requested.
    ///   - layout: The audio output layout that was requested.
    ///   - segmentCount: Number of segments that were fully published.
    ///   - droppedRanges: Sample ranges that could not be captured.
    ///   - checkpointAge: Age in seconds of the newest durable checkpoint at finish time.
    ///   - failure: A human-readable failure summary, or `nil` on success.
    public init(
        sessionID: UUID,
        kind: RecordingKind,
        layout: AudioOutputLayout,
        segmentCount: Int,
        droppedRanges: [SampleRange],
        checkpointAge: Double,
        failure: String?
    ) {
        self.sessionID = sessionID
        self.kind = kind
        self.layout = layout
        self.segmentCount = segmentCount
        self.droppedRanges = droppedRanges
        self.checkpointAge = checkpointAge
        self.failure = failure
    }
}
