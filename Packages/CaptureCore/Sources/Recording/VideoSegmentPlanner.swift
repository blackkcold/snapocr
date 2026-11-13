import AudioToolbox
import CoreMedia
import Foundation

/// One closed screen-video recovery chunk or visible segment.
public struct ScreenBoundary: Sendable, Hashable {
    /// Whether this boundary closes a recovery chunk or a visible segment.
    public enum Kind: Sendable, Hashable {
        /// Closes one approximately five-minute recovery chunk.
        case chunk
        /// Closes one visible segment.
        case segment
    }

    /// Boundary type.
    public let kind: Kind
    /// Zero-based visible segment index.
    public let segmentIndex: Int
    /// Zero-based recovery chunk index within the visible segment.
    public let chunkIndex: Int
    /// Index of the first frame in the closed range.
    public let startFrameIndex: Int64
    /// Exclusive index after the last frame in the closed range.
    public let endFrameIndex: Int64
    /// Presentation time at the start of the closed range.
    public let startTime: CMTime
    /// Exclusive end time of the closed range.
    public let endTime: CMTime
    /// Whether the first frame in the closed range is a sync frame.
    public let firstFrameIsSync: Bool

    /// Creates a screen boundary.
    public init(
        kind: Kind,
        segmentIndex: Int,
        chunkIndex: Int,
        startFrameIndex: Int64,
        endFrameIndex: Int64,
        startTime: CMTime,
        endTime: CMTime,
        firstFrameIsSync: Bool
    ) {
        self.kind = kind
        self.segmentIndex = segmentIndex
        self.chunkIndex = chunkIndex
        self.startFrameIndex = startFrameIndex
        self.endFrameIndex = endFrameIndex
        self.startTime = startTime
        self.endTime = endTime
        self.firstFrameIsSync = firstFrameIsSync
    }
}

/// Result of appending a video frame or advancing the monotonic clock.
public enum ScreenBoundaryDecision: Sendable, Equatable {
    /// The current chunk remains open.
    case keepCurrent
    /// Close the current recovery chunk before the incoming frame.
    case closeChunk(ScreenBoundary)
    /// Close the current visible segment before the incoming frame.
    case closeSegment(ScreenBoundary)
    /// Close a recovery chunk while retaining one sync pixel sample for its successor.
    case cachedChunkBoundary(ScreenBoundary)
}

/// Errors raised when creating an invalid video-boundary planner.
public enum VideoSegmentPlannerError: Error, Equatable, Sendable {
    /// Durations, frame rate, or host-clock frequency are invalid.
    case invalidConfiguration
}

/// Plans two-level screen boundaries from observed frame timing and monotonic ticks.
///
/// The planner uses actual presentation timestamps when frames arrive. Its tick
/// path advances a sparse/static source from the first frame's monotonic host-time
/// anchor, so recovery rotation does not depend on receiving another frame.
public final class VideoSegmentPlanner {
    private static let hardMaximumSegmentDuration: TimeInterval = 3_540
    private static let hardCheckpointTarget: TimeInterval = 300

    private let maximumSegmentDuration: TimeInterval
    private let checkpointTarget: TimeInterval
    private let frameRate: Int
    private let hostTicksPerSecond: UInt64
    private var epochTime: CMTime?
    private var epochHostTime: UInt64?
    private var lastHostTime: UInt64?
    private var segmentIndex = 0
    private var chunkIndex = 0
    private var segmentStartTime: CMTime?
    private var segmentStartFrame: Int64 = 0
    private var segmentFirstFrameIsSync = false
    private var nextChunkStartTime: CMTime?
    private var nextChunkStartFrame: Int64 = 0
    private var firstFrameIsSync = false
    private var lastFrameIndex: Int64 = -1
    private var lastFrameEndTime: CMTime?
    private var boundaries: [ScreenBoundary] = []
    private var hasOpenFrame = false

