import CoreMedia
import Foundation

/// Maps monotonic host-time ticks to an integer audio sample grid and back.
///
/// The clock never accumulates floating-point seconds. Host-time deltas are
/// split into whole and remainder ticks so every intermediate product is
/// overflow-checked. Invalid timebases or sample rates never trap; conversions
/// return `nil` or `CMTime.invalid` instead.
public struct AudioSampleClock: Sendable {
    private let epochHostTime: UInt64
    private let hostTicksPerSecond: UInt64
    private let sampleRate: Int

    /// Creates a clock anchored at the recording epoch.
    ///
    /// A clock with an invalid timebase or sample rate is constructed without
    /// trapping; its conversions return `nil` or `CMTime.invalid`.
    ///
    /// - Parameters:
    ///   - epochHostTime: Host-time tick that represents sample index zero.
    ///   - hostTicksPerSecond: Host clock ticks per second; must be positive and
    ///     representable as `Int64`.
    ///   - sampleRate: Sample-grid rate in hertz; must be positive and fit `CMTimeScale`.
    public init(epochHostTime: UInt64, hostTicksPerSecond: UInt64, sampleRate: Int) {
        self.epochHostTime = epochHostTime
        self.hostTicksPerSecond = hostTicksPerSecond
        self.sampleRate = sampleRate
    }

    /// Returns the sample-grid index for a host timestamp.
    ///
    /// The elapsed tick delta is converted with truncation toward zero after
    /// splitting it into whole seconds and remainder ticks, so an arbitrary
    /// host timestamp is always within one sample of its exact real position.
    /// A timestamp before the epoch truncates fractional samples toward zero;
    /// it yields `0` until the delta reaches at least one whole sample, and only
    /// then becomes negative. Timestamps before the epoch therefore never
    /// produce a negative zero or a smaller-than-one-sample negative index.
    ///
    /// - Parameter hostTime: Host-time tick to map.
    /// - Returns: The sample index, or `nil` for an invalid clock, a delta whose
    ///   magnitude exceeds `Int64`, or an overflowing intermediate product.
    public func sampleIndex(forHostTime hostTime: UInt64) -> Int64? {
        guard hasValidConfiguration else { return nil }

        let delta: Int64
        if hostTime >= epochHostTime {
            let difference = hostTime - epochHostTime
            guard difference <= UInt64(Int64.max) else { return nil }
            delta = Int64(difference)
        } else {
            let difference = epochHostTime - hostTime
            guard difference <= UInt64(Int64.max) else { return nil }
            delta = -Int64(difference)
        }

        let ticksPerSecond = Int64(hostTicksPerSecond)
        let wholeSeconds = delta / ticksPerSecond
        let remainderTicks = delta % ticksPerSecond
        let sampleRate = Int64(self.sampleRate)

        let (wholeSamples, wholeOverflow) = wholeSeconds.multipliedReportingOverflow(
            by: sampleRate
        )
        guard !wholeOverflow else { return nil }

        let (scaledRemainder, remainderOverflow) = remainderTicks.multipliedReportingOverflow(
            by: sampleRate
        )
        guard !remainderOverflow else { return nil }

        let fractionalSamples = scaledRemainder / ticksPerSecond
        let (index, additionOverflow) = wholeSamples.addingReportingOverflow(fractionalSamples)
        guard !additionOverflow else { return nil }

        return index
    }

    /// Returns the host timestamp for a sample index.
    ///
    /// Conversion uses ceiling division so that mapping a sample to host time
    /// and back through ``sampleIndex(forHostTime:)`` returns the same sample
    /// for every representable index when the host clock is at least as fine as
    /// the sample grid (`hostTicksPerSecond >= sampleRate`). The result lands on
    /// or above the exact grid point and less than one tick beyond it. When the
    /// host clock is coarser than the sample grid, multiple samples share one
    /// tick and per-sample round trips are not guaranteed.
    ///
    /// - Parameter sample: Nonnegative sample-grid index.
    /// - Returns: The host-time tick, or `nil` for a negative sample, an invalid
    ///   clock, or an overflowing intermediate product or sum.
    public func hostTime(forSample sample: Int64) -> UInt64? {
        guard hasValidConfiguration, sample >= 0 else { return nil }

        let ticksPerSecond = hostTicksPerSecond
        let sampleRate = UInt64(sampleRate)
        let sampleValue = UInt64(sample)
        let wholeSeconds = sampleValue / sampleRate
        let remainingSamples = sampleValue % sampleRate

        let (wholeTicks, wholeOverflow) = wholeSeconds.multipliedReportingOverflow(
            by: ticksPerSecond
        )
        guard !wholeOverflow else { return nil }

        let (partialNumerator, partialOverflow) = remainingSamples.multipliedReportingOverflow(
            by: ticksPerSecond
        )
        guard !partialOverflow else { return nil }

        let partialTicks = partialNumerator / sampleRate
        let partialRemainder = partialNumerator % sampleRate
        let roundingTicks = partialRemainder == 0 ? UInt64.zero : UInt64(1)
        let (roundedPartialTicks, roundingOverflow) = partialTicks.addingReportingOverflow(
            roundingTicks
        )
        guard !roundingOverflow else { return nil }

        let (delta, deltaOverflow) = wholeTicks.addingReportingOverflow(roundedPartialTicks)
        guard !deltaOverflow else { return nil }

        let (hostTime, hostOverflow) = epochHostTime.addingReportingOverflow(delta)
        guard !hostOverflow else { return nil }

        return hostTime
    }

    /// Returns the presentation timestamp for a sample index.
    ///
    /// Negative indexes are valid and produce negative times before the epoch.
    ///
    /// - Parameter sample: Sample-grid index.
    /// - Returns: A time with `sample` as its value and the clock's sample rate
    ///   as its timescale, or `CMTime.invalid` for an invalid clock.
    public func time(forSample sample: Int64) -> CMTime {
        guard hasValidConfiguration else { return .invalid }
        return CMTime(value: sample, timescale: CMTimeScale(sampleRate))
    }

    private var hasValidConfiguration: Bool {
        hostTicksPerSecond > 0
            && hostTicksPerSecond <= UInt64(Int64.max)
            && sampleRate > 0
            && sampleRate <= Int(Int32.max)
    }
}
