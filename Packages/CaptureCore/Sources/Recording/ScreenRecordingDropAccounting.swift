import Foundation

/// Per-stage screen-recording frame drops.
///
/// Each lost frame belongs to exactly one stage:
/// - `captureCallbackDrops`: the bounded frame stream evicted queued work, which
///   the capture callback observes as `.streamDrop` when `yield` returns `.dropped`.
/// - `frameStreamDrops`: a frame the frame task already consumed but could not
///   append because processing had stopped or failed.
/// - `writerDrops`: `AVAssetWriterInput` rejected the frame.
///
/// A `.terminated` yield means the stream finished normally; it is not a
/// backpressure drop. The frame and status streams use `.bufferingNewest`, so a
/// `yield` may drop for a slow consumer; these counts never claim zero loss for
/// streams that can drop by design.
public struct ScreenRecordingDropAccounting: Sendable, Hashable {
    /// Frames the capture callback dropped under bounded stream backpressure.
    public let captureCallbackDrops: Int64
    /// Frames consumed by the frame task that could not reach a segment writer.
    public let frameStreamDrops: Int64
    /// Frames rejected by the video writer.
    public let writerDrops: Int64

    /// Creates a per-stage drop accounting value; negative input clamps to zero.
    public init(captureCallbackDrops: Int64, frameStreamDrops: Int64, writerDrops: Int64) {
        self.captureCallbackDrops = max(0, captureCallbackDrops)
        self.frameStreamDrops = max(0, frameStreamDrops)
        self.writerDrops = max(0, writerDrops)
    }

    /// No frames were dropped at any stage.
    public static let zero = Self(captureCallbackDrops: 0, frameStreamDrops: 0, writerDrops: 0)

    /// All dropped frames; saturates at `Int64.max` instead of overflowing.
    public var total: Int64 {
        Self.saturatingAdd(
            Self.saturatingAdd(captureCallbackDrops, frameStreamDrops),
            writerDrops
        )
    }

    private static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : sum
    }
}

/// A lock-protected, saturating counter for the frame-stream stage.
///
/// Counting never allocates a task or awaits, so the capture path cannot be
/// slowed down by accounting.
final class ScreenRecordingDropCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count: Int64 = 0

    /// Adds `1` unless the count already saturated.
    func increment() {
        lock.lock()
        if count < Int64.max { count += 1 }
        lock.unlock()
    }

    /// The saturated count.
    var value: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
