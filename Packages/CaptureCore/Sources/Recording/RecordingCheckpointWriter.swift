// The brief allows exactly two Task 7 source files, so the writer's public types and actor share this file.
// swiftlint:disable file_length

import AVFoundation
import CryptoKit
import Darwin
import Foundation

/// A checkpoint sink that can also finish its segment and report coverage.
///
/// The coordinator owns one sink per visible segment. A sink stays writable
/// after a neighbouring segment opens so that roles which cross a boundary
/// late can still place their prefix in the older segment.
public protocol SegmentCheckpointSink: AudioCheckpointSink, Sendable {
    /// The segment served by this sink.
    var segmentBoundary: SegmentBoundary { get }

    /// Closes the sink and returns every committed checkpoint in the segment.
    ///
    /// - Returns: The segment's committed checkpoint set.
    /// - Throws: An error when the final chunk cannot be committed.
    func finishSegment() async throws -> SegmentCheckpointSet

    /// Closes the sink and returns checkpoints plus per-track coverage.
    ///
    /// - Returns: The segment's checkpoints and coverage.
    /// - Throws: An error when the final chunk cannot be committed.
    func finishSegmentBundle() async throws -> RecordingSegmentCheckpointBundle
}

/// Resolves the visible segment that owns a global 48 kHz session sample.
public protocol RecordingSegmentPlan: Sendable {
    /// Returns the half-open boundary containing `sample`.
    ///
    /// - Parameter sample: A 48 kHz session-global sample index.
    /// - Returns: The boundary whose range contains the sample.
    /// - Throws: An error when no boundary contains the sample.
    func boundary(containing sample: Int64) throws -> SegmentBoundary

    /// Returns the boundary that follows `boundary`.
    ///
    /// - Parameter boundary: The current half-open boundary.
    /// - Returns: The next contiguous boundary.
    /// - Throws: An error when the plan has no following boundary.
    func nextBoundary(after boundary: SegmentBoundary) throws -> SegmentBoundary
}

/// A fixed-length segment plan measured in 48 kHz session samples.
public struct AudioSegmentPlan: RecordingSegmentPlan {
    /// Maximum number of samples in one segment.
    public let maximumSegmentSamples: Int64

    /// Creates a fixed-length segment plan.
    ///
    /// - Parameter maximumSegmentSamples: Segment length in samples; defaults
    ///   to the audio-only maximum from ``RecordingSegmentPolicy``.
    public init(maximumSegmentSamples: Int64 = RecordingSegmentPolicy.maximumSegmentSamples) {
        self.maximumSegmentSamples = maximumSegmentSamples
    }

    /// Returns the fixed-length boundary containing `sample`.
    ///
    /// - Parameter sample: A non-negative 48 kHz session-global sample index.
    /// - Returns: The contiguous boundary containing the sample.
    /// - Throws: ``RecordingCheckpointError/invalidConfiguration`` for a
    ///   non-positive segment length and
    ///   ``RecordingCheckpointError/blockOutsideSegment`` for a negative sample.
    public func boundary(containing sample: Int64) throws -> SegmentBoundary {
        guard maximumSegmentSamples > 0 else {
            throw RecordingCheckpointError.invalidConfiguration
        }
        guard sample >= 0 else {
            throw RecordingCheckpointError.blockOutsideSegment
        }
        let index = sample / maximumSegmentSamples
        guard index <= Int64(Int.max) else {
            throw RecordingCheckpointError.invalidConfiguration
        }
        let startSample = index * maximumSegmentSamples
        return SegmentBoundary(
            index: Int(index),
            startSample: startSample,
            endSample: startSample + maximumSegmentSamples
        )
    }

    /// Returns the next fixed-length boundary.
    ///
    /// - Parameter boundary: A boundary aligned to the configured segment length.
    /// - Returns: The following contiguous boundary.
    /// - Throws: ``RecordingCheckpointError/invalidConfiguration`` when the
    ///   boundary is not aligned to the configured segment length.
    public func nextBoundary(after boundary: SegmentBoundary) throws -> SegmentBoundary {
        guard maximumSegmentSamples > 0, boundary.endSample % maximumSegmentSamples == 0 else {
            throw RecordingCheckpointError.invalidConfiguration
        }
        return SegmentBoundary(
            index: boundary.index + 1,
            startSample: boundary.endSample,
            endSample: boundary.endSample + maximumSegmentSamples
        )
    }
}

/// Makes a checkpoint file and directory durable.
public protocol RecordingDurabilityBarrier: Sendable {
    /// Flushes one file to stable storage.
    ///
    /// - Parameter url: The file to flush.
    /// - Throws: An error when the flush cannot be completed.
    func syncFile(at url: URL) throws

    /// Flushes one directory entry to stable storage.
    ///
    /// - Parameter url: The directory to flush.
    /// - Throws: An error when the flush cannot be completed.
    func syncDirectory(at url: URL) throws
}

/// The production durability barrier backed by `F_FULLFSYNC` and `fsync`.
public struct SystemRecordingDurabilityBarrier: RecordingDurabilityBarrier {
    /// Creates the system durability barrier.
    public init() {}

    /// Flushes one file with `F_FULLFSYNC`, falling back to `fsync`.
    ///
    /// - Parameter url: The file to flush.
    /// - Throws: ``RecordingCheckpointError/durabilityFailed(path:)`` when the
    ///   file cannot be opened or flushed.
    public func syncFile(at url: URL) throws {
        let fileDescriptor = open(url.path, O_RDONLY)
        guard fileDescriptor >= 0 else {
            throw RecordingCheckpointError.durabilityFailed(path: url.path)
        }
        defer { close(fileDescriptor) }
        if fcntl(fileDescriptor, F_FULLFSYNC) == -1, fsync(fileDescriptor) != 0 {
            throw RecordingCheckpointError.durabilityFailed(path: url.path)
        }
    }

