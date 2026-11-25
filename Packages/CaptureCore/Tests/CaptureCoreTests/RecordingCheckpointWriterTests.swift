import AVFoundation
import Foundation
import Testing

@testable import CaptureCore

/// Shared fixtures for the Task 7 checkpoint writer and coordinator tests.
enum T7TestSupport {
    static func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapglass-t07-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func makeStaging(in root: URL, named name: String = "staging") throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    static func block(
        role: RecordingTrackRole,
        startSample: Int64,
        frameCount: Int,
        sampleRate: Int = 48_000,
        channelCount: Int = 1,
        values: [Float] = [0.5]
    ) -> AudioPCMBlock {
        let channelValues = (0..<channelCount).map { values[$0 % values.count] }
        let channels = channelValues.map { value in
            Array(repeating: value, count: frameCount)
        }
        return AudioPCMBlock(
            role: role,
            range: SampleRange(startSample: startSample, sampleCount: Int64(frameCount)),
            sampleRate: sampleRate,
            channelCount: channelCount,
            frameCount: frameCount,
            hostTime: 0,
            channels: channels,
            isSilence: channelValues.allSatisfy { $0 == 0 }
        )
    }
    static func sidecarURLs(in directory: URL) throws -> [URL] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        return
            names
            .filter { $0.hasPrefix("checkpoint-") && $0.hasSuffix(".json") }
            .sorted()
            .map { directory.appendingPathComponent($0) }
    }
    static func cafNames(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".caf") }
            .sorted()
    }
    static func sha256(of url: URL) throws -> String {
        try RecordingCheckpointSidecar.sha256(ofFileAt: url)
    }
    static func record(for commit: CheckpointCommit, in directory: URL) throws -> RecordingCheckpointRecord {
        let urls = try sidecarURLs(in: directory)
        let records = try urls.map { url in
            try RecordingCheckpointSidecar.decode(Data(contentsOf: url), path: url.path)
        }
        return try #require(
            records.first { $0.checkpointID == commit.checkpointID },
            "No sidecar for checkpoint \(commit.checkpointID)"
        )
    }
}
struct RecordingCheckpointWriterTests {
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
    private func makeWriter(
        root: URL,
        staging: URL,
        segment: SegmentBoundary,
        sampleRate: Int = 48_000,
        roles: Set<RecordingTrackRole> = [.mixed],
        durability: any RecordingDurabilityBarrier = SystemRecordingDurabilityBarrier(),
        faults: any RecordingCheckpointFaultInjecting = T7FaultInjector()
    ) throws -> RecordingCheckpointWriter {
        let capturedDate = fixedDate
        return try RecordingCheckpointWriter(
            directory: staging,
            sessionRoot: root,
            segment: segment,
            sampleRate: sampleRate,
            roles: roles,
            durability: durability,
            now: { capturedDate },
            faults: faults
        )
    }
    @Test func checkpointWritesOneContiguousCAFPerRoleWithGlobalRange() async throws {
        let root = try T7TestSupport.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = try T7TestSupport.makeStaging(in: root)
        let writer = try makeWriter(
            root: root,
            staging: staging,
            segment: SegmentBoundary(index: 1, startSample: 0, endSample: 48_000)
        )
        for offset in [Int64(0), 480, 960] {
            try await writer.append(T7TestSupport.block(role: .mixed, startSample: offset, frameCount: 480))
        }
        let commit = try await writer.commitCheckpoint()
        #expect(commit.segmentIndex == 1)
        #expect(commit.range == SampleRange(startSample: 0, sampleCount: 1_440))
        #expect(commit.committedAt == fixedDate)
        let url = try #require(commit.trackURLs[.mixed])
        #expect(url.lastPathComponent == "mixed-0001.caf")
        #expect(url.deletingLastPathComponent().lastPathComponent == "staging")
        let caf = try T7TestSupport.readCAF(at: url)
        #expect(caf.sampleRate == 48_000)
        #expect(caf.channelCount == 1)
        #expect(caf.frames == 1_440)
        #expect(caf.bitDepth == 16)
        #expect(caf.isFloat == false)
        let record = try T7TestSupport.record(for: commit, in: staging)
        #expect(record.schemaVersion == RecordingCheckpointRecord.currentSchemaVersion)
        #expect(record.startSample == 0)
        #expect(record.sampleCount == 1_440)
        let track = try #require(record.tracks.first)
        #expect(track.role == "mixed")
        #expect(track.fileName == "mixed-0001.caf")
        #expect(track.sampleRate == 48_000)
        #expect(track.channelCount == 1)
        #expect(track.frameCount == 1_440)
        #expect(track.writerSynthesizedSilenceFrames == 0)
        let fileSize = try #require(
            FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        )
        #expect(track.byteCount == fileSize.int64Value)
        #expect(track.sha256 == (try T7TestSupport.sha256(of: url)))
    }
    @Test func checkpointCommitIsIdempotentWithoutNewSamples() async throws {
        let root = try T7TestSupport.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = try T7TestSupport.makeStaging(in: root)
        let writer = try makeWriter(
            root: root,
            staging: staging,
            segment: SegmentBoundary(index: 0, startSample: 0, endSample: 48_000)
        )
        try await writer.append(T7TestSupport.block(role: .mixed, startSample: 0, frameCount: 480))
        let first = try await writer.commitCheckpoint()
        let filesAfterFirstCommit = try T7TestSupport.cafNames(in: staging)
        let second = try await writer.commitCheckpoint()
        #expect(second == first)
        #expect(try T7TestSupport.cafNames(in: staging) == filesAfterFirstCommit)
        #expect(try T7TestSupport.sidecarURLs(in: staging).count == 1)
    }
    @Test func appendRejectsForwardGapWithoutAdvancing() async throws {
        let root = try T7TestSupport.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = try T7TestSupport.makeStaging(in: root)
        let writer = try makeWriter(
            root: root,
            staging: staging,
            segment: SegmentBoundary(index: 0, startSample: 0, endSample: 48_000)
        )
        try await writer.append(T7TestSupport.block(role: .mixed, startSample: 0, frameCount: 480))
        await #expect(
            throws: RecordingCheckpointError.nonContiguousRange(expectedStart: 480, actualStart: 960)
        ) {
            try await writer.append(T7TestSupport.block(role: .mixed, startSample: 960, frameCount: 480))
        }
        try await writer.append(T7TestSupport.block(role: .mixed, startSample: 480, frameCount: 480))
        let commit = try await writer.commitCheckpoint()
        #expect(commit.range == SampleRange(startSample: 0, sampleCount: 960))
        let url = try #require(commit.trackURLs[.mixed])
        #expect(try T7TestSupport.readCAF(at: url).frames == 960)
        let stats = await writer.statistics()
        #expect(stats.appendedFramesByRole[.mixed] == 960)
        #expect(stats.writerSynthesizedSilenceFramesByRole[.mixed] == 0)
        #expect(stats.committedFramesByRole[.mixed] == 960)
    }
    @Test func partialRoleWriteNeverReturnsCommit() async throws {
        let root = try T7TestSupport.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = try T7TestSupport.makeStaging(in: root)
        let roles: Set<RecordingTrackRole> = [.system, .microphone]
        let writer = try makeWriter(
            root: root,
            staging: staging,
            segment: SegmentBoundary(index: 0, startSample: 0, endSample: 48_000),
            sampleRate: 8_000,
            roles: roles
        )
        try await writer.append(T7TestSupport.block(role: .system, startSample: 0, frameCount: 480, sampleRate: 8_000))
        let firstCommit = try await writer.commitCheckpoint()
        #expect(firstCommit.range == SampleRange(startSample: 0, sampleCount: 480))
        var faults = T7FaultInjector()
        faults.failWrite = [.microphone]
        let failingWriter = try makeWriter(
            root: root,
            staging: staging,
            segment: SegmentBoundary(index: 0, startSample: 480, endSample: 48_000),
            sampleRate: 8_000,
            roles: roles,
            faults: faults
        )
        try await failingWriter.append(
            T7TestSupport.block(role: .system, startSample: 480, frameCount: 480, sampleRate: 8_000)
        )
        await #expect(throws: RecordingCheckpointError.self) {
            try await failingWriter.append(
                T7TestSupport.block(role: .microphone, startSample: 480, frameCount: 480, sampleRate: 8_000)
            )
        }
        await #expect(throws: RecordingCheckpointError.self) {
            _ = try await failingWriter.commitCheckpoint()
        }
        #expect(try T7TestSupport.cafNames(in: staging) == ["system-0001.caf", "system-0002.caf"])
        let retainedURL = staging.appendingPathComponent("system-0002.caf")
        let retainedHash = try T7TestSupport.sha256(of: retainedURL)
        let retryWriter = try makeWriter(
            root: root,
            staging: staging,
            segment: SegmentBoundary(index: 0, startSample: 480, endSample: 48_000),
            sampleRate: 8_000,
            roles: roles
        )
        try await retryWriter.append(
            T7TestSupport.block(role: .system, startSample: 480, frameCount: 480, sampleRate: 8_000)
        )
        try await retryWriter.append(
            T7TestSupport.block(role: .microphone, startSample: 480, frameCount: 480, sampleRate: 8_000)
        )
        let retryCommit = try await retryWriter.commitCheckpoint()
        #expect(retryCommit.range == SampleRange(startSample: 480, sampleCount: 480))
        #expect(try T7TestSupport.sha256(of: retainedURL) == retainedHash)
        #expect(
            try T7TestSupport.cafNames(in: staging) == [
                "mic-0003.caf",
                "system-0001.caf",
                "system-0002.caf",
                "system-0003.caf",
            ])
        let retryRecord = try T7TestSupport.record(for: retryCommit, in: staging)
        #expect(!retryRecord.tracks.contains { $0.fileName == "system-0002.caf" })
    }
    @Test func finishSegmentIsIdempotentAndRejectsAppend() async throws {
        let root = try T7TestSupport.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = try T7TestSupport.makeStaging(in: root)
        let writer = try makeWriter(
            root: root,
            staging: staging,
            segment: SegmentBoundary(index: 0, startSample: 0, endSample: 48_000)
        )
        try await writer.append(T7TestSupport.block(role: .mixed, startSample: 0, frameCount: 480))
        let first = try await writer.finishSegment()
        let second = try await writer.finishSegment()
        #expect(first == second)
        #expect(first.checkpoints.count == 1)
        #expect(first.checkpoints.first?.range == SampleRange(startSample: 0, sampleCount: 480))
        await #expect(throws: RecordingCheckpointError.segmentClosed) {
            try await writer.append(T7TestSupport.block(role: .mixed, startSample: 480, frameCount: 480))
        }
        await #expect(throws: RecordingCheckpointError.segmentClosed) {
            _ = try await writer.commitCheckpoint()
        }
    }

    @Test func existingCAFNameSymlinkFailsClosedWithoutTouchingOutsideTarget() async throws {
        for variant in ["dangling", "live"] {
            let fixture = try T7TestSupport.makeRoot()
            defer { try? FileManager.default.removeItem(at: fixture) }
            let sessionRoot = fixture.appendingPathComponent("session", isDirectory: true)
            let staging = sessionRoot.appendingPathComponent("staging", isDirectory: true)
            let outside = fixture.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let target = outside.appendingPathComponent("victim.caf")
            let sentinel = Data("sentinel".utf8)
            if variant == "live" {
                try sentinel.write(to: target)
            }
            try FileManager.default.createSymbolicLink(
                at: staging.appendingPathComponent("mixed-0001.caf"),
                withDestinationURL: target
            )
            let writer = try makeWriter(
                root: sessionRoot,
                staging: staging,
                segment: SegmentBoundary(index: 0, startSample: 0, endSample: 8_000),
                sampleRate: 8_000
            )
            let error = await T7TestSupport.captureError {
                try await writer.append(
                    T7TestSupport.block(role: .mixed, startSample: 0, frameCount: 480, sampleRate: 8_000)
                )
            }
            #expect(error == RecordingCheckpointError.pathEscapesSessionRoot)
            if variant == "live" {
                #expect(try Data(contentsOf: target) == sentinel)
            } else {
                #expect(!FileManager.default.fileExists(atPath: target.path))
            }
        }
    }

    @Test func checksumAndSchemaRoundTrip() async throws {
        let root = try T7TestSupport.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = try T7TestSupport.makeStaging(in: root)
        let writer = try makeWriter(
            root: root,
            staging: staging,
            segment: SegmentBoundary(index: 0, startSample: 0, endSample: 48_000)
        )
        try await writer.append(T7TestSupport.block(role: .mixed, startSample: 0, frameCount: 480))
        let commit = try await writer.commitCheckpoint()

        let sidecarURL = try #require(try T7TestSupport.sidecarURLs(in: staging).first)
        let data = try Data(contentsOf: sidecarURL)
        let record = try RecordingCheckpointSidecar.decode(data, path: sidecarURL.path)
        let encoded = try RecordingCheckpointSidecar.encode(record)
        let roundTripped = try RecordingCheckpointSidecar.decode(encoded, path: sidecarURL.path)
        #expect(roundTripped == record)
        #expect(record.checkpointID == commit.checkpointID)

        try RecordingCheckpointSidecar.verify(record: record, tracksDirectory: staging)

        let cafURL = try #require(commit.trackURLs[.mixed])
        let handle = try FileHandle(forWritingTo: cafURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x00]))
        try handle.close()
        #expect(throws: RecordingCheckpointError.verificationFailed(path: cafURL.path)) {
            try RecordingCheckpointSidecar.verify(record: record, tracksDirectory: staging)
        }

        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var mutated = json
        mutated["schemaVersion"] = 2
        let unknownData = try JSONSerialization.data(withJSONObject: mutated)
        #expect(throws: RecordingCheckpointError.verificationFailed(path: sidecarURL.path)) {
            try RecordingCheckpointSidecar.decode(unknownData, path: sidecarURL.path)
        }
    }

    @Test func pathEscapingSessionRootFailsClosed() throws {
        let root = try T7TestSupport.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = try T7TestSupport.makeRoot()
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = root.appendingPathComponent("escape", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let candidates = [
            root.appendingPathComponent("../outside", isDirectory: true),
            outside,
            link,
        ]
        for candidate in candidates {
            #expect(throws: RecordingCheckpointError.pathEscapesSessionRoot) {
                _ = try RecordingCheckpointWriter(
                    directory: candidate,
                    sessionRoot: root,
                    segment: SegmentBoundary(index: 0, startSample: 0, endSample: 1_000),
                    sampleRate: 48_000,
                    roles: [.mixed]
                )
            }
        }
    }

    @Test func blockFormatMismatchFailsClosed() async throws {
        let root = try T7TestSupport.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = try T7TestSupport.makeStaging(in: root)
        let writer = try makeWriter(
            root: root,
            staging: staging,
            segment: SegmentBoundary(index: 0, startSample: 0, endSample: 1_920)
        )

        await #expect(throws: RecordingCheckpointError.incompatibleFormat(role: .system)) {
            try await writer.append(T7TestSupport.block(role: .system, startSample: 0, frameCount: 480))
        }
        await #expect(throws: RecordingCheckpointError.incompatibleFormat(role: .mixed)) {
            try await writer.append(
                T7TestSupport.block(role: .mixed, startSample: 0, frameCount: 480, sampleRate: 44_100)
            )
        }
        try await writer.append(T7TestSupport.block(role: .mixed, startSample: 0, frameCount: 480))
        await #expect(throws: RecordingCheckpointError.incompatibleFormat(role: .mixed)) {
            try await writer.append(
                T7TestSupport.block(
                    role: .mixed,
                    startSample: 480,
                    frameCount: 480,
                    channelCount: 2,
                    values: [0.5, 0.25]
                )
            )
        }
        await #expect(throws: RecordingCheckpointError.blockOutsideSegment) {
            try await writer.append(T7TestSupport.block(role: .mixed, startSample: 1_920, frameCount: 480))
        }
        await #expect(throws: RecordingCheckpointError.blockOutsideSegment) {
            try await writer.append(T7TestSupport.block(role: .mixed, startSample: 1_680, frameCount: 480))
        }

        let commit = try await writer.commitCheckpoint()
        #expect(commit.range == SampleRange(startSample: 0, sampleCount: 480))
        let url = try #require(commit.trackURLs[.mixed])
        #expect(try T7TestSupport.readCAF(at: url).frames == 480)
        #expect(try T7TestSupport.sidecarURLs(in: staging).count == 1)
    }

}

