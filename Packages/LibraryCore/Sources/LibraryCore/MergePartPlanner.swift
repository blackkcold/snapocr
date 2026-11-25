import Foundation

/// One output file produced by a merge, expressed as a contiguous run of
/// segment indices. The exporter resolves these indices to media ranges.
public struct MergePart: Sendable, Equatable, Identifiable {
    public var id: Int { segmentIndices.first ?? -1 }
    public let segmentIndices: [Int]
    public let duration: TimeInterval
    /// A single source segment can itself exceed the exporter's maximum
    /// duration (for example a legacy or foreign file). The part is still
    /// reported so the UI can explain why it cannot be exported in one piece.
    public let isOverLimit: Bool

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

    public static func totalDuration(for parts: [MergePart]) -> TimeInterval {
        parts.reduce(0) { $0 + $1.duration }
    }
}