    /// Flushes one directory with `fsync`.
    ///
    /// - Parameter url: The directory to flush.
    /// - Throws: ``RecordingCheckpointError/durabilityFailed(path:)`` when the
    ///   directory cannot be opened or flushed.
    public func syncDirectory(at url: URL) throws {
        let fileDescriptor = open(url.path, O_RDONLY | O_DIRECTORY)
        guard fileDescriptor >= 0 else {
            throw RecordingCheckpointError.durabilityFailed(path: url.path)
        }
        defer { close(fileDescriptor) }
        guard fsync(fileDescriptor) == 0 else {
            throw RecordingCheckpointError.durabilityFailed(path: url.path)
        }
    }
}

/// A codable half-open sample range on the 48 kHz session grid.
public struct RecordingSampleRange: Codable, Sendable, Hashable {
    /// Index of the first sample in the range.
    public let startSample: Int64
    /// Number of samples covered by the range.
    public let sampleCount: Int64

    /// Creates a sample range.
    ///
    /// - Parameters:
    ///   - startSample: Index of the first sample.
    ///   - sampleCount: Number of samples covered by the range.
    public init(startSample: Int64, sampleCount: Int64) {
        self.startSample = startSample
        self.sampleCount = sampleCount
    }

    /// Index one past the last sample in the range.
    public var endSample: Int64 {
        startSample + sampleCount
    }
}

/// Committed coverage for one track role inside one segment.
public struct RecordingTrackCoverage: Codable, Sendable, Hashable {
    /// Fixed role string: `mixed`, `system`, or `microphone`.
    public let role: String
    /// Fixed sample rate of the track.
    public let sampleRate: Int
    /// Fixed channel count of the track; zero when the role was never active.
    public let channelCount: Int
    /// Whether the role appended any audio in the segment.
    public let wasActive: Bool
    /// Inclusive 48 kHz session-global first committed sample, including writer silence.
    public let firstSample: Int64?
    /// Exclusive 48 kHz session-global last committed sample.
    public let lastSample: Int64?
    /// Segment-global ranges not covered by the role's CAF files.
    public let missingRanges: [RecordingSampleRange]
    /// Frames the writer synthesized as a prefix for this role.
    public let writerSynthesizedSilenceFrames: Int64

    /// Creates track coverage.
    ///
    /// - Parameters:
    ///   - role: Fixed role string.
    ///   - sampleRate: Fixed sample rate of the track.
    ///   - channelCount: Fixed channel count of the track.
    ///   - wasActive: Whether the role appended any audio.
    ///   - firstSample: Inclusive first committed sample.
    ///   - lastSample: Exclusive last committed sample.
    ///   - missingRanges: Segment-global ranges absent from the CAF files.
    ///   - writerSynthesizedSilenceFrames: Frames synthesized as a prefix.
    public init(
        role: String,
        sampleRate: Int,
        channelCount: Int,
        wasActive: Bool,
        firstSample: Int64?,
        lastSample: Int64?,
        missingRanges: [RecordingSampleRange],
        writerSynthesizedSilenceFrames: Int64
    ) {
        self.role = role
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.wasActive = wasActive
        self.firstSample = firstSample
        self.lastSample = lastSample
        self.missingRanges = missingRanges
        self.writerSynthesizedSilenceFrames = writerSynthesizedSilenceFrames
    }
}

/// Committed coverage for every configured role in one segment.
public struct RecordingSegmentCoverage: Codable, Sendable, Hashable {
    /// Zero-based index of the segment.
    public let segmentIndex: Int
    /// Segment start on the 48 kHz session grid.
    public let segmentStartSample: Int64
    /// Actual segment end on the 48 kHz session grid; may be short for a final segment.
    public let segmentEndSample: Int64
    /// Coverage for each configured role.
    public let tracks: [RecordingTrackCoverage]

    /// Creates segment coverage.
    ///
    /// - Parameters:
    ///   - segmentIndex: Zero-based segment index.
    ///   - segmentStartSample: Segment start on the session grid.
    ///   - segmentEndSample: Actual segment end on the session grid.
    ///   - tracks: Coverage for each configured role.
    public init(
        segmentIndex: Int,
        segmentStartSample: Int64,
        segmentEndSample: Int64,
        tracks: [RecordingTrackCoverage]
    ) {
        self.segmentIndex = segmentIndex
        self.segmentStartSample = segmentStartSample
        self.segmentEndSample = segmentEndSample
        self.tracks = tracks
    }
}

/// The closed result of one segment: durable checkpoints plus coverage.
public struct RecordingSegmentCheckpointBundle: Sendable, Hashable {
    /// Committed checkpoints in append order.
    public let checkpoints: SegmentCheckpointSet
    /// Per-role coverage for the entire segment.
    public let coverage: RecordingSegmentCoverage

    /// Creates a segment checkpoint bundle.
    ///
    /// - Parameters:
    ///   - checkpoints: Committed checkpoints in append order.
    ///   - coverage: Per-role coverage for the segment.
    public init(checkpoints: SegmentCheckpointSet, coverage: RecordingSegmentCoverage) {
        self.checkpoints = checkpoints
        self.coverage = coverage
    }
}

/// Committed frame accounting for one writer.
public struct RecordingCheckpointWriterStats: Sendable, Hashable {
    /// Input frames committed for each role.
    public let appendedFramesByRole: [RecordingTrackRole: Int64]
    /// Prefix-silence frames synthesized by the writer for each role.
    public let writerSynthesizedSilenceFramesByRole: [RecordingTrackRole: Int64]
    /// Total frames committed for each role.
    public let committedFramesByRole: [RecordingTrackRole: Int64]