extension RecordingCheckpointWriterTests {
    @Test func closedCAFReadsBackDeclaredRateFramesSamples() async throws {
        let root = try T7TestSupport.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = try T7TestSupport.makeStaging(in: root)
        let writer = try makeWriter(
            root: root,
            staging: staging,
            segment: SegmentBoundary(index: 0, startSample: 0, endSample: 8_000),
            sampleRate: 8_000
        )
        let block = T7TestSupport.block(
            role: .mixed,
            startSample: 0,
            frameCount: 240,
            sampleRate: 8_000,
            channelCount: 2,
            values: [0.5, -0.25]
        )
        try await writer.append(block)
        let commit = try await writer.commitCheckpoint()
        let url = try #require(commit.trackURLs[.mixed])
        let caf = try T7TestSupport.readCAF(at: url)

        #expect(caf.sampleRate == 8_000)
        #expect(caf.channelCount == 2)
        #expect(caf.frames == 240)
        #expect(caf.bitDepth == 16)
        #expect(caf.isFloat == false)
        #expect(caf.channels.count == 2)
        for frame in [0, 119, 239] {
            #expect(abs(caf.channels[0][frame] - 0.5) < 0.0001)
            #expect(abs(caf.channels[1][frame] - (-0.25)) < 0.0001)
        }
    }

