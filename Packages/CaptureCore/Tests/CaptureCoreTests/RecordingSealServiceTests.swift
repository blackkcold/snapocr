import AVFoundation
import Foundation
import Testing

@testable import CaptureCore

/// Thread-safe publication hook used by the Task 8 seal tests.
final class T8CapturingHook: SegmentPublicationHooking, @unchecked Sendable {
    enum Behavior: Sendable {
        case succeed
        case fail
        case wait(T8Gate)
    }

    private let lock = NSLock()
    private var storedCandidate: SegmentPublicationCandidate?
    private var storedFinalExisted = false
    private let behavior: Behavior

    init(behavior: Behavior = .succeed) {
        self.behavior = behavior
    }

    var candidate: SegmentPublicationCandidate? {
        lock.lock()
        defer { lock.unlock() }
        return storedCandidate
    }

    var finalExistedAtHook: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedFinalExisted
    }

    func beforePublish(_ candidate: SegmentPublicationCandidate) async throws {
        let existed = FileManager.default.fileExists(atPath: candidate.reservedFinalURL.path)
        store(candidate, finalExisted: existed)

        switch behavior {
        case .succeed:
            return
        case .fail:
            throw T8TestError.injectedFailure
        case .wait(let gate):
            try await gate.wait()
        }
    }

    private func store(_ candidate: SegmentPublicationCandidate, finalExisted: Bool) {
        lock.lock()
        storedCandidate = candidate
        storedFinalExisted = finalExisted
        lock.unlock()
    }
}

/// Cancellation-aware test gate for the single-flight and cancel tests.
final class T8Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var open = false

    func wait() async throws {
        markEntered()
        for _ in 0..<4_000 {
            if isOpen { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw T8TestError.injectedFailure
    }

    func waitUntilEntered() async throws {
        for _ in 0..<4_000 {
            if hasEntered { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw T8TestError.injectedFailure
    }

    func openGate() {
        lock.lock()
        open = true
        lock.unlock()
    }

    private var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return open
    }

    private var hasEntered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return entered
    }

    private func markEntered() {
        lock.lock()
        entered = true
        lock.unlock()
    }
}

private func t8Inode(of url: URL) throws -> UInt64 {
    var status = stat()
    let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
        guard let path else { return -1 }
        return lstat(path, &status)
    }
    guard result == 0 else { throw T8TestError.unreadableAudio }
    return status.st_ino
}

@Suite(.serialized)
struct RecordingSealServiceTests {
    private func mixedFixture(
        root: URL,
        segmentEnd: Int64 = 4_800,
        chunks: [[T8Append]]? = nil
    ) async throws -> T8BundleFixture {
        try await T8TestSupport.makeBundle(
            sessionRoot: root,
            segmentEnd: segmentEnd,
            roles: [.mixed],
            chunks: chunks ?? [[T8Append(role: .mixed, startSample: 0, frameCount: 4_800)]]
        )
    }

    private func separateFixture(root: URL, segmentEnd: Int64 = 4_800) async throws -> T8BundleFixture {
        try await T8TestSupport.makeBundle(
            sessionRoot: root,
            segmentEnd: segmentEnd,
            roles: [.system, .microphone],
            chunks: [
                [
                    T8Append(role: .system, startSample: 0, frameCount: 4_800, amplitude: 0.6),
                    T8Append(role: .microphone, startSample: 0, frameCount: 4_800, amplitude: 0.4),
                ]
            ]
        )
    }

    private func makeContext(
        destination: URL,
        layout: AudioOutputLayout,
        stem: String = "take",
        kind: RecordingKind = .audio
    ) -> RecordingSealContext {
        RecordingSealContext(
            sessionID: UUID(),
            kind: kind,
            layout: layout,
            sampleRate: T8TestSupport.sampleRate,
            outputStem: stem,
            destinationDirectory: destination
        )
    }