    /// Creates writer statistics.
    ///
    /// - Parameters:
    ///   - appendedFramesByRole: Committed input frames for each role.
    ///   - writerSynthesizedSilenceFramesByRole: Synthesized prefix frames for each role.
    ///   - committedFramesByRole: Total committed frames for each role.
    public init(
        appendedFramesByRole: [RecordingTrackRole: Int64],
        writerSynthesizedSilenceFramesByRole: [RecordingTrackRole: Int64],
        committedFramesByRole: [RecordingTrackRole: Int64]
    ) {
        self.appendedFramesByRole = appendedFramesByRole
        self.writerSynthesizedSilenceFramesByRole = writerSynthesizedSilenceFramesByRole
        self.committedFramesByRole = committedFramesByRole
    }
}

/// The durable sidecar record for one committed checkpoint.
///
/// The record is written next to the CAF files and read by later stages. All
/// sample coordinates are 48 kHz session-global samples; a CAF always starts
/// at file frame zero.
public struct RecordingCheckpointRecord: Codable, Sendable, Hashable {
    /// Schema version written by this implementation.
    public static let currentSchemaVersion = 1

    /// Version of the record schema.
    public let schemaVersion: Int
    /// Identity of the checkpoint shared with `CheckpointCommit`.
    public let checkpointID: UUID
    /// Zero-based index of the owning segment.
    public let segmentIndex: Int
    /// Session-global first sample of the committed chunk.
    public let startSample: Int64
    /// Number of samples in the committed chunk.
    public let sampleCount: Int64
    /// One track for every role that participated in the chunk.
    public let tracks: [Track]
    /// Wall-clock time at which the chunk became durable.
    public let committedAt: Date

    /// One committed CAF track inside a checkpoint.
    public struct Track: Codable, Sendable, Hashable {
        /// Fixed role string: `mixed`, `system`, or `microphone`.
        public let role: String
        /// CAF file name relative to the checkpoint directory.
        public let fileName: String
        /// Fixed track sample rate.
        public let sampleRate: Int
        /// Fixed track channel count.
        public let channelCount: Int
        /// Number of frames stored in the CAF.
        public let frameCount: Int64
        /// Number of bytes in the CAF, including its header.
        public let byteCount: Int64
        /// Lowercase hexadecimal SHA-256 of the whole CAF file.
        public let sha256: String
        /// Frames the writer synthesized as a prefix for this chunk.
        public let writerSynthesizedSilenceFrames: Int64

        /// Creates a track record.
        ///
        /// - Parameters:
        ///   - role: Fixed role string.
        ///   - fileName: CAF file name relative to the checkpoint directory.
        ///   - sampleRate: Fixed track sample rate.
        ///   - channelCount: Fixed track channel count.
        ///   - frameCount: Number of frames stored in the CAF.
        ///   - byteCount: Number of bytes in the CAF.
        ///   - sha256: Lowercase hexadecimal SHA-256 of the CAF.
        ///   - writerSynthesizedSilenceFrames: Frames synthesized as a prefix.
        public init(
            role: String,
            fileName: String,
            sampleRate: Int,
            channelCount: Int,
            frameCount: Int64,
            byteCount: Int64,
            sha256: String,
            writerSynthesizedSilenceFrames: Int64
        ) {
            self.role = role
            self.fileName = fileName
            self.sampleRate = sampleRate
            self.channelCount = channelCount
            self.frameCount = frameCount
            self.byteCount = byteCount
            self.sha256 = sha256
            self.writerSynthesizedSilenceFrames = writerSynthesizedSilenceFrames
        }
    }

    /// Creates a record using the current schema version.
    ///
    /// - Parameters:
    ///   - checkpointID: Identity shared with `CheckpointCommit`.
    ///   - segmentIndex: Zero-based segment index.
    ///   - startSample: Session-global first sample of the chunk.
    ///   - sampleCount: Number of samples in the chunk.
    ///   - tracks: One track for every participating role.
    ///   - committedAt: Wall-clock durability time.
    public init(
        checkpointID: UUID,
        segmentIndex: Int,
        startSample: Int64,
        sampleCount: Int64,
        tracks: [Track],
        committedAt: Date
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.checkpointID = checkpointID
        self.segmentIndex = segmentIndex
        self.startSample = startSample
        self.sampleCount = sampleCount
        self.tracks = tracks
        self.committedAt = committedAt
    }
}

/// Failures raised by checkpoint writing, coordination, and verification.
public enum RecordingCheckpointError: Error, Equatable, Sendable {
    /// The writer or plan configuration is invalid.
    case invalidConfiguration
    /// A directory is missing, is not a directory, or escapes the session root.
    case pathEscapesSessionRoot
    /// A sample range lies outside the segment.
    case blockOutsideSegment
    /// A role resumed before its last written sample.
    case nonContiguousRange(expectedStart: Int64, actualStart: Int64)
    /// A role range overlaps already written media in the chunk.
    case rangeOverlap(expectedStart: Int64, actualStart: Int64)
    /// A role, sample rate, channel count, or frame count is incompatible.
    case incompatibleFormat(role: RecordingTrackRole?)
    /// Participating roles do not end at the same committed sample.
    case trackRangesDoNotMatch
    /// A non-final segment has not reached its boundary end.
    case segmentIncomplete(expectedEnd: Int64, actualEnd: Int64)
    /// Writing a track or sidecar failed.
    case writeFailed(role: RecordingTrackRole?, reason: String)
    /// A file, sidecar, or directory could not be made durable.
    case durabilityFailed(path: String)
    /// A record or CAF failed verification.
    case verificationFailed(path: String)
    /// There is no uncommitted chunk to commit.
    case emptyCheckpoint
    /// The segment is already closed.
    case segmentClosed
    /// The coordinator does not know the requested segment index.
    case unknownSegment(Int)
}

