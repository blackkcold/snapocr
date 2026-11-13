import CoreMedia
import Foundation
import Testing

@testable import CaptureCore

struct AudioSampleClockTests {
    @Test func oneGigahertzClockMapsTenMillisecondsTo480Samples() {
        let clock = AudioSampleClock(
            epochHostTime: 5_000_000,
            hostTicksPerSecond: 1_000_000_000,
            sampleRate: 48_000
        )

        #expect(clock.sampleIndex(forHostTime: 15_000_000) == 480)
    }

    @Test func twentyFourMegahertzTimebaseMaps240000TicksTo480Samples() {
        let clock = AudioSampleClock(
            epochHostTime: 5_000_000,
            hostTicksPerSecond: 24_000_000,
            sampleRate: 48_000
        )

        #expect(clock.sampleIndex(forHostTime: 5_240_000) == 480)
    }

    @Test func preEpochHostTimeProducesNegativeSamples() {
        let clock = AudioSampleClock(
            epochHostTime: 5_000_000_000,
            hostTicksPerSecond: 1_000_000_000,
            sampleRate: 48_000
        )

        #expect(clock.sampleIndex(forHostTime: 4_990_000_000) == -480)
    }

    @Test func largeEpochWithSmallNegativeDeltaStaysCorrect() {
        let epoch = UInt64(Int64.max)
        let clock = AudioSampleClock(
            epochHostTime: epoch,
            hostTicksPerSecond: 1_000_000_000,
            sampleRate: 48_000
        )

        #expect(clock.sampleIndex(forHostTime: epoch - 10_000_000) == -480)
    }

    @Test func eightHourOffsetDoesNotOverflow() {
        let clock = AudioSampleClock(
            epochHostTime: 5_000_000,
            hostTicksPerSecond: 1_000_000_000,
            sampleRate: 48_000
        )
        let hostTime: UInt64 = 5_000_000 + 28_800 * 1_000_000_000

        #expect(clock.sampleIndex(forHostTime: hostTime) == 1_382_400_000)
    }

    @Test func hostTimeBeyondInt64DeltaReturnsNil() {
        let clock = AudioSampleClock(
            epochHostTime: 5_000_000,
            hostTicksPerSecond: 1_000_000_000,
            sampleRate: 48_000
        )
        let lateEpoch = AudioSampleClock(
            epochHostTime: UInt64(Int64.max) + 100,
            hostTicksPerSecond: 1_000_000_000,
            sampleRate: 48_000
        )

        #expect(clock.sampleIndex(forHostTime: UInt64.max) == nil)
        #expect(lateEpoch.sampleIndex(forHostTime: 0) == nil)
    }

    @Test func sampleIndexMultiplicationOverflowReturnsNil() {
        let coarseTimebase = AudioSampleClock(
            epochHostTime: 0,
            hostTicksPerSecond: 1,
            sampleRate: 48_000
        )
        let wideTimebase = AudioSampleClock(
            epochHostTime: 0,
            hostTicksPerSecond: 1_000_000_000_000_000_000,
            sampleRate: 48_000
        )

        #expect(coarseTimebase.sampleIndex(forHostTime: UInt64(Int64.max)) == nil)
        #expect(wideTimebase.sampleIndex(forHostTime: 1_000_000_000_000_000) == nil)
    }

    @Test func hostTimeForNegativeSampleReturnsNil() {
        let clock = AudioSampleClock(
            epochHostTime: 5_000_000,
            hostTicksPerSecond: 1_000_000_000,
            sampleRate: 48_000
        )

        #expect(clock.hostTime(forSample: -1) == nil)
        #expect(clock.hostTime(forSample: Int64.min) == nil)
    }

    @Test func sampleBeyondRepresentableHostTimeReturnsNil() {
        let clock = AudioSampleClock(
            epochHostTime: 5_000_000,
            hostTicksPerSecond: 1_000_000_000,
            sampleRate: 48_000
        )
        let lateEpoch = AudioSampleClock(
            epochHostTime: UInt64.max - 100,
            hostTicksPerSecond: 1_000_000_000,
            sampleRate: 48_000
        )

        #expect(clock.hostTime(forSample: Int64.max) == nil)
        #expect(lateEpoch.hostTime(forSample: 48_000) == nil)
    }

    @Test func sampleHostRoundTripIsStableOnRepresentableGrid() throws {
        let clock = AudioSampleClock(
            epochHostTime: 5_000_000,
            hostTicksPerSecond: 1_000_000_000,
            sampleRate: 48_000
        )
        let samples: [Int64] = [0, 1, 2, 479, 480, 481, 48_000, 169_920_000, 1_382_400_000]

        for sample in samples {
            let hostTime = try #require(clock.hostTime(forSample: sample))
            #expect(clock.sampleIndex(forHostTime: hostTime) == sample)
        }
    }

