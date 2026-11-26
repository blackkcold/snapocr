import CaptureCore
import Foundation

/// Combines already-validated single-session export plans into one timeline.
///
/// This intentionally stays in the library layer: `ExportPlan.init` and
/// `RecordingExportPlanner.revalidate` are public, while the composition
/// exporter only consumes the resulting clips.
public enum RecordingPlanMerger {
    /// Merges already-validated single-session plans into one export plan.
    ///
    /// The merged plan concatenates the source ranges and clips of every input,
    /// re-encodes a track if any input re-encodes it, uses the widest channel
    /// count per role, and sums the estimated duration and peak size. The result
    /// is revalidated before it is returned.
    ///
    /// - Parameters:
    ///   - plans: Validated plans to combine, in playback order.
    ///   - sessionID: Session identifier recorded on the merged plan.
    ///   - destination: Where the merged output is written.
    ///   - template: Output spec whose shape and video codec are reused; the
    ///     audio format is rebuilt from the inputs.
    /// - Returns: A revalidated plan covering all input clips.
    /// - Throws: `ExportError.emptySelection` when there are no plans or no
    ///   clips, or an error from `RecordingExportPlanner.revalidate` when the
    ///   merged plan is inconsistent.
    public static func merge(
        _ plans: [ExportPlan],
        sessionID: UUID,
        destination: ExportDestination,
        outputSpec template: ExportOutputSpec
    ) throws -> ExportPlan {
        guard let first = plans.first, !plans.isEmpty else {
            throw ExportError.emptySelection
        }
        let clips = plans.flatMap(\.clips)
        guard !clips.isEmpty else { throw ExportError.emptySelection }

        var trackMap: [RecordingTrackRole: ExportAudioOperation] = [:]
        var channels: [RecordingTrackRole: Int] = [:]
        for plan in plans {
            for (role, operation) in plan.trackMap {
                if let existing = trackMap[role] {
                    trackMap[role] =
                        (existing == .reencodeAudio || operation == .reencodeAudio)
                        ? .reencodeAudio
                        : existing
                } else {
                    trackMap[role] = operation
                }
            }
            for (role, count) in plan.outputSpec.audioFormat.channelCountByRole {
                channels[role] = max(channels[role] ?? 1, count)
            }
        }

        let spec = ExportOutputSpec(
            destination: destination,
            shape: template.shape,
            videoCodec: template.videoCodec,
            audioFormat: ExportAudioFormat(
                codec: "aac",
                sampleRate: 48_000,
                channelCountByRole: channels
            )
        )

        let merged = ExportPlan(
            sessionID: sessionID,
            outputSpec: spec,
            sourceRanges: plans.flatMap(\.sourceRanges),
            clips: clips,
            requestedRanges: plans.reduce(into: [:]) { result, plan in
                result.merge(plan.requestedRanges) { first, _ in first }
            },
            effectiveRanges: plans.reduce(into: [:]) { result, plan in
                result.merge(plan.effectiveRanges) { first, _ in first }
            },
            trackMap: trackMap,
            audioGainDB: first.audioGainDB,
            audioSourcesBySegment: plans.reduce(into: [:]) { result, plan in
                result.merge(plan.audioSourcesBySegment) { first, _ in first }
            },
            videoPassthrough: isVideoShape(template.shape),
            audioOperation: plans.contains { $0.audioOperation == .reencodeAudio }
                ? .reencodeAudio
                : first.audioOperation,
            estimatedDuration: plans.reduce(0) { $0 + $1.estimatedDuration },
            estimatedPeakBytes: plans.reduce(0) { $0 + $1.estimatedPeakBytes }
        )

        return try RecordingExportPlanner.revalidate(
            merged,
            actualRanges: merged.effectiveRanges
        )
    }

    private static func isVideoShape(_ shape: ExportOutputShape) -> Bool {
        if case .singleFile(let fileExtension) = shape {
            return fileExtension.lowercased() == "mp4"
        }
        return false
    }
}