/// Internal fault seam used by tests to inject durability and write failures.
internal protocol RecordingCheckpointFaultInjecting: Sendable {
    func checkWrite(role: RecordingTrackRole?) throws
    func checkClose(role: RecordingTrackRole?) throws
    func checkFileSync(role: RecordingTrackRole?) throws
    func checkSidecarRename() throws
    func checkDirectorySync() throws
}

/// The production no-op fault injector.
internal struct NoRecordingCheckpointFaults: RecordingCheckpointFaultInjecting {
    func checkWrite(role: RecordingTrackRole?) throws {}
    func checkClose(role: RecordingTrackRole?) throws {}
    func checkFileSync(role: RecordingTrackRole?) throws {}
    func checkSidecarRename() throws {}
    func checkDirectorySync() throws {}
}

/// Sidecar encoding, hashing, and verification helpers.
internal enum RecordingCheckpointSidecar {
    static func encode(_ record: RecordingCheckpointRecord) throws -> Data {
        guard record.schemaVersion == RecordingCheckpointRecord.currentSchemaVersion else {
            throw RecordingCheckpointError.verificationFailed(path: "<memory>")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            return try encoder.encode(record)
        } catch {
            throw RecordingCheckpointError.verificationFailed(path: "<memory>")
        }
    }

    static func decode(_ data: Data, path: String) throws -> RecordingCheckpointRecord {
        let decoder = JSONDecoder()
        let record: RecordingCheckpointRecord
        do {
            record = try decoder.decode(RecordingCheckpointRecord.self, from: data)
        } catch {
            throw RecordingCheckpointError.verificationFailed(path: path)
        }
        guard record.schemaVersion == RecordingCheckpointRecord.currentSchemaVersion else {
            throw RecordingCheckpointError.verificationFailed(path: path)
        }
        return record
    }

    static func sha256(ofFileAt url: URL) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw RecordingCheckpointError.verificationFailed(path: url.path)
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        do {
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                hasher.update(data: data)
            }
        } catch {
            throw RecordingCheckpointError.verificationFailed(path: url.path)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func verify(record: RecordingCheckpointRecord, tracksDirectory: URL) throws {
        let root = tracksDirectory.resolvingSymlinksInPath().standardizedFileURL
        for track in record.tracks {
            let candidate = tracksDirectory.appendingPathComponent(track.fileName).standardizedFileURL
            let resolved = candidate.resolvingSymlinksInPath()
            guard candidate.deletingLastPathComponent().path == root.path,
                  resolved.path == candidate.path
            else {
                throw RecordingCheckpointError.verificationFailed(path: candidate.path)
            }
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try FileManager.default.attributesOfItem(atPath: candidate.path)
            } catch {
                throw RecordingCheckpointError.verificationFailed(path: candidate.path)
            }
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
            guard size == track.byteCount else {
                throw RecordingCheckpointError.verificationFailed(path: candidate.path)
            }
            let digest: String
            do {
                digest = try sha256(ofFileAt: candidate)
            } catch {
                throw RecordingCheckpointError.verificationFailed(path: candidate.path)
            }
            guard digest == track.sha256 else {
                throw RecordingCheckpointError.verificationFailed(path: candidate.path)
            }
        }
    }
}

/// Resolves and revalidates checkpoint output directories.
internal enum RecordingCheckpointPath {
    /// Non-following state of one directory entry.
    internal enum EntryState {
        case absent
        case present(isSymbolicLink: Bool)
    }

    static func entryState(at url: URL) throws -> EntryState {
        var info = stat()
        let status = url.path.withCString { lstat($0, &info) }
        if status == 0 {
            return .present(isSymbolicLink: (info.st_mode & S_IFMT) == S_IFLNK)
        }
        if errno == ENOENT {
            return .absent
        }
        throw RecordingCheckpointError.pathEscapesSessionRoot
    }

    static func resolve(directory: URL, sessionRoot: URL) throws -> (directory: URL, sessionRoot: URL) {
        guard !directory.path.contains("\0"), !sessionRoot.path.contains("\0") else {
            throw RecordingCheckpointError.invalidConfiguration
        }
        let resolvedRoot = sessionRoot.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw RecordingCheckpointError.pathEscapesSessionRoot
        }
        let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        guard FileManager.default.fileExists(atPath: resolvedDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw RecordingCheckpointError.pathEscapesSessionRoot
        }
        let rootComponents = resolvedRoot.pathComponents
        let directoryComponents = resolvedDirectory.pathComponents
        guard directoryComponents.count > rootComponents.count,
              Array(directoryComponents.prefix(rootComponents.count)) == rootComponents
        else {
            throw RecordingCheckpointError.pathEscapesSessionRoot
        }
        return (resolvedDirectory, resolvedRoot)
    }
}

/// One open 16-bit PCM CAF track inside a checkpoint chunk.
private final class CheckpointTrackFile {
    let url: URL
    private let role: RecordingTrackRole
    private let channelCount: Int
    private var file: AVAudioFile?

    init(url: URL, role: RecordingTrackRole, sampleRate: Int, channelCount: Int) throws {
        self.url = url
        self.role = role
        self.channelCount = channelCount
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(sampleRate),
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        do {
            file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
        } catch {
            throw RecordingCheckpointError.writeFailed(role: role, reason: "Unable to create CAF")
        }
    }

    func write(channels: [[Float]], frameCount: Int) throws {
        var offset = 0
        while offset < frameCount {
            let count = min(8_192, frameCount - offset)
            try writeSlice(channels: channels, offset: offset, frameCount: count)
            offset += count
        }
    }

    func writeSilence(frames: Int64) throws {
        var remaining = frames
        while remaining > 0 {
            let count = Int(min(remaining, 8_192))
            try writeSlice(channels: [], offset: 0, frameCount: count)
            remaining -= Int64(count)
        }
    }

    func close() {
        file = nil
    }

