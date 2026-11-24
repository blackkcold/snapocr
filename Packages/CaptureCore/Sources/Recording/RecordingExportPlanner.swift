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

    fileprivate init(_ role: RecordingTrackRole) {
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
    private static let sessionSampleRate: Int64 = 48_000

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
            let reason: ExportDisabledReason
            switch error {
            case .emptySelection: reason = .emptySelection
            case .overLimit(let overage): reason = .overLimit(overageSeconds: overage)
            case .incompatibleCodec: reason = .incompatibleCodec
            case .missingSource: reason = .missingSource
            case .destinationUnavailable: reason = .destinationUnavailable
            case .passthroughUnsupported: reason = .passthroughUnsupported
            case .exportInProgress, .cancelled, .publishFailed: reason = .missingSource
            }
            let empty = fallbackOutputSpec(session: session, selection: selection)
            return ExportAssessment(
                requestedRanges: [:], effectiveRanges: [:], requestedDuration: 0,
                effectiveDuration: 0, overageSeconds: 0, disabledReason: reason,
                outputSpec: empty, clips: [], trackMap: [:], audioOperation: .missingSilence,
                videoPassthrough: false, estimatedPeakBytes: 0
            )
        } catch {
            return ExportAssessment(
                requestedRanges: [:], effectiveRanges: [:], requestedDuration: 0,
                effectiveDuration: 0, overageSeconds: 0, disabledReason: .missingSource,
                outputSpec: ExportOutputSpec(
                    destination: selection.destination,
                    shape: fallbackOutputSpec(session: session, selection: selection).shape,
                    videoCodec: nil,
                    audioFormat: fallbackOutputSpec(session: session, selection: selection).audioFormat
                ), clips: [], trackMap: [:], audioOperation: .missingSilence,
                videoPassthrough: false, estimatedPeakBytes: 0
            )
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

    private static func build(
        session: RecordingSessionRecord,
        selection: ExportSelection,
        audioSourcesBySegment: [UUID: ExportAudioSource],
        allowOverLimit: Bool = false
    ) throws -> ExportPlan {
            guard !selection.segmentIDs.isEmpty else { throw ExportError.emptySelection }
        guard selection.audioGainDB.isFinite,
              isExistingDirectory(selection.destination.directory), validStem(selection.destination.stem)
        else { throw ExportError.destinationUnavailable }

        let selectedIDs = Set(selection.segmentIDs)
        let foundSegments = session.segments.filter { selectedIDs.contains($0.id) }
        guard foundSegments.count == selectedIDs.count else { throw ExportError.missingSource }
        let segments = foundSegments.sorted {
            $0.index == $1.index ? $0.startSample < $1.startSample : $0.index < $1.index
        }
        guard segments.allSatisfy({
            $0.state == .published && $0.index >= 0
                && $0.startSample >= 0 && $0.sampleCount > 0
        })
        else { throw ExportError.missingSource }

        var requestedByID: [UUID: SampleRange] = [:]
        var effectiveByID: [UUID: SampleRange] = [:]
        var videoByID: [UUID: ExportTimeRange] = [:]
        var descriptorsByID: [UUID: [PlannerAudioDescriptor]] = [:]
        var videoCodec: String?
        let wantsVideo = session.kind == .screen && selection.includeVideo

        for segment in segments {
            let segmentRange = SampleRange(startSample: segment.startSample, sampleCount: segment.sampleCount)
            let raw = selection.rangesBySegment[segment.id] ?? segmentRange
            guard raw.sampleCount > 0 else { throw ExportError.emptySelection }
            let lower = max(segmentRange.startSample, raw.startSample)
            let upper = min(segmentRange.endSample, raw.endSample)
            guard upper > lower else { throw ExportError.emptySelection }
            let requested = SampleRange(startSample: lower, sampleCount: upper - lower)
            requestedByID[segment.id] = requested
            var effective = requested

            guard let source = audioSourcesBySegment[segment.id], !source.urls.isEmpty,
                  source.urls.allSatisfy({ $0.isFileURL && fileExists($0) })
            else { throw ExportError.missingSource }
            let audioDescriptors = try inspectAudioSources(source, segment: segment, sessionLayout: session.layout)
            guard !audioDescriptors.isEmpty else { throw ExportError.missingSource }
            descriptorsByID[segment.id] = audioDescriptors

            if wantsVideo {
                guard let videoURL = segment.videoURL, videoURL.isFileURL, fileExists(videoURL)
                else { throw ExportError.missingSource }
                let scan: VideoRangeInspection
                do {
                    scan = try inspectVideoRange(
                        url: videoURL, trackIndex: segment.videoTrackIndex ?? 0,
                        segmentStartSample: segment.startSample, segmentSampleCount: segment.sampleCount,
                        requested: requested
                    )
                } catch let error as ExportError {
                    throw error
                } catch {
                    throw ExportError.passthroughUnsupported
                }
                if let videoCodec, videoCodec != scan.codec { throw ExportError.incompatibleCodec }
                videoCodec = scan.codec
                videoByID[segment.id] = scan.range
                effective = SampleRange(
                    startSample: min(effective.startSample, scan.effective.startSample),
                    sampleCount: max(effective.endSample, scan.effective.endSample)
                        - min(effective.startSample, scan.effective.startSample)
                )
            }
            effectiveByID[segment.id] = effective
        }

        let effectiveDuration = effectiveByID.values.reduce(0.0) {
            $0 + Double($1.sampleCount) / Double(sessionSampleRate)
        }
        let overage = max(0, effectiveDuration - maximumExportDuration)
        guard allowOverLimit || overage <= 0 else { throw ExportError.overLimit(overageSeconds: overage) }

        let outputRoles = resolveOutputRoles(
            selection: selection.trackSelection, layout: session.layout,
            descriptorsByID: descriptorsByID
        )
        guard !outputRoles.isEmpty else { throw ExportError.missingSource }
        var trackMap: [RecordingTrackRole: ExportAudioOperation] = [:]
        for outputRole in outputRoles {
            let matching = descriptorsByID.values.flatMap { descriptors in
                matchingDescriptors(descriptors, outputRole: outputRole)
            }
            if matching.isEmpty {
                trackMap[outputRole] = .missingSilence
            } else if outputRole == .mixed && selection.trackSelection == .mixed,
                      matching.contains(where: { $0.mediaKind == .published }) {
                trackMap[outputRole] = .mixedFromPublished
            } else {
                trackMap[outputRole] = .reencodeAudio
            }
        }
        guard descriptorsByID.values.flatMap({ $0 }).contains(where: { !$0.urls.isEmpty }) else {
            throw ExportError.missingSource
        }

        let outputShape: ExportOutputShape
        if wantsVideo {
            outputShape = .singleFile(fileExtension: "mp4")
        } else if selection.trackSelection == .sourceSeparated {
            outputShape = .directory
        } else {
            outputShape = .singleFile(fileExtension: "m4a")
        }
        let channelCounts = Dictionary(uniqueKeysWithValues: outputRoles.map { role in
            let matches = descriptorsByID.values.flatMap { matchingDescriptors($0, outputRole: role) }
            let channels = matches.map(\.channelCount).filter { (1...2).contains($0) }.max() ?? 2
            return (role, min(2, max(1, channels)))
        })
        let outputSpec = ExportOutputSpec(
            destination: selection.destination, shape: outputShape, videoCodec: videoCodec,
            audioFormat: ExportAudioFormat(
                codec: "aac",
                sampleRate: Int(sessionSampleRate),
                channelCountByRole: channelCounts
            )
        )
        var clips: [ExportClip] = []
        var sourceRanges: [ExportSourceRange] = []
        for segment in segments {
            guard let requested = requestedByID[segment.id], let effective = effectiveByID[segment.id] else { continue }
            let descriptors = descriptorsByID[segment.id] ?? []
            clips.append(ExportClip(
                segmentID: segment.id, index: segment.index, requestedRange: requested,
                effectiveRange: effective, videoRange: videoByID[segment.id]
            ))
            for outputRole in outputRoles {
                var urls = matchingDescriptors(descriptors, outputRole: outputRole).flatMap(\.urls)
                if let videoURL = segment.videoURL { urls.insert(videoURL, at: 0) }
                urls = uniqueURLs(urls)
                sourceRanges.append(ExportSourceRange(
                    segmentID: segment.id, segmentIndex: segment.index, role: ExportTrackRole(outputRole),
                    requested: ExportSampleRange(
                        startSample: requested.startSample,
                        sampleCount: requested.sampleCount
                    ),
                    effective: ExportSampleRange(
                        startSample: effective.startSample,
                        sampleCount: effective.sampleCount
                    ),
                    videoRange: videoByID[segment.id], videoTrackIndex: segment.videoTrackIndex,
                    segmentRange: ExportSampleRange(startSample: segment.startSample, sampleCount: segment.sampleCount),
                    sourceFiles: urls
                ))
            }
        }
        let audioOperation: ExportAudioOperation
        if outputRoles.contains(where: { trackMap[$0] == .mixedFromPublished }) {
            audioOperation = .mixedFromPublished
        } else if outputRoles.allSatisfy({ trackMap[$0] == .missingSilence }) {
            audioOperation = .missingSilence
        } else {
            audioOperation = .reencodeAudio
        }
        let peakBytes = estimatePeakBytes(
            clips: clips, segments: segments, outputRoles: outputRoles,
            videoPassthrough: wantsVideo, outputSpec: outputSpec
        )
        return ExportPlan(
            sessionID: session.id, outputSpec: outputSpec, sourceRanges: sourceRanges, clips: clips,
            requestedRanges: requestedByID, effectiveRanges: effectiveByID, trackMap: trackMap,
            audioGainDB: selection.audioGainDB,
            audioSourcesBySegment: audioSourcesBySegment.filter { selectedIDs.contains($0.key) },
            videoPassthrough: wantsVideo, audioOperation: audioOperation,
            estimatedDuration: effectiveDuration, estimatedPeakBytes: peakBytes
        )
    }

    private static func assessment(for plan: ExportPlan, disabledReason: ExportDisabledReason?) -> ExportAssessment {
        let requestedDuration = plan.clips.reduce(0.0) {
            $0 + Double($1.requestedRange.sampleCount) / Double(sessionSampleRate)
        }
        return ExportAssessment(
            requestedRanges: plan.requestedRanges, effectiveRanges: plan.effectiveRanges,
            requestedDuration: requestedDuration, effectiveDuration: plan.estimatedDuration,
            overageSeconds: max(0, plan.estimatedDuration - maximumExportDuration),
            disabledReason: disabledReason, outputSpec: plan.outputSpec, clips: plan.clips,
            trackMap: plan.trackMap, audioOperation: plan.audioOperation,
            videoPassthrough: plan.videoPassthrough, estimatedPeakBytes: plan.estimatedPeakBytes
        )
    }

    private static func fallbackOutputSpec(
        session: RecordingSessionRecord,
        selection: ExportSelection
    ) -> ExportOutputSpec {
        let shape: ExportOutputShape
        if session.kind == .screen && selection.includeVideo {
            shape = .singleFile(fileExtension: "mp4")
        } else if selection.trackSelection == .sourceSeparated {
            shape = .directory
        } else {
            shape = .singleFile(fileExtension: "m4a")
        }
        let roles: [RecordingTrackRole] = selection.trackSelection == .mixed ? [.mixed] : [.system, .microphone]
        return ExportOutputSpec(
            destination: selection.destination, shape: shape, videoCodec: nil,
            audioFormat: ExportAudioFormat(
                codec: "aac", sampleRate: Int(sessionSampleRate),
                channelCountByRole: Dictionary(uniqueKeysWithValues: roles.map { ($0, 2) })
            )
        )
    }

    private static func resolveOutputRoles(
        selection: ExportTrackSelection,
        layout: AudioOutputLayout,
        descriptorsByID: [UUID: [PlannerAudioDescriptor]]
    ) -> [RecordingTrackRole] {
        switch selection {
        case .mixed:
            return [.mixed]
        case .sourceSeparated:
            var found = Set(descriptorsByID.values.flatMap { $0.map(\.role) })
            if found.isEmpty, layout == .mixed { found = [.mixed] }
            if found.isEmpty { found = [.system, .microphone] }
            return RecordingCheckpointWriter.roleOrder.filter { found.contains($0) }
        }
    }

    fileprivate static func matchingDescriptors(
        _ descriptors: [PlannerAudioDescriptor], outputRole: RecordingTrackRole
    ) -> [PlannerAudioDescriptor] {
        if outputRole == .mixed {
            let alreadyMixed = descriptors.filter { $0.role == .mixed }
            if !alreadyMixed.isEmpty { return alreadyMixed }
            return descriptors.filter { $0.role == .system || $0.role == .microphone }
        }
        return descriptors.filter { $0.role == outputRole }
    }

    private static func inspectAudioSources(
        _ source: ExportAudioSource,
        segment: PublishedSegment,
        sessionLayout: AudioOutputLayout
    ) throws -> [PlannerAudioDescriptor] {
        let mediaKind: PlannerAudioDescriptor.MediaKind
        switch source {
        case .checkpointPCM: mediaKind = .checkpoint
        case .publishedMedia: mediaKind = .published
        case .recoveredMedia: mediaKind = .published
        }
        var result: [PlannerAudioDescriptor] = []
        for url in uniqueURLs(source.urls) {
            switch source {
            case .checkpointPCM:
                let sidecars = try FileManager.default.contentsOfDirectory(
                    at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil
                ).filter { $0.lastPathComponent.hasPrefix("checkpoint-") && $0.pathExtension == "json" }
                var match: (RecordingCheckpointRecord, RecordingCheckpointRecord.Track)?
                for sidecar in sidecars {
                    guard let data = try? Data(contentsOf: sidecar),
                          let record = try? JSONDecoder().decode(RecordingCheckpointRecord.self, from: data),
                          let track = record.tracks.first(where: { $0.fileName == url.lastPathComponent })
                    else { continue }
                    match = (record, track)
                    break
                }
                guard let (record, track) = match,
                      record.segmentIndex == segment.index,
                      record.sampleCount > 0, track.frameCount >= record.sampleCount,
                      let role = recordingRole(track.role), track.sampleRate > 0,
                      (1...2).contains(track.channelCount)
                else { throw ExportError.missingSource }
                result.append(PlannerAudioDescriptor(
                    role: role,
                    url: url,
                    urls: [url],
                    range: SampleRange(
                        startSample: record.startSample,
                        sampleCount: record.sampleCount
                    ),
                    sampleRate: track.sampleRate, channelCount: track.channelCount, mediaKind: mediaKind
                ))
            case .publishedMedia:
                let roles = roles(for: url, segment: segment, layout: sessionLayout)
                guard !roles.isEmpty else { throw ExportError.missingSource }
                let audioInfo = inspectAudioFormat(url: url)
                for role in roles {
                    result.append(PlannerAudioDescriptor(
                        role: role, url: url, urls: [url],
                        range: SampleRange(startSample: segment.startSample, sampleCount: segment.sampleCount),
                        sampleRate: audioInfo.sampleRate, channelCount: audioInfo.channelCount, mediaKind: mediaKind
                    ))
                }
            case .recoveredMedia:
                // Recovered media is the recorder's original file, not a sealed
                // product: read the format from the file itself and report an
                // honest missing source when it cannot be decoded as audio.
                let roles = roles(for: url, segment: segment, layout: sessionLayout)
                guard !roles.isEmpty, let audioInfo = readableAudioFormat(url: url) else {
                    throw ExportError.missingSource
                }
                for role in roles {
                    result.append(PlannerAudioDescriptor(
                        role: role, url: url, urls: [url],
                        range: SampleRange(startSample: segment.startSample, sampleCount: segment.sampleCount),
                        sampleRate: audioInfo.sampleRate, channelCount: audioInfo.channelCount, mediaKind: mediaKind
                    ))
                }
            }
        }
        guard !result.isEmpty else { throw ExportError.missingSource }
        return result
    }

    private static func roles(
        for url: URL,
        segment: PublishedSegment,
        layout: AudioOutputLayout
    ) -> [RecordingTrackRole] {
        let fileRoles = segment.files.compactMap { rawRole, relative -> RecordingTrackRole? in
            guard URL(fileURLWithPath: relative).lastPathComponent == url.lastPathComponent else { return nil }
            return recordingRole(rawRole)
        }
        if !fileRoles.isEmpty { return Array(Set(fileRoles)).sorted { roleOrder($0) < roleOrder($1) } }
        let mapped = segment.trackMap.keys.compactMap(recordingRole)
        if mapped.count == 1 { return mapped }
        if layout == .mixed { return [.mixed] }
        if segment.trackMap.count > 1 {
            return RecordingCheckpointWriter.roleOrder.filter { mapped.contains($0) }
        }
        return []
    }

    private static func inspectAudioFormat(url: URL) -> (sampleRate: Int, channelCount: Int) {
        DispatchQueue.global(qos: .utility).sync {
            guard let file = try? AVAudioFile(forReading: url) else {
                return (Int(sessionSampleRate), 2)
            }
            let rate = Int(file.processingFormat.sampleRate.rounded())
            let channels = Int(file.processingFormat.channelCount)
            return (rate > 0 ? rate : Int(sessionSampleRate), (1...2).contains(channels) ? channels : 2)
        }
    }

    /// Real format of a file that must be readable, or `nil` when it is not.
    ///
    /// Recovered media has no portable record to fall back on, so an unreadable
    /// file must be reported as a missing source instead of a guessed format.
    private static func readableAudioFormat(url: URL) -> (sampleRate: Int, channelCount: Int)? {
        DispatchQueue.global(qos: .utility).sync {
            guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }
            let rate = Int(file.processingFormat.sampleRate.rounded())
            let channels = Int(file.processingFormat.channelCount)
            guard rate > 0, (1...2).contains(channels) else { return nil }
            return (rate, channels)
        }
    }

    static func inspectVideoRange(
        url: URL,
        trackIndex: Int,
        segmentStartSample: Int64,
        segmentSampleCount: Int64,
        requested: SampleRange
    ) throws -> VideoRangeInspection {
        try DispatchQueue.global(qos: .userInitiated).sync {
            let asset = AVURLAsset(url: url)
            let tracks = asset.tracks(withMediaType: .video)
            guard trackIndex >= 0, trackIndex < tracks.count else { throw ExportError.passthroughUnsupported }
            let track = tracks[trackIndex]
            guard track.timeRange.isValid, track.timeRange.duration.isValid,
                  track.timeRange.duration.seconds.isFinite, track.timeRange.duration.seconds > 0
            else { throw ExportError.passthroughUnsupported }

            let requestedStart = CMTimeAdd(
                track.timeRange.start,
                CMTime(value: requested.startSample - segmentStartSample, timescale: CMTimeScale(sessionSampleRate))
            )
            let requestedEnd = CMTimeAdd(
                track.timeRange.start,
                CMTime(value: requested.endSample - segmentStartSample, timescale: CMTimeScale(sessionSampleRate))
            )
            let trackEnd = CMTimeRangeGetEnd(track.timeRange)
            guard CMTimeCompare(requestedStart, track.timeRange.start) >= 0,
                  CMTimeCompare(requestedEnd, trackEnd) <= 0
            else { throw ExportError.passthroughUnsupported }

            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            guard reader.canAdd(output) else { throw ExportError.passthroughUnsupported }
            reader.add(output)
            guard reader.startReading() else { throw ExportError.passthroughUnsupported }
            var startKeyframe: CMTime?
            var endTime: CMTime?
            var codec: String?
            var sampleCount = 0
            while let sample = output.copyNextSampleBuffer() {
                let format = CMSampleBufferGetFormatDescription(sample)
                if codec == nil, let format {
                    codec = videoCodecName(CMFormatDescriptionGetMediaSubType(format))
                }
                let count = CMSampleBufferGetNumSamples(sample)
                guard count > 0 else { continue }
                var needed: CMItemCount = 0
                var timings = Array(repeating: CMSampleTimingInfo(
                    duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid
                ), count: count)
                let timingStatus = CMSampleBufferGetSampleTimingInfoArray(
                    sample, entryCount: count, arrayToFill: &timings, entriesNeededOut: &needed
                )
                guard timingStatus == noErr, needed == count else {
                    reader.cancelReading()
                    throw ExportError.passthroughUnsupported
                }
                let attachments = CMSampleBufferGetSampleAttachmentsArray(
                    sample,
                    createIfNecessary: false
                ) as? [[CFString: Any]]
                for index in 0..<count {
                    let timing = timings[index]
                    guard timing.presentationTimeStamp.isValid, timing.decodeTimeStamp.isValid else {
                        reader.cancelReading()
                        throw ExportError.passthroughUnsupported
                    }
                    let notSync = attachments?.indices.contains(index) == true
                        ? (attachments?[index][kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
                        : false
                    if !notSync, CMTimeCompare(timing.presentationTimeStamp, requestedStart) <= 0,
                       startKeyframe.map({ CMTimeCompare(timing.presentationTimeStamp, $0) > 0 }) ?? true {
                        startKeyframe = timing.presentationTimeStamp
                    }
                    if CMTimeCompare(timing.presentationTimeStamp, requestedEnd) < 0 {
                        let duration = timing.duration.isValid && timing.duration.value > 0
                            ? timing.duration
                            : .zero
                        let sampleEnd = CMTimeAdd(timing.presentationTimeStamp, duration)
                        if sampleEnd.isValid, endTime.map({ CMTimeCompare(sampleEnd, $0) > 0 }) ?? true {
                            endTime = sampleEnd
                        }
                    }
                    sampleCount += 1
                }
            }
            guard reader.status == .completed, sampleCount > 0,
                  let startKeyframe, let endTime, let codec,
                  CMTimeCompare(endTime, requestedEnd) >= 0,
                  CMTimeCompare(endTime, trackEnd) <= 0
            else { throw ExportError.passthroughUnsupported }
            guard codec == "h264" || codec == "hevc" else { throw ExportError.passthroughUnsupported }

            let startOffset = CMTimeSubtract(startKeyframe, track.timeRange.start).seconds
            let endOffset = CMTimeSubtract(endTime, track.timeRange.start).seconds
            guard startOffset.isFinite, endOffset.isFinite, endOffset > startOffset else {
                throw ExportError.passthroughUnsupported
            }
            let rawStart = segmentStartSample + Int64(floor(startOffset * Double(sessionSampleRate)))
            let rawEnd = segmentStartSample + Int64(ceil(endOffset * Double(sessionSampleRate)))
            let segmentEnd = segmentStartSample + segmentSampleCount
            let effectiveStart = max(segmentStartSample, rawStart)
            let effectiveEnd = min(segmentEnd, rawEnd)
            guard effectiveEnd > effectiveStart,
                  effectiveStart <= requested.startSample, effectiveEnd >= requested.endSample
            else { throw ExportError.passthroughUnsupported }
            let duration = CMTimeSubtract(endTime, startKeyframe)
            guard duration.isValid, duration.value > 0, duration.timescale > 0 else {
                throw ExportError.passthroughUnsupported
            }
            return VideoRangeInspection(
                codec: codec,
                range: ExportTimeRange(
                    startValue: startKeyframe.value, startTimescale: startKeyframe.timescale,
                    durationValue: duration.value, durationTimescale: duration.timescale
                ),
                effective: SampleRange(startSample: effectiveStart, sampleCount: effectiveEnd - effectiveStart)
            )
        }
    }

    private static func videoCodecName(_ subtype: FourCharCode) -> String? {
        switch subtype {
        case kCMVideoCodecType_H264: return "h264"
        case kCMVideoCodecType_HEVC: return "hevc"
        default: return nil
        }
    }

    private static func recordingRole(_ name: String) -> RecordingTrackRole? {
        switch name.lowercased() {
        case "mixed": .mixed
        case "system": .system
        case "microphone", "mic": .microphone
        default: nil
        }
    }

    private static func roleOrder(_ role: RecordingTrackRole) -> Int {
        switch role {
        case .mixed: 0
        case .system: 1
        case .microphone: 2
        }
    }

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private static func isExistingDirectory(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private static func validStem(_ stem: String) -> Bool {
        !stem.isEmpty && stem != "." && stem != ".." && !stem.hasPrefix(".")
            && !stem.contains("/") && !stem.contains("\\") && !stem.contains("\0")
    }

    private static func estimatePeakBytes(
        clips: [ExportClip],
        segments: [PublishedSegment],
        outputRoles: [RecordingTrackRole],
        videoPassthrough: Bool,
        outputSpec: ExportOutputSpec
    ) -> Int64 {
        let audioRate = Int64(max(1, outputRoles.count)) * 192_000
        let audioBytes = Int64(max(0, clips.reduce(Int64(0)) { $0 + $1.effectiveRange.sampleCount }))
            .multipliedReportingOverflow(by: audioRate).partialValue / (sessionSampleRate * 8)
        var videoBytes: Int64 = 0
        if videoPassthrough {
            for clip in clips {
                guard let segment = segments.first(where: { $0.id == clip.segmentID }),
                      let url = segment.videoURL,
                      segment.sampleCount > 0
                else { continue }
                guard let size = (try? FileManager.default.attributesOfItem(
                    atPath: url.path
                )[.size] as? NSNumber)?.int64Value else { continue }
                let selected = min(segment.sampleCount, clip.effectiveRange.sampleCount)
                videoBytes = saturatingAdd(videoBytes, max(0, size) * selected / segment.sampleCount)
            }
        }
        let outputEstimate = saturatingAdd(audioBytes, videoBytes)
        // The reserved transaction stage contains the complete output; double the
        // estimate leaves conservative headroom for writer/container scratch data.
        return max(1, saturatingAdd(outputEstimate, outputEstimate))
    }

    private static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : value
    }

    private static func assessment(for error: ExportError) -> ExportDisabledReason {
        switch error {
        case .emptySelection: .emptySelection
        case .overLimit(let seconds): .overLimit(overageSeconds: seconds)
        case .incompatibleCodec: .incompatibleCodec
        case .missingSource: .missingSource
        case .destinationUnavailable: .destinationUnavailable
        case .passthroughUnsupported: .passthroughUnsupported
        case .exportInProgress, .cancelled, .publishFailed: .missingSource
        }
    }
}

struct VideoRangeInspection: Sendable {
    let codec: String
    let range: ExportTimeRange
    let effective: SampleRange
}

private struct PlannerAudioDescriptor: Sendable {
    enum MediaKind: Sendable, Equatable { case checkpoint, published }
    let role: RecordingTrackRole
    let url: URL
    let urls: [URL]
    let range: SampleRange
    let sampleRate: Int
    let channelCount: Int
    let mediaKind: MediaKind
}

private extension SampleRange {
    var endSample: Int64 { startSample + sampleCount }
}
