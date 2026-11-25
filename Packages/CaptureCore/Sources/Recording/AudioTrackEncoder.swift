import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

/// The sealed result of encoding one track role for one segment.
public struct AudioSealResult: Sendable, Hashable {
    /// The role that was encoded.
    public let role: RecordingTrackRole
    /// The encoded m4a written by the encoder.
    public let url: URL
    /// Session-global range covered by the encoded track, including inserted silence.
    public let effectiveRange: SampleRange
    /// Encoder priming frames written into the m4a packet table.
    public let primingFrames: Int
    /// Encoder remainder frames written into the m4a packet table.
    public let remainderFrames: Int
    /// Frames of silence inserted to preserve the segment timeline.
    public let insertedSilenceFrames: Int64
    /// Creates an audio seal result.
    public init(
        role: RecordingTrackRole, url: URL, effectiveRange: SampleRange,
        primingFrames: Int, remainderFrames: Int, insertedSilenceFrames: Int64
    ) {
        self.role = role
        self.url = url
        self.effectiveRange = effectiveRange
        self.primingFrames = primingFrames
        self.remainderFrames = remainderFrames
        self.insertedSilenceFrames = insertedSilenceFrames
    }
}
/// A portable description of one sealed recording segment.
///
/// The record is embedded in a single-file m4a or written as the multi-track
/// directory's `manifest.json`. All ranges are session-global 48 kHz samples.
public struct SegmentPortableRecord: Codable, Sendable, Hashable {
    /// Schema version written by this implementation.
    public static let currentSchemaVersion = 1
    /// Version of the record schema.
    public let schemaVersion: Int
    /// Identity of the recording session.
    public let sessionID: UUID
    /// Identity of the sealed segment.
    public let segmentID: UUID
    /// Zero-based segment index.
    public let segmentIndex: Int
    /// Raw recording kind string: `audio` or `screen`.
    public let kind: String
    /// Raw audio layout string: `mixed` or `separateTracks`.
    public let layout: String
    /// Fixed sample rate of every track in the segment.
    public let sampleRate: Int
    /// Session-global first sample covered by the segment.
    public let startSample: Int64
    /// Number of samples covered by the segment.
    public let sampleCount: Int64
    /// One entry per audio track.
    public let tracks: [Track]
    /// Segment-global ranges that were not captured by any source.
    public let missingRanges: [RecordingSampleRange]
    /// Final screen video URL, or `nil` for audio-only products.
    public let videoURL: URL?
    /// Index of the audio track in a screen MP4, or `nil` for audio-only products.
    public let videoTrackIndex: Int?
    /// One audio track in a portable segment record.
    public struct Track: Codable, Sendable, Hashable {
        /// Raw role string: `mixed`, `system`, or `microphone`.
        public let role: String
        /// Fixed channel count of the track.
        public let channelCount: Int
        /// Published file name relative to the segment directory.
        public let fileName: String
        /// Session-global valid sample range of the track.
        public let validRange: RecordingSampleRange
        /// Encoder priming frames written by the AAC encoder.
        public let primingFrames: Int
        /// Encoder remainder frames written by the AAC encoder.
        public let remainderFrames: Int
        /// Silence frames inserted by the seal layer.
        public let insertedSilenceFrames: Int64
        /// Encoded AAC packet count read from the finished file.
        public let encodedPacketCount: Int
        /// Decoded PCM frame count read back from the finished file.
        public let decodedFrameCount: Int64
        /// Creates a track record.
        public init(
            role: String, channelCount: Int, fileName: String,
            validRange: RecordingSampleRange, primingFrames: Int, remainderFrames: Int,
            insertedSilenceFrames: Int64, encodedPacketCount: Int, decodedFrameCount: Int64
        ) {
            self.role = role
            self.channelCount = channelCount
            self.fileName = fileName
            self.validRange = validRange
            self.primingFrames = primingFrames
            self.remainderFrames = remainderFrames
            self.insertedSilenceFrames = insertedSilenceFrames
            self.encodedPacketCount = encodedPacketCount
            self.decodedFrameCount = decodedFrameCount
        }
    }
    /// Creates a portable segment record.
    public init(
        schemaVersion: Int = SegmentPortableRecord.currentSchemaVersion,
        sessionID: UUID, segmentID: UUID, segmentIndex: Int, kind: String, layout: String,
        sampleRate: Int, startSample: Int64, sampleCount: Int64, tracks: [Track],
        missingRanges: [RecordingSampleRange], videoURL: URL? = nil, videoTrackIndex: Int? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.segmentID = segmentID
        self.segmentIndex = segmentIndex
        self.kind = kind
        self.layout = layout
        self.sampleRate = sampleRate
        self.startSample = startSample
        self.sampleCount = sampleCount
        self.tracks = tracks
        self.missingRanges = missingRanges
        self.videoURL = videoURL
        self.videoTrackIndex = videoTrackIndex
    }
}
/// Reads and writes the Task 8 portable metadata carrier in an m4a.
///
/// This helper owns the T8 metadata format. Task 9's `RecordingPortableMetadata`
/// may delegate to it; T8 does not claim the Task 9 type name.
public enum SegmentPortableMetadata {
    /// Prefix identifying the embedded JSON comment.
    public static let marker = "snapglass.segment.v1:"
    /// Writes a record into a new m4a using a native passthrough remux.
    public static func embed(
        _ record: SegmentPortableRecord, from sourceURL: URL, to destinationURL: URL
    ) async throws {
        guard record.schemaVersion == SegmentPortableRecord.currentSchemaVersion else {
            throw RecordingSealError.metadataInvalid
        }
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw RecordingSealError.metadataDestinationExists
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do { data = try encoder.encode(record) } catch { throw RecordingSealError.metadataInvalid }
        guard let json = String(data: data, encoding: .utf8) else {
            throw RecordingSealError.metadataInvalid
        }
        let item = AVMutableMetadataItem()
        item.keySpace = .quickTimeMetadata
        item.key = AVMetadataKey.quickTimeMetadataKeyComment as NSString
        item.value = (marker + json) as NSString
        let tempURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".SnapGlass-\(UUID().uuidString)-embed.m4a")
        defer { try? fileManager.removeItem(at: tempURL) }
        guard
            let session = AVAssetExportSession(
                asset: AVURLAsset(url: sourceURL), presetName: AVAssetExportPresetPassthrough
            )
        else { throw RecordingSealError.metadataExportFailed }
        session.outputURL = tempURL
        session.outputFileType = .m4a
        session.metadata = [item]
        let box = ExportSessionBox(session)
        await withCheckedContinuation { continuation in
            session.exportAsynchronously { continuation.resume() }
        }
        guard box.session.status == .completed else {
            throw RecordingSealError.metadataExportFailed
        }
        try Task.checkCancellation()
        do { try fileManager.moveItem(at: tempURL, to: destinationURL) } catch {
            throw RecordingSealError.metadataExportFailed
        }
        guard try await read(from: destinationURL) == record else {
            throw RecordingSealError.metadataInvalid
        }
    }
    /// Reads the first Task 8 record embedded in an m4a.
    public static func read(from url: URL) async throws -> SegmentPortableRecord {
        let readURL = try readableURL(for: url)
        defer {
            if readURL != url { try? FileManager.default.removeItem(at: readURL) }
        }
        let items: [AVMetadataItem]
        do { items = try await AVURLAsset(url: readURL).load(.metadata) } catch {
            throw RecordingSealError.metadataMissing
        }
        for item in items {
            guard let value = try? await item.load(.value),
                let string = value as? String, string.hasPrefix(marker)
            else { continue }
            let json = String(string.dropFirst(marker.count))
            guard let data = json.data(using: .utf8) else {
                throw RecordingSealError.metadataInvalid
            }
            let record: SegmentPortableRecord
            do { record = try JSONDecoder().decode(SegmentPortableRecord.self, from: data) } catch {
                throw RecordingSealError.metadataInvalid
            }
            guard record.schemaVersion == SegmentPortableRecord.currentSchemaVersion else {
                throw RecordingSealError.metadataInvalid
            }
            return record
        }
        throw RecordingSealError.metadataMissing
    }
    private static func readableURL(for url: URL) throws -> URL {
        guard url.pathExtension.lowercased() != "m4a" else { return url }
        let alias = url.deletingLastPathComponent()
            .appendingPathComponent(".SnapGlass-\(UUID().uuidString)-read.m4a")
        do { try FileManager.default.linkItem(at: url, to: alias) } catch {
            do { try FileManager.default.copyItem(at: url, to: alias) } catch {
                throw RecordingSealError.metadataMissing
            }
        }
        return alias
    }
}
private final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
}
/// Failures raised while encoding one role's continuous AAC track.
public enum AudioTrackEncoderError: Error, Equatable, Sendable {
    /// The sample rate, channel count, bit rate, or output extension is unsupported.
    case invalidFormat
    /// The segment index is negative.
    case invalidSegmentIndex
    /// A segment must be started before appending or finishing.
    case beginSegmentRequired
    /// The encoder already started its single segment context.
    case segmentAlreadyBegun
    /// A checkpoint belongs to a different segment.
    case segmentIndexMismatch
    /// The checkpoint does not contain this encoder's role.
    case roleNotInCheckpoint
    /// A checkpoint overlaps or moves backward in the segment timeline.
    case rangeOverlap
    /// A checkpoint's source CAF cannot be opened.
    case sourceUnreadable
    /// The source CAF's sample rate or channel count differs from the encoder.
    case sourceFormatMismatch
    /// The source CAF contains fewer frames than the committed checkpoint range.
    case sourceFrameCountMismatch
    /// The asset writer could not start, append, or finish.
    case writerFailed
    /// The finished m4a's packet table or decoded frame count did not match the input.
    case encodingVerificationFailed
    /// The encoder was already finished.
    case finished
    /// No PCM or silence was written before finishing.
    case noAudio
}
/// Internal byte and packet accounting captured while finishing an m4a.
struct AudioEncodingVerification: Sendable, Hashable {
    let validFrameCount: Int64
    let encodedPacketCount: Int
    let decodedFrameCount: Int64
    let primingFrames: Int
    let remainderFrames: Int
}
private struct PacketTableInfo {
    let validFrameCount: Int64
    let packetCount: Int
    let primingFrames: Int
    let remainderFrames: Int
}
/// Encodes one role's checkpoints into a single continuous AAC context.
///
/// The actor opens exactly one `AVAssetWriter` and audio input per segment.
/// Checkpoint boundaries never end the writer session, so encoder priming is
/// paid once per segment and role instead of once per checkpoint.
public actor AudioTrackEncoder {
    private let role: RecordingTrackRole
    private let sampleRate: Int
    private let channelCount: Int
    private let bitRate: Int
    private let outputURL: URL
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var segmentIndex: Int?
    private var nextSample: Int64?
    private var effectiveStartSample: Int64?
    private var writtenFrames: Int64 = 0
    private var insertedSilenceFrames: Int64 = 0
    private var isAppending = false
    private var isFinished = false
    private var failed = false
    private var verificationStorage: AudioEncodingVerification?
    /// Number of encoder contexts started for this track.
    private(set) var contextStartCount = 0
    /// Verification details captured by ``finish()``.
    var verification: AudioEncodingVerification? { verificationStorage }
    /// Creates an encoder for one track role.
    public init(
        role: RecordingTrackRole, sampleRate: Int, channelCount: Int,
        bitRate: Int, outputURL: URL
    ) throws {
        guard outputURL.isFileURL, outputURL.pathExtension.lowercased() == "m4a",
            !outputURL.lastPathComponent.isEmpty,
            (8_000...192_000).contains(sampleRate), (1...2).contains(channelCount),
            (16_000...512_000).contains(bitRate)
        else { throw AudioTrackEncoderError.invalidFormat }
        self.role = role
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitRate = bitRate
        self.outputURL = outputURL
    }
    /// Starts the single AAC context for a segment.
    public func beginSegment(_ segmentIndex: Int) throws {
        guard !isFinished else { throw AudioTrackEncoderError.finished }
        guard self.segmentIndex == nil else { throw AudioTrackEncoderError.segmentAlreadyBegun }
        guard segmentIndex >= 0 else { throw AudioTrackEncoderError.invalidSegmentIndex }
        guard !failed else { throw AudioTrackEncoderError.writerFailed }
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a) } catch {
            failed = true
            throw AudioTrackEncoderError.writerFailed
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderBitRateKey: bitRate,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            failed = true
            throw AudioTrackEncoderError.writerFailed
        }
        writer.add(input)
        guard writer.startWriting() else {
            failed = true
            throw AudioTrackEncoderError.writerFailed
        }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer
        self.input = input
        self.segmentIndex = segmentIndex
        contextStartCount += 1
    }
    /// Appends one committed checkpoint's source frames without restarting the encoder.
    ///
    /// A gap before the checkpoint is filled with silence so later media keeps
    /// its session-global position.
    public func append(_ checkpoint: CheckpointCommit) async throws {
        guard !failed else { throw AudioTrackEncoderError.writerFailed }
        guard !isFinished else { throw AudioTrackEncoderError.finished }
        guard let segmentIndex, writer != nil, input != nil else {
            throw AudioTrackEncoderError.beginSegmentRequired
        }
        guard checkpoint.segmentIndex == segmentIndex else {
            throw AudioTrackEncoderError.segmentIndexMismatch
        }
        guard let trackURL = checkpoint.trackURLs[role] else {
            throw AudioTrackEncoderError.roleNotInCheckpoint
        }
        guard checkpoint.range.sampleCount > 0 else { throw AudioTrackEncoderError.invalidFormat }
        guard !isAppending else { throw AudioTrackEncoderError.writerFailed }
        isAppending = true
        defer { isAppending = false }
        do {
            try await positionBeforeAppending(startSample: checkpoint.range.startSample)
            try await appendPCM(from: trackURL, frameCount: checkpoint.range.sampleCount)
            nextSample = checkpoint.range.startSample + checkpoint.range.sampleCount
        } catch {
            failed = true
            throw error
        }
    }
    /// Appends silence at the current timeline position.
    func appendSilence(frames: Int64) async throws {
        guard frames >= 0 else { throw AudioTrackEncoderError.invalidFormat }
        guard frames > 0 else { return }
        guard !failed else { throw AudioTrackEncoderError.writerFailed }
        guard !isFinished else { throw AudioTrackEncoderError.finished }
        guard input != nil else { throw AudioTrackEncoderError.beginSegmentRequired }
        guard !isAppending else { throw AudioTrackEncoderError.writerFailed }
        isAppending = true
        defer { isAppending = false }
        do {
            try await appendSilenceFrames(frames)
            if let nextSample { self.nextSample = nextSample + frames }
        } catch {
            failed = true
            throw error
        }
    }
    /// Finishes the m4a and verifies its real packet accounting.
    public func finish() async throws -> AudioSealResult {
        guard !isFinished else { throw AudioTrackEncoderError.finished }
        guard let writer, let input, let effectiveStartSample else {
            throw AudioTrackEncoderError.beginSegmentRequired
        }
        guard writtenFrames > 0 else { throw AudioTrackEncoderError.noAudio }
        guard !isAppending else { throw AudioTrackEncoderError.writerFailed }
        isAppending = true
        defer { isAppending = false }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            failed = true
            throw AudioTrackEncoderError.writerFailed
        }
        do {
            try Task.checkCancellation()
            let packetTable = try readPacketTable()
            guard packetTable.validFrameCount == writtenFrames else {
                throw AudioTrackEncoderError.encodingVerificationFailed
            }
            let decodedFrames = try await countDecodedFrames()
            guard decodedFrames == writtenFrames else {
                throw AudioTrackEncoderError.encodingVerificationFailed
            }
            let verification = AudioEncodingVerification(
                validFrameCount: packetTable.validFrameCount,
                encodedPacketCount: packetTable.packetCount,
                decodedFrameCount: decodedFrames,
                primingFrames: packetTable.primingFrames,
                remainderFrames: packetTable.remainderFrames
            )
            verificationStorage = verification
            isFinished = true
            return AudioSealResult(
                role: role, url: outputURL,
                effectiveRange: SampleRange(
                    startSample: effectiveStartSample, sampleCount: writtenFrames
                ),
                primingFrames: verification.primingFrames,
                remainderFrames: verification.remainderFrames,
                insertedSilenceFrames: insertedSilenceFrames
            )
        } catch let error as AudioTrackEncoderError {
            failed = true
            throw error
        } catch {
            failed = true
            throw AudioTrackEncoderError.encodingVerificationFailed
        }
    }
}