    func byteCount() throws -> Int64 {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw RecordingCheckpointError.verificationFailed(path: url.path)
        }
        guard let size = (attributes[.size] as? NSNumber)?.int64Value else {
            throw RecordingCheckpointError.verificationFailed(path: url.path)
        }
        return size
    }

    private func writeSlice(channels: [[Float]], offset: Int, frameCount: Int) throws {
        guard let file else {
            throw RecordingCheckpointError.writeFailed(role: role, reason: "CAF is closed")
        }
        guard file.processingFormat.channelCount == channelCount,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: file.processingFormat,
                  frameCapacity: AVAudioFrameCount(frameCount)
              ),
              let storage = buffer.int16ChannelData?[0]
        else {
            throw RecordingCheckpointError.writeFailed(role: role, reason: "Unable to allocate PCM buffer")
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        for frame in 0..<frameCount {
            for channel in 0..<channelCount {
                let value = channels.isEmpty ? 0 : channels[channel][offset + frame]
                storage[frame * channelCount + channel] = Self.quantized(value)
            }
        }
        do {
            try file.write(from: buffer)
        } catch {
            throw RecordingCheckpointError.writeFailed(role: role, reason: "CAF write failed")
        }
    }

    private static func quantized(_ value: Float) -> Int16 {
        guard value.isFinite else { return 0 }
        let scaled = (value * 32_768).rounded()
        return Int16(max(-32_768, min(32_767, scaled)))
    }
}

