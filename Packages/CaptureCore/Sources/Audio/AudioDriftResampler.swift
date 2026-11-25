import Foundation

/// One batch of session-rate audio produced by ``AudioDriftResampler``.
public struct ResampleBatch: Sendable {
    /// Full 48 kHz blocks; every block has `outputSampleRate` frames except a final short block.
    public let blocks: [AudioPCMBlock]
    /// Current bounded drift correction in parts per million.
    public let correctionPPM: Double
    /// Buffered input duration measured from the next output position.
    public let watermarkSeconds: Double
    /// Real input frames accepted from the processed block.
    public let consumedFrames: Int
    /// Missing input frames inserted as silence before the processed block.
    public let gapFrames: Int
    /// Missing frames expressed on the fixed 48 kHz session grid.
    public let sessionGapFrames: Int

    /// Creates a resample batch.
    ///
    /// - Parameters:
    ///   - blocks: Produced session-rate blocks.
    ///   - correctionPPM: Current bounded drift correction.
    ///   - watermarkSeconds: Buffered input duration at the next output position.
    ///   - consumedFrames: Real input frames accepted from the processed block.
    ///   - gapFrames: Missing input frames inserted as silence.
    ///   - sessionGapFrames: Missing frames on the 48 kHz session grid.
    public init(
        blocks: [AudioPCMBlock],
        correctionPPM: Double,
        watermarkSeconds: Double,
        consumedFrames: Int,
        gapFrames: Int,
        sessionGapFrames: Int = 0
    ) {
        self.blocks = blocks
        self.correctionPPM = correctionPPM
        self.watermarkSeconds = watermarkSeconds
        self.consumedFrames = consumedFrames
        self.gapFrames = gapFrames
        self.sessionGapFrames = sessionGapFrames
    }
}

/// A validation or lifecycle failure while resampling one source.
public enum AudioResampleError: Error, Equatable {
    /// The sample rates, watermark, or correction bound cannot be used.
    case invalidConfiguration
    /// The input block was produced at a different sample rate.
    case incompatibleSampleRate
    /// The input block has an unsupported channel layout.
    case incompatibleChannelCount
    /// The input block has no frames or inconsistent channel storage.
    case invalidFrameCount
    /// The source was already flushed and cannot accept more input.
    case alreadyFlushed
}

/// Converts one native source stream to the fixed 48 kHz session grid with bounded drift correction.
///
/// Every source owns one instance. Input is copied into an owned FIFO; no borrowed
/// pointer survives a call. Fractional positions use linear interpolation and a
/// phase accumulator, so ratio changes never discard samples. Source-frame range
/// jumps are materialized as equal-length silence before the next block.
public final class AudioDriftResampler: @unchecked Sendable {
    private let inputSampleRate: Int
    private let outputSampleRate: Int
    private let targetWatermarkSeconds: Double
    private let maxCorrectionPPM: Double
    private let baseStep: Double
    private let configurationIsValid: Bool
    private let lock = NSLock()

    private var correctionPPM = 0.0
    private var smoothedWatermarkSeconds: Double
    private var pendingChannels: [[Float]] = []
    private var pendingStartFrame: Int64 = 0
    private var expectedInputFrame: Int64?
    private var readPosition = 0.0
    private var nextOutputStart: Int64 = 0
    private var hasInput = false
    private var flushed = false
    private var currentRole: RecordingTrackRole = .mixed
    private var gapCarryNumerator: Int64 = 0