    @Test func singleFileHasNoExternalManifest() async throws {
        let root = try T8TestSupport.makeRoot("seal-single")
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = try T8TestSupport.makeDirectory("destination", in: root)
        let fixture = try await mixedFixture(root: root)
        let segmentID = UUID()
        let context = makeContext(destination: destination, layout: .mixed)
        let sealed = try await RecordingSealService().seal(
            fixture.bundle,
            videoChunks: [],
            segmentID: segmentID,
            context: context
        )

        #expect(sealed.segmentID == segmentID)
        #expect(sealed.index == 0)
        #expect(sealed.manifestURL == nil)
        #expect(sealed.videoURL == nil)
        #expect(sealed.videoTrackIndex == nil)
        #expect(sealed.videoBoundary == nil)
        #expect(sealed.trackMap == [.mixed: 0])
        #expect(sealed.effectiveRange == SampleRange(startSample: 0, sampleCount: 4_800))
        #expect(sealed.files[.mixed] == destination.appendingPathComponent("take-00.m4a"))
        #expect(try T8TestSupport.visibleFileNames(in: destination) == ["take-00.m4a"])
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("manifest.json").path))

        let mixedURL = try #require(sealed.files[.mixed])
        let record = try await SegmentPortableMetadata.read(from: mixedURL)
        #expect(record.sessionID == context.sessionID)
        #expect(record.segmentID == segmentID)
        #expect(record.segmentIndex == 0)
        #expect(record.kind == "audio")
        #expect(record.layout == "mixed")
        #expect(record.sampleRate == T8TestSupport.sampleRate)
        #expect(record.startSample == 0)
        #expect(record.sampleCount == 4_800)
        #expect(record.videoURL == nil)
        #expect(record.videoTrackIndex == nil)
        #expect(record.tracks.count == 1)
        let track = try #require(record.tracks.first)
        #expect(track.role == "mixed")
        #expect(track.channelCount == 1)
        #expect(track.fileName == "take-00.m4a")
        #expect(track.validRange == RecordingSampleRange(startSample: 0, sampleCount: 4_800))
        #expect(track.primingFrames > 0)
    }

    @Test func multiTrackDirectoryRequiresManifest() async throws {
        let root = try T8TestSupport.makeRoot("seal-multi")
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = try T8TestSupport.makeDirectory("destination", in: root)
        let fixture = try await separateFixture(root: root)
        let context = makeContext(destination: destination, layout: .separateTracks)
        let sealed = try await RecordingSealService().seal(
            fixture.bundle,
            videoChunks: [],
            segmentID: UUID(),
            context: context
        )

        let directory = destination.appendingPathComponent("take-00", isDirectory: true)
        #expect(sealed.manifestURL == directory.appendingPathComponent("manifest.json"))
        #expect(sealed.files[.system] == directory.appendingPathComponent("system.m4a"))
        #expect(sealed.files[.microphone] == directory.appendingPathComponent("mic.m4a"))
        #expect(sealed.trackMap == [.system: 0, .microphone: 1])
        #expect(sealed.videoURL == nil)
        #expect(sealed.videoTrackIndex == nil)
        #expect(
            Set(try T8TestSupport.visibleFileNames(in: directory)) == [
                "manifest.json", "mic.m4a", "system.m4a",
            ])
        #expect(try T8TestSupport.visibleFileNames(in: destination) == ["take-00"])

        let manifestURL = try #require(sealed.manifestURL)
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(SegmentPortableRecord.self, from: manifestData)
        #expect(manifest.tracks.map(\.role) == ["system", "microphone"])
        #expect(manifest.tracks.map(\.fileName) == ["system.m4a", "mic.m4a"])
        #expect(manifest.startSample == 0)
        #expect(manifest.sampleCount == 4_800)
        #expect(manifest.tracks.allSatisfy { $0.channelCount == 1 })
        #expect(manifest.tracks.allSatisfy { $0.primingFrames > 0 })
        let systemURL = try #require(sealed.files[.system])
        let microphoneURL = try #require(sealed.files[.microphone])
        #expect(try T8TestSupport.validFrameCount(of: systemURL) == 4_800)
        #expect(try T8TestSupport.validFrameCount(of: microphoneURL) == 4_800)

        let systemRecord = try await SegmentPortableMetadata.read(from: systemURL)
        let microphoneRecord = try await SegmentPortableMetadata.read(from: microphoneURL)
        #expect(systemRecord == manifest)
        #expect(microphoneRecord == manifest)
    }

    @Test func screenVideoOptionalFieldsRoundTrip() throws {
        let sessionID = UUID()
        let segmentID = UUID()
        let videoURL = URL(fileURLWithPath: "/tmp/snapglass-screen.mp4")
        let record = SegmentPortableRecord(
            sessionID: sessionID,
            segmentID: segmentID,
            segmentIndex: 3,
            kind: "screen",
            layout: "separateTracks",
            sampleRate: 48_000,
            startSample: 48_000,
            sampleCount: 96_000,
            tracks: [
                SegmentPortableRecord.Track(
                    role: "system",
                    channelCount: 2,
                    fileName: "system.m4a",
                    validRange: RecordingSampleRange(startSample: 48_000, sampleCount: 96_000),
                    primingFrames: 2_112,
                    remainderFrames: 64,
                    insertedSilenceFrames: 0,
                    encodedPacketCount: 94,
                    decodedFrameCount: 96_000
                )
            ],
            missingRanges: [RecordingSampleRange(startSample: 120_000, sampleCount: 480)],
            videoURL: videoURL,
            videoTrackIndex: 0
        )
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(SegmentPortableRecord.self, from: data)
        #expect(decoded == record)
        #expect(decoded.videoURL == videoURL)
        #expect(decoded.videoTrackIndex == 0)
        #expect(decoded.kind == "screen")
        #expect(!decoded.tracks.contains { $0.role == "video" })

        let audioOnly = SegmentPortableRecord(
            sessionID: sessionID,
            segmentID: segmentID,
            segmentIndex: 0,
            kind: "audio",
            layout: "mixed",
            sampleRate: 48_000,
            startSample: 0,
            sampleCount: 4_800,
            tracks: [],
            missingRanges: []
        )
        #expect(audioOnly.videoURL == nil)
        #expect(audioOnly.videoTrackIndex == nil)

        let sealed = SealedSegment(
            segmentID: segmentID,
            index: 3,
            files: [.system: URL(fileURLWithPath: "/tmp/system.m4a")],
            manifestURL: URL(fileURLWithPath: "/tmp/manifest.json"),
            effectiveRange: SampleRange(startSample: 48_000, sampleCount: 96_000),
            videoBoundary: CMTime(value: 2, timescale: 1),
            trackMap: [.system: 0],
            videoURL: videoURL,
            videoTrackIndex: 0
        )
        #expect(sealed.videoURL == videoURL)
        #expect(sealed.videoTrackIndex == 0)
        #expect(sealed.files.keys.allSatisfy { $0 != .mixed })
        #expect(sealed.videoBoundary == CMTime(value: 2, timescale: 1))
    }

    @Test func beforePublishSeesActualReservedFinalURLAndHashes() async throws {
        let root = try T8TestSupport.makeRoot("seal-hook")
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = try T8TestSupport.makeDirectory("destination", in: root)
        let sentinel = destination.appendingPathComponent("take-00.m4a")
        try Data("SENTINEL".utf8).write(to: sentinel)
        let fixture = try await mixedFixture(root: root)
        let segmentID = UUID()
        let hook = T8CapturingHook()
        let service = RecordingSealService(publicationHooks: [hook])
        let context = makeContext(destination: destination, layout: .mixed)
        let sealed = try await service.seal(
            fixture.bundle,
            videoChunks: [],
            segmentID: segmentID,
            context: context
        )

        let candidate = try #require(hook.candidate)
        #expect(candidate.segmentID == segmentID)
        #expect(candidate.segmentIndex == 0)
        #expect(candidate.isDirectory == false)
        #expect(candidate.reservedFinalURL.lastPathComponent == "take-00_2.m4a")
        #expect(candidate.stagingURL != candidate.reservedFinalURL)
        #expect(candidate.stagedFileURLs == [.mixed: candidate.stagingURL])
        #expect(candidate.manifestURL == nil)
        #expect(candidate.coverage == fixture.bundle.coverage)
        #expect(candidate.effectiveRange == RecordingSampleRange(startSample: 0, sampleCount: 4_800))
        #expect(hook.finalExistedAtHook == false)

        let record = try await SegmentPortableMetadata.read(from: candidate.reservedFinalURL)
        let expectedHash = try T8TestSupport.sha256(of: candidate.reservedFinalURL)
        #expect(candidate.contentHashes[record.tracks[0].fileName] == expectedHash)
        #expect(candidate.contentHashes.count == 1)
        #expect(sealed.files[.mixed] == candidate.reservedFinalURL)
        #expect(try Data(contentsOf: sentinel) == Data("SENTINEL".utf8))
        #expect(try T8TestSupport.validFrameCount(of: candidate.reservedFinalURL) == 4_800)
    }

    @Test func beforePublishFailureRetainsStageAndDoesNotPublish() async throws {
        let root = try T8TestSupport.makeRoot("seal-hook-fail")
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = try T8TestSupport.makeDirectory("destination", in: root)
        let fixture = try await mixedFixture(root: root)
        let hook = T8CapturingHook(behavior: .fail)
        let service = RecordingSealService(publicationHooks: [hook])
        let context = makeContext(destination: destination, layout: .mixed)
        do {
            _ = try await service.seal(
                fixture.bundle,
                videoChunks: [],
                segmentID: UUID(),
                context: context
            )
            Issue.record("seal should throw when a publication hook fails")
        } catch is T8TestError {}

        let candidate = try #require(hook.candidate)
        #expect(FileManager.default.fileExists(atPath: candidate.stagingURL.path))
        #expect(!FileManager.default.fileExists(atPath: candidate.reservedFinalURL.path))
        #expect(try T8TestSupport.visibleFileNames(in: destination).isEmpty)
        let stagedRecord = try await SegmentPortableMetadata.read(from: candidate.stagingURL)
        #expect(stagedRecord.segmentID == candidate.segmentID)
        #expect(try T8TestSupport.checkpointSourceHashes(fixture) == fixture.sourceHashes)
    }

    @Test func publisherURLMismatchFailsClosed() async throws {
        let root = try T8TestSupport.makeRoot("seal-url-mismatch")
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = try T8TestSupport.makeDirectory("destination", in: root)
        let fixture = try await mixedFixture(root: root)
        let wrongURL = destination.appendingPathComponent("wrong.m4a")
        let service = RecordingSealService(
            publicationHooks: [],
            publishOverride: { _, _ in wrongURL }
        )
        let context = makeContext(destination: destination, layout: .mixed)
        do {
            _ = try await service.seal(
                fixture.bundle,
                videoChunks: [],
                segmentID: UUID(),
                context: context
            )
            Issue.record("seal should fail when the published URL differs from the reservation")
        } catch let error as RecordingSealError {
            #expect(error == .publishedURLMismatch)
        }

        #expect(!FileManager.default.fileExists(atPath: wrongURL.path))
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("take-00.m4a").path))
        #expect(try T8TestSupport.visibleFileNames(in: destination).isEmpty)
        let hidden = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        #expect(hidden.contains { $0.hasSuffix(".partial") })
        #expect(try T8TestSupport.checkpointSourceHashes(fixture) == fixture.sourceHashes)
    }

}