    @Test func emptySegmentProducesNoFiles() async throws {
        let root = try T7TestSupport.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = try T7TestSupport.makeStaging(in: root)
        let writer = try makeWriter(
            root: root,
            staging: staging,
            segment: SegmentBoundary(index: 0, startSample: 0, endSample: 48_000)
        )

        let bundle = try await writer.finishSegmentBundle()
        let set = try await writer.finishSegment()

        #expect(set.checkpoints.isEmpty)
        #expect(bundle.checkpoints == set)
        #expect(bundle.coverage.segmentIndex == 0)
        #expect(bundle.coverage.segmentStartSample == 0)
        #expect(bundle.coverage.segmentEndSample == 0)
        #expect(bundle.coverage.tracks.count == 1)
        let track = try #require(bundle.coverage.tracks.first)
        #expect(track.role == "mixed")
        #expect(track.wasActive == false)
        #expect(track.firstSample == nil)
        #expect(track.lastSample == nil)
        #expect(track.missingRanges.isEmpty)
        #expect(try T7TestSupport.cafNames(in: staging).isEmpty)
        #expect(try T7TestSupport.sidecarURLs(in: staging).isEmpty)
    }

    @Test func roleFirstAppearingMidChunkGetsPrefixSilenceAndSameRange() async throws {
        let root = try T7TestSupport.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = try T7TestSupport.makeStaging(in: root)
        let writer = try makeWriter(
            root: root,
            staging: staging,
            segment: SegmentBoundary(index: 0, startSample: 0, endSample: 8_000),
            sampleRate: 8_000,
            roles: [.system]
        )

        try await writer.append(
            T7TestSupport.block(role: .system, startSample: 480, frameCount: 480, sampleRate: 8_000)
        )
        let commit = try await writer.commitCheckpoint()
        #expect(commit.range == SampleRange(startSample: 0, sampleCount: 960))

        let url = try #require(commit.trackURLs[.system])
        let caf = try T7TestSupport.readCAF(at: url)
        #expect(caf.frames == 960)
        #expect(abs(caf.channels[0][0]) < 0.0001)
        #expect(abs(caf.channels[0][479]) < 0.0001)
        #expect(abs(caf.channels[0][480] - 0.5) < 0.0001)
        #expect(abs(caf.channels[0][959] - 0.5) < 0.0001)

        let bundle = try await writer.finishSegmentBundle()
        let coverage = try #require(bundle.coverage.tracks.first)
        #expect(coverage.role == "system")
        #expect(coverage.wasActive)
        #expect(coverage.firstSample == 0)
        #expect(coverage.lastSample == 960)
        #expect(coverage.missingRanges.isEmpty)

        let record = try T7TestSupport.record(for: commit, in: staging)
        #expect(record.startSample == 0)
        #expect(record.sampleCount == 960)
        #expect(record.tracks.first?.writerSynthesizedSilenceFrames == 480)
    }