    /// Creates a resampler for one source generation.
    ///
    /// - Parameters:
    ///   - inputSampleRate: Native source rate in hertz.
    ///   - outputSampleRate: Session output rate in hertz; defaults to 48 kHz.
    ///   - targetWatermarkSeconds: Buffered input duration used by drift correction.
    ///   - maxCorrectionPPM: Absolute correction bound in parts per million.
    public init(
        inputSampleRate: Int,
        outputSampleRate: Int = 48_000,
        targetWatermarkSeconds: Double,
        maxCorrectionPPM: Int
    ) {
        self.inputSampleRate = inputSampleRate
        self.outputSampleRate = outputSampleRate
        self.targetWatermarkSeconds = targetWatermarkSeconds
        self.maxCorrectionPPM = Double(max(0, maxCorrectionPPM))
        self.baseStep = Double(inputSampleRate) / Double(max(1, outputSampleRate))
        self.smoothedWatermarkSeconds = targetWatermarkSeconds
        self.configurationIsValid =
            inputSampleRate > 0
            && inputSampleRate <= 768_000
            && outputSampleRate > 0
            && outputSampleRate <= 768_000
            && targetWatermarkSeconds.isFinite
            && targetWatermarkSeconds >= 0
            && maxCorrectionPPM >= 0
    }

    /// Appends one native block and returns every complete output block that can be rendered.
    ///
    /// - Parameter block: Owned native-rate block.
    /// - Returns: Complete output blocks plus correction and watermark diagnostics.
    /// - Throws: ``AudioResampleError`` when the block does not match this resampler.
    public func process(_ block: AudioPCMBlock) throws -> ResampleBatch {
        lock.lock()
        defer { lock.unlock() }
        try ensureReady()
        try validate(block)
        currentRole = block.role
        let split = splitLeadingOverlap(block)
        let sessionGap = sessionGapFramesLocked(inputFrames: split.gapFrames)
        if split.gapFrames > 0 {
            appendSilence(split.gapFrames)
        }
        if split.block.frameCount > 0 {
            if !hasInput {
                hasInput = true
                pendingStartFrame = split.block.range.startSample
            }
            append(split.block)
        }
        expectedInputFrame = split.block.range.startSample + Int64(split.block.frameCount)
        updateCorrection(elapsedSeconds: Double(split.block.frameCount) / Double(inputSampleRate))
        let blocks = renderFullBlocks()
        compact()
        return ResampleBatch(
            blocks: blocks,
            correctionPPM: correctionPPM,
            watermarkSeconds: watermarkSeconds,
            consumedFrames: split.block.frameCount,
            gapFrames: split.gapFrames,
            sessionGapFrames: sessionGap
        )
    }

    /// Emits every remaining input frame as a final short block.
    ///
    /// - Returns: Remaining output blocks at the fixed 48 kHz grid.
    /// - Throws: ``AudioResampleError/alreadyFlushed`` when called twice.
    public func flush() throws -> ResampleBatch {
        lock.lock()
        defer { lock.unlock() }
        guard !flushed else {
            throw AudioResampleError.alreadyFlushed
        }
        flushed = true
        guard hasInput, let pendingCount = pendingChannels.first?.count, readPosition < Double(pendingCount)
        else {
            return ResampleBatch(
                blocks: [],
                correctionPPM: correctionPPM,
                watermarkSeconds: 0,
                consumedFrames: 0,
                gapFrames: 0
            )
        }
        let step = currentStep
        var blocks: [AudioPCMBlock] = []
        while readPosition < Double(pendingCount) - 0.5 {
            let remaining = Double(pendingCount) - readPosition
            let frames = min(480, max(1, Int((remaining / step).rounded())))
            blocks.append(renderBlock(frameCount: frames, step: step))
            readPosition += Double(frames) * step
        }
        compact()
        return ResampleBatch(
            blocks: blocks,
            correctionPPM: correctionPPM,
            watermarkSeconds: watermarkSeconds,
            consumedFrames: 0,
            gapFrames: 0
        )
    }
}

extension AudioDriftResampler {
    private struct SplitBlock {
        let block: AudioPCMBlock
        let gapFrames: Int
    }

    private func ensureReady() throws {
        guard configurationIsValid else {
            throw AudioResampleError.invalidConfiguration
        }
        guard !flushed else {
            throw AudioResampleError.alreadyFlushed
        }
    }