extension RecordingSealServiceTests {
    @Test func publishPreparedAdoptsVerifiedStageAfterCrash() async throws {
        let root = try T8TestSupport.makeRoot("seal-prepared")
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = try T8TestSupport.makeDirectory("destination", in: root)
        let fixture = try await mixedFixture(root: root)
        let hook = T8CapturingHook(behavior: .fail)
        let context = makeContext(destination: destination, layout: .mixed)
        do {
            _ = try await RecordingSealService(publicationHooks: [hook]).seal(
                fixture.bundle,
                videoChunks: [],
                segmentID: UUID(),
                context: context
            )
        } catch is T8TestError {}
        let candidate = try #require(hook.candidate)

        let sealed = try await RecordingSealService().publishPrepared(candidate)
        #expect(sealed.segmentID == candidate.segmentID)
        #expect(sealed.files[.mixed] == candidate.reservedFinalURL)
        #expect(sealed.manifestURL == nil)
        #expect(sealed.trackMap == [.mixed: 0])
        #expect(FileManager.default.fileExists(atPath: candidate.reservedFinalURL.path))
        let record = try await SegmentPortableMetadata.read(from: candidate.reservedFinalURL)
        #expect(record.segmentID == candidate.segmentID)
        #expect(record.tracks.count == 1)
    }

