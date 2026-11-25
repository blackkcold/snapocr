import Foundation

/// Pure sample-domain segmentation rules for audio-only recordings.
public enum RecordingSegmentPolicy {
    /// Maximum number of 48 kHz samples in one visible audio segment.
    ///
    /// 169,920,000 samples equal 3,540 seconds and are reserved for audio-only
    /// recordings; video uses real frame boundaries instead.
    public static let maximumSegmentSamples: Int64 = 169_920_000

    /// Maximum age of a durable checkpoint, in seconds.
    public static let maximumCheckpointAge: TimeInterval = 300

    /// Returns contiguous segment boundaries covering `totalSamples`.
    ///
    /// Segment indexes start at zero. Zero or negative totals produce no
    /// boundaries, and every returned segment contains at least one sample.
    ///
    /// - Parameter totalSamples: Total valid samples in the audio recording.
    /// - Returns: Contiguous, non-overlapping boundaries whose sample counts sum
    ///   to `totalSamples`.
    public static func audioBoundaries(totalSamples: Int64) -> [SegmentBoundary] {
        guard totalSamples > 0 else { return [] }

        var boundaries: [SegmentBoundary] = []
        var startSample: Int64 = 0
        var index = 0

        while startSample < totalSamples {
            let remainingSamples = totalSamples - startSample
            let sampleCount = min(maximumSegmentSamples, remainingSamples)
            let endSample = startSample + sampleCount
            boundaries.append(
                SegmentBoundary(index: index, startSample: startSample, endSample: endSample)
            )
            startSample = endSample
            index += 1
        }

        return boundaries
    }
}
