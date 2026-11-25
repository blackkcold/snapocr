import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

private struct ExportFileManagerBox: @unchecked Sendable {
    let value: FileManager
}

/// Writes one export at a time. Work is detached from the caller's executor so
/// synchronous AVAssetReader calls and bounded PCM processing never run on UI.
public actor RecordingCompositionExporter {
    private let fileManager: ExportFileManagerBox
    private var exportInProgress = false

    public init(fileManager: FileManager = .default) {
        self.fileManager = ExportFileManagerBox(value: fileManager)
    }

    public func export(
        _ plan: ExportPlan,
        progress: @escaping @Sendable (ExportProgress) -> Void
    ) async throws -> ExportResult {
        guard !exportInProgress else { throw ExportError.exportInProgress }
        exportInProgress = true
        defer { exportInProgress = false }

        let fileManager = self.fileManager
        let task = Task.detached(priority: .userInitiated) {
            try await RecordingExportWorker.run(plan, fileManager: fileManager.value, progress: progress)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

enum RecordingExportWorker {
    static func run(
        _ originalPlan: ExportPlan,
        fileManager: FileManager,
        progress callback: @escaping @Sendable (ExportProgress) -> Void
    ) async throws -> ExportResult {
        let progress = ExportProgressThrottle(callback)
        let resources = ExportExecutionResources()
        var transaction: RecordingOutputTransaction?
        progress.emit(0, phase: "revalidating", force: true)

        do {
            let plan = try await revalidateActualMedia(originalPlan)
            try Task.checkCancellation()
            let request = try outputRequest(for: plan)
            let outputTransaction: RecordingOutputTransaction
            do {
                outputTransaction = try RecordingOutputTransaction(request: request, fileManager: fileManager)
            } catch RecordingOutputTransactionError.invalidDestinationDirectory {
                throw ExportError.destinationUnavailable
            } catch {
                throw ExportError.publishFailed(stagingURL: nil)
            }
            transaction = outputTransaction
            let stageURL = outputTransaction.partialURL

            let sourceURLs =
                plan.audioSourcesBySegment.values.flatMap(\.urls)
                + plan.sourceRanges.flatMap(\.sourceFiles)
            let finalPath = canonicalPath(outputTransaction.finalURL)
            guard !sourceURLs.contains(where: { canonicalPath($0) == finalPath }),
                canonicalPath(stageURL) != finalPath
            else { throw ExportError.destinationUnavailable }

            try outputTransaction.prepareForWriting()
            try Task.checkCancellation()
            progress.emit(0.04, phase: "preparing")

            let roles = orderedOutputRoles(plan)
            guard !roles.isEmpty else { throw ExportError.missingSource }
            if plan.videoPassthrough {
                try await exportVideoComposition(
                    plan, outputURL: stageURL, roles: roles,
                    resources: resources, progress: progress
                )
            } else if case .directory = plan.outputSpec.shape {
                try await exportSeparatedAudioDirectory(
                    plan, stagingURL: stageURL, roles: roles,
                    resources: resources, progress: progress
                )
            } else {
                try await exportAudioFile(
                    plan, outputURL: stageURL, roles: roles,
                    resources: resources, progress: progress
                )
            }

            try Task.checkCancellation()
            try outputTransaction.markWriterFinished()
            progress.emit(0.92, phase: "publishing")
            let publishedURL = try outputTransaction.publish()
            let outputFacts = inspectOutput(at: publishedURL, shape: plan.outputSpec.shape, fileManager: fileManager)
            progress.emit(1, phase: "complete", force: true)
            return ExportResult(
                outputURL: publishedURL,
                actualDuration: outputFacts.duration,
                videoPassthrough: plan.videoPassthrough,
                audioOperation: plan.audioOperation,
                trackCount: outputFacts.trackCount
            )
        } catch {
            try throwMappedFailure(
                error,
                transaction: transaction,
                fileManager: fileManager,
                resources: resources
            )
        }
    }

    private static func throwMappedFailure(
        _ error: Error,
        transaction: RecordingOutputTransaction?,
        fileManager: FileManager,
        resources: ExportExecutionResources
    ) throws -> Never {
        resources.cancel()
        guard let transaction else {
            if Task.isCancelled { throw ExportError.cancelled(stagingURL: nil) }
            throw error
        }
        let stageURL = transaction.partialURL
        preserveStage(stageURL, directory: transaction.isDirectoryOutput, fileManager: fileManager)
        if Task.isCancelled || error is CancellationError {
            throw ExportError.cancelled(stagingURL: stageURL)
        }
        if let exportError = error as? ExportError {
            switch exportError {
            case .cancelled:
                throw ExportError.cancelled(stagingURL: stageURL)
            case .exportInProgress, .emptySelection, .overLimit, .incompatibleCodec,
                .missingSource, .destinationUnavailable, .passthroughUnsupported:
                throw ExportError.publishFailed(stagingURL: stageURL)
            case .publishFailed:
                throw ExportError.publishFailed(stagingURL: stageURL)
            }
        }
        throw ExportError.publishFailed(stagingURL: stageURL)
    }
}

struct ExportAudioTrackMetadata {
    let role: RecordingTrackRole
    let range: SampleRange
    let sampleRate: Int
    let channelCount: Int
    let primingFrames: Int
    let remainderFrames: Int
}

final class ExportAudioCursor {
    let url: URL
    let role: RecordingTrackRole
    let range: SampleRange
    let channelCount: Int
    private let file: AVAudioFile
    private let primingFrames: Int64
    private let sampleRate: Int

    init(url: URL, metadata: ExportAudioTrackMetadata, outputSampleRate: Int) throws {
        guard metadata.range.sampleCount > 0, metadata.sampleRate > 0,
            (1...2).contains(metadata.channelCount), metadata.sampleRate == outputSampleRate
        else { throw ExportError.passthroughUnsupported }
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw ExportError.missingSource }
        guard Int(file.processingFormat.sampleRate.rounded()) == metadata.sampleRate,
            Int(file.processingFormat.channelCount) == metadata.channelCount
        else { throw ExportError.missingSource }
        let validFrames = AVAudioFramePosition(metadata.range.sampleCount)
        let priming = AVAudioFramePosition(max(0, metadata.primingFrames))
        let remainder = AVAudioFramePosition(max(0, metadata.remainderFrames))
        let canUsePacketPadding = file.length >= priming + validFrames + remainder
        guard file.length >= validFrames || canUsePacketPadding else { throw ExportError.missingSource }
        self.url = url
        role = metadata.role
        range = metadata.range
        channelCount = metadata.channelCount
        self.file = file
        primingFrames = canUsePacketPadding ? Int64(priming) : 0
        sampleRate = metadata.sampleRate
    }

    func read(_ range: SampleRange) throws -> [[Float]] {
        guard range.startSample >= self.range.startSample,
            range.endSample <= self.range.endSample,
            range.sampleCount > 0
        else { throw ExportError.missingSource }
        let offset = range.startSample - self.range.startSample
        let frameOffset = AVAudioFramePosition(offset * Int64(sampleRate) / 48_000)
        let frameCount = AVAudioFrameCount(range.sampleCount * Int64(sampleRate) / 48_000)
        guard frameCount > 0 else { throw ExportError.missingSource }
        file.framePosition = AVAudioFramePosition(primingFrames) + frameOffset
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            throw ExportError.publishFailed(stagingURL: nil)
        }
        do { try file.read(into: buffer, frameCount: frameCount) } catch { throw ExportError.missingSource }
        guard buffer.frameLength == frameCount else { throw ExportError.missingSource }
        var channels = Array(repeating: Array(repeating: Float.zero, count: Int(frameCount)), count: channelCount)
        if let data = buffer.floatChannelData {
            for channel in 0..<channelCount {
                let stride = buffer.format.isInterleaved ? channelCount : 1
                for frame in 0..<Int(frameCount) {
                    let sourceChannel = buffer.format.isInterleaved ? 0 : channel
                    let sourceFrame = frame * stride + (buffer.format.isInterleaved ? channel : 0)
                    channels[channel][frame] = data[sourceChannel][sourceFrame]
                }
            }
        } else if let data = buffer.int16ChannelData {
            for channel in 0..<channelCount {
                let stride = buffer.format.isInterleaved ? channelCount : 1
                for frame in 0..<Int(frameCount) {
                    let sourceChannel = buffer.format.isInterleaved ? 0 : channel
                    let sourceFrame = frame * stride + (buffer.format.isInterleaved ? channel : 0)
                    let raw = data[sourceChannel][sourceFrame]
                    channels[channel][frame] = Float(raw) / 32_768
                }
            }
        } else {
            throw ExportError.passthroughUnsupported
        }
        return channels
    }
}

final class ExportAudioSink {
    let input: AVAssetWriterInput
    let sampleRate: Int
    let channelCount: Int
    private var outputFrame: Int64 = 0

    init(input: AVAssetWriterInput, sampleRate: Int, channelCount: Int) {
        self.input = input
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    func append(_ buffer: AVAudioPCMBuffer, presentationSample: Int64) async throws {
        guard presentationSample == outputFrame, Int(buffer.format.sampleRate.rounded()) == sampleRate,
            Int(buffer.format.channelCount) == channelCount
        else { throw ExportError.passthroughUnsupported }
        guard let data = try makeSampleBuffer(from: buffer, presentationSample: presentationSample) else {
            throw ExportError.passthroughUnsupported
        }
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            await Task.yield()
        }
        guard input.append(data) else { throw ExportError.publishFailed(stagingURL: nil) }
        outputFrame += Int64(buffer.frameLength)
    }

    private func makeSampleBuffer(from buffer: AVAudioPCMBuffer, presentationSample: Int64) throws -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: CMTime(value: presentationSample, timescale: CMTimeScale(sampleRate)),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil,
            formatDescription: buffer.format.formatDescription,
            sampleCount: CMItemCount(buffer.frameLength), sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { return nil }
        let dataStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, bufferList: buffer.audioBufferList
        )
        guard dataStatus == noErr, CMSampleBufferSetDataReady(sampleBuffer) == noErr else { return nil }
        return sampleBuffer
    }
}

