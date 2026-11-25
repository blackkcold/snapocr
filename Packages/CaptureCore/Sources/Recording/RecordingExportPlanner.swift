import AVFoundation
import CoreMedia
import Foundation

/// How an export maps recorded source tracks onto its output tracks.
public enum ExportTrackSelection: Sendable, Equatable {
    case mixed
    case sourceSeparated
}

/// The audio work an export performs for its output tracks.
///
/// The planner records the operation per output role so the exporter and the
/// summary UI agree on whether audio is copied, re-encoded, mixed from a
/// published file, or replaced with silence.
public enum ExportAudioOperation: Sendable, Equatable {
    case passthrough
    case reencodeAudio
    case mixedFromPublished
    case missingSilence
}

/// The files an export may read audio from for one segment.
///
/// Checkpoints are unsealed PCM written during recording, published media is a
/// sealed product, and recovered media was adopted in place after an interrupted
/// session. The planner validates all three, but only published media carries
/// sealed-product metadata.
public enum ExportAudioSource: Sendable {
    case checkpointPCM([URL])
    case publishedMedia([URL])
    /// Media adopted in place from an interrupted session.
    ///
    /// These files are the recorder's originals, so they carry no sealed-product
    /// portable metadata. Preview and export read them directly instead of
    /// requiring a published product, and never copy or re-encode them.
    case recoveredMedia([URL])

    /// Every file this source contributes, in planner order.
    public var urls: [URL] {
        switch self {
        case .checkpointPCM(let urls), .publishedMedia(let urls), .recoveredMedia(let urls): urls
        }
    }
}

/// Where an export writes its product: a directory plus the file stem to use.
public struct ExportDestination: Sendable, Equatable {
    /// Existing directory that receives the published product.
    public let directory: URL
    /// Base name for the product, without an extension.
    public let stem: String

    /// Creates a destination from a directory and a stem.
    public init(directory: URL, stem: String) {
        self.directory = directory
        self.stem = stem
    }
}

/// The on-disk shape of an export product.
///
/// A single file carries the requested extension (`mp4` for video, `m4a` for
/// mixed audio); a directory holds one file per output role.
public enum ExportOutputShape: Sendable, Equatable {
    case singleFile(fileExtension: String)
    case directory
}

/// The encoded audio format an export targets.
public struct ExportAudioFormat: Sendable, Equatable {
    /// Encoder identifier; the planner always targets `aac`.
    public let codec: String
    /// Output sample rate in hertz.
    public let sampleRate: Int
    /// Channel count for each output role, clamped to one or two channels.
    public let channelCountByRole: [RecordingTrackRole: Int]

    /// Creates an audio output format.
    public init(codec: String, sampleRate: Int, channelCountByRole: [RecordingTrackRole: Int]) {
        self.codec = codec
        self.sampleRate = sampleRate
        self.channelCountByRole = channelCountByRole
    }
}

/// The complete description of what an export writes, independent of its media.
public struct ExportOutputSpec: Sendable, Equatable {
    /// Directory, stem, and therefore the final product path.
    public let destination: ExportDestination
    /// Single file or directory product.
    public let shape: ExportOutputShape
    /// Passthrough video codec (`h264` or `hevc`), or `nil` without video.
    public let videoCodec: String?
    /// Target audio encoding.
    public let audioFormat: ExportAudioFormat

    /// Creates an output specification.
    public init(
        destination: ExportDestination,
        shape: ExportOutputShape,
        videoCodec: String?,
        audioFormat: ExportAudioFormat
    ) {
        self.destination = destination
        self.shape = shape
        self.videoCodec = videoCodec
        self.audioFormat = audioFormat
    }
}

/// A track role in an export plan, serialized under its stable raw name.
public enum ExportTrackRole: String, Sendable, Codable, CaseIterable {
    case mixed
    case system
    case microphone

    init(_ role: RecordingTrackRole) {
        switch role {
        case .mixed: self = .mixed
        case .system: self = .system
        case .microphone: self = .microphone
        }
    }

