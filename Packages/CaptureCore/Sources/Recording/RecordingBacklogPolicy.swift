import Foundation

/// The result of asking the backlog policy to schedule work.
public enum BacklogDecision: Sendable, Hashable {
    /// Work may proceed.
    case run
    /// Work may be retried after the backlog or in-flight work changes.
    case `defer`(reason: String)
    /// The input or policy is invalid and work must fail closed.
    case stop(reason: String)
}

/// Priority and watermark rules for capture, sealing, and thumbnail export.
public struct RecordingBacklogPolicy: Sendable, Hashable {
    /// Work class used to preserve capture and publication priority.
    public enum Priority: Int, Sendable {
        /// Checkpoint/capture work is never delayed by seal or export backlog.
        case captureCheckpoint = 0
        /// Segment sealing has priority over optional thumbnail export.
        case seal = 1
        /// Optional thumbnail export is last priority.
        case exportThumbnail = 2
    }

    /// Maximum number of admitted seal operations at once.
    public let maximumConcurrentSeals: Int
    /// Backlog size at which the gate enters pressure mode.
    public let highWatermarkBytes: Int64
    /// Backlog size at which the gate exits pressure mode.
    public let lowWatermarkBytes: Int64

    /// Creates a policy. Invalid values result in `.stop` decisions, not traps.
    public init(
        maximumConcurrentSeals: Int = 1,
        highWatermarkBytes: Int64,
        lowWatermarkBytes: Int64
    ) {
        self.maximumConcurrentSeals = maximumConcurrentSeals
        self.highWatermarkBytes = highWatermarkBytes
        self.lowWatermarkBytes = lowWatermarkBytes
    }

    /// Decides whether work may run for the supplied nonnegative backlog.
    /// Hysteresis is latched by ``RecordingPipelineSpaceGate`` across samples.
    public func admit(_ priority: Priority, backlogBytes: Int64) -> BacklogDecision {
        guard isValid else { return .stop(reason: "invalid backlog policy") }
        guard backlogBytes >= 0 else { return .stop(reason: "negative backlog size") }

        switch priority {
        case .captureCheckpoint:
            return .run
        case .seal:
            return backlogBytes > highWatermarkBytes
                ? .defer(reason: "seal backlog is above the high watermark")
                : .run
        case .exportThumbnail:
            return backlogBytes > lowWatermarkBytes
                ? .defer(reason: "optional export is below seal priority")
                : .run
        }
    }

    var isValid: Bool {
        maximumConcurrentSeals > 0 && lowWatermarkBytes >= 0 && highWatermarkBytes >= lowWatermarkBytes
    }
}