    private func validate(_ block: AudioPCMBlock) throws {
        guard block.sampleRate == inputSampleRate else {
            throw AudioResampleError.incompatibleSampleRate
        }
        guard block.channelCount == 1 || block.channelCount == 2,
            block.channels.count == block.channelCount
        else {
            throw AudioResampleError.incompatibleChannelCount
        }
        guard block.frameCount > 0,
            block.channels.allSatisfy({ $0.count == block.frameCount }),
            block.range.sampleCount == Int64(block.frameCount)
        else {
            throw AudioResampleError.invalidFrameCount
        }
    }

    private func splitLeadingOverlap(_ block: AudioPCMBlock) -> SplitBlock {
        guard let expected = expectedInputFrame else {
            return SplitBlock(block: block, gapFrames: 0)
        }
        let delta = block.range.startSample - expected
        if delta > 0 {
            guard delta <= Int64(Int.max) else {
                return SplitBlock(block: emptyBlock(from: block, frames: 0), gapFrames: 0)
            }
            return SplitBlock(block: block, gapFrames: Int(delta))
        }
        guard delta < 0 else {
            return SplitBlock(block: block, gapFrames: 0)
        }
        let overlap = Int(min(-delta, Int64(block.frameCount)))
        let remaining = block.frameCount - overlap
        guard remaining > 0 else {
            return SplitBlock(block: emptyBlock(from: block, frames: 0), gapFrames: 0)
        }
        let channels = block.channels.map { Array($0.dropFirst(overlap)) }
        let trimmed = AudioPCMBlock(
            role: block.role,
            range: SampleRange(
                startSample: block.range.startSample + Int64(overlap),
                sampleCount: Int64(remaining)
            ),
            sampleRate: block.sampleRate,
            channelCount: block.channelCount,
            frameCount: remaining,
            hostTime: block.hostTime,
            channels: channels,
            isSilence: channels.allSatisfy { $0.allSatisfy { $0 == 0 } }
        )
        return SplitBlock(block: trimmed, gapFrames: 0)
    }

    private func emptyBlock(from block: AudioPCMBlock, frames: Int) -> AudioPCMBlock {
        AudioPCMBlock(
            role: block.role,
            range: SampleRange(
                startSample: block.range.startSample + Int64(block.frameCount),
                sampleCount: Int64(frames)
            ),
            sampleRate: block.sampleRate,
            channelCount: block.channelCount,
            frameCount: frames,
            hostTime: block.hostTime,
            channels: block.channels.map { _ in [] },
            isSilence: true
        )
    }

    private func append(_ block: AudioPCMBlock) {
        if pendingChannels.isEmpty {
            pendingChannels = Array(repeating: [], count: block.channelCount)
        }
        for channel in 0..<block.channelCount {
            pendingChannels[channel].append(contentsOf: block.channels[channel])
        }
    }

    private func appendSilence(_ frames: Int) {
        guard frames > 0, !pendingChannels.isEmpty else {
            return
        }
        for channel in pendingChannels.indices {
            pendingChannels[channel].append(contentsOf: repeatElement(0, count: frames))
        }
    }

    private func updateCorrection(elapsedSeconds: Double) {
        guard maxCorrectionPPM > 0 else {
            correctionPPM = 0
            return
        }
        let current = watermarkSeconds
        smoothedWatermarkSeconds += (current - smoothedWatermarkSeconds) * 0.1
        let denominator = max(targetWatermarkSeconds, 0.001)
        let target = clamped(
            (smoothedWatermarkSeconds - targetWatermarkSeconds) / denominator * maxCorrectionPPM,
            limit: maxCorrectionPPM
        )
        let elapsed = max(elapsedSeconds, 1 / Double(inputSampleRate))
        let maxStep = maxCorrectionPPM * elapsed / 2
        correctionPPM += clamped(target - correctionPPM, limit: maxStep)
        correctionPPM = clamped(correctionPPM, limit: maxCorrectionPPM)
    }