/// Writes contiguous 16-bit PCM CAF chunks and commits them with SHA-256 sidecars.
///
/// The writer owns exactly one visible segment. It accepts blocks on the fixed
/// 48 kHz session grid, keeps one write cursor per role, and commits each chunk
/// only after every participating CAF is closed, flushed, hashed, described by a
/// sidecar, and the containing directory is durable.
public actor RecordingCheckpointWriter: SegmentCheckpointSink {
    /// The segment served by this writer.
    public nonisolated let segmentBoundary: SegmentBoundary

    private enum Phase {
        case open
        case closed
        case failed
    }

    private struct RoleState {
        var lastSample: Int64?
        var firstSample: Int64?
        var channelCount: Int?
        var writtenSilenceFrames: Int64 = 0
        var committedInputFrames: Int64 = 0
        var committedSilenceFrames: Int64 = 0
        var committedFrames: Int64 = 0
    }

    private struct ChunkState {
        var checkpointID = UUID()
        var participants: Set<RecordingTrackRole> = []
        var files: [RecordingTrackRole: CheckpointTrackFile] = [:]
        var framesByRole: [RecordingTrackRole: Int64] = [:]
        var silenceByRole: [RecordingTrackRole: Int64] = [:]
    }

    private let requestedDirectory: URL
    private let requestedSessionRoot: URL
    private let directory: URL
    private let sessionRoot: URL
    private let sampleRate: Int
    private let roles: Set<RecordingTrackRole>
    private let orderedRoles: [RecordingTrackRole]
    private let durability: any RecordingDurabilityBarrier
    private let faults: any RecordingCheckpointFaultInjecting
    private let now: @Sendable () -> Date

    private var phase: Phase = .open
    private var chunkStart: Int64
    private var chunk = ChunkState()
    private var chunkOrdinal = 0
    private var roleStates: [RecordingTrackRole: RoleState]
    private var committedCheckpoints: [CheckpointCommit] = []
    private var lastCommit: CheckpointCommit?
    private var cachedBundle: RecordingSegmentCheckpointBundle?

    /// Creates a checkpoint writer rooted at an existing staging directory.
    ///
    /// - Parameters:
    ///   - directory: Existing real directory inside `sessionRoot` that receives CAFs.
    ///   - sessionRoot: Existing real directory that bounds all writes.
    ///   - segment: The visible segment owned by this writer.
    ///   - sampleRate: Fixed session sample rate in hertz.
    ///   - roles: Configured track roles; never-active roles get coverage only.
    ///   - durability: File and directory flush implementation.
    ///   - now: Wall-clock source for committed timestamps.
    /// - Throws: ``RecordingCheckpointError`` when configuration or paths are invalid.
    public init(
        directory: URL,
        sessionRoot: URL,
        segment: SegmentBoundary,
        sampleRate: Int,
        roles: Set<RecordingTrackRole>,
        durability: any RecordingDurabilityBarrier = SystemRecordingDurabilityBarrier(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        try self.init(
            directory: directory,
            sessionRoot: sessionRoot,
            segment: segment,
            sampleRate: sampleRate,
            roles: roles,
            durability: durability,
            now: now,
            faults: NoRecordingCheckpointFaults()
        )
    }

    internal init(
        directory: URL,
        sessionRoot: URL,
        segment: SegmentBoundary,
        sampleRate: Int,
        roles: Set<RecordingTrackRole>,
        durability: any RecordingDurabilityBarrier,
        now: @escaping @Sendable () -> Date,
        faults: any RecordingCheckpointFaultInjecting
    ) throws {
        guard sampleRate > 0, !roles.isEmpty,
              segment.index >= 0, segment.endSample > segment.startSample
        else {
            throw RecordingCheckpointError.invalidConfiguration
        }
        let resolved = try RecordingCheckpointPath.resolve(directory: directory, sessionRoot: sessionRoot)
        segmentBoundary = segment
        requestedDirectory = directory
        requestedSessionRoot = sessionRoot
        self.directory = resolved.directory
        self.sessionRoot = resolved.sessionRoot
        self.sampleRate = sampleRate
        self.roles = roles
        orderedRoles = Self.roleOrder.filter { roles.contains($0) }
        self.durability = durability
        self.faults = faults
        self.now = now
        chunkStart = segment.startSample
        roleStates = Dictionary(
            uniqueKeysWithValues: orderedRoles.map { ($0, RoleState()) }
        )
    }

    /// Appends one block to the current chunk.
    ///
    /// A role that appears for the first time in a chunk receives a bounded
    /// silence prefix from the chunk start to the block start. After that the
    /// role must continue exactly at its own written tail.
    ///
    /// - Parameter block: The owned PCM block on the fixed session grid.
    /// - Throws: ``RecordingCheckpointError`` when the block is invalid or the
    ///   writer has already failed or closed.
    public func append(_ block: AudioPCMBlock) async throws {
        try ensureWritable()
        try validate(block)
        let blockStart = block.range.startSample
        let frameCount = Int64(block.frameCount)
        let blockEnd = blockStart + frameCount
        guard blockStart >= segmentBoundary.startSample, blockEnd <= segmentBoundary.endSample else {
            throw RecordingCheckpointError.blockOutsideSegment
        }
        guard blockStart >= chunkStart else {
            throw RecordingCheckpointError.rangeOverlap(
                expectedStart: max(roleStates[block.role]?.lastSample ?? chunkStart, chunkStart),
                actualStart: blockStart
            )
        }

        var prefixFrames: Int64 = 0
        if let lastSample = roleStates[block.role]?.lastSample {
            guard blockStart >= lastSample else {
                throw RecordingCheckpointError.rangeOverlap(expectedStart: lastSample, actualStart: blockStart)
            }
            guard blockStart == lastSample else {
                throw RecordingCheckpointError.nonContiguousRange(expectedStart: lastSample, actualStart: blockStart)
            }
        } else {
            prefixFrames = blockStart - chunkStart
        }

        do {
            try faults.checkWrite(role: block.role)
            if chunk.participants.isEmpty {
                try beginChunk()
            }
            let file = try trackFile(for: block.role, channelCount: block.channelCount)
            if prefixFrames > 0 {
                try file.writeSilence(frames: prefixFrames)
                chunk.framesByRole[block.role, default: 0] += prefixFrames
                chunk.silenceByRole[block.role, default: 0] += prefixFrames
            }
            try file.write(channels: block.channels, frameCount: block.frameCount)
            chunk.framesByRole[block.role, default: 0] += frameCount
            chunk.participants.insert(block.role)

            var state = roleStates[block.role] ?? RoleState()
            if state.firstSample == nil {
                state.firstSample = prefixFrames > 0 ? chunkStart : blockStart
            }
            state.lastSample = blockEnd
            state.channelCount = block.channelCount
            state.writtenSilenceFrames += prefixFrames
            roleStates[block.role] = state
        } catch let error as RecordingCheckpointError {
            phase = .failed
            throw error
        } catch {
            phase = .failed
            throw RecordingCheckpointError.writeFailed(role: block.role, reason: "writeFailed")
        }
    }

    /// Durability boundary note (P2: evaluated, deferred, not implemented).
    ///
    /// Appending chunk frames and the journal encode + `F_FULLFSYNC` barrier are
    /// still one commit path. Separating them may be possible later, but only with
    /// runtime evidence that it is safe, and it must preserve the committed
    /// contract: no result may report "safe" before the files are closed and
    /// verified and the ledger is durable. The ≤300 s recovery-point target and the
    /// `nextCheckpointSeconds` / `tailReserveSeconds` values are unchanged. This
    /// comment records a deferral, not a performance win.
    ///
    /// Commits the current chunk.
    ///
    /// Repeating the call without new samples returns the previous commit. The
    /// first empty chunk throws ``RecordingCheckpointError/emptyCheckpoint``.
    ///
    /// - Returns: The durable commit for the chunk.
    /// - Throws: ``RecordingCheckpointError`` when the chunk cannot be committed.
    public func commitCheckpoint() async throws -> CheckpointCommit {
        switch phase {
        case .failed:
            throw RecordingCheckpointError.writeFailed(role: nil, reason: "writerFailed")
        case .closed:
            throw RecordingCheckpointError.segmentClosed
        case .open:
            break
        }
        guard !chunk.participants.isEmpty else {
            if let lastCommit {
                return lastCommit
            }
            throw RecordingCheckpointError.emptyCheckpoint
        }
        let ends = chunk.participants.compactMap { roleStates[$0]?.lastSample }
        guard ends.count == chunk.participants.count,
              Set(ends).count == 1,
              let endSample = ends.first
        else {
            throw RecordingCheckpointError.trackRangesDoNotMatch
        }
        do {
            return try commitChunk(endingAt: endSample)
        } catch let error as RecordingCheckpointError {
            phase = .failed
            throw error
        } catch {
            phase = .failed
            throw RecordingCheckpointError.writeFailed(role: nil, reason: "commitFailed")
        }
    }

    /// Finishes the segment and returns its committed checkpoints.
    ///
    /// - Returns: The segment's committed checkpoint set.
    /// - Throws: ``RecordingCheckpointError`` when the final chunk fails.
    public func finishSegment() async throws -> SegmentCheckpointSet {
        try await finishSegmentBundle().checkpoints
    }

    /// Finishes the segment and returns checkpoints plus coverage.
    ///
    /// - Returns: The segment's checkpoints and actual-end coverage.
    /// - Throws: ``RecordingCheckpointError`` when the final chunk fails.
    public func finishSegmentBundle() async throws -> RecordingSegmentCheckpointBundle {
        if let cachedBundle {
            return cachedBundle
        }
        switch phase {
        case .failed:
            throw RecordingCheckpointError.writeFailed(role: nil, reason: "writerFailed")
        case .closed:
            throw RecordingCheckpointError.segmentClosed
        case .open:
            if !chunk.participants.isEmpty {
                do {
                    _ = try commitChunk(endingAt: try currentChunkEnd())
                } catch let error as RecordingCheckpointError {
                    phase = .failed
                    throw error
                } catch {
                    phase = .failed
                    throw RecordingCheckpointError.writeFailed(role: nil, reason: "commitFailed")
                }
            }
        }
        let bundle = RecordingSegmentCheckpointBundle(
            checkpoints: SegmentCheckpointSet(
                segmentIndex: segmentBoundary.index,
                checkpoints: committedCheckpoints
            ),
            coverage: makeCoverage(actualEnd: chunkStart)
        )
        cachedBundle = bundle
        phase = .closed
        return bundle
    }

    private func ensureWritable() throws {
        switch phase {
        case .open:
            return
        case .closed:
            throw RecordingCheckpointError.segmentClosed
        case .failed:
            throw RecordingCheckpointError.writeFailed(role: nil, reason: "writerFailed")
        }
    }

    private func currentChunkEnd() throws -> Int64 {
        let ends = chunk.participants.compactMap { roleStates[$0]?.lastSample }
        guard ends.count == chunk.participants.count, Set(ends).count == 1, let end = ends.first else {
            throw RecordingCheckpointError.trackRangesDoNotMatch
        }
        return end
    }

    private func commitChunk(endingAt endSample: Int64) throws -> CheckpointCommit {
        let sampleCount = endSample - chunkStart
        guard sampleCount > 0 else {
            throw RecordingCheckpointError.emptyCheckpoint
        }
        var tracks: [RecordingCheckpointRecord.Track] = []
        var trackURLs: [RecordingTrackRole: URL] = [:]
        for role in orderedRoles where chunk.participants.contains(role) {
            let committed = try commitTrack(role: role, sampleCount: sampleCount)
            tracks.append(committed.track)
            trackURLs[role] = committed.url
        }
        guard tracks.count == chunk.participants.count else {
            throw RecordingCheckpointError.trackRangesDoNotMatch
        }
        let record = RecordingCheckpointRecord(
            checkpointID: chunk.checkpointID,
            segmentIndex: segmentBoundary.index,
            startSample: chunkStart,
            sampleCount: sampleCount,
            tracks: tracks,
            committedAt: now()
        )
        _ = try writeSidecar(record: record)
        let commit = CheckpointCommit(
            checkpointID: chunk.checkpointID,
            segmentIndex: segmentBoundary.index,
            range: SampleRange(startSample: chunkStart, sampleCount: sampleCount),
            trackURLs: trackURLs,
            committedAt: record.committedAt
        )
        updateCommittedStatistics(sampleCount: sampleCount)
        committedCheckpoints.append(commit)
        lastCommit = commit
        chunkStart = endSample
        chunk = ChunkState()
        return commit
    }

    private func commitTrack(
        role: RecordingTrackRole,
        sampleCount: Int64
    ) throws -> (track: RecordingCheckpointRecord.Track, url: URL) {
        guard let file = chunk.files[role],
              let frames = chunk.framesByRole[role],
              frames == sampleCount
        else {
            throw RecordingCheckpointError.trackRangesDoNotMatch
        }
        do {
            try faults.checkClose(role: role)
        } catch {
            throw RecordingCheckpointError.writeFailed(role: role, reason: "closeFailed")
        }
        file.close()
        do {
            try faults.checkFileSync(role: role)
            try durability.syncFile(at: file.url)
        } catch {
            throw RecordingCheckpointError.durabilityFailed(path: file.url.path)
        }
        let byteCount: Int64
        do {
            byteCount = try file.byteCount()
        } catch {
            throw RecordingCheckpointError.verificationFailed(path: file.url.path)
        }
        let digest: String
        do {
            digest = try RecordingCheckpointSidecar.sha256(ofFileAt: file.url)
        } catch {
            throw RecordingCheckpointError.verificationFailed(path: file.url.path)
        }
        let track = RecordingCheckpointRecord.Track(
            role: Self.roleString(role),
            fileName: file.url.lastPathComponent,
            sampleRate: sampleRate,
            channelCount: roleStates[role]?.channelCount ?? 0,
            frameCount: sampleCount,
            byteCount: byteCount,
            sha256: digest,
            writerSynthesizedSilenceFrames: chunk.silenceByRole[role] ?? 0
        )
        return (track, file.url)
    }

    private func writeSidecar(record: RecordingCheckpointRecord) throws -> URL {
        let uuid = chunk.checkpointID.uuidString.lowercased()
        let sidecarURL = directory.appendingPathComponent("checkpoint-\(uuid).json")
        let temporaryURL = directory.appendingPathComponent(".checkpoint-\(uuid).json.tmp")
        let data: Data
        do {
            data = try RecordingCheckpointSidecar.encode(record)
        } catch {
            throw RecordingCheckpointError.verificationFailed(path: sidecarURL.path)
        }
        do {
            try data.write(to: temporaryURL, options: .withoutOverwriting)
        } catch {
            throw RecordingCheckpointError.writeFailed(role: nil, reason: "sidecarWriteFailed")
        }
        do {
            try faults.checkFileSync(role: nil)
            try durability.syncFile(at: temporaryURL)
        } catch {
            throw RecordingCheckpointError.durabilityFailed(path: temporaryURL.path)
        }
        do {
            try faults.checkSidecarRename()
        } catch {
            throw RecordingCheckpointError.durabilityFailed(path: sidecarURL.path)
        }
        let renameResult = temporaryURL.withUnsafeFileSystemRepresentation { source in
            sidecarURL.withUnsafeFileSystemRepresentation { destination in
                guard let source, let destination else { return Int(-1) }
                return Int(rename(source, destination))
            }
        }
        guard renameResult == 0 else {
            throw RecordingCheckpointError.durabilityFailed(path: sidecarURL.path)
        }
        do {
            try faults.checkDirectorySync()
            try durability.syncDirectory(at: directory)
        } catch {
            throw RecordingCheckpointError.durabilityFailed(path: directory.path)
        }
        return sidecarURL
    }
}

extension RecordingCheckpointWriter {
    /// Returns committed frame accounting for this segment.
    ///
    /// - Returns: Per-role input, synthesized silence, and committed totals.
    public func statistics() -> RecordingCheckpointWriterStats {
        var appended: [RecordingTrackRole: Int64] = [:]
        var silence: [RecordingTrackRole: Int64] = [:]
        var committed: [RecordingTrackRole: Int64] = [:]
        for role in orderedRoles {
            let state = roleStates[role] ?? RoleState()
            appended[role] = state.committedInputFrames
            silence[role] = state.committedSilenceFrames
            committed[role] = state.committedFrames
        }
        return RecordingCheckpointWriterStats(
            appendedFramesByRole: appended,
            writerSynthesizedSilenceFramesByRole: silence,
            committedFramesByRole: committed
        )
    }

    func validate(_ block: AudioPCMBlock) throws {
        guard roles.contains(block.role) else {
            throw RecordingCheckpointError.incompatibleFormat(role: block.role)
        }
        guard block.frameCount > 0,
              Int64(block.frameCount) == block.range.sampleCount,
              block.sampleRate == sampleRate,
              block.channelCount > 0,
              block.channelCount == block.channels.count,
              block.channels.allSatisfy({ $0.count == block.frameCount })
        else {
            throw RecordingCheckpointError.incompatibleFormat(role: block.role)
        }
        if let channelCount = roleStates[block.role]?.channelCount, channelCount != block.channelCount {
            throw RecordingCheckpointError.incompatibleFormat(role: block.role)
        }
    }

    func beginChunk() throws {
        let resolved = try RecordingCheckpointPath.resolve(
            directory: requestedDirectory,
            sessionRoot: requestedSessionRoot
        )
        guard resolved.directory.path == directory.path else {
            throw RecordingCheckpointError.pathEscapesSessionRoot
        }
        chunkOrdinal += 1
        while (try ordinalIsAvailable(chunkOrdinal)) == false {
            chunkOrdinal += 1
        }
        chunk = ChunkState()
    }

    func ordinalIsAvailable(_ ordinal: Int) throws -> Bool {
        for role in orderedRoles {
            let name = "\(Self.fileToken(role))-\(String(format: "%04d", ordinal)).caf"
            let url = directory.appendingPathComponent(name)
            switch try RecordingCheckpointPath.entryState(at: url) {
            case .absent:
                continue
            case .present(let isSymbolicLink):
                if isSymbolicLink {
                    throw RecordingCheckpointError.pathEscapesSessionRoot
                }
                return false
            }
        }
        return true
    }

    fileprivate func trackFile(for role: RecordingTrackRole, channelCount: Int) throws -> CheckpointTrackFile {
        if let file = chunk.files[role] {
            return file
        }
        let fileName = "\(Self.fileToken(role))-\(String(format: "%04d", chunkOrdinal)).caf"
        let url = directory.appendingPathComponent(fileName)
        switch try RecordingCheckpointPath.entryState(at: url) {
        case .absent:
            break
        case .present(let isSymbolicLink):
            if isSymbolicLink {
                throw RecordingCheckpointError.pathEscapesSessionRoot
            }
            throw RecordingCheckpointError.writeFailed(role: role, reason: "CAF already exists")
        }
        let file = try CheckpointTrackFile(
            url: url,
            role: role,
            sampleRate: sampleRate,
            channelCount: channelCount
        )
        chunk.files[role] = file
        return file
    }

    func updateCommittedStatistics(sampleCount: Int64) {
        for role in chunk.participants {
            var state = roleStates[role] ?? RoleState()
            let silence = chunk.silenceByRole[role] ?? 0
            state.committedInputFrames += sampleCount - silence
            state.committedSilenceFrames += silence
            state.committedFrames += sampleCount
            roleStates[role] = state
        }
    }

    func makeCoverage(actualEnd: Int64) -> RecordingSegmentCoverage {
        let segmentStart = segmentBoundary.startSample
        let tracks = orderedRoles.map { role -> RecordingTrackCoverage in
            let state = roleStates[role] ?? RoleState()
            var missing: [RecordingSampleRange] = []
            if let first = state.firstSample, let last = state.lastSample {
                if first > segmentStart {
                    missing.append(
                        RecordingSampleRange(startSample: segmentStart, sampleCount: first - segmentStart)
                    )
                }
                if last < actualEnd {
                    missing.append(
                        RecordingSampleRange(startSample: last, sampleCount: actualEnd - last)
                    )
                }
            } else if actualEnd > segmentStart {
                missing.append(
                    RecordingSampleRange(
                        startSample: segmentStart,
                        sampleCount: actualEnd - segmentStart
                    )
                )
            }
            return RecordingTrackCoverage(
                role: Self.roleString(role),
                sampleRate: sampleRate,
                channelCount: state.channelCount ?? 0,
                wasActive: state.firstSample != nil,
                firstSample: state.firstSample,
                lastSample: state.lastSample,
                missingRanges: missing,
                writerSynthesizedSilenceFrames: state.writtenSilenceFrames
            )
        }
        return RecordingSegmentCoverage(
            segmentIndex: segmentBoundary.index,
            segmentStartSample: segmentStart,
            segmentEndSample: actualEnd,
            tracks: tracks
        )
    }

    static let roleOrder: [RecordingTrackRole] = [.mixed, .system, .microphone]

    static func fileToken(_ role: RecordingTrackRole) -> String {
        switch role {
        case .mixed:
            return "mixed"
        case .system:
            return "system"
        case .microphone:
            return "mic"
        }
    }

    static func roleString(_ role: RecordingTrackRole) -> String {
        switch role {
        case .mixed:
            return "mixed"
        case .system:
            return "system"
        case .microphone:
            return "microphone"
        }
    }
}