final class ExportAssetWriter {
    let writer: AVAssetWriter
    let videoInput: AVAssetWriterInput?
    let videoFormatDescription: CMFormatDescription?
    let audioSinks: [RecordingTrackRole: ExportAudioSink]
    private let inputs: [AVAssetWriterInput]

    private init(
        writer: AVAssetWriter,
        videoInput: AVAssetWriterInput?,
        videoFormatDescription: CMFormatDescription?,
        audioSinks: [RecordingTrackRole: ExportAudioSink],
        inputs: [AVAssetWriterInput]
    ) {
        self.writer = writer
        self.videoInput = videoInput
        self.videoFormatDescription = videoFormatDescription
        self.audioSinks = audioSinks
        self.inputs = inputs
    }

    private struct Input {
        let url: URL
        let type: AVFileType
        let sourceVideo: CMFormatDescription?
        let transform: CGAffineTransform
        let sampleRate: Int
        let channelsByRole: [RecordingTrackRole: Int]
    }

    static func audioFile(
        at url: URL,
        sampleRate: Int,
        channelsByRole: [RecordingTrackRole: Int]
    ) throws -> ExportAssetWriter {
        try make(
            Input(
                url: url, type: .m4a, sourceVideo: nil, transform: .identity,
                sampleRate: sampleRate, channelsByRole: channelsByRole
            ))
    }