    /// Creates a planner with hard-safe production durations.
    ///
    /// - Parameters:
    ///   - maximumSegmentDuration: Visible-segment maximum; must be in `0...3540` seconds.
    ///   - checkpointTarget: Recovery-chunk target; must be in `0...300` seconds.
    ///   - frameRate: Positive configured frame rate.
    ///   - hostTicksPerSecond: Monotonic host-time frequency; defaults to the platform clock.
    /// - Throws: ``VideoSegmentPlannerError/invalidConfiguration`` for invalid values.
    public init(
        maximumSegmentDuration: TimeInterval = 3_540,
        checkpointTarget: TimeInterval = 300,
        frameRate: Int,
        hostTicksPerSecond: UInt64 = AudioSourceTimestampMapper.nativeHostTicksPerSecond()
    ) throws {
        guard maximumSegmentDuration.isFinite,
              maximumSegmentDuration > 0,
              maximumSegmentDuration <= Self.hardMaximumSegmentDuration,
              checkpointTarget.isFinite,
              checkpointTarget > 0,
              checkpointTarget <= Self.hardCheckpointTarget,
              checkpointTarget <= maximumSegmentDuration,
              frameRate > 0,
              frameRate <= Int(Int32.max),
              hostTicksPerSecond > 0,
              hostTicksPerSecond <= UInt64(Int32.max) else {
            throw VideoSegmentPlannerError.invalidConfiguration
        }
        self.maximumSegmentDuration = maximumSegmentDuration
        self.checkpointTarget = checkpointTarget
        self.frameRate = frameRate
        self.hostTicksPerSecond = hostTicksPerSecond
    }

    /// Appends an observed frame and closes a boundary when actual frame timing requires it.
    ///
    /// - Parameter frame: Timing for an actual video frame.
    /// - Returns: The boundary to close before this frame, or `.keepCurrent`.
    public func append(_ frame: VideoFrameSample) -> ScreenBoundaryDecision {
        guard frame.index >= 0,
              frame.presentationTime.isValid,
              frame.presentationTime.isNumeric,
              frame.duration.isValid,
              frame.duration.isNumeric,
              CMTimeCompare(frame.duration, .zero) > 0,
              frame.index > lastFrameIndex else {
            return .keepCurrent
        }
        if epochTime == nil {
            guard frame.isSync else { return .keepCurrent }
            epochTime = frame.presentationTime
            epochHostTime = lastHostTime
            segmentStartTime = frame.presentationTime
            segmentStartFrame = frame.index
            segmentFirstFrameIsSync = true
            nextChunkStartTime = frame.presentationTime
            nextChunkStartFrame = frame.index
            firstFrameIsSync = true
            hasOpenFrame = true
            lastFrameIndex = frame.index
            lastFrameEndTime = CMTimeAdd(frame.presentationTime, frame.duration)
            return .keepCurrent
        }

        guard let chunkStart = nextChunkStartTime,
              let segmentStartTime,
              let lastFrameEndTime else {
            return .keepCurrent
        }

        if !hasOpenFrame {
            guard frame.isSync else {
                lastFrameIndex = frame.index
                return .keepCurrent
            }
            nextChunkStartTime = frame.presentationTime
            nextChunkStartFrame = frame.index
            firstFrameIsSync = true
        }
        let observedTime = frame.presentationTime
        let currentChunkStart = nextChunkStartTime ?? chunkStart
        let currentLastFrameEnd = hasOpenFrame
            ? lastFrameEndTime
            : CMTimeAdd(frame.presentationTime, frame.duration)
        let elapsedSegment = CMTimeGetSeconds(CMTimeSubtract(observedTime, segmentStartTime))
        let elapsedChunk = CMTimeGetSeconds(CMTimeSubtract(observedTime, currentChunkStart))
        guard elapsedSegment.isFinite, elapsedChunk.isFinite else { return .keepCurrent }

        let isSegmentBoundary = elapsedSegment >= maximumSegmentDuration
        let isChunkBoundary = elapsedChunk >= checkpointTarget
        guard isSegmentBoundary || isChunkBoundary else {
            if !hasOpenFrame {
                nextChunkStartFrame = frame.index
                firstFrameIsSync = frame.isSync
            }
            lastFrameIndex = frame.index
            self.lastFrameEndTime = maxTime(lastFrameEndTime, CMTimeAdd(frame.presentationTime, frame.duration))
            hasOpenFrame = true
            return .keepCurrent
        }

        guard frame.isSync else {
            lastFrameIndex = frame.index
            self.lastFrameEndTime = maxTime(lastFrameEndTime, CMTimeAdd(frame.presentationTime, frame.duration))
            hasOpenFrame = true
            return .keepCurrent
        }

        let kind: ScreenBoundary.Kind = isSegmentBoundary ? .segment : .chunk
        let maximumEnd = CMTimeAdd(
            segmentStartTime,
            CMTime(seconds: maximumSegmentDuration, preferredTimescale: 1_000_000)
        )
        let requestedEnd = kind == .segment ? minTime(observedTime, maximumEnd) : observedTime
        let endTime = maxTime(currentLastFrameEnd, requestedEnd)
        if kind == .segment {
            let chunkBoundary = makeBoundary(kind: .chunk, endFrameIndex: frame.index, endTime: endTime)
            record(chunkBoundary)
        }
        let boundary = makeBoundary(kind: kind, endFrameIndex: frame.index, endTime: endTime)
        record(boundary)
        advance(after: boundary)
        if kind == .segment {
            self.segmentStartTime = endTime
            segmentStartFrame = frame.index
            segmentFirstFrameIsSync = frame.isSync
        }
        lastFrameIndex = frame.index
        self.lastFrameEndTime = CMTimeAdd(frame.presentationTime, frame.duration)
        hasOpenFrame = true

        switch kind {
        case .chunk:
            return frame.isSync ? .cachedChunkBoundary(boundary) : .closeChunk(boundary)
        case .segment:
            return .closeSegment(boundary)
        }
    }