    fileprivate var recordingRole: RecordingTrackRole {
        switch self {
        case .mixed: .mixed
        case .system: .system
        case .microphone: .microphone
        }
    }
}

/// A half-open range on the 48 kHz export sample grid.
public struct ExportSampleRange: Sendable, Codable, Equatable {
    /// Index of the first sample.
    public let startSample: Int64
    /// Number of samples covered by the range.
    public let sampleCount: Int64

    /// Creates an export sample range.
    public init(startSample: Int64, sampleCount: Int64) {
        self.startSample = startSample
        self.sampleCount = sampleCount
    }

    /// Index one past the last sample in the range.
    public var endSample: Int64 { startSample + sampleCount }
}

/// A media time range stored as separate value and timescale pairs.
///
/// Timescales are kept exactly as the asset reported them so the range can be
/// turned back into a `CMTimeRange` without rounding.
public struct ExportTimeRange: Sendable, Codable, Equatable {
    /// Start time numerator.
    public let startValue: Int64
    /// Start time denominator.
    public let startTimescale: Int32
    /// Duration numerator.
    public let durationValue: Int64
    /// Duration denominator.
    public let durationTimescale: Int32

    /// Creates an export time range.
    public init(
        startValue: Int64,
        startTimescale: Int32,
        durationValue: Int64,
        durationTimescale: Int32
    ) {
        self.startValue = startValue
        self.startTimescale = startTimescale
        self.durationValue = durationValue
        self.durationTimescale = durationTimescale
    }

    var cmTimeRange: CMTimeRange {
        CMTimeRange(
            start: CMTime(value: startValue, timescale: startTimescale),
            duration: CMTime(value: durationValue, timescale: durationTimescale)
        )
    }
}

/// The source material and sample ranges one output track reads for one segment.
public struct ExportSourceRange: Sendable, Codable, Equatable {
    /// Identity of the segment this range belongs to.
    public let segmentID: UUID
    /// Zero-based publication index of the segment.
    public let segmentIndex: Int
    /// Output role whose audio this range feeds.
    public let role: ExportTrackRole
    /// Range the user selected, clipped to the segment.
    public let requested: ExportSampleRange
    /// Range the planner can actually produce after video inspection.
    public let effective: ExportSampleRange
    /// Video time range to copy when passthrough covers the request, else `nil`.
    public let videoRange: ExportTimeRange?
    /// Index of the video track inside the source file, when one applies.
    public let videoTrackIndex: Int?
    /// Full sample extent of the segment, used to translate trims.
    public let segmentRange: ExportSampleRange
    /// Files the exporter reads for this range; video, when present, comes first.
    public let sourceFiles: [URL]

    /// Creates a source range.
    public init(
        segmentID: UUID,
        segmentIndex: Int,
        role: ExportTrackRole,
        requested: ExportSampleRange,
        effective: ExportSampleRange,
        videoRange: ExportTimeRange?,
        videoTrackIndex: Int? = nil,
        segmentRange: ExportSampleRange,
        sourceFiles: [URL]
    ) {
        self.segmentID = segmentID
        self.segmentIndex = segmentIndex
        self.role = role
        self.requested = requested
        self.effective = effective
        self.videoRange = videoRange
        self.videoTrackIndex = videoTrackIndex
        self.segmentRange = segmentRange
        self.sourceFiles = sourceFiles
    }
}

/// What the user asked to export before any validation or media inspection.
public struct ExportSelection: Sendable {
    /// Selected segment identities; planning always orders them by publication index.
    public let segmentIDs: [UUID]
    /// Optional trim per segment; a missing entry means the full segment.
    public let rangesBySegment: [UUID: SampleRange]
    /// Whether output keeps one mixed track or one track per source role.
    public let trackSelection: ExportTrackSelection
    /// Whether a screen session should include its video stream. The default
    /// preserves the original screen-export behaviour for existing callers.
    public let includeVideo: Bool
    /// Gain applied while mixing, in decibels.
    public let audioGainDB: Float
    /// Directory and stem for the published product.
    public let destination: ExportDestination

