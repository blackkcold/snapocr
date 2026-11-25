import Foundation

// MARK: Export plan assembly

extension RecordingExportPlanner {
    /// Everything one segment contributes to a plan.
    ///
    /// Each segment is resolved in a single pass so validation, audio, and video
    /// failures keep their original precedence.
    private struct SegmentPlan {
        let requested: SampleRange
        let effective: SampleRange
        let videoRange: ExportTimeRange?
        let videoCodec: String?
        let descriptors: [PlannerAudioDescriptor]
    }

    /// Per-segment planning results, keyed by segment identity.
    struct SegmentScan {
        var requestedByID: [UUID: SampleRange] = [:]
        var effectiveByID: [UUID: SampleRange] = [:]
        var videoByID: [UUID: ExportTimeRange] = [:]
        var descriptorsByID: [UUID: [PlannerAudioDescriptor]] = [:]
        var videoCodec: String?
    }

    static func build(
        session: RecordingSessionRecord,
        selection: ExportSelection,
        audioSourcesBySegment: [UUID: ExportAudioSource],
        allowOverLimit: Bool = false
    ) throws -> ExportPlan {
        try validateSelection(selection)
        let resolved = try resolveSegments(session: session, selection: selection)
        let wantsVideo = session.kind == .screen && selection.includeVideo
        let scan = try scanSegments(
            resolved.segments, selection: selection,
            audioSourcesBySegment: audioSourcesBySegment,
            wantsVideo: wantsVideo, layout: session.layout
        )

        let effectiveDuration = scan.effectiveByID.values.reduce(0.0) {
            $0 + Double($1.sampleCount) / Double(sessionSampleRate)
        }
        let overage = max(0, effectiveDuration - maximumExportDuration)
        guard allowOverLimit || overage <= 0 else { throw ExportError.overLimit(overageSeconds: overage) }

        let tracks = try resolveTracks(
            selection: selection.trackSelection, layout: session.layout,
            descriptorsByID: scan.descriptorsByID
        )
        let outputSpec = makeOutputSpec(
            selection: selection, wantsVideo: wantsVideo, videoCodec: scan.videoCodec,
            outputRoles: tracks.roles, descriptorsByID: scan.descriptorsByID
        )
        let produced = makeClipsAndSourceRanges(
            segments: resolved.segments, scan: scan, outputRoles: tracks.roles
        )
        let peakBytes = estimatePeakBytes(
            clips: produced.clips, segments: resolved.segments, outputRoles: tracks.roles,
            videoPassthrough: wantsVideo
        )
        return ExportPlan(
            sessionID: session.id, outputSpec: outputSpec, sourceRanges: produced.sourceRanges,
            clips: produced.clips, requestedRanges: scan.requestedByID,
            effectiveRanges: scan.effectiveByID, trackMap: tracks.trackMap,
            audioGainDB: selection.audioGainDB,
            audioSourcesBySegment: audioSourcesBySegment.filter { resolved.selectedIDs.contains($0.key) },
            videoPassthrough: wantsVideo,
            audioOperation: audioOperation(outputRoles: tracks.roles, trackMap: tracks.trackMap),
            estimatedDuration: effectiveDuration, estimatedPeakBytes: peakBytes
        )
    }

    /// Rejects selections that cannot name an output at all.
    private static func validateSelection(_ selection: ExportSelection) throws {
        guard !selection.segmentIDs.isEmpty else { throw ExportError.emptySelection }
        guard selection.audioGainDB.isFinite,
              isExistingDirectory(selection.destination.directory), validStem(selection.destination.stem)
        else { throw ExportError.destinationUnavailable }
    }

    /// Resolves the selected segments in publication order.
    private static func resolveSegments(
        session: RecordingSessionRecord,
        selection: ExportSelection
    ) throws -> (segments: [PublishedSegment], selectedIDs: Set<UUID>) {
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
        return (segments, selectedIDs)
    }

    /// Plans every selected segment, preserving source, codec, and range checks.
    private static func scanSegments(
        _ segments: [PublishedSegment],
        selection: ExportSelection,
        audioSourcesBySegment: [UUID: ExportAudioSource],
        wantsVideo: Bool,
        layout: AudioOutputLayout
    ) throws -> SegmentScan {
        var scan = SegmentScan()
        for segment in segments {
            let plan = try planSegment(
                segment, selection: selection, wantsVideo: wantsVideo,
                audioSource: audioSourcesBySegment[segment.id], sessionLayout: layout
            )
            if let codec = plan.videoCodec {
                if let videoCodec = scan.videoCodec, videoCodec != codec {
                    throw ExportError.incompatibleCodec
                }
                scan.videoCodec = codec
            }
            scan.requestedByID[segment.id] = plan.requested
            scan.effectiveByID[segment.id] = plan.effective
            scan.descriptorsByID[segment.id] = plan.descriptors
            if let videoRange = plan.videoRange { scan.videoByID[segment.id] = videoRange }
        }
        return scan
    }

    /// Resolves one segment's requested range, audio descriptors, and video extent.
    private static func planSegment(
        _ segment: PublishedSegment,
        selection: ExportSelection,
        wantsVideo: Bool,
        audioSource: ExportAudioSource?,
        sessionLayout: AudioOutputLayout
    ) throws -> SegmentPlan {
        let segmentRange = SampleRange(startSample: segment.startSample, sampleCount: segment.sampleCount)
        let raw = selection.rangesBySegment[segment.id] ?? segmentRange
        guard raw.sampleCount > 0 else { throw ExportError.emptySelection }
        let lower = max(segment.startSample, raw.startSample)
        let upper = min(segment.sampleCount + segment.startSample, raw.sampleCount + raw.startSample)
        guard upper > lower else { throw ExportError.emptySelection }
        let requested = SampleRange(startSample: lower, sampleCount: upper - lower)
        let descriptors = try requiredAudioDescriptors(
            source: audioSource, segment: segment, sessionLayout: sessionLayout
        )
        guard wantsVideo else {
            return SegmentPlan(
                requested: requested, effective: requested, videoRange: nil,
                videoCodec: nil, descriptors: descriptors
            )
        }
        let inspection = try inspectedVideo(segment: segment, requested: requested)
        let effectiveStart = min(requested.startSample, inspection.effective.startSample)
        let effective = SampleRange(
            startSample: effectiveStart,
            sampleCount: max(
                requested.sampleCount + requested.startSample,
                inspection.effective.sampleCount + inspection.effective.startSample
            ) - effectiveStart
        )
        return SegmentPlan(
            requested: requested, effective: effective, videoRange: inspection.range,
            videoCodec: inspection.codec, descriptors: descriptors
        )
    }

    /// Maps video inspection failures onto the planner's export errors.
    private static func inspectedVideo(
        segment: PublishedSegment,
        requested: SampleRange
    ) throws -> VideoRangeInspection {
        guard let videoURL = segment.videoURL, videoURL.isFileURL, fileExists(videoURL)
        else { throw ExportError.missingSource }
        do {
            return try inspectVideoRange(
                url: videoURL, trackIndex: segment.videoTrackIndex ?? 0,
                segmentStartSample: segment.startSample, segmentSampleCount: segment.sampleCount,
                requested: requested
            )
        } catch let error as ExportError {
            throw error
        } catch {
            throw ExportError.passthroughUnsupported
        }
    }
}
