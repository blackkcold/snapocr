import CaptureCore
import Foundation

extension RecordingExportViewModel {
    func assess() -> ExportAssessment {
        if let assessment { return assessment }
        guard let session else { return Self.emptyAssessment(destination: currentDestination) }
        return RecordingExportPlanner.assess(
            session: session,
            selection: makeSelection(for: session),
            audioSourcesBySegment: [:]
        )
    }

    func validatedPlan() throws -> ExportPlan {
        guard validatedPlanGeneration == assessmentGeneration,
            let cachedPlan
        else {
            if let overage = assessment?.overageSeconds, overage > 0 {
                throw ExportError.overLimit(overageSeconds: overage)
            }
            throw assessment?.disabledReason.map(Self.exportError(for:)) ?? ExportError.emptySelection
        }
        let overage = max(0, cachedPlan.estimatedDuration - RecordingExportPlanner.maximumExportDuration)
        guard overage == 0 else { throw ExportError.overLimit(overageSeconds: overage) }
        return cachedPlan
    }

    func setSegmentSelected(_ segmentID: UUID, isSelected: Bool) {
        guard let segment = session?.segments.first(where: { $0.id == segmentID }),
            segment.state == .published
        else { return }
        if isSelected {
            selectedSegmentIDs.insert(segmentID)
        } else {
            selectedSegmentIDs.remove(segmentID)
            if previewSegmentID == segmentID { releasePreviewLease() }
        }
        succeededOutputURL = nil
        refreshAssessment()
    }

    func trimRange(for segment: PublishedSegment) -> SampleRange {
        rangesBySegment[segment.id]
            ?? SampleRange(startSample: segment.startSample, sampleCount: segment.sampleCount)
    }

    func setTrimRange(_ range: SampleRange, for segmentID: UUID) {
        guard let segment = session?.segments.first(where: { $0.id == segmentID }),
            segment.state == .published, segment.sampleCount > 0
        else { return }
        let segmentEnd = segment.startSample + segment.sampleCount
        let start = max(segment.startSample, range.startSample)
        let end = min(segmentEnd, range.startSample + range.sampleCount)
        guard end > start else { return }
        if start == segment.startSample && end == segmentEnd {
            rangesBySegment[segmentID] = nil
        } else {
            rangesBySegment[segmentID] = SampleRange(startSample: start, sampleCount: end - start)
        }
        succeededOutputURL = nil
        if selectedSegmentIDs.contains(segmentID) { refreshAssessment() }
    }

    func setOutputMode(_ mode: RecordingExportOutputMode) {
        guard availableOutputModes.contains(mode), outputMode != mode else { return }
        outputMode = mode
        succeededOutputURL = nil
        refreshAssessment()
    }

    func setOutputDirectory(_ directory: URL) {
        guard directory.isFileURL else { return }
        hasUserChosenOutputDirectory = true
        outputDirectory = directory.standardizedFileURL
        succeededOutputURL = nil
        refreshAssessment()
    }

    func setOutputStem(_ stem: String) {
        guard outputStem != stem else { return }
        outputStem = stem
        succeededOutputURL = nil
        refreshAssessment()
    }

    func setAudioGainDB(_ value: Double) {
        guard value.isFinite else { return }
        let clamped = min(12, max(-24, value))
        guard audioGainDB != clamped else { return }
        audioGainDB = clamped
        refreshAssessment()
    }

    var currentDestination: ExportDestination {
        ExportDestination(directory: outputDirectory, stem: outputStem)
    }

    func makeSelection(for session: RecordingSessionRecord) -> ExportSelection {
        let orderedIDs = session.segments
            .filter { selectedSegmentIDs.contains($0.id) && $0.state == .published }
            .sorted { $0.index < $1.index }
            .map(\.id)
        let selectedRanges = rangesBySegment.filter { orderedIDs.contains($0.key) }
        return ExportSelection(
            segmentIDs: orderedIDs,
            rangesBySegment: selectedRanges,
            trackSelection: outputMode.trackSelection,
            includeVideo: outputMode.includesVideo,
            audioGainDB: Float(audioGainDB),
            destination: currentDestination
        )
    }

