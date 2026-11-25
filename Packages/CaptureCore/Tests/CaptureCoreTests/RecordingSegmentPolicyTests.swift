import Foundation
import Testing

@testable import CaptureCore

struct RecordingSegmentPolicyTests {
    @Test func twoHourRecordingSplitsInto59MinuteSegments() {
        let boundaries = RecordingSegmentPolicy.audioBoundaries(totalSamples: 345_600_000)

        #expect(boundaries.count == 3)
        #expect(boundaries.map(\.index) == [0, 1, 2])
        #expect(boundaries.map(\.startSample) == [0, 169_920_000, 339_840_000])
        #expect(boundaries.map(\.endSample) == [169_920_000, 339_840_000, 345_600_000])
        #expect(boundaries.map { $0.endSample - $0.startSample } == [169_920_000, 169_920_000, 5_760_000])
    }

    @Test func exactMaximumSegmentProducesOneSegment() {
        let boundaries = RecordingSegmentPolicy.audioBoundaries(totalSamples: 169_920_000)

        #expect(boundaries.count == 1)
        #expect(boundaries.first?.startSample == 0)
        #expect(boundaries.first?.endSample == 169_920_000)
    }

    @Test func oneSampleBeyondMaximumProducesTwoSegments() {
        let boundaries = RecordingSegmentPolicy.audioBoundaries(totalSamples: 169_920_001)

        #expect(boundaries.count == 2)
        #expect(boundaries.map(\.startSample) == [0, 169_920_000])
        #expect(boundaries.map(\.endSample) == [169_920_000, 169_920_001])
    }

    @Test func zeroAndNegativeSamplesProduceNoSegments() {
        #expect(RecordingSegmentPolicy.audioBoundaries(totalSamples: 0).isEmpty)
        #expect(RecordingSegmentPolicy.audioBoundaries(totalSamples: -1).isEmpty)
        #expect(RecordingSegmentPolicy.audioBoundaries(totalSamples: Int64.min).isEmpty)
    }

    @Test func boundariesAreContiguousAndConserveSamples() {
        let totals: [Int64] = [
            1,
            169_919_999,
            169_920_000,
            169_920_001,
            339_840_000,
            345_600_000,
            400_000_000,
        ]

        for total in totals {
            let boundaries = RecordingSegmentPolicy.audioBoundaries(totalSamples: total)

            #expect(!boundaries.isEmpty)
            #expect(boundaries.first?.startSample == 0)
            #expect(boundaries.last?.endSample == total)
            #expect(boundaries.enumerated().allSatisfy { $0.element.index == $0.offset })

            for (previous, next) in zip(boundaries, boundaries.dropFirst()) {
                #expect(previous.endSample == next.startSample)
            }

            for boundary in boundaries {
                let count = boundary.endSample - boundary.startSample
                #expect(count > 0)
                #expect(count <= RecordingSegmentPolicy.maximumSegmentSamples)
            }

            let totalCount = boundaries.reduce(Int64.zero) { partial, boundary in
                partial + (boundary.endSample - boundary.startSample)
            }
            #expect(totalCount == total)
        }
    }

    @Test func maximumCheckpointAgeIsFiveMinutes() {
        #expect(RecordingSegmentPolicy.maximumCheckpointAge == 300)
    }
}