    @Test func publishPreparedRejectsReservedFinalNameMismatch() async throws {
        let root = try T8TestSupport.makeRoot("seal-reserved-name")
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = try T8TestSupport.makeDirectory("destination", in: root)
        let fixture = try await mixedFixture(root: root)
        let hook = T8CapturingHook(behavior: .fail)
        let context = makeContext(destination: destination, layout: .mixed)
        do {
            _ = try await RecordingSealService(publicationHooks: [hook]).seal(
                fixture.bundle,
                videoChunks: [],
                segmentID: UUID(),
                context: context
            )
        } catch is T8TestError {}
        let staged = try #require(hook.candidate)
        let mismatchedFinal = destination.appendingPathComponent("take-00_2.m4a")
        let mismatched = SegmentPublicationCandidate(
            segmentID: staged.segmentID,
            segmentIndex: staged.segmentIndex,
            stagingURL: staged.stagingURL,
            reservedFinalURL: mismatchedFinal,
            isDirectory: staged.isDirectory,
            stagedFileURLs: staged.stagedFileURLs,
            contentHashes: staged.contentHashes,
            manifestURL: staged.manifestURL,
            effectiveRange: staged.effectiveRange,
            coverage: staged.coverage
        )

        do {
            _ = try await RecordingSealService().publishPrepared(mismatched)
            Issue.record("publishPrepared should reject a reserved final name mismatch before publishing")
        } catch let error as RecordingSealError {
            #expect(error == .invalidCandidate)
        }
        #expect(!FileManager.default.fileExists(atPath: mismatchedFinal.path))
        #expect(FileManager.default.fileExists(atPath: staged.stagingURL.path))
        #expect(try T8TestSupport.checkpointSourceHashes(fixture) == fixture.sourceHashes)
    }