    @Test func neverActiveRoleProducesNoTrackOrFile() async throws {
        let root = try T7TestSupport.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = try T7TestSupport.makeStaging(in: root)
        let writer = try makeWriter(
            root: root,
            staging: staging,
            segment: SegmentBoundary(index: 0, startSample: 0, endSample: 48_000),
            roles: [.mixed, .system]
        )
        try await writer.append(T7TestSupport.block(role: .mixed, startSample: 0, frameCount: 480))
        let commit = try await writer.commitCheckpoint()

        #expect(Set(commit.trackURLs.keys) == [.mixed])
        #expect(try T7TestSupport.cafNames(in: staging) == ["mixed-0001.caf"])
        let record = try T7TestSupport.record(for: commit, in: staging)
        #expect(record.tracks.map(\.role) == ["mixed"])

        let bundle = try await writer.finishSegmentBundle()
        let system = try #require(bundle.coverage.tracks.first { $0.role == "system" })
        #expect(system.wasActive == false)
        #expect(system.firstSample == nil)
        #expect(system.lastSample == nil)
        #expect(system.missingRanges == [RecordingSampleRange(startSample: 0, sampleCount: 480)])
    }

    @Test func statsCountInputPlusSynthesizedSilence() async throws {
        let root = try T7TestSupport.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = try T7TestSupport.makeStaging(in: root)
        let writer = try makeWriter(
            root: root,
            staging: staging,
            segment: SegmentBoundary(index: 0, startSample: 0, endSample: 8_000),
            sampleRate: 8_000,
            roles: [.mixed, .system]
        )

        try await writer.append(T7TestSupport.block(role: .mixed, startSample: 0, frameCount: 480, sampleRate: 8_000))
        try await writer.append(T7TestSupport.block(role: .mixed, startSample: 480, frameCount: 480, sampleRate: 8_000))
        try await writer.append(
            T7TestSupport.block(role: .system, startSample: 480, frameCount: 480, sampleRate: 8_000)
        )
        let commit = try await writer.commitCheckpoint()
        #expect(commit.range == SampleRange(startSample: 0, sampleCount: 960))

        let stats = await writer.statistics()
        for role in [RecordingTrackRole.mixed, .system] {
            let committed = try #require(stats.committedFramesByRole[role])
            let appended = try #require(stats.appendedFramesByRole[role])
            let silence = try #require(stats.writerSynthesizedSilenceFramesByRole[role])
            #expect(committed == appended + silence)
            #expect(committed == 960)
        }
        #expect(stats.appendedFramesByRole[.mixed] == 960)
        #expect(stats.writerSynthesizedSilenceFramesByRole[.mixed] == 0)
        #expect(stats.appendedFramesByRole[.system] == 480)
        #expect(stats.writerSynthesizedSilenceFramesByRole[.system] == 480)
    }