    private func sessionGapFramesLocked(inputFrames: Int) -> Int {
        guard inputFrames > 0 else {
            return 0
        }
        let scaled = Int64(inputFrames) * Int64(outputSampleRate) + gapCarryNumerator
        let sessionFrames = scaled / Int64(inputSampleRate)
        gapCarryNumerator = scaled % Int64(inputSampleRate)
        return Int(sessionFrames)
    }

    private var currentStep: Double {
        baseStep / (1 + correctionPPM * 0.000_001)
    }

    private var watermarkSeconds: Double {
        guard let count = pendingChannels.first?.count else {
            return 0
        }
        return max(0, Double(count) - readPosition) / Double(inputSampleRate)
    }

    private func renderFullBlocks() -> [AudioPCMBlock] {
        guard let count = pendingChannels.first?.count else {
            return []
        }
        let step = currentStep
        var blocks: [AudioPCMBlock] = []
        while readPosition + Double(479) * step < Double(count) {
            blocks.append(renderBlock(frameCount: 480, step: step))
            readPosition += 480 * step
        }
        return blocks
    }

    private func renderBlock(frameCount: Int, step: Double) -> AudioPCMBlock {
        let count = pendingChannels.first?.count ?? 0
        var channels = (0..<pendingChannels.count).map { _ in
            [Float](repeating: 0, count: frameCount)
        }
        for frame in 0..<frameCount {
            let position = readPosition + Double(frame) * step
            let lower = min(max(0, Int(position.rounded(.down))), max(0, count - 1))
            let upper = min(lower + 1, max(0, count - 1))
            let fraction = Float(position - Double(lower))
            for channel in pendingChannels.indices {
                let first = pendingChannels[channel][lower]
                let second = pendingChannels[channel][upper]
                channels[channel][frame] = first + (second - first) * fraction
            }
        }
        let isSilence = channels.allSatisfy { $0.allSatisfy { $0 == 0 } }
        let block = AudioPCMBlock(
            role: currentRole,
            range: SampleRange(startSample: nextOutputStart, sampleCount: Int64(frameCount)),
            sampleRate: outputSampleRate,
            channelCount: channels.count,
            frameCount: frameCount,
            hostTime: 0,
            channels: channels,
            isSilence: isSilence
        )
        nextOutputStart += Int64(frameCount)
        return block
    }

    private func compact() {
        guard let count = pendingChannels.first?.count else {
            return
        }
        let discard = min(count, max(0, Int(readPosition.rounded(.down))))
        guard discard > 0 else {
            return
        }
        for channel in pendingChannels.indices {
            pendingChannels[channel].removeFirst(discard)
        }
        pendingStartFrame += Int64(discard)
        readPosition -= Double(discard)
    }

    private func clamped(_ value: Double, limit: Double) -> Double {
        min(limit, max(-limit, value))
    }
}

extension AudioDriftResampler {
    /// Current control-side diagnostics; not required to be one instant.
    internal var diagnosticValues: (correctionPPM: Double, watermarkSeconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        return (correctionPPM, watermarkSeconds)
    }

    /// Converts a terminal missing-input interval into session frames.
    ///
    /// - Parameter inputFrames: Missing source frames at the end of the ring.
    /// - Returns: Missing frames on the fixed 48 kHz session grid.
    internal func sessionGapFrames(forInputFrames inputFrames: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return sessionGapFramesLocked(inputFrames: inputFrames)
    }

    /// Adds terminal source silence after a closed ring reports a final gap.
    ///
    /// - Parameter frames: Missing input frames at the end of the source.
    /// - Returns: Complete output blocks produced by the added silence.
    /// - Throws: ``AudioResampleError`` when the resampler is not ready.
    internal func appendTerminalGap(_ frames: Int) throws -> [AudioPCMBlock] {
        lock.lock()
        defer { lock.unlock() }
        try ensureReady()
        guard frames > 0, hasInput else {
            return []
        }
        appendSilence(frames)
        expectedInputFrame = (expectedInputFrame ?? pendingStartFrame) + Int64(frames)
        let blocks = renderFullBlocks()
        compact()
        return blocks
    }
}