/// Errors raised while streaming PCM into an AAC input in a containing MP4.
public enum AudioAACStreamSinkError: Error, Equatable, Sendable {
    /// The role, PCM layout, sample range, or AAC settings are invalid.
    case invalidFormat
    /// The MP4 writer cannot accept the AAC input or a sample.
    case writerFailed
    /// The sink has already been closed.
    case finished
}

/// Streams PCM blocks into one AAC input owned by a containing MP4 writer.
///
/// The writer performs AAC encoding directly into its MP4. This adapter does
/// not create a temporary m4a or restart an encoder at checkpoint boundaries.
public final class AudioAACStreamSink: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let role: RecordingTrackRole
    private let sampleRate: Int
    private let channelCount: Int
    private var isFinished = false

    /// Adds one AAC track input to a writer that has not started writing yet.
    public init(
        writer: AVAssetWriter,
        role: RecordingTrackRole,
        sampleRate: Int,
        channelCount: Int,
        bitRate: Int
    ) throws {
        guard (8_000...192_000).contains(sampleRate),
            (1...2).contains(channelCount),
            (16_000...512_000).contains(bitRate)
        else { throw AudioAACStreamSinkError.invalidFormat }

        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channelCount,
                AVEncoderBitRateKey: bitRate,
            ]
        )
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw AudioAACStreamSinkError.writerFailed }
        writer.add(input)
        self.writer = writer
        self.input = input
        self.role = role
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    /// Encodes and appends one block at its session-global sample position.
    ///
    /// - Parameters:
    ///   - block: Owned Float32 PCM for this track role.
    ///   - segmentStartSample: Session sample corresponding to `mediaOrigin`.
    ///   - mediaOrigin: Output time of the segment's first media sample.
    /// - Throws: ``AudioAACStreamSinkError/finished`` when the track input was
    ///   already closed, ``AudioAACStreamSinkError/invalidFormat`` when the block
    ///   does not match the encoder's format or sample range, and
    ///   ``AudioAACStreamSinkError/writerFailed`` when the writer is no longer
    ///   writing or rejects the buffer. Cancellation while waiting for the writer
    ///   surfaces as `CancellationError`.
    public func append(
        _ block: AudioPCMBlock,
        segmentStartSample: Int64,
        mediaOrigin: CMTime
    ) async throws {
        guard !isFinished else { throw AudioAACStreamSinkError.finished }
        guard block.role == role,
            block.sampleRate == sampleRate,
            block.channelCount == channelCount,
            block.frameCount > 0,
            block.range.sampleCount == Int64(block.frameCount),
            block.range.startSample >= segmentStartSample,
            block.channels.count == channelCount,
            block.channels.allSatisfy({ $0.count == block.frameCount }),
            mediaOrigin.isValid,
            mediaOrigin.isNumeric
        else { throw AudioAACStreamSinkError.invalidFormat }

        let offset = block.range.startSample - segmentStartSample
        let presentationTime = CMTimeAdd(
            mediaOrigin,
            CMTime(value: offset, timescale: CMTimeScale(sampleRate))
        )
        guard presentationTime.isValid, presentationTime.isNumeric,
            let pcm = try? AudioSampleBufferFactory.makePCMBuffer(
                channels: block.channels,
                sampleRate: sampleRate
            ),
            let sampleBuffer = try? AudioSampleBufferFactory.makeSampleBuffer(
                from: pcm,
                presentationTime: presentationTime
            )
        else { throw AudioAACStreamSinkError.invalidFormat }

        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            guard writer.status == .writing else { throw AudioAACStreamSinkError.writerFailed }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        guard input.append(sampleBuffer) else { throw AudioAACStreamSinkError.writerFailed }
    }

    /// Closes this track input after its final PCM block has been appended.
    public func finish() throws {
        guard !isFinished else { throw AudioAACStreamSinkError.finished }
        isFinished = true
        // `markAsFinished` raises when the writer never started (status .unknown)
        // or already finished; cleanup paths must stay crash-free.
        if writer.status == .writing {
            input.markAsFinished()
        }
    }
}