    @Test func nonDivisibleSampleRateRoundTrips() throws {
        let clock = AudioSampleClock(
            epochHostTime: 0,
            hostTicksPerSecond: 1_000_000_000,
            sampleRate: 44_100
        )

        for sample in [0, 1, 441, 44_100, 1_000_000] as [Int64] {
            let hostTime = try #require(clock.hostTime(forSample: sample))
            #expect(clock.sampleIndex(forHostTime: hostTime) == sample)
        }
    }

    @Test func hostTimeForSampleLandsWithinOneTickAboveExactGridPoint() throws {
        let epoch: UInt64 = 5_000_000
        let ticksPerSecond: Int64 = 1_000_000_000
        let sampleRate: Int64 = 48_000
        let clock = AudioSampleClock(
            epochHostTime: epoch,
            hostTicksPerSecond: UInt64(ticksPerSecond),
            sampleRate: Int(sampleRate)
        )

        for sample in [1, 481, 48_000, 169_920_000] as [Int64] {
            let hostTime = try #require(clock.hostTime(forSample: sample))
            let delta = Int64(hostTime - epoch)
            let numerator = sample * ticksPerSecond

            #expect(delta * sampleRate >= numerator)
            #expect(delta * sampleRate < numerator + sampleRate)
        }
    }

    @Test func arbitraryHostTimesQuantizeWithinOneSample() {
        let epoch: UInt64 = 5_000_000_000
        let clock = AudioSampleClock(
            epochHostTime: epoch,
            hostTicksPerSecond: 1_000_000_000,
            sampleRate: 48_000
        )
        let cases: [(offset: Int64, expected: Int64)] = [
            (1, 0),
            (20_833, 0),
            (20_834, 1),
            (500_000_000, 24_000),
            (10_000_001, 480),
            (-20_833, 0),
            (-20_834, -1),
            (-10_000_001, -480),
            (-480_000_000, -23_040),
        ]

        for item in cases {
            let hostTime = UInt64(Int64(epoch) + item.offset)
            let exact = Double(item.offset) * 48_000.0 / 1_000_000_000.0

            #expect(clock.sampleIndex(forHostTime: hostTime) == item.expected)
            #expect(abs(Double(item.expected) - exact) < 1.0)
        }
    }

    @Test func timeUsesIntegerSampleTimescale() {
        let clock = AudioSampleClock(
            epochHostTime: 5_000_000,
            hostTicksPerSecond: 1_000_000_000,
            sampleRate: 48_000
        )

        let time = clock.time(forSample: 480)
        #expect(time.isValid)
        #expect(time.value == 480)
        #expect(time.timescale == 48_000)

        let preEpochTime = clock.time(forSample: -480)
        #expect(preEpochTime.isValid)
        #expect(preEpochTime.value == -480)
        #expect(preEpochTime.timescale == 48_000)
    }

    @Test func invalidTimebaseOrSampleRateReturnsNilOrInvalidTime() {
        let invalidClocks = [
            AudioSampleClock(epochHostTime: 0, hostTicksPerSecond: 0, sampleRate: 48_000),
            AudioSampleClock(epochHostTime: 0, hostTicksPerSecond: 1_000_000_000, sampleRate: 0),
            AudioSampleClock(epochHostTime: 0, hostTicksPerSecond: 1_000_000_000, sampleRate: -48_000),
            AudioSampleClock(
                epochHostTime: 0,
                hostTicksPerSecond: 1_000_000_000,
                sampleRate: Int(Int32.max) + 1
            ),
        ]

        for clock in invalidClocks {
            #expect(clock.sampleIndex(forHostTime: 1_000_000) == nil)
            #expect(clock.hostTime(forSample: 0) == nil)
            #expect(!clock.time(forSample: 0).isValid)
        }
    }

    @Test func preEpochShorterThanOneSampleTruncatesToZero() {
        let epoch: UInt64 = 5_000_000_000
        let clock = AudioSampleClock(
            epochHostTime: epoch,
            hostTicksPerSecond: 1_000_000_000,
            sampleRate: 48_000
        )

        #expect(clock.sampleIndex(forHostTime: epoch - 1) == 0)
        #expect(clock.sampleIndex(forHostTime: epoch - 20_833) == 0)
        #expect(clock.sampleIndex(forHostTime: epoch - 20_834) == -1)
    }

    @Test func coarseTimebaseDoesNotGuaranteePerSampleRoundTrip() throws {
        let clock = AudioSampleClock(
            epochHostTime: 10_000,
            hostTicksPerSecond: 24_000,
            sampleRate: 48_000
        )

        let hostTime = try #require(clock.hostTime(forSample: 1))
        #expect(hostTime == 10_001)
        #expect(clock.sampleIndex(forHostTime: hostTime) == 2)
    }
}