    /// Creates an export selection.
    ///
    /// - Parameters:
    ///   - segmentIDs: Selected segment identities.
    ///   - rangesBySegment: Optional trims keyed by segment identity.
    ///   - trackSelection: Mixed or source-separated output.
    ///   - includeVideo: Whether to include video for a screen session.
    ///   - audioGainDB: Mixing gain in decibels.
    ///   - destination: Product directory and stem.
    public init(
        segmentIDs: [UUID] = [],
        rangesBySegment: [UUID: SampleRange] = [:],
        trackSelection: ExportTrackSelection = .mixed,
        includeVideo: Bool = true,
        audioGainDB: Float = 0,
        destination: ExportDestination
    ) {
        self.segmentIDs = segmentIDs
        self.rangesBySegment = rangesBySegment
        self.trackSelection = trackSelection
        self.includeVideo = includeVideo
        self.audioGainDB = audioGainDB
        self.destination = destination
    }
}

/// One segment's trimmed window, in the order the export lays it out.
public struct ExportClip: Sendable, Equatable {
    /// Identity of the segment being trimmed.
    public let segmentID: UUID
    /// Zero-based publication index of the segment.
    public let index: Int
    /// Range the user selected, clipped to the segment.
    public let requestedRange: SampleRange
    /// Range the output will actually contain after video inspection.
    public let effectiveRange: SampleRange
    /// Video range to copy for this clip, or `nil` for audio-only output.
    public let videoRange: ExportTimeRange?

    /// Creates an export clip.
    public init(
        segmentID: UUID,
        index: Int,
        requestedRange: SampleRange,
        effectiveRange: SampleRange,
        videoRange: ExportTimeRange?
    ) {
        self.segmentID = segmentID
        self.index = index
        self.requestedRange = requestedRange
        self.effectiveRange = effectiveRange
        self.videoRange = videoRange
    }
}

/// The planner's dry-run verdict for a selection, used to enable or explain export.
public struct ExportAssessment: Sendable {
    /// Requested trim per segment, after clipping to segment bounds.
    public let requestedRanges: [UUID: SampleRange]
    /// Range the planner can produce per segment, after video inspection.
    public let effectiveRanges: [UUID: SampleRange]
    /// Total requested duration in seconds at 48 kHz.
    public let requestedDuration: TimeInterval
    /// Total output duration in seconds after inspection.
    public let effectiveDuration: TimeInterval
    /// Seconds beyond `RecordingExportPlanner.maximumExportDuration`, or zero.
    public let overageSeconds: TimeInterval
    /// Why the export cannot start, or `nil` when it can.
    public let disabledReason: ExportDisabledReason?
    /// Product shape and format the export would use.
    public let outputSpec: ExportOutputSpec
    /// Ordered clips the export would render.
    public let clips: [ExportClip]
    /// Audio operation chosen for each output role.
    public let trackMap: [RecordingTrackRole: ExportAudioOperation]
    /// Operation for the export as a whole, derived from `trackMap`.
    public let audioOperation: ExportAudioOperation
    /// Whether the video stream can be copied without re-encoding.
    public let videoPassthrough: Bool
    /// Conservative peak bytes the export may write, including staging headroom.
    public let estimatedPeakBytes: Int64

    /// Creates an export assessment.
    public init(
        requestedRanges: [UUID: SampleRange],
        effectiveRanges: [UUID: SampleRange],
        requestedDuration: TimeInterval,
        effectiveDuration: TimeInterval,
        overageSeconds: TimeInterval,
        disabledReason: ExportDisabledReason?,
        outputSpec: ExportOutputSpec,
        clips: [ExportClip],
        trackMap: [RecordingTrackRole: ExportAudioOperation],
        audioOperation: ExportAudioOperation,
        videoPassthrough: Bool,
        estimatedPeakBytes: Int64
    ) {
        self.requestedRanges = requestedRanges
        self.effectiveRanges = effectiveRanges
        self.requestedDuration = requestedDuration
        self.effectiveDuration = effectiveDuration
        self.overageSeconds = overageSeconds
        self.disabledReason = disabledReason
        self.outputSpec = outputSpec
        self.clips = clips
        self.trackMap = trackMap
        self.audioOperation = audioOperation
        self.videoPassthrough = videoPassthrough
        self.estimatedPeakBytes = estimatedPeakBytes
    }
}