    @Test func roleStopsMidSegmentCoverageHasExplicitMissingRange() async throws {
        let root = try T7TestSupport.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = try T7TestSupport.makeStaging(in: root)
        let writer = try makeWriter(
            root: root,
            staging: staging,
            segment: SegmentBoundary(index: 0, startSample: 0, endSample: 1_920),
            sampleRate: 8_000,
            roles: [.mixed, .system]
        )

        try await writer.append(T7TestSupport.block(role: .system, startSample: 0, frameCount: 960, sampleRate: 8_000))
        _ = try await writer.commitCheckpoint()
        try await writer.append(
            T7TestSupport.block(role: .mixed, startSample: 960, frameCount: 960, sampleRate: 8_000)
        )
        let secondCommit = try await writer.commitCheckpoint()
        #expect(secondCommit.range == SampleRange(startSample: 960, sampleCount: 960))

        let bundle = try await writer.finishSegmentBundle()
        #expect(bundle.coverage.segmentStartSample == 0)
        #expect(bundle.coverage.segmentEndSample == 1_920)
        let system = try #require(bundle.coverage.tracks.first { $0.role == "system" })
        #expect(system.wasActive)
        #expect(system.lastSample == 960)
        #expect(system.missingRanges == [RecordingSampleRange(startSample: 960, sampleCount: 960)])
        let mixed = try #require(bundle.coverage.tracks.first { $0.role == "mixed" })
        #expect(mixed.firstSample == 960)
        #expect(mixed.missingRanges == [RecordingSampleRange(startSample: 0, sampleCount: 960)])
    }