    func refreshAssessment() {
        guard let session, let service = previewService else {
            assessment = nil
            summary = nil
            isAssessing = false
            cachedPlan = nil
            validatedPlanGeneration = nil
            return
        }

        assessmentGeneration += 1
        let generation = assessmentGeneration
        assessmentTask?.cancel()
        let previousLeases = selectedSourceLeases
        selectedSourceLeases = nil
        let selection = makeSelection(for: session)
        assessment = nil
        summary = nil
        cachedPlan = nil
        validatedPlanGeneration = nil
        isAssessing = true

        let task = Task.detached(priority: .userInitiated) {
            if let previousLeases {
                await RecordingExportWork.release(previousLeases.leases, using: previousLeases.service)
            }
            return await RecordingExportWork.evaluate(
                session: session,
                selection: selection,
                service: service
            )
        }
        assessmentTask = task
        Task { @MainActor [weak self] in
            let result = await task.value
            guard let self else {
                await RecordingExportWork.release(result.leases, using: service)
                return
            }
            guard self.assessmentGeneration == generation,
                self.selectedSessionID == session.id
            else {
                await RecordingExportWork.release(result.leases, using: service)
                return
            }
            self.assessmentTask = nil
            self.isAssessing = false
            self.assessment = result.assessment
            self.cachedPlan = result.plan
            self.validatedPlanGeneration = result.plan == nil ? nil : generation
            self.selectedSourceLeases = RecordingExportLeaseBundle(service: service, leases: result.leases)
            self.summary = Self.makeSummary(for: result.assessment, session: session)
        }
    }

    func invalidateAssessment() {
        assessmentGeneration += 1
        assessmentTask?.cancel()
        assessmentTask = nil
        isAssessing = false
        cachedPlan = nil
        validatedPlanGeneration = nil
    }

    func releaseSelectedSourceLeases() {
        guard let bundle = selectedSourceLeases else { return }
        selectedSourceLeases = nil
        Task.detached {
            await RecordingExportWork.release(bundle.leases, using: bundle.service)
        }
    }

    static func makeSummary(
        for assessment: ExportAssessment,
        session: RecordingSessionRecord
    ) -> RecordingExportSummary {
        let videoLabel = assessment.videoPassthrough ? "Video passthrough" : "Audio only"
        let audioLabel: String
        switch assessment.audioOperation {
        case .passthrough: audioLabel = "Audio passthrough"
        case .reencodeAudio: audioLabel = "Audio re-encode"
        case .mixedFromPublished: audioLabel = "Mixed published audio"
        case .missingSilence: audioLabel = "Audio source unavailable"
        }
        let missingID = session.segments.first(where: { $0.state == .missing })?.id
        return RecordingExportSummary(
            selectedDuration: assessment.requestedDuration,
            maximumDuration: RecordingExportPlanner.maximumExportDuration,
            overage: assessment.overageSeconds,
            videoPassthroughLabel: videoLabel,
            audioOperationLabel: audioLabel,
            trackCount: assessment.trackMap.count + (assessment.videoPassthrough ? 1 : 0),
            missingState: missingID.map(MissingState.missing(segmentID:)) ?? .none
        )
    }

    static func exportError(for reason: ExportDisabledReason) -> ExportError {
        switch reason {
        case .emptySelection: .emptySelection
        case .overLimit(let seconds): .overLimit(overageSeconds: seconds)
        case .incompatibleCodec: .incompatibleCodec
        case .missingSource: .missingSource
        case .destinationUnavailable: .destinationUnavailable
        case .passthroughUnsupported: .passthroughUnsupported
        }
    }

    static func emptyAssessment(destination: ExportDestination) -> ExportAssessment {
        ExportAssessment(
            requestedRanges: [:],
            effectiveRanges: [:],
            requestedDuration: 0,
            effectiveDuration: 0,
            overageSeconds: 0,
            disabledReason: .emptySelection,
            outputSpec: ExportOutputSpec(
                destination: destination,
                shape: .singleFile(fileExtension: "m4a"),
                videoCodec: nil,
                audioFormat: ExportAudioFormat(codec: "aac", sampleRate: 48_000, channelCountByRole: [:])
            ),
            clips: [],
            trackMap: [:],
            audioOperation: .missingSilence,
            videoPassthrough: false,
            estimatedPeakBytes: 0
        )
    }
}