/// Why the planner cannot enable an export for the current selection.
///
/// These mirror the planner's errors, plus the over-limit case that `assess`
/// measures and reports instead of throwing.
public enum ExportDisabledReason: Sendable, Equatable {
    case emptySelection
    case overLimit(overageSeconds: TimeInterval)
    case incompatibleCodec
    case missingSource
    case destinationUnavailable
    case passthroughUnsupported
}

/// A validated, immutable description of one export, ready for the exporter.
///
/// The plan fixes segment order, per-role source files, trim windows, output
/// format, and the size estimate; the exporter revalidates the actual media
/// before writing but never re-plans.
public struct ExportPlan: Sendable {
    /// Identity of the session being exported.
    public let sessionID: UUID
    /// Product directory, shape, and format.
    public let outputSpec: ExportOutputSpec
    /// Source files and ranges, one entry per selected segment and output role.
    public let sourceRanges: [ExportSourceRange]
    /// Ordered clips to render.
    public let clips: [ExportClip]
    /// Requested trim per segment.
    public let requestedRanges: [UUID: SampleRange]
    /// Effective range per segment after inspection.
    public let effectiveRanges: [UUID: SampleRange]
    /// Audio operation chosen for each output role.
    public let trackMap: [RecordingTrackRole: ExportAudioOperation]
    /// Mixing gain in decibels.
    public let audioGainDB: Float
    /// Audio files each selected segment contributes.
    public let audioSourcesBySegment: [UUID: ExportAudioSource]
    /// Whether video is copied without re-encoding.
    public let videoPassthrough: Bool
    /// Operation for the export as a whole.
    public let audioOperation: ExportAudioOperation
    /// Total output duration in seconds.
    public let estimatedDuration: TimeInterval
    /// Conservative peak byte estimate, including staging headroom.
    public let estimatedPeakBytes: Int64

    /// Creates an export plan.
    public init(
        sessionID: UUID,
        outputSpec: ExportOutputSpec,
        sourceRanges: [ExportSourceRange],
        clips: [ExportClip],
        requestedRanges: [UUID: SampleRange],
        effectiveRanges: [UUID: SampleRange],
        trackMap: [RecordingTrackRole: ExportAudioOperation],
        audioGainDB: Float,
        audioSourcesBySegment: [UUID: ExportAudioSource],
        videoPassthrough: Bool,
        audioOperation: ExportAudioOperation,
        estimatedDuration: TimeInterval,
        estimatedPeakBytes: Int64
    ) {
        self.sessionID = sessionID
        self.outputSpec = outputSpec
        self.sourceRanges = sourceRanges
        self.clips = clips
        self.requestedRanges = requestedRanges
        self.effectiveRanges = effectiveRanges
        self.trackMap = trackMap
        self.audioGainDB = audioGainDB
        self.audioSourcesBySegment = audioSourcesBySegment
        self.videoPassthrough = videoPassthrough
        self.audioOperation = audioOperation
        self.estimatedDuration = estimatedDuration
        self.estimatedPeakBytes = estimatedPeakBytes
    }
}

/// Failures that prevent an export from producing a published product.
///
/// The planner throws the selection and source cases; the exporter adds
/// `exportInProgress`, cancellation, and publish failures. `cancelled` and
/// `publishFailed` may carry the staging URL so the caller can clean it up.
public enum ExportError: Error, Equatable, Sendable {
    case emptySelection
    case overLimit(overageSeconds: TimeInterval)
    case incompatibleCodec
    case missingSource
    case destinationUnavailable
    case passthroughUnsupported
    case exportInProgress
    case cancelled(stagingURL: URL?)
    case publishFailed(stagingURL: URL?)
}