    static func videoFile(
        at url: URL,
        sourceFormatHint: CMFormatDescription,
        transform: CGAffineTransform,
        sampleRate: Int,
        channelsByRole: [RecordingTrackRole: Int]
    ) throws -> ExportAssetWriter {
        try make(
            Input(
                url: url, type: .mp4, sourceVideo: sourceFormatHint, transform: transform,
                sampleRate: sampleRate, channelsByRole: channelsByRole
            ))
    }

    private static func make(_ input: Input) throws -> ExportAssetWriter {
        let url = input.url
        let type = input.type
        let sourceVideo = input.sourceVideo
        let transform = input.transform
        let sampleRate = input.sampleRate
        let channelsByRole = input.channelsByRole
        guard (8_000...192_000).contains(sampleRate), !channelsByRole.isEmpty else {
            throw ExportError.passthroughUnsupported
        }
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: type)
        } catch {
            throw ExportError.publishFailed(stagingURL: url)
        }
        var inputs: [AVAssetWriterInput] = []
        var videoInput: AVAssetWriterInput?
        if let sourceVideo {
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: sourceVideo)
            input.expectsMediaDataInRealTime = false
            input.transform = transform
            guard writer.canAdd(input) else { throw ExportError.passthroughUnsupported }
            writer.add(input)
            inputs.append(input)
            videoInput = input
        }
        var audioSinks: [RecordingTrackRole: ExportAudioSink] = [:]
        for (role, channels) in channelsByRole.sorted(by: { roleIndex($0.key) < roleIndex($1.key) }) {
            guard (1...2).contains(channels) else { throw ExportError.passthroughUnsupported }
            let bitrate = channels == 1 ? 96_000 : 160_000
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: bitrate,
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw ExportError.passthroughUnsupported }
            writer.add(input)
            inputs.append(input)
            audioSinks[role] = ExportAudioSink(input: input, sampleRate: sampleRate, channelCount: channels)
        }
        return ExportAssetWriter(
            writer: writer, videoInput: videoInput, videoFormatDescription: sourceVideo,
            audioSinks: audioSinks, inputs: inputs
        )
    }

    func start() throws {
        guard writer.startWriting() else { throw ExportError.publishFailed(stagingURL: writer.outputURL) }
        writer.startSession(atSourceTime: .zero)
    }

    func finish() async {
        for input in inputs { input.markAsFinished() }
        await writer.finishWriting()
    }

    private static func roleIndex(_ role: RecordingTrackRole) -> Int {
        switch role {
        case .mixed: 0
        case .system: 1
        case .microphone: 2
        }
    }
}