    /// Advances planned boundaries from a monotonic host-time tick.
    ///
    /// - Parameter hostTime: Monotonic host tick in the configured clock domain.
    /// - Returns: A due boundary, if one became due without a new append.
    public func tick(hostTime: UInt64) -> ScreenBoundaryDecision {
        guard lastHostTime.map({ hostTime >= $0 }) ?? true else {
            return .keepCurrent
        }
        if lastHostTime == nil {
            lastHostTime = hostTime
            return .keepCurrent
        }
        defer { lastHostTime = hostTime }
        guard let epochTime,
              let epochHostTime = self.epochHostTime,
              let chunkStart = nextChunkStartTime,
              let segmentStartTime,
              hasOpenFrame,
              let lastFrameEndTime else {
            return .keepCurrent
        }
        let (delta, overflow) = hostTime.subtractingReportingOverflow(epochHostTime)
        guard !overflow, delta <= UInt64(Int64.max) else { return .keepCurrent }
        let projected = CMTimeAdd(
            epochTime,
            CMTime(value: Int64(delta), timescale: CMTimeScale(hostTicksPerSecond))
        )
        guard projected.isValid, projected.isNumeric else { return .keepCurrent }
        let elapsedSegment = CMTimeGetSeconds(CMTimeSubtract(projected, segmentStartTime))
        let elapsedChunk = CMTimeGetSeconds(CMTimeSubtract(projected, chunkStart))
        guard elapsedSegment.isFinite, elapsedChunk.isFinite else { return .keepCurrent }
        let isSegmentBoundary = elapsedSegment >= maximumSegmentDuration
        let isChunkBoundary = elapsedChunk >= checkpointTarget
        guard isSegmentBoundary || isChunkBoundary else { return .keepCurrent }

        let kind: ScreenBoundary.Kind = isSegmentBoundary ? .segment : .chunk
        let maxSegmentEnd = CMTimeAdd(
            segmentStartTime,
            CMTime(seconds: maximumSegmentDuration, preferredTimescale: 1_000_000)
        )
        let requestedEnd = kind == .segment ? minTime(projected, maxSegmentEnd) : projected
        let endTime = maxTime(lastFrameEndTime, requestedEnd)
        if kind == .segment {
            let chunkBoundary = makeBoundary(kind: .chunk, endFrameIndex: lastFrameIndex + 1, endTime: endTime)
            record(chunkBoundary)
        }
        let boundary = makeBoundary(kind: kind, endFrameIndex: lastFrameIndex + 1, endTime: endTime)
        record(boundary)
        advance(after: boundary)
        if kind == .segment {
            self.segmentStartTime = endTime
            segmentStartFrame = boundary.endFrameIndex
            segmentFirstFrameIsSync = false
        }
        hasOpenFrame = false
        return kind == .segment ? .closeSegment(boundary) : .closeChunk(boundary)
    }