    @Test func finalShortSegmentCoverageUsesActualEnd() async throws {
        let root = try T7TestSupport.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = try T7TestSupport.makeStaging(in: root)
        let writer = try makeWriter(
            root: root,
            staging: staging,
            segment: SegmentBoundary(
                index: 3,
                startSample: 0,
                endSample: RecordingSegmentPolicy.maximumSegmentSamples
            )
        )
        try await writer.append(T7TestSupport.block(role: .mixed, startSample: 0, frameCount: 100))
        let bundle = try await writer.finishSegmentBundle()

        #expect(bundle.coverage.segmentEndSample == 100)
        #expect(bundle.coverage.segmentEndSample != RecordingSegmentPolicy.maximumSegmentSamples)
        let track = try #require(bundle.coverage.tracks.first)
        #expect(track.lastSample == 100)
        #expect(track.missingRanges.isEmpty)
        #expect(bundle.checkpoints.checkpoints.first?.range == SampleRange(startSample: 0, sampleCount: 100))
    }

    @Test func silencePrefixIsBoundedByCurrentChunk() async throws {
        let root = try T7TestSupport.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = try T7TestSupport.makeStaging(in: root)
        let writer = try makeWriter(
            root: root,
            staging: staging,
            segment: SegmentBoundary(index: 0, startSample: 0, endSample: 1_920),
            sampleRate: 8_000,
            roles: [.system, .mixed]
        )

        try await writer.append(T7TestSupport.block(role: .system, startSample: 0, frameCount: 480, sampleRate: 8_000))
        _ = try await writer.commitCheckpoint()
        try await writer.append(
            T7TestSupport.block(role: .mixed, startSample: 960, frameCount: 240, sampleRate: 8_000)
        )
        let commit = try await writer.commitCheckpoint()

        #expect(commit.range == SampleRange(startSample: 480, sampleCount: 720))
        let url = try #require(commit.trackURLs[.mixed])
        #expect(url.lastPathComponent == "mixed-0002.caf")
        let caf = try T7TestSupport.readCAF(at: url)
        #expect(caf.frames == 720)
        #expect(abs(caf.channels[0][0]) < 0.0001)
        #expect(abs(caf.channels[0][479]) < 0.0001)
        #expect(abs(caf.channels[0][480] - 0.5) < 0.0001)

        let record = try T7TestSupport.record(for: commit, in: staging)
        #expect(record.startSample == 480)
        #expect(record.sampleCount == 720)
        #expect(record.tracks.first?.writerSynthesizedSilenceFrames == 480)

        let bundle = try await writer.finishSegmentBundle()
        let mixed = try #require(bundle.coverage.tracks.first { $0.role == "mixed" })
        #expect(mixed.firstSample == 480)
        #expect(mixed.missingRanges.first == RecordingSampleRange(startSample: 0, sampleCount: 480))
    }