final class ExportExecutionResources {
    private var readers: [AVAssetReader] = []
    private var writers: [AVAssetWriter] = []

    func add(_ reader: AVAssetReader) { readers.append(reader) }
    func remove(_ reader: AVAssetReader) { readers.removeAll { $0 === reader } }
    func add(_ writer: AVAssetWriter) { writers.append(writer) }

    func cancel() {
        for reader in readers where reader.status == .reading { reader.cancelReading() }
        for writer in writers where writer.status == .writing || writer.status == .unknown {
            writer.cancelWriting()
        }
    }
}

struct ExportVideoSource {
    let url: URL
    let asset: AVURLAsset
    let track: AVAssetTrack
    let formatDescription: CMFormatDescription
}

final class ExportProgressThrottle {
    private let lock = NSLock()
    private let callback: @Sendable (ExportProgress) -> Void
    private var lastEmitNanos: UInt64 = 0

    init(_ callback: @escaping @Sendable (ExportProgress) -> Void) {
        self.callback = callback
    }

    func emit(_ fraction: Double, phase: String, force: Bool = false) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        defer { lock.unlock() }
        _ = force
        guard lastEmitNanos == 0 || now - lastEmitNanos >= 250_000_000 else { return }
        lastEmitNanos = now
        callback(ExportProgress(fraction: min(1, max(0, fraction)), phase: phase))
    }
}

private extension SampleRange {
    var endSample: Int64 { startSample + sampleCount }
}
