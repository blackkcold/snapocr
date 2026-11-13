import AVFoundation
import CryptoKit
import Foundation
import Testing
@testable import CaptureCore

/// One synthetic block appended to the Task 8 checkpoint fixture.
struct T8Append: Sendable {
    let role: RecordingTrackRole
    let startSample: Int64
    let frameCount: Int
    let amplitude: Float
    let silent: Bool

    init(
        role: RecordingTrackRole,
        startSample: Int64,
        frameCount: Int,
        amplitude: Float = 0.6,
        silent: Bool = false
    ) {
        self.role = role
        self.startSample = startSample
        self.frameCount = frameCount
        self.amplitude = amplitude
        self.silent = silent
    }
}

/// Real checkpoint material produced through the Task 7 writer.
struct T8BundleFixture: Sendable {
    let bundle: RecordingSegmentCheckpointBundle
    let commits: [CheckpointCommit]
    let sessionRoot: URL
    let checkpointDirectory: URL
    let sourceHashes: [String: String]
}

/// Decoded PCM read back from a real m4a.
struct T8DecodedAudio: Sendable {
    let frameCount: Int64
    let channels: [[Float]]

    func meanAbsolute(channel: Int, start: Int, count: Int) -> Float {
        guard channel < channels.count, start >= 0, count > 0 else { return 0 }
        let samples = channels[channel]
        let end = min(samples.count, start + count)
        guard start < end else { return 0 }
        var total: Float = 0
        for index in start..<end {
            total += abs(samples[index])
        }
        return total / Float(end - start)
    }
}

final class T8DecodeBox: @unchecked Sendable {
    let asset: AVAsset
    let track: AVAssetTrack

    init(asset: AVAsset, track: AVAssetTrack) {
        self.asset = asset
        self.track = track
    }
}

/// Shared fixtures for the Task 8 encoder and seal tests.
enum T8TestSupport {
    static let sampleRate = 48_000
    static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    static func makeRoot(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapglass-t08-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func makeDirectory(_ name: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    static func tone(_ append: T8Append, sampleRate: Int = sampleRate) -> AudioPCMBlock {
        let frames = append.frameCount
        let values: [Float]
        if append.silent {
            values = Array(repeating: 0, count: frames)
        } else {
            values = (0..<frames).map { offset in
                let position = Double(append.startSample + Int64(offset))
                return Float(sin(2.0 * Double.pi * 440.0 * position / Double(sampleRate))) * append.amplitude
            }
        }
        return AudioPCMBlock(
            role: append.role,
            range: SampleRange(startSample: append.startSample, sampleCount: Int64(frames)),
            sampleRate: sampleRate,
            channelCount: 1,
            frameCount: frames,
            hostTime: 0,
            channels: [values],
            isSilence: append.silent
        )
    }

    static func makeBundle(
        sessionRoot: URL,
        segmentIndex: Int = 0,
        segmentStart: Int64 = 0,
        segmentEnd: Int64,
        sampleRate: Int = sampleRate,
        roles: Set<RecordingTrackRole>,
        chunks: [[T8Append]],
        directoryName: String = "checkpoints"
    ) async throws -> T8BundleFixture {
        let checkpointDirectory = try makeDirectory(directoryName, in: sessionRoot)
        let writer = try RecordingCheckpointWriter(
            directory: checkpointDirectory,
            sessionRoot: sessionRoot,
            segment: SegmentBoundary(index: segmentIndex, startSample: segmentStart, endSample: segmentEnd),
            sampleRate: sampleRate,
            roles: roles,
            now: { fixedDate }
        )
        var commits: [CheckpointCommit] = []
        for chunk in chunks {
            for append in chunk {
                try await writer.append(tone(append, sampleRate: sampleRate))
            }
            commits.append(try await writer.commitCheckpoint())
        }
        let bundle = try await writer.finishSegmentBundle()
        return T8BundleFixture(
            bundle: bundle,
            commits: commits,
            sessionRoot: sessionRoot,
            checkpointDirectory: checkpointDirectory,
            sourceHashes: try hashesOfCAFFiles(in: checkpointDirectory)
        )
    }

    static func hashesOfCAFFiles(in directory: URL) throws -> [String: String] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".caf") }
            .sorted()
        var hashes: [String: String] = [:]
        for name in names {
            hashes[name] = try sha256(of: directory.appendingPathComponent(name))
        }
        return hashes
    }

    static func sha256(of url: URL) throws -> String {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while true {
            let data = try handle.read(upToCount: 1 << 20) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Reads only the container's valid frame count; no decoded PCM is materialized.
    static func validFrameCount(of url: URL) throws -> Int64 {
        let file = try AVAudioFile(forReading: url)
        return file.length
    }

    static func audioFormat(of url: URL) throws -> (sampleRate: Double, channelCount: Int) {
        let file = try AVAudioFile(forReading: url)
        return (file.fileFormat.sampleRate, Int(file.fileFormat.channelCount))
    }

    /// Decodes a real m4a into small, test-owned PCM arrays.
    static func decode(_ url: URL) async throws -> T8DecodedAudio {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw T8TestError.missingAudioTrack
        }
        let box = T8DecodeBox(asset: asset, track: track)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try decodeSync(box)) } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func decodeSync(_ box: T8DecodeBox) throws -> T8DecodedAudio {
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
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? T8TestError.unreadableAudio
        }
        var channels: [[Float]] = []
        var total: Int64 = 0
        while let sampleBuffer = output.copyNextSampleBuffer() {
            let frameCount = Int(CMSampleBufferGetNumSamples(sampleBuffer))
            guard frameCount > 0,
                  let format = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                  let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer)
            else { continue }
            let channelCount = Int(description.mChannelsPerFrame)
            if channels.isEmpty {
                channels = Array(repeating: [], count: channelCount)
            }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            let status = CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &length,
                dataPointerOut: &pointer
            )
            guard status == noErr, let pointer else { continue }
            let data = Data(bytes: pointer, count: length)
            data.withUnsafeBytes { raw in
                for frame in 0..<frameCount {
                    for channel in 0..<channelCount {
                        let offset = (frame * channelCount + channel) * 2
                        let sample = raw.loadUnaligned(fromByteOffset: offset, as: Int16.self)
                        channels[channel].append(Float(sample) / 32_768)
                    }
                }
            }
            total += Int64(frameCount)
        }
        guard reader.status == .completed else {
            throw reader.error ?? T8TestError.unreadableAudio
        }
        return T8DecodedAudio(frameCount: total, channels: channels)
    }

    static func visibleFileNames(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }

    static func checkpointSourceHashes(_ fixture: T8BundleFixture) throws -> [String: String] {
        try hashesOfCAFFiles(in: fixture.checkpointDirectory)
    }
}