    @Test func publishPreparedRejectsSymlinkOrHashMismatch() async throws {
        let hashRoot = try T8TestSupport.makeRoot("seal-hash-mismatch")
        defer { try? FileManager.default.removeItem(at: hashRoot) }
        let hashDestination = try T8TestSupport.makeDirectory("destination", in: hashRoot)
        let hashFixture = try await mixedFixture(root: hashRoot)
        let hashHook = T8CapturingHook(behavior: .fail)
        do {
            _ = try await RecordingSealService(publicationHooks: [hashHook]).seal(
                hashFixture.bundle,
                videoChunks: [],
                segmentID: UUID(),
                context: makeContext(destination: hashDestination, layout: .mixed)
            )
        } catch is T8TestError {}
        let hashCandidate = try #require(hashHook.candidate)
        let hashHandle = try FileHandle(forWritingTo: hashCandidate.stagingURL)
        try hashHandle.seekToEnd()
        try hashHandle.write(contentsOf: Data([0x00]))
        try hashHandle.close()
        do {
            _ = try await RecordingSealService().publishPrepared(hashCandidate)
            Issue.record("publishPrepared should reject a content hash mismatch")
        } catch let error as RecordingSealError {
            #expect(error == .hashMismatch)
        }
        #expect(!FileManager.default.fileExists(atPath: hashCandidate.reservedFinalURL.path))
        #expect(FileManager.default.fileExists(atPath: hashCandidate.stagingURL.path))

        let linkRoot = try T8TestSupport.makeRoot("seal-symlink")
        defer { try? FileManager.default.removeItem(at: linkRoot) }
        let linkDestination = try T8TestSupport.makeDirectory("destination", in: linkRoot)
        let linkFixture = try await mixedFixture(root: linkRoot)
        let linkHook = T8CapturingHook(behavior: .fail)
        do {
            _ = try await RecordingSealService(publicationHooks: [linkHook]).seal(
                linkFixture.bundle,
                videoChunks: [],
                segmentID: UUID(),
                context: makeContext(destination: linkDestination, layout: .mixed)
            )
        } catch is T8TestError {}
        let linkCandidate = try #require(linkHook.candidate)
        let realStage = linkDestination.appendingPathComponent("real.m4a")
        try FileManager.default.moveItem(at: linkCandidate.stagingURL, to: realStage)
        try FileManager.default.createSymbolicLink(at: linkCandidate.stagingURL, withDestinationURL: realStage)
        do {
            _ = try await RecordingSealService().publishPrepared(linkCandidate)
            Issue.record("publishPrepared should reject a symlinked stage")
        } catch let error as RecordingSealError {
            #expect(error == .stagingNotRegularFile)
        }
        #expect(!FileManager.default.fileExists(atPath: linkCandidate.reservedFinalURL.path))
        #expect(FileManager.default.fileExists(atPath: realStage.path))
    }

