import Foundation

// MARK: Assessments and disabled reasons

extension RecordingExportPlanner {
    static func assessment(for plan: ExportPlan, disabledReason: ExportDisabledReason?) -> ExportAssessment {
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

    /// Describes what the destination would have produced before validation failed.
    static func fallbackOutputSpec(
        session: RecordingSessionRecord,
        selection: ExportSelection
    ) -> ExportOutputSpec {
        let roles: [RecordingTrackRole] =
            selection.trackSelection == .mixed
            ? [.mixed]
            : [.system, .microphone]
        return ExportOutputSpec(
            destination: selection.destination,
            shape: outputShape(
                wantsVideo: session.kind == .screen && selection.includeVideo,
                selection: selection.trackSelection
            ),
            videoCodec: nil,
            audioFormat: ExportAudioFormat(
                codec: "aac",
                sampleRate: Int(sessionSampleRate),
                channelCountByRole: Dictionary(uniqueKeysWithValues: roles.map { ($0, 2) })
            )
        )
    }

    /// The empty assessment shown when planning throws.
    static func failedAssessment(
        session: RecordingSessionRecord,
        selection: ExportSelection,
        reason: ExportDisabledReason
    ) -> ExportAssessment {
        ExportAssessment(
            requestedRanges: [:], effectiveRanges: [:], requestedDuration: 0,
            effectiveDuration: 0, overageSeconds: 0, disabledReason: reason,
            outputSpec: fallbackOutputSpec(session: session, selection: selection),
            clips: [], trackMap: [:], audioOperation: .missingSilence,
            videoPassthrough: false, estimatedPeakBytes: 0
        )
    }

    static func assessment(for error: ExportError) -> ExportDisabledReason {
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