/// A progress update emitted while an export runs.
public struct ExportProgress: Sendable, Equatable {
    /// Completed fraction of the export, from 0 to 1.
    public let fraction: Double
    /// Short machine-readable stage name, such as `preparing` or `publishing`.
    public let phase: String

    /// Creates a progress update.
    public init(fraction: Double, phase: String) {
        self.fraction = fraction
        self.phase = phase
    }
}

/// The published product of a completed export.
public struct ExportResult: Sendable, Equatable {
    /// Final product URL, after the staging location published it.
    public let outputURL: URL
    /// Measured duration of the written product in seconds.
    public let actualDuration: TimeInterval
    /// Whether video was copied without re-encoding.
    public let videoPassthrough: Bool
    /// Audio operation the exporter performed.
    public let audioOperation: ExportAudioOperation
    /// Number of audio tracks in the product.
    public let trackCount: Int

    /// Creates an export result.
    public init(
        outputURL: URL,
        actualDuration: TimeInterval,
        videoPassthrough: Bool,
        audioOperation: ExportAudioOperation,
        trackCount: Int
    ) {
        self.outputURL = outputURL
        self.actualDuration = actualDuration
        self.videoPassthrough = videoPassthrough
        self.audioOperation = audioOperation
        self.trackCount = trackCount
    }
}

/// Turns a session record and an export selection into a validated export plan.
///
/// Planning is pure: it inspects media formats and video packet boundaries but
/// writes nothing. `assess` reports a verdict for the UI, `plan` throws on an
/// invalid selection, and `revalidate` re-checks a plan against the ranges the
/// exporter actually observed.
public enum RecordingExportPlanner {
    /// Longest export the planner allows, in seconds, just under two hours.
    ///
    /// A selection whose effective duration exceeds this is rejected with
    /// `ExportError.overLimit`; `assess` reports the overage instead of throwing.
    public static let maximumExportDuration: TimeInterval = 7_170
    static let sessionSampleRate: Int64 = 48_000

    /// Evaluates a selection without throwing, for enabling and explaining export.
    ///
    /// A plan that fails validation becomes a zero-duration assessment with
    /// `disabledReason` set. An over-limit plan is still measured, so the UI can
    /// show how far it exceeds the limit.
    ///
    /// - Parameters:
    ///   - session: The session record whose segments are being exported.
    ///   - selection: The segments, trims, track layout, and destination requested.
    ///   - audioSourcesBySegment: Audio files available for each segment.
    /// - Returns: The assessment for the selection.
    public static func assess(
        session: RecordingSessionRecord,
        selection: ExportSelection,
        audioSourcesBySegment: [UUID: ExportAudioSource]
    ) -> ExportAssessment {
        do {
            let plan = try build(
                session: session, selection: selection,
                audioSourcesBySegment: audioSourcesBySegment, allowOverLimit: true
            )
            let overage = max(0, plan.estimatedDuration - maximumExportDuration)
            return assessment(
                for: plan,
                disabledReason: overage > 0 ? .overLimit(overageSeconds: overage) : nil
            )
        } catch let error as ExportError {
            return failedAssessment(session: session, selection: selection, reason: assessment(for: error))
        } catch {
            return failedAssessment(session: session, selection: selection, reason: .missingSource)
        }
    }

    /// Builds the validated export plan or throws the first planning failure.
    ///
    /// Segments are ordered by publication index and every trim is clipped to its
    /// segment. A screen export inspects each video track to find a keyframe start
    /// that covers the requested window, and mixed video codecs are rejected.
    /// Missing media and over-limit durations throw rather than degrading silently.
    ///
    /// - Parameters:
    ///   - session: The session record whose segments are being exported.
    ///   - selection: The segments, trims, track layout, and destination requested.
    ///   - audioSourcesBySegment: Audio files available for each segment.
    /// - Returns: A plan the exporter can execute.
    /// - Throws: `ExportError` when the selection cannot be produced.
    public static func plan(
        session: RecordingSessionRecord,
        selection: ExportSelection,
        audioSourcesBySegment: [UUID: ExportAudioSource]
    ) throws -> ExportPlan {
        try build(session: session, selection: selection, audioSourcesBySegment: audioSourcesBySegment)
    }