    @Test func publishPreparedExistingFinalVerifiesAndAdopts() async throws {
        let root = try T8TestSupport.makeRoot("seal-existing-final")
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = try T8TestSupport.makeDirectory("destination", in: root)
        let fixture = try await mixedFixture(root: root)
        let hook = T8CapturingHook()
        let context = makeContext(destination: destination, layout: .mixed)
        let first = try await RecordingSealService(publicationHooks: [hook]).seal(
            fixture.bundle,
            videoChunks: [],
            segmentID: UUID(),
            context: context
        )
        let candidate = try #require(hook.candidate)
        let publishedHash = try T8TestSupport.sha256(of: candidate.reservedFinalURL)
        let publishedInode = try t8Inode(of: candidate.reservedFinalURL)

        let adopted = try await RecordingSealService().publishPrepared(candidate)
        #expect(adopted == first)
        #expect(adopted.files[.mixed] == candidate.reservedFinalURL)
        #expect(try T8TestSupport.sha256(of: candidate.reservedFinalURL) == publishedHash)
        #expect(try t8Inode(of: candidate.reservedFinalURL) == publishedInode)
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("take-00_2.m4a").path))
        #expect(try T8TestSupport.visibleFileNames(in: destination) == ["take-00.m4a"])
    }

    @Test func publishPreparedHardlinkSourceNotDeletedWhileLeased() async throws {
        let root = try T8TestSupport.makeRoot("seal-leased")
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = try T8TestSupport.makeDirectory("destination", in: root)
        let fixture = try await mixedFixture(root: root)
        let hook = T8CapturingHook(behavior: .fail)
        do {
            _ = try await RecordingSealService(publicationHooks: [hook]).seal(
                fixture.bundle,
                videoChunks: [],
                segmentID: UUID(),
                context: makeContext(destination: destination, layout: .mixed)
            )
        } catch is T8TestError {}
        let candidate = try #require(hook.candidate)
        let stagedHash = try T8TestSupport.sha256(of: candidate.stagingURL)

        _ = try await RecordingSealService().publishPrepared(candidate)
        #expect(FileManager.default.fileExists(atPath: candidate.stagingURL.path))
        #expect(FileManager.default.fileExists(atPath: candidate.reservedFinalURL.path))
        #expect(try T8TestSupport.sha256(of: candidate.stagingURL) == stagedHash)
        #expect(try t8Inode(of: candidate.stagingURL) == t8Inode(of: candidate.reservedFinalURL))
    }

    @Test func sealFailureRetainsStagingAndNeverOverwrites() async throws {
        let root = try T8TestSupport.makeRoot("seal-encode-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = try T8TestSupport.makeDirectory("destination", in: root)
        let fixture = try await separateFixture(root: root)
        let sentinelDirectory = destination.appendingPathComponent("take-00", isDirectory: true)
        try FileManager.default.createDirectory(at: sentinelDirectory, withIntermediateDirectories: false)
        let sentinel = sentinelDirectory.appendingPathComponent("sentinel.txt")
        try Data("KEEP".utf8).write(to: sentinel)

        let microphoneCAF = try #require(
            try FileManager.default.contentsOfDirectory(atPath: fixture.checkpointDirectory.path)
                .first { $0.hasPrefix("mic-") && $0.hasSuffix(".caf") }
        )
        try FileManager.default.removeItem(
            at: fixture.checkpointDirectory.appendingPathComponent(microphoneCAF)
        )

        do {
            _ = try await RecordingSealService().seal(
                fixture.bundle,
                videoChunks: [],
                segmentID: UUID(),
                context: makeContext(destination: destination, layout: .separateTracks)
            )
            Issue.record("seal should fail when a source CAF is missing")
        } catch let error as AudioTrackEncoderError {
            #expect(error == .sourceUnreadable)
        }

        #expect(try Data(contentsOf: sentinel) == Data("KEEP".utf8))
        #expect(try T8TestSupport.visibleFileNames(in: destination) == ["take-00"])
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("take-00_2").path))
        let hidden = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        #expect(hidden.contains { $0.hasPrefix(".SnapGlass-") && $0.hasSuffix(".staging") })
        let remainingSystemHashes = try T8TestSupport.hashesOfCAFFiles(in: fixture.checkpointDirectory)
        #expect(remainingSystemHashes == fixture.sourceHashes.filter { !$0.key.hasPrefix("mic-") })
    }

    @Test func cancelledSealKeepsSourcesAndPublishesNothing() async throws {
        let root = try T8TestSupport.makeRoot("seal-cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = try T8TestSupport.makeDirectory("destination", in: root)
        let fixture = try await mixedFixture(root: root)
        let gate = T8Gate()
        let hook = T8CapturingHook(behavior: .wait(gate))
        let service = RecordingSealService(publicationHooks: [hook])
        let context = makeContext(destination: destination, layout: .mixed)
        let task = Task {
            try await service.seal(
                fixture.bundle,
                videoChunks: [],
                segmentID: UUID(),
                context: context
            )
        }
        try await gate.waitUntilEntered()
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("cancelled seal should not complete")
        } catch is CancellationError {}

        let candidate = try #require(hook.candidate)
        #expect(FileManager.default.fileExists(atPath: candidate.stagingURL.path))
        #expect(!FileManager.default.fileExists(atPath: candidate.reservedFinalURL.path))
        #expect(try T8TestSupport.visibleFileNames(in: destination).isEmpty)
        #expect(try T8TestSupport.checkpointSourceHashes(fixture) == fixture.sourceHashes)
    }

    @Test func videoChunksArePassthroughOnly() async throws {
        let root = try T8TestSupport.makeRoot("seal-video")
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = try T8TestSupport.makeDirectory("destination", in: root)
        let chunk = destination.appendingPathComponent("chunk.mov")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: chunk)
        let chunkHash = try T8TestSupport.sha256(of: chunk)
        let fixture = try await mixedFixture(root: root)
        do {
            _ = try await RecordingSealService().seal(
                fixture.bundle,
                videoChunks: [chunk],
                segmentID: UUID(),
                context: makeContext(destination: destination, layout: .mixed)
            )
            Issue.record("Task 8 must reject video chunks instead of silently dropping them")
        } catch let error as RecordingSealError {
            #expect(error == .videoChunksUnsupported)
        }
        #expect(try T8TestSupport.sha256(of: chunk) == chunkHash)
        #expect(try T8TestSupport.visibleFileNames(in: destination) == ["chunk.mov"])
        #expect(try T8TestSupport.checkpointSourceHashes(fixture) == fixture.sourceHashes)
    }

    @Test func concurrentSealCallsRunOneAtATime() async throws {
        let root = try T8TestSupport.makeRoot("seal-single-flight")
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = try T8TestSupport.makeDirectory("destination", in: root)
        let fixture = try await mixedFixture(root: root)
        let gate = T8Gate()
        let hook = T8CapturingHook(behavior: .wait(gate))
        let service = RecordingSealService(publicationHooks: [hook])
        let context = makeContext(destination: destination, layout: .mixed)
        let first = Task {
            try await service.seal(
                fixture.bundle,
                videoChunks: [],
                segmentID: UUID(),
                context: context
            )
        }
        try await gate.waitUntilEntered()
        do {
            _ = try await service.seal(
                fixture.bundle,
                videoChunks: [],
                segmentID: UUID(),
                context: context
            )
            Issue.record("a second concurrent seal must be rejected")
        } catch let error as RecordingSealError {
            #expect(error == .sealInProgress)
        }
        gate.openGate()
        let sealed = try await first.value
        let mixedURL = try #require(sealed.files[.mixed])
        #expect(FileManager.default.fileExists(atPath: mixedURL.path))
        #expect(try T8TestSupport.visibleFileNames(in: destination) == ["take-00.m4a"])
    }
}