    /// Returns the ordered table of boundaries observed or ticked so far.
    public func boundaryTable() -> [ScreenBoundary] {
        boundaries
    }

    /// Current visible segment index.
    var currentSegmentIndex: Int { segmentIndex }

    /// Current recovery chunk index within the visible segment.
    var currentChunkIndex: Int { chunkIndex }

    /// Epoch presentation time used to map audio samples onto video boundaries.
    var recordingEpoch: CMTime? { epochTime }

    /// Maps a host tick onto the planner's media timeline after an epoch exists.
    func mediaTime(for hostTime: UInt64) -> CMTime? {
        guard let epochTime, let epochHostTime,
              hostTime >= epochHostTime else { return nil }
        let delta = hostTime - epochHostTime
        guard delta <= UInt64(Int64.max) else { return nil }
        let time = CMTimeAdd(
            epochTime,
            CMTime(value: Int64(delta), timescale: CMTimeScale(hostTicksPerSecond))
        )
        return time.isValid && time.isNumeric ? time : nil
    }

    private func makeBoundary(kind: ScreenBoundary.Kind, endFrameIndex: Int64, endTime: CMTime) -> ScreenBoundary {
        let startsAtSegment = kind == .segment
        return ScreenBoundary(
            kind: kind,
            segmentIndex: segmentIndex,
            chunkIndex: chunkIndex,
            startFrameIndex: startsAtSegment ? segmentStartFrame : nextChunkStartFrame,
            endFrameIndex: max(startsAtSegment ? segmentStartFrame : nextChunkStartFrame, endFrameIndex),
            startTime: (startsAtSegment ? segmentStartTime : nextChunkStartTime) ?? endTime,
            endTime: endTime,
            firstFrameIsSync: startsAtSegment ? segmentFirstFrameIsSync : firstFrameIsSync
        )
    }

    private func record(_ boundary: ScreenBoundary) {
        guard boundary.endTime.isValid,
              CMTimeCompare(boundary.endTime, boundary.startTime) > 0,
              boundary.endFrameIndex > boundary.startFrameIndex else {
            return
        }
        boundaries.append(boundary)
    }

    private func advance(after boundary: ScreenBoundary) {
        nextChunkStartFrame = boundary.endFrameIndex
        nextChunkStartTime = boundary.endTime
        firstFrameIsSync = false
        if boundary.kind == .segment {
            segmentIndex += 1
            chunkIndex = 0
        } else {
            chunkIndex += 1
        }
    }

    private func maxTime(_ lhs: CMTime, _ rhs: CMTime) -> CMTime {
        CMTimeCompare(lhs, rhs) >= 0 ? lhs : rhs
    }

    private func minTime(_ lhs: CMTime, _ rhs: CMTime) -> CMTime {
        CMTimeCompare(lhs, rhs) <= 0 ? lhs : rhs
    }
}