extension AudioTrackEncoder {
    private func positionBeforeAppending(startSample: Int64) async throws {
        guard let nextSample else {
            effectiveStartSample = startSample - writtenFrames
            self.nextSample = startSample
            return
        }
        if startSample < nextSample { throw AudioTrackEncoderError.rangeOverlap }
        if startSample > nextSample {
            try await appendSilenceFrames(startSample - nextSample)
        }
    }
    private func appendPCM(from url: URL, frameCount: Int64) async throws {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch {
            throw AudioTrackEncoderError.sourceUnreadable
        }
        let format = file.processingFormat
        guard Int(format.sampleRate.rounded()) == sampleRate,
            Int(format.channelCount) == channelCount, !format.isInterleaved
        else { throw AudioTrackEncoderError.sourceFormatMismatch }
        guard file.length >= frameCount else {
            throw AudioTrackEncoderError.sourceFrameCountMismatch
        }
        var remaining = frameCount
        while remaining > 0 {
            try Task.checkCancellation()
            let chunkFrames = Int(min(Int64(4_096), remaining))
            guard
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: format, frameCapacity: AVAudioFrameCount(chunkFrames)
                )
            else { throw AudioTrackEncoderError.writerFailed }
            do {
                try file.read(into: buffer, frameCount: AVAudioFrameCount(chunkFrames))
            } catch { throw AudioTrackEncoderError.sourceUnreadable }
            guard Int(buffer.frameLength) == chunkFrames else {
                throw AudioTrackEncoderError.sourceFrameCountMismatch
            }
            try await append(buffer: buffer)
            remaining -= Int64(chunkFrames)
        }
    }
    private func appendSilenceFrames(_ frames: Int64) async throws {
        var remaining = frames
        guard
            let format = AVAudioFormat(
                standardFormatWithSampleRate: Double(sampleRate),
                channels: AVAudioChannelCount(channelCount)
            )
        else { throw AudioTrackEncoderError.invalidFormat }
        while remaining > 0 {
            try Task.checkCancellation()
            let chunkFrames = Int(min(Int64(4_096), remaining))
            guard
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: format, frameCapacity: AVAudioFrameCount(chunkFrames)
                )
            else { throw AudioTrackEncoderError.writerFailed }
            buffer.frameLength = AVAudioFrameCount(chunkFrames)
            for channel in 0..<channelCount {
                guard let data = buffer.floatChannelData?[channel] else {
                    throw AudioTrackEncoderError.writerFailed
                }
                data.update(repeating: 0, count: chunkFrames)
            }
            try await append(buffer: buffer)
            remaining -= Int64(chunkFrames)
            insertedSilenceFrames += Int64(chunkFrames)
        }
    }
    private func append(buffer: AVAudioPCMBuffer) async throws {
        guard let input, let writer else { throw AudioTrackEncoderError.beginSegmentRequired }
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            guard writer.status == .writing else { throw AudioTrackEncoderError.writerFailed }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let sampleBuffer = try makeSampleBuffer(from: buffer)
        guard input.append(sampleBuffer) else { throw AudioTrackEncoderError.writerFailed }
        writtenFrames += Int64(buffer.frameLength)
    }
    private func makeSampleBuffer(from buffer: AVAudioPCMBuffer) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: CMTime(value: writtenFrames, timescale: CMTimeScale(sampleRate)),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil,
            formatDescription: buffer.format.formatDescription,
            sampleCount: CMItemCount(buffer.frameLength), sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard createStatus == noErr, let sampleBuffer else {
            throw AudioTrackEncoderError.writerFailed
        }
        let dataStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, bufferList: buffer.audioBufferList
        )
        guard dataStatus == noErr, CMSampleBufferSetDataReady(sampleBuffer) == noErr else {
            throw AudioTrackEncoderError.writerFailed
        }
        return sampleBuffer
    }
    private func readPacketTable() throws -> PacketTableInfo {
        var fileID: AudioFileID?
        let openStatus = AudioFileOpenURL(outputURL as CFURL, .readPermission, 0, &fileID)
        guard openStatus == noErr, let fileID else {
            throw AudioTrackEncoderError.encodingVerificationFailed
        }
        defer { AudioFileClose(fileID) }
        var info = AudioFilePacketTableInfo()
        var infoSize = UInt32(MemoryLayout<AudioFilePacketTableInfo>.size)
        let infoStatus = AudioFileGetProperty(
            fileID, kAudioFilePropertyPacketTableInfo, &infoSize, &info
        )
        guard infoStatus == noErr else {
            throw AudioTrackEncoderError.encodingVerificationFailed
        }
        var packetCount: UInt64 = 0
        var packetSize = UInt32(MemoryLayout<UInt64>.size)
        let packetStatus = AudioFileGetProperty(
            fileID, kAudioFilePropertyAudioDataPacketCount, &packetSize, &packetCount
        )
        guard packetStatus == noErr, packetCount > 0, packetCount <= UInt64(Int.max),
            info.mNumberValidFrames > 0, info.mPrimingFrames >= 0, info.mRemainderFrames >= 0
        else { throw AudioTrackEncoderError.encodingVerificationFailed }
        return PacketTableInfo(
            validFrameCount: info.mNumberValidFrames,
            packetCount: Int(packetCount),
            primingFrames: Int(info.mPrimingFrames),
            remainderFrames: Int(info.mRemainderFrames)
        )
    }
    private func countDecodedFrames() async throws -> Int64 {
        let asset = AVURLAsset(url: outputURL)
        let tracks: [AVAssetTrack]
        do { tracks = try await asset.loadTracks(withMediaType: .audio) } catch {
            throw AudioTrackEncoderError.encodingVerificationFailed
        }
        guard let track = tracks.first else {
            throw AudioTrackEncoderError.encodingVerificationFailed
        }
        let box = DecodeBox(asset: asset, track: track)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do { continuation.resume(returning: try Self.decodeFrameCount(box)) } catch {
                    continuation.resume(throwing: AudioTrackEncoderError.encodingVerificationFailed)
                }
            }
        }
    }
    private static func decodeFrameCount(_ box: DecodeBox) throws -> Int64 {
        let reader = try AVAssetReader(asset: box.asset)
        let output = AVAssetReaderTrackOutput(
            track: box.track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        )
        guard reader.canAdd(output) else {
            throw AudioTrackEncoderError.encodingVerificationFailed
        }
        reader.add(output)
        guard reader.startReading() else {
            throw AudioTrackEncoderError.encodingVerificationFailed
        }
        var total: Int64 = 0
        while let sampleBuffer = output.copyNextSampleBuffer() {
            total += Int64(CMSampleBufferGetNumSamples(sampleBuffer))
        }
        guard reader.status == .completed else {
            throw AudioTrackEncoderError.encodingVerificationFailed
        }
        return total
    }
}
private final class DecodeBox: @unchecked Sendable {
    let asset: AVAsset
    let track: AVAssetTrack
    init(asset: AVAsset, track: AVAssetTrack) {
        self.asset = asset
        self.track = track
    }
}
