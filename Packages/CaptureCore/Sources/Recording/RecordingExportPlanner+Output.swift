import Foundation

// MARK: Output specification, clips, and size estimation

extension RecordingExportPlanner {
    /// Resolves the output roles and their audio operation in one pass.
    ///
    /// The trailing source check is deliberately kept here so the caller sees the
    /// same `missingSource` failure at the same point in the build.
    static func resolveTracks(
        selection: ExportTrackSelection,
        layout: AudioOutputLayout,
        descriptorsByID: [UUID: [PlannerAudioDescriptor]]
    ) throws -> (
        roles: [RecordingTrackRole], trackMap: [RecordingTrackRole: ExportAudioOperation]
    ) {
        let outputRoles = resolveOutputRoles(
            selection: selection, layout: layout, descriptorsByID: descriptorsByID
        )
        guard !outputRoles.isEmpty else { throw ExportError.missingSource }
        var trackMap: [RecordingTrackRole: ExportAudioOperation] = [:]
        for outputRole in outputRoles {
            let matching = descriptorsByID.values.flatMap { descriptors in
                matchingDescriptors(descriptors, outputRole: outputRole)
            }
            if matching.isEmpty {
                trackMap[outputRole] = .missingSilence
            } else if outputRole == .mixed && selection == .mixed,
                matching.contains(where: { $0.mediaKind == .published })
            {
                trackMap[outputRole] = .mixedFromPublished
            } else {
                trackMap[outputRole] = .reencodeAudio
            }
        }
        guard descriptorsByID.values.flatMap({ $0 }).contains(where: { !$0.urls.isEmpty }) else {
            throw ExportError.missingSource
        }
        return (outputRoles, trackMap)
    }

    static func makeOutputSpec(
        selection: ExportSelection,
        wantsVideo: Bool,
        videoCodec: String?,
        outputRoles: [RecordingTrackRole],
        descriptorsByID: [UUID: [PlannerAudioDescriptor]]
    ) -> ExportOutputSpec {
        let channelCounts = Dictionary(
            uniqueKeysWithValues: outputRoles.map { role in
                let matches = descriptorsByID.values.flatMap { matchingDescriptors($0, outputRole: role) }
                let channels = matches.map(\.channelCount).filter { (1...2).contains($0) }.max() ?? 2
                return (role, min(2, max(1, channels)))
            })
        return ExportOutputSpec(
            destination: selection.destination,
            shape: outputShape(wantsVideo: wantsVideo, selection: selection.trackSelection),
            videoCodec: videoCodec,
            audioFormat: ExportAudioFormat(
                codec: "aac",
                sampleRate: Int(sessionSampleRate),
                channelCountByRole: channelCounts
            )
        )
    }

    static func outputShape(
        wantsVideo: Bool,
        selection: ExportTrackSelection
    ) -> ExportOutputShape {
        if wantsVideo {
            return .singleFile(fileExtension: "mp4")
        }
        if selection == .sourceSeparated {
            return .directory
        }
        return .singleFile(fileExtension: "m4a")
    }

    static func makeClipsAndSourceRanges(
        segments: [PublishedSegment],
        scan: SegmentScan,
        outputRoles: [RecordingTrackRole]
    ) -> (clips: [ExportClip], sourceRanges: [ExportSourceRange]) {
        var clips: [ExportClip] = []
        var sourceRanges: [ExportSourceRange] = []
        for segment in segments {
            guard let requested = scan.requestedByID[segment.id],
                let effective = scan.effectiveByID[segment.id]
            else { continue }
            let descriptors = scan.descriptorsByID[segment.id] ?? []
            let clip = ExportClip(
                segmentID: segment.id, index: segment.index, requestedRange: requested,
                effectiveRange: effective, videoRange: scan.videoByID[segment.id]
            )
            clips.append(clip)
            for outputRole in outputRoles {
                sourceRanges.append(
                    sourceRange(
                        segment: segment, role: outputRole, clip: clip, descriptors: descriptors
                    ))
            }
        }
        return (clips, sourceRanges)
    }

    private static func sourceRange(
        segment: PublishedSegment,
        role: RecordingTrackRole,
        clip: ExportClip,
        descriptors: [PlannerAudioDescriptor]
    ) -> ExportSourceRange {
        var urls = matchingDescriptors(descriptors, outputRole: role).flatMap(\.urls)
        if let videoURL = segment.videoURL { urls.insert(videoURL, at: 0) }
        return ExportSourceRange(
            segmentID: segment.id, segmentIndex: segment.index, role: ExportTrackRole(role),
            requested: ExportSampleRange(
                startSample: clip.requestedRange.startSample,
                sampleCount: clip.requestedRange.sampleCount
            ),
            effective: ExportSampleRange(
                startSample: clip.effectiveRange.startSample,
                sampleCount: clip.effectiveRange.sampleCount
            ),
            videoRange: clip.videoRange, videoTrackIndex: segment.videoTrackIndex,
            segmentRange: ExportSampleRange(
                startSample: segment.startSample,
                sampleCount: segment.sampleCount
            ),
            sourceFiles: uniqueURLs(urls)
        )
    }

    static func audioOperation(
        outputRoles: [RecordingTrackRole],
        trackMap: [RecordingTrackRole: ExportAudioOperation]
    ) -> ExportAudioOperation {
        if outputRoles.contains(where: { trackMap[$0] == .mixedFromPublished }) {
            return .mixedFromPublished
        }
        if outputRoles.allSatisfy({ trackMap[$0] == .missingSilence }) {
            return .missingSilence
        }
        return .reencodeAudio
    }

    static func estimatePeakBytes(
        clips: [ExportClip],
        segments: [PublishedSegment],
        outputRoles: [RecordingTrackRole],
        videoPassthrough: Bool
    ) -> Int64 {
        let audioBytes = estimatedAudioBytes(clips: clips, outputRoles: outputRoles)
        let videoBytes = videoPassthrough ? estimatedVideoBytes(clips: clips, segments: segments) : 0
        let outputEstimate = saturatingAdd(audioBytes, videoBytes)
        // The reserved transaction stage contains the complete output; double the
        // estimate leaves conservative headroom for writer/container scratch data.
        return max(1, saturatingAdd(outputEstimate, outputEstimate))
    }

    private static func estimatedAudioBytes(
        clips: [ExportClip],
        outputRoles: [RecordingTrackRole]
    ) -> Int64 {
        let audioRate = Int64(max(1, outputRoles.count)) * 192_000
        return Int64(max(0, clips.reduce(Int64(0)) { $0 + $1.effectiveRange.sampleCount }))
            .multipliedReportingOverflow(by: audioRate).partialValue / (sessionSampleRate * 8)
    }

    private static func estimatedVideoBytes(
        clips: [ExportClip],
        segments: [PublishedSegment]
    ) -> Int64 {
        var videoBytes: Int64 = 0
        for clip in clips {
            guard let segment = segments.first(where: { $0.id == clip.segmentID }),
                let url = segment.videoURL,
                segment.sampleCount > 0
            else { continue }
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = (attributes?[.size] as? NSNumber)?.int64Value else { continue }
            let selected = min(segment.sampleCount, clip.effectiveRange.sampleCount)
            videoBytes = saturatingAdd(videoBytes, max(0, size) * selected / segment.sampleCount)
        }
        return videoBytes
    }

    static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : value
    }
}
