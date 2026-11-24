import AVFoundation
import CoreMedia
import Foundation

public enum ExportTrackSelection: Sendable, Equatable {
    case mixed
    case sourceSeparated
}

public enum ExportAudioOperation: Sendable, Equatable {
    case passthrough
    case reencodeAudio
    case mixedFromPublished
    case missingSilence
}

public enum ExportAudioSource: Sendable {
    case checkpointPCM([URL])
    case publishedMedia([URL])
    /// Media adopted in place from an interrupted session.
    ///
    /// These files are the recorder's originals, so they carry no sealed-product
    /// portable metadata. Preview and export read them directly instead of
    /// requiring a published product, and never copy or re-encode them.
    case recoveredMedia([URL])

    public var urls: [URL] {
        switch self {
        case .checkpointPCM(let urls), .publishedMedia(let urls), .recoveredMedia(let urls): urls
        }
    }
}

public struct ExportDestination: Sendable, Equatable {
    public let directory: URL
    public let stem: String

    public init(directory: URL, stem: String) {
        self.directory = directory
        self.stem = stem
    }
}

public enum ExportOutputShape: Sendable, Equatable {
    case singleFile(fileExtension: String)
    case directory
}

public struct ExportAudioFormat: Sendable, Equatable {
    public let codec: String
    public let sampleRate: Int
    public let channelCountByRole: [RecordingTrackRole: Int]

    public init(codec: String, sampleRate: Int, channelCountByRole: [RecordingTrackRole: Int]) {
        self.codec = codec
        self.sampleRate = sampleRate
        self.channelCountByRole = channelCountByRole
    }
}

public struct ExportOutputSpec: Sendable, Equatable {
    public let destination: ExportDestination
    public let shape: ExportOutputShape
    public let videoCodec: String?
    public let audioFormat: ExportAudioFormat

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

public struct ExportSampleRange: Sendable, Codable, Equatable {
    public let startSample: Int64
    public let sampleCount: Int64

    public init(startSample: Int64, sampleCount: Int64) {
        self.startSample = startSample
        self.sampleCount = sampleCount
    }

    public var endSample: Int64 { startSample + sampleCount }
}

public struct ExportTimeRange: Sendable, Codable, Equatable {
    public let startValue: Int64
    public let startTimescale: Int32
    public let durationValue: Int64
    public let durationTimescale: Int32

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

public struct ExportSourceRange: Sendable, Codable, Equatable {
    public let segmentID: UUID
    public let segmentIndex: Int
    public let role: ExportTrackRole
    public let requested: ExportSampleRange
    public let effective: ExportSampleRange
    public let videoRange: ExportTimeRange?
    public let videoTrackIndex: Int?
    public let segmentRange: ExportSampleRange
    public let sourceFiles: [URL]

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

public struct ExportSelection: Sendable {
    public let segmentIDs: [UUID]
    public let rangesBySegment: [UUID: SampleRange]
    public let trackSelection: ExportTrackSelection
    /// Whether a screen session should include its video stream. The default
    /// preserves the original screen-export behaviour for existing callers.
    public let includeVideo: Bool
    public let audioGainDB: Float
    public let destination: ExportDestination

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

public struct ExportClip: Sendable, Equatable {
    public let segmentID: UUID
    public let index: Int
    public let requestedRange: SampleRange
    public let effectiveRange: SampleRange
    public let videoRange: ExportTimeRange?

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

public struct ExportAssessment: Sendable {
    public let requestedRanges: [UUID: SampleRange]
    public let effectiveRanges: [UUID: SampleRange]
    public let requestedDuration: TimeInterval
    public let effectiveDuration: TimeInterval
    public let overageSeconds: TimeInterval
    public let disabledReason: ExportDisabledReason?
    public let outputSpec: ExportOutputSpec
    public let clips: [ExportClip]
    public let trackMap: [RecordingTrackRole: ExportAudioOperation]
    public let audioOperation: ExportAudioOperation
    public let videoPassthrough: Bool
    public let estimatedPeakBytes: Int64

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

public enum ExportDisabledReason: Sendable, Equatable {
    case emptySelection
    case overLimit(overageSeconds: TimeInterval)
    case incompatibleCodec
    case missingSource
    case destinationUnavailable
    case passthroughUnsupported
}

public struct ExportPlan: Sendable {
    public let sessionID: UUID
    public let outputSpec: ExportOutputSpec
    public let sourceRanges: [ExportSourceRange]
    public let clips: [ExportClip]
    public let requestedRanges: [UUID: SampleRange]
    public let effectiveRanges: [UUID: SampleRange]
    public let trackMap: [RecordingTrackRole: ExportAudioOperation]
    public let audioGainDB: Float
    public let audioSourcesBySegment: [UUID: ExportAudioSource]
    public let videoPassthrough: Bool
    public let audioOperation: ExportAudioOperation
    public let estimatedDuration: TimeInterval
    public let estimatedPeakBytes: Int64

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

public struct ExportProgress: Sendable, Equatable {
    public let fraction: Double
    public let phase: String

    public init(fraction: Double, phase: String) {
        self.fraction = fraction
        self.phase = phase
    }
}

public struct ExportResult: Sendable, Equatable {
    public let outputURL: URL
    public let actualDuration: TimeInterval
    public let videoPassthrough: Bool
    public let audioOperation: ExportAudioOperation
    public let trackCount: Int

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

public enum RecordingExportPlanner {
    public static let maximumExportDuration: TimeInterval = 7_170
    static let sessionSampleRate: Int64 = 48_000

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

    public static func plan(
        session: RecordingSessionRecord,
        selection: ExportSelection,
        audioSourcesBySegment: [UUID: ExportAudioSource]
    ) throws -> ExportPlan {
        try build(session: session, selection: selection, audioSourcesBySegment: audioSourcesBySegment)
    }

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
            clips.append(ExportClip(
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