enum T8TestError: Error {
    case missingAudioTrack
    case unreadableAudio
    case injectedFailure
}

@Suite(.serialized)
struct AudioTrackEncoderTests {
    private func encoder(
        root: URL,
        role: RecordingTrackRole,
        name: String = "encoded.m4a",
        sampleRate: Int = T8TestSupport.sampleRate,
        channelCount: Int = 1,
        bitRate: Int = 96_000
    ) throws -> AudioTrackEncoder {
        let directory = root.appendingPathComponent("encoded", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try AudioTrackEncoder(
            role: role,
            sampleRate: sampleRate,
            channelCount: channelCount,
            bitRate: bitRate,
            outputURL: directory.appendingPathComponent(name)
        )
    }

    @Test func threeCheckpointsOneM4APerRoleOneContext() async throws {
        let root = try T8TestSupport.makeRoot("encoder-three")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await T8TestSupport.makeBundle(
            sessionRoot: root,
            segmentEnd: 14_400,
            roles: [.mixed],
            chunks: [
                [T8Append(role: .mixed, startSample: 0, frameCount: 4_800)],
                [T8Append(role: .mixed, startSample: 4_800, frameCount: 4_800)],
                [T8Append(role: .mixed, startSample: 9_600, frameCount: 4_800)],
            ]
        )
        let encoder = try encoder(root: root, role: .mixed)
        try await encoder.beginSegment(0)
        for commit in fixture.commits {
            try await encoder.append(commit)
        }
        let result = try await encoder.finish()

        #expect(await encoder.contextStartCount == 1)
        #expect(result.role == .mixed)
        #expect(result.effectiveRange == SampleRange(startSample: 0, sampleCount: 14_400))
        #expect(result.insertedSilenceFrames == 0)
        #expect(try T8TestSupport.visibleFileNames(in: root.appendingPathComponent("encoded")) == ["encoded.m4a"])
        #expect(try T8TestSupport.validFrameCount(of: result.url) == 14_400)
        let decoded = try await T8TestSupport.decode(result.url)
        #expect(decoded.frameCount == 14_400)
        #expect(decoded.meanAbsolute(channel: 0, start: 0, count: 14_400) > 0.05)
    }

    @Test func singleTrackOnlyMixed() async throws {
        let root = try T8TestSupport.makeRoot("encoder-single-matrix")
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = try T8TestSupport.makeDirectory("destination", in: root)
        let fixture = try await T8TestSupport.makeBundle(
            sessionRoot: root,
            segmentEnd: 4_800,
            roles: [.mixed],
            chunks: [[T8Append(role: .mixed, startSample: 0, frameCount: 4_800)]]
        )
        let context = RecordingSealContext(
            sessionID: UUID(),
            kind: .audio,
            layout: .mixed,
            sampleRate: T8TestSupport.sampleRate,
            outputStem: "take",
            destinationDirectory: destination
        )
        let sealed = try await RecordingSealService().seal(
            fixture.bundle,
            videoChunks: [],
            segmentID: UUID(),
            context: context
        )

        #expect(Set(sealed.files.keys) == [.mixed])
        #expect(sealed.manifestURL == nil)
        #expect(try T8TestSupport.visibleFileNames(in: destination) == ["take-00.m4a"])
        #expect(try T8TestSupport.visibleFileNames(in: root.appendingPathComponent("checkpoints")).count == 2)
    }

    @Test func separateTracksOnlySystemAndMic() async throws {
        let root = try T8TestSupport.makeRoot("encoder-separate-matrix")
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = try T8TestSupport.makeDirectory("destination", in: root)
        let fixture = try await T8TestSupport.makeBundle(
            sessionRoot: root,
            segmentEnd: 4_800,
            roles: [.system, .microphone],
            chunks: [
                [
                    T8Append(role: .system, startSample: 0, frameCount: 4_800, amplitude: 0.6),
                    T8Append(role: .microphone, startSample: 0, frameCount: 4_800, amplitude: 0.4),
                ],
            ]
        )
        let context = RecordingSealContext(
            sessionID: UUID(),
            kind: .audio,
            layout: .separateTracks,
            sampleRate: T8TestSupport.sampleRate,
            outputStem: "take",
            destinationDirectory: destination
        )
        let sealed = try await RecordingSealService().seal(
            fixture.bundle,
            videoChunks: [],
            segmentID: UUID(),
            context: context
        )

        #expect(Set(sealed.files.keys) == [.system, .microphone])
        #expect(sealed.files[.system]?.lastPathComponent == "system.m4a")
        #expect(sealed.files[.microphone]?.lastPathComponent == "mic.m4a")
        #expect(sealed.files[.mixed] == nil)
        let systemURL = try #require(sealed.files[.system])
        #expect(try T8TestSupport.visibleFileNames(in: systemURL.deletingLastPathComponent()) == [
            "manifest.json",
            "mic.m4a",
            "system.m4a",
        ])
    }

    @Test func aacTrimMetadataRoundTrips() async throws {
        let root = try T8TestSupport.makeRoot("encoder-trim")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await T8TestSupport.makeBundle(
            sessionRoot: root,
            segmentEnd: 14_400,
            roles: [.mixed],
            chunks: [
                [T8Append(role: .mixed, startSample: 0, frameCount: 4_800)],
                [T8Append(role: .mixed, startSample: 4_800, frameCount: 4_800)],
                [T8Append(role: .mixed, startSample: 9_600, frameCount: 4_800)],
            ]
        )
        let encoder = try encoder(root: root, role: .mixed)
        try await encoder.beginSegment(0)
        for commit in fixture.commits {
            try await encoder.append(commit)
        }
        let result = try await encoder.finish()
        let verification = try #require(await encoder.verification)

        #expect(result.primingFrames > 0)
        #expect(result.remainderFrames >= 0)
        #expect(result.insertedSilenceFrames == 0)
        #expect(verification.encodedPacketCount > 0)
        #expect(verification.decodedFrameCount == result.effectiveRange.sampleCount)
        #expect(verification.validFrameCount == result.effectiveRange.sampleCount)
        #expect(try T8TestSupport.validFrameCount(of: result.url) == result.effectiveRange.sampleCount)

        let record = SegmentPortableRecord(
            sessionID: UUID(),
            segmentID: UUID(),
            segmentIndex: 0,
            kind: "audio",
            layout: "mixed",
            sampleRate: T8TestSupport.sampleRate,
            startSample: result.effectiveRange.startSample,
            sampleCount: result.effectiveRange.sampleCount,
            tracks: [
                SegmentPortableRecord.Track(
                    role: "mixed",
                    channelCount: 1,
                    fileName: "take-00.m4a",
                    validRange: RecordingSampleRange(
                        startSample: result.effectiveRange.startSample,
                        sampleCount: result.effectiveRange.sampleCount
                    ),
                    primingFrames: result.primingFrames,
                    remainderFrames: result.remainderFrames,
                    insertedSilenceFrames: result.insertedSilenceFrames,
                    encodedPacketCount: verification.encodedPacketCount,
                    decodedFrameCount: verification.decodedFrameCount
                ),
            ],
            missingRanges: []
        )
        let metadataURL = root.appendingPathComponent("metadata.m4a")
        try await SegmentPortableMetadata.embed(record, from: result.url, to: metadataURL)
        let readBack = try await SegmentPortableMetadata.read(from: metadataURL)
        #expect(readBack == record)

        let items = try await AVURLAsset(url: metadataURL).load(.metadata)
        let markerPresent = items.contains { item in
            guard let string = item.value as? String else { return false }
            return string.hasPrefix(SegmentPortableMetadata.marker)
        }
        #expect(markerPresent)
    }

    @Test func audioContextDoesNotRestartAtCheckpoint() async throws {
        let root = try T8TestSupport.makeRoot("encoder-context")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await T8TestSupport.makeBundle(
            sessionRoot: root,
            segmentEnd: 14_400,
            roles: [.mixed],
            chunks: [
                [T8Append(role: .mixed, startSample: 0, frameCount: 4_800)],
                [T8Append(role: .mixed, startSample: 4_800, frameCount: 4_800)],
                [T8Append(role: .mixed, startSample: 9_600, frameCount: 4_800)],
            ]
        )
        let encoder = try encoder(root: root, role: .mixed)
        try await encoder.beginSegment(0)
        for (index, commit) in fixture.commits.enumerated() {
            try await encoder.append(commit)
            #expect(await encoder.contextStartCount == 1, "context restarted after checkpoint \(index)")
            #expect(try T8TestSupport.visibleFileNames(in: root.appendingPathComponent("encoded")) == [
                "encoded.m4a"
            ])
        }
        _ = try await encoder.finish()
        #expect(await encoder.contextStartCount == 1)
    }

    @Test func coverageMissingRangeIsSilencedWithoutTimelineShift() async throws {
        let root = try T8TestSupport.makeRoot("encoder-silence")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await T8TestSupport.makeBundle(
            sessionRoot: root,
            segmentEnd: 9_600,
            roles: [.system, .microphone],
            chunks: [
                [
                    T8Append(role: .system, startSample: 0, frameCount: 4_800, amplitude: 0.6),
                    T8Append(role: .microphone, startSample: 0, frameCount: 4_800, amplitude: 0.4),
                ],
                [T8Append(role: .system, startSample: 4_800, frameCount: 4_800, amplitude: 0.6)],
            ]
        )
        let microphoneCoverage = try #require(fixture.bundle.coverage.tracks.first { $0.role == "microphone" })
        #expect(microphoneCoverage.missingRanges == [
            RecordingSampleRange(startSample: 4_800, sampleCount: 4_800)
        ])

        let systemEncoder = try encoder(root: root, role: .system, name: "system.m4a")
        try await systemEncoder.beginSegment(0)
        for commit in fixture.commits {
            try await systemEncoder.append(commit)
        }
        let systemResult = try await systemEncoder.finish()

        let microphoneEncoder = try encoder(root: root, role: .microphone, name: "mic.m4a")
        try await microphoneEncoder.beginSegment(0)
        try await microphoneEncoder.append(fixture.commits[0])
        try await microphoneEncoder.appendSilence(frames: 4_800)
        let microphoneResult = try await microphoneEncoder.finish()

        #expect(systemResult.effectiveRange == SampleRange(startSample: 0, sampleCount: 9_600))
        #expect(microphoneResult.effectiveRange == SampleRange(startSample: 0, sampleCount: 9_600))
        #expect(systemResult.insertedSilenceFrames == 0)
        #expect(microphoneResult.insertedSilenceFrames == 4_800)

        let decodedSystem = try await T8TestSupport.decode(systemResult.url)
        let decodedMicrophone = try await T8TestSupport.decode(microphoneResult.url)
        #expect(decodedSystem.frameCount == 9_600)
        #expect(decodedMicrophone.frameCount == 9_600)
        #expect(decodedMicrophone.meanAbsolute(channel: 0, start: 0, count: 4_800) > 0.05)
        #expect(decodedMicrophone.meanAbsolute(channel: 0, start: 4_800, count: 4_800) < 0.01)
        #expect(decodedSystem.meanAbsolute(channel: 0, start: 4_800, count: 4_800) > 0.05)
    }

    @Test func neverActiveRoleProducesNoTrack() async throws {
        let root = try T8TestSupport.makeRoot("encoder-never-active")
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = try T8TestSupport.makeDirectory("destination", in: root)
        let fixture = try await T8TestSupport.makeBundle(
            sessionRoot: root,
            segmentEnd: 4_800,
            roles: [.system, .microphone],
            chunks: [[T8Append(role: .system, startSample: 0, frameCount: 4_800)]]
        )
        let microphoneCoverage = try #require(fixture.bundle.coverage.tracks.first { $0.role == "microphone" })
        #expect(microphoneCoverage.wasActive == false)
        #expect(microphoneCoverage.channelCount == 0)

        let context = RecordingSealContext(
            sessionID: UUID(),
            kind: .audio,
            layout: .separateTracks,
            sampleRate: T8TestSupport.sampleRate,
            outputStem: "take",
            destinationDirectory: destination
        )
        let sealed = try await RecordingSealService().seal(
            fixture.bundle,
            videoChunks: [],
            segmentID: UUID(),
            context: context
        )
        #expect(Set(sealed.files.keys) == [.system])
        #expect(try T8TestSupport.visibleFileNames(in: destination) == ["take-00"])
        let directory = try #require(sealed.manifestURL?.deletingLastPathComponent())
        #expect(Set(try T8TestSupport.visibleFileNames(in: directory)) == ["manifest.json", "system.m4a"])
    }

    @Test func encoderRejectsInvalidRoleOrFormat() async throws {
        let root = try T8TestSupport.makeRoot("encoder-validation")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("encoded"), withIntermediateDirectories: true
        )
        let output = root.appendingPathComponent("encoded/out.m4a")

        #expect(throws: AudioTrackEncoderError.invalidFormat) {
            _ = try AudioTrackEncoder(
                role: .mixed, sampleRate: 0, channelCount: 1, bitRate: 96_000, outputURL: output
            )
        }
        #expect(throws: AudioTrackEncoderError.invalidFormat) {
            _ = try AudioTrackEncoder(
                role: .mixed, sampleRate: 48_000, channelCount: 3, bitRate: 96_000, outputURL: output
            )
        }
        #expect(throws: AudioTrackEncoderError.invalidFormat) {
            _ = try AudioTrackEncoder(
                role: .mixed, sampleRate: 48_000, channelCount: 1, bitRate: 0, outputURL: output
            )
        }
        #expect(throws: AudioTrackEncoderError.invalidFormat) {
            _ = try AudioTrackEncoder(
                role: .mixed, sampleRate: 48_000, channelCount: 1, bitRate: 96_000,
                outputURL: root.appendingPathComponent("encoded/out.wav")
            )
        }

        let fixture = try await T8TestSupport.makeBundle(
            sessionRoot: root,
            segmentEnd: 4_800,
            roles: [.mixed],
            chunks: [[T8Append(role: .mixed, startSample: 0, frameCount: 4_800)]]
        )
        let commit = try #require(fixture.commits.first)
        let unopened = try encoder(root: root, role: .mixed, name: "unopened.m4a")
        await #expect(throws: AudioTrackEncoderError.beginSegmentRequired) {
            try await unopened.append(commit)
        }
        await #expect(throws: AudioTrackEncoderError.beginSegmentRequired) {
            _ = try await unopened.finish()
        }

        let systemEncoder = try encoder(root: root, role: .system, name: "system.m4a")
        try await systemEncoder.beginSegment(0)
        await #expect(throws: AudioTrackEncoderError.roleNotInCheckpoint) {
            try await systemEncoder.append(commit)
        }
        await #expect(throws: AudioTrackEncoderError.segmentAlreadyBegun) {
            try await systemEncoder.beginSegment(0)
        }

        let wrongSegment = try encoder(root: root, role: .mixed, name: "wrong-segment.m4a")
        try await wrongSegment.beginSegment(1)
        await #expect(throws: AudioTrackEncoderError.segmentIndexMismatch) {
            try await wrongSegment.append(commit)
        }
    }
}
