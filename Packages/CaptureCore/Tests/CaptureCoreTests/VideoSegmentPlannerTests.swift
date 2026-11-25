import CoreMedia
import Testing

@testable import CaptureCore

struct VideoSegmentPlannerTests {
    @Test func plannerUsesObservedFrameTableInsteadOfFixedFrameCount() throws {
        let planner = try VideoSegmentPlanner(
            maximumSegmentDuration: 4,
            checkpointTarget: 1,
            frameRate: 30,
            hostTicksPerSecond: 1_000
        )

        #expect(planner.append(frame(0, time: 0)) == .keepCurrent)
        #expect(planner.append(frame(1, time: 0.5)) == .keepCurrent)
        let decision = planner.append(frame(2, time: 1.5))

        guard case .cachedChunkBoundary(let boundary) = decision else {
            Issue.record("Expected the observed 1.5-second frame to close a recovery chunk.")
            return
        }
        #expect(boundary.kind == .chunk)
        #expect(boundary.startFrameIndex == 0)
        #expect(boundary.endFrameIndex == 2)
        #expect(CMTimeGetSeconds(boundary.endTime) == 1.5)
    }

    @Test func monotonicTickClosesStaticChunkWithoutAnotherFrame() throws {
        let planner = try VideoSegmentPlanner(
            maximumSegmentDuration: 4,
            checkpointTarget: 1,
            frameRate: 30,
            hostTicksPerSecond: 1_000
        )
        #expect(planner.tick(hostTime: 10_000) == .keepCurrent)
        #expect(planner.append(frame(0, time: 0)) == .keepCurrent)

        let decision = planner.tick(hostTime: 11_000)
        guard case .closeChunk(let boundary) = decision else {
            Issue.record("Expected the monotonic tick to rotate a static source.")
            return
        }
        #expect(boundary.endFrameIndex == 1)
        #expect(CMTimeGetSeconds(boundary.endTime) == 1)
    }

    @Test func invalidDurationOrFrameRateFailsClosed() {
        #expect(throws: VideoSegmentPlannerError.self) {
            try VideoSegmentPlanner(maximumSegmentDuration: .infinity, frameRate: 30)
        }
        #expect(throws: VideoSegmentPlannerError.self) {
            try VideoSegmentPlanner(checkpointTarget: 301, frameRate: 30)
        }
        #expect(throws: VideoSegmentPlannerError.self) {
            try VideoSegmentPlanner(frameRate: 0)
        }
    }

    @Test func chunkBoundaryTargetsThreeHundredSecondsAndClosesBeforeIncomingFrame() throws {
        let planner = try VideoSegmentPlanner(frameRate: 1, hostTicksPerSecond: 1)
        #expect(planner.append(frame(0, time: 0, duration: CMTime(value: 1, timescale: 1))) == .keepCurrent)

        let decision = planner.append(frame(1, time: 300, duration: CMTime(value: 1, timescale: 1)))
        guard case .cachedChunkBoundary(let boundary) = decision else {
            Issue.record("Expected the sync frame at 300 seconds to close the preceding chunk.")
            return
        }
        #expect(boundary.kind == .chunk)
        #expect(boundary.firstFrameIsSync)
        #expect(boundary.endFrameIndex == 1)
        #expect(CMTimeGetSeconds(boundary.endTime) == 300)
    }

    @Test func segmentBoundaryStaysWithinMaximumAndOneFrameOfSyncAlignment() throws {
        let planner = try VideoSegmentPlanner(frameRate: 1, hostTicksPerSecond: 1)
        for index in 0..<3_540 {
            let decision = planner.append(
                frame(Int64(index), time: Double(index), duration: CMTime(value: 1, timescale: 1))
            )
            if index == 0 {
                #expect(decision == .keepCurrent)
            }
        }

        let decision = planner.append(
            frame(3_540, time: 3_540, duration: CMTime(value: 1, timescale: 1))
        )
        guard case .closeSegment(let boundary) = decision else {
            Issue.record("Expected the visible segment to close at its 3,540-second limit.")
            return
        }
        let duration = CMTimeGetSeconds(CMTimeSubtract(boundary.endTime, boundary.startTime))
        #expect(duration <= 3_540)
        #expect(duration >= 3_539)
        #expect(boundary.firstFrameIsSync)
    }

    @Test func nonSyncBoundaryWaitsForSyncFrameAndPreservesObservedTime() throws {
        let planner = try VideoSegmentPlanner(
            maximumSegmentDuration: 4,
            checkpointTarget: 1,
            frameRate: 30,
            hostTicksPerSecond: 1_000
        )
        #expect(planner.append(frame(0, time: 0)) == .keepCurrent)
        #expect(planner.append(frame(1, time: 1.1, isSync: false)) == .keepCurrent)

        let decision = planner.append(frame(2, time: 1.2))
        guard case .cachedChunkBoundary(let boundary) = decision else {
            Issue.record("Expected the next sync frame to close the overdue chunk.")
            return
        }
        #expect(boundary.firstFrameIsSync)
        #expect(boundary.endFrameIndex == 2)
        #expect(CMTimeGetSeconds(boundary.endTime) == 1.2)
    }

    @Test func droppedFrameIndexesDoNotShiftObservedBoundaryTime() throws {
        let planner = try VideoSegmentPlanner(
            maximumSegmentDuration: 4,
            checkpointTarget: 1,
            frameRate: 30,
            hostTicksPerSecond: 1_000
        )
        #expect(planner.append(frame(0, time: 0)) == .keepCurrent)

        let decision = planner.append(frame(5, time: 1.25))
        guard case .cachedChunkBoundary(let boundary) = decision else {
            Issue.record("Expected the actual 1.25-second frame timestamp to trigger the chunk.")
            return
        }
        #expect(boundary.endFrameIndex == 5)
        #expect(CMTimeGetSeconds(boundary.endTime) == 1.25)
    }

    private func frame(
        _ index: Int64,
        time: Double,
        isSync: Bool = true,
        duration: CMTime? = nil
    ) -> VideoFrameSample {
        VideoFrameSample(
            index: index,
            presentationTime: CMTime(seconds: time, preferredTimescale: 1_000),
            decodeTime: .invalid,
            duration: duration ?? CMTime(value: 1, timescale: 30),
            isSync: isSync
        )
    }
}