    @Test func participantTailMismatchNeverPartiallyCommits() async throws {
        let root = try T7TestSupport.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = try T7TestSupport.makeStaging(in: root)
        let writer = try makeWriter(
            root: root,
            staging: staging,
            segment: SegmentBoundary(index: 0, startSample: 0, endSample: 960),
            sampleRate: 8_000,
            roles: [.mixed, .system]
        )

        try await writer.append(T7TestSupport.block(role: .mixed, startSample: 0, frameCount: 480, sampleRate: 8_000))
        try await writer.append(T7TestSupport.block(role: .system, startSample: 0, frameCount: 240, sampleRate: 8_000))
        await #expect(throws: RecordingCheckpointError.trackRangesDoNotMatch) {
            _ = try await writer.commitCheckpoint()
        }
        #expect(try T7TestSupport.sidecarURLs(in: staging).isEmpty)
        #expect(try T7TestSupport.cafNames(in: staging) == ["mixed-0001.caf", "system-0001.caf"])

        try await writer.append(
            T7TestSupport.block(role: .system, startSample: 240, frameCount: 240, sampleRate: 8_000)
        )
        let commit = try await writer.commitCheckpoint()
        #expect(commit.range == SampleRange(startSample: 0, sampleCount: 480))
    }

    @Test func injectedCommitFaultsFailClosedWithoutCommit() async throws {
        let scenarios: [(name: String, faults: T7FaultInjector)] = [
            ("close", T7FaultInjector(failClose: [.mixed])),
            ("file-sync", T7FaultInjector(failFileSync: [.mixed])),
            ("rename", T7FaultInjector(failSidecarRename: true)),
            ("directory-sync", T7FaultInjector(failDirectorySync: true)),
        ]

        for scenario in scenarios {
            let root = try T7TestSupport.makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let staging = try T7TestSupport.makeStaging(in: root)
            let writer = try makeWriter(
                root: root,
                staging: staging,
                segment: SegmentBoundary(index: 0, startSample: 0, endSample: 8_000),
                sampleRate: 8_000,
                faults: scenario.faults
            )
            try await writer.append(
                T7TestSupport.block(role: .mixed, startSample: 0, frameCount: 480, sampleRate: 8_000)
            )
            let error = await T7TestSupport.captureError {
                _ = try await writer.commitCheckpoint()
            }
            switch (scenario.name, error) {
            case ("close", .some(.writeFailed(let role, _))):
                #expect(role == .mixed)
            case ("file-sync", .some(.durabilityFailed(let path))):
                #expect(path == staging.appendingPathComponent("mixed-0001.caf").path)
            case ("rename", .some(.durabilityFailed(let path))):
                #expect(path.hasSuffix(".json"))
            case ("directory-sync", .some(.durabilityFailed(let path))):
                #expect(path == staging.path)
            default:
                Issue.record("Unexpected error for \(scenario.name): \(String(describing: error))")
            }
            #expect(try T7TestSupport.cafNames(in: staging) == ["mixed-0001.caf"])
            if scenario.name == "directory-sync" {
                #expect(try T7TestSupport.sidecarURLs(in: staging).count == 1)
            } else {
                #expect(try T7TestSupport.sidecarURLs(in: staging).isEmpty)
            }
            await #expect(throws: RecordingCheckpointError.self) {
                try await writer.append(
                    T7TestSupport.block(role: .mixed, startSample: 480, frameCount: 480, sampleRate: 8_000)
                )
            }
        }
    }
}
