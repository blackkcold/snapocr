import Foundation

/// One output file produced by a merge, expressed as a contiguous run of
/// segment indices. The exporter resolves these indices to media ranges.
public struct MergePart: Sendable, Equatable, Identifiable {
    /// Identifier of the part: the first segment index, or `-1` when empty.
    public var id: Int { segmentIndices.first ?? -1 }
    /// Segment indices that the part covers, in playback order.
    public let segmentIndices: [Int]
    /// Total duration of the covered segments in seconds.
    public let duration: TimeInterval
    /// A single source segment can itself exceed the exporter's maximum
    /// duration (for example a legacy or foreign file). The part is still
    /// reported so the UI can explain why it cannot be exported in one piece.
    public let isOverLimit: Bool

    /// Creates a part with the given values.
    ///
    /// - Parameters:
    ///   - segmentIndices: Segment indices covered by the part.
    ///   - duration: Total duration of the covered segments in seconds.
    ///   - isOverLimit: Whether the part exceeds the exporter's maximum.
    public init(segmentIndices: [Int], duration: TimeInterval, isOverLimit: Bool) {
        self.segmentIndices = segmentIndices
        self.duration = duration
        self.isOverLimit = isOverLimit
    }
}

/// Splits an ordered list of segment durations into merge parts without
/// ever cutting inside a segment. The existing exporter publishes at most
/// 1:59:30 per file, so a three-segment two-hour recording becomes two files
/// at the segment boundary rather than failing with `overLimit`.
public enum MergePartPlanner {
    /// Splits segment durations into parts that each fit within a maximum
    /// duration, without ever cutting inside a segment.
    ///
    /// Non-finite and negative durations are treated as `0`. A segment whose
    /// own duration exceeds `maximumDuration` is emitted as a part marked
    /// `isOverLimit`.
    ///
    /// - Parameters:
    ///   - segmentDurations: Durations of the ordered segments in seconds.
    ///   - maximumDuration: Longest part the exporter accepts, in seconds.
    /// - Returns: Parts in playback order, or an empty array when
    ///   `maximumDuration` is not positive.
    public static func parts(
        segmentDurations: [TimeInterval],
        maximumDuration: TimeInterval
    ) -> [MergePart] {
        guard maximumDuration > 0 else { return [] }

        var result: [MergePart] = []
        var currentIndices: [Int] = []
        var currentDuration: TimeInterval = 0

        func flush(isOverLimit: Bool) {
            guard !currentIndices.isEmpty else { return }
            result.append(
                MergePart(
                    segmentIndices: currentIndices,
                    duration: currentDuration,
                    isOverLimit: isOverLimit
                )
            )
            currentIndices = []
            currentDuration = 0
        }

        for (index, rawDuration) in segmentDurations.enumerated() {
            let duration = rawDuration.isFinite ? max(0, rawDuration) : 0
            if !currentIndices.isEmpty, currentDuration + duration > maximumDuration {
                flush(isOverLimit: false)
            }
            currentIndices.append(index)
            currentDuration += duration
            if currentDuration > maximumDuration {
                flush(isOverLimit: true)
            }
        }

        flush(isOverLimit: currentDuration > maximumDuration)
        return result
    }

    /// Sums the durations of the given parts.
    ///
    /// - Parameter parts: Parts to add up.
    /// - Returns: Total duration in seconds.
    public static func totalDuration(for parts: [MergePart]) -> TimeInterval {
        parts.reduce(0) { $0 + $1.duration }
    }
}