    /// Re-checks a plan against the media ranges the exporter actually observed.
    ///
    /// Each clip keeps its requested range and adopts the observed range only when
    /// that media still covers the request. Duration and overage are recomputed,
    /// so a plan that grew past the limit fails here even if it passed planning.
    ///
    /// - Parameters:
    ///   - plan: The plan returned by `plan(session:selection:audioSourcesBySegment:)`.
    ///   - actualRanges: Observed sample range per segment identity.
    /// - Returns: A plan carrying the observed effective ranges.
    /// - Throws: `ExportError.emptySelection` when the plan has no clips,
    ///   `ExportError.missingSource` when observed media no longer covers a
    ///   request, and `ExportError.overLimit` when the recomputed duration exceeds
    ///   the maximum.
    public static func revalidate(_ plan: ExportPlan, actualRanges: [UUID: SampleRange]) throws -> ExportPlan {
        guard !plan.clips.isEmpty else { throw ExportError.emptySelection }
        var effective: [UUID: SampleRange] = [:]
        var clips: [ExportClip] = []
        for clip in plan.clips {
            let requested = plan.requestedRanges[clip.segmentID] ?? clip.requestedRange
            let actual = actualRanges[clip.segmentID] ?? plan.effectiveRanges[clip.segmentID] ?? clip.effectiveRange
            guard requested.sampleCount > 0, actual.sampleCount > 0,
                actual.startSample <= requested.startSample,
                actual.endSample >= requested.endSample,
                actual.startSample >= 0
            else { throw ExportError.missingSource }
            effective[clip.segmentID] = actual
            clips.append(
                ExportClip(
                    segmentID: clip.segmentID, index: clip.index,
                    requestedRange: requested, effectiveRange: actual, videoRange: clip.videoRange
                ))
        }
        let duration = clips.reduce(0.0) { $0 + Double($1.effectiveRange.sampleCount) / Double(sessionSampleRate) }
        let overage = max(0, duration - maximumExportDuration)
        guard overage <= 0 else { throw ExportError.overLimit(overageSeconds: overage) }
        let sourceRanges = plan.sourceRanges.map { source in
            ExportSourceRange(
                segmentID: source.segmentID, segmentIndex: source.segmentIndex, role: source.role,
                requested: ExportSampleRange(
                    startSample: plan.requestedRanges[source.segmentID]?.startSample ?? source.requested.startSample,
                    sampleCount: plan.requestedRanges[source.segmentID]?.sampleCount ?? source.requested.sampleCount
                ),
                effective: ExportSampleRange(
                    startSample: effective[source.segmentID]?.startSample ?? source.effective.startSample,
                    sampleCount: effective[source.segmentID]?.sampleCount ?? source.effective.sampleCount
                ),
                videoRange: source.videoRange, videoTrackIndex: source.videoTrackIndex,
                segmentRange: source.segmentRange,
                sourceFiles: source.sourceFiles
            )
        }
        return ExportPlan(
            sessionID: plan.sessionID, outputSpec: plan.outputSpec, sourceRanges: sourceRanges,
            clips: clips, requestedRanges: plan.requestedRanges, effectiveRanges: effective,
            trackMap: plan.trackMap, audioGainDB: plan.audioGainDB,
            audioSourcesBySegment: plan.audioSourcesBySegment,
            videoPassthrough: plan.videoPassthrough, audioOperation: plan.audioOperation,
            estimatedDuration: duration, estimatedPeakBytes: plan.estimatedPeakBytes
        )
    }
}

private extension SampleRange {
    var endSample: Int64 { startSample + sampleCount }
}
