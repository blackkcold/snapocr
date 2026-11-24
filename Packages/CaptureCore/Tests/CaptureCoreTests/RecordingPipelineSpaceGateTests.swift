import Foundation
import Testing

@testable import CaptureCore

struct RecordingPipelineSpaceGateTests {
    @Test func lowSpacePreflightDeniesT9PipelineBeforeMediaCreation() async throws {
        let root = TestTemporaryDirectory.root("Task10-SpaceGate")
        let roots = RecordingPipelineRoots(
            sessionRoot: root.appendingPathComponent("recordings", isDirectory: true),
            indexURL: root.appendingPathComponent("recording-index.json"),
            outputDirectory: root.appendingPathComponent("output", isDirectory: true)
        )
        let provider = MutableGateCapacityProvider(defaultCapacity: 10_000_000_000)
        let configuration = AudioRecordingConfiguration(
            kind: .audio,
            mode: .system,
            layout: .mixed,
            sampleRate: 48_000,
            channelCountByRole: [.mixed: 2],
            bitRate: 128_000
        )
        let pipeline = try RecordingAudioPipelineFactory.makeSpaceGated(
            configuration: configuration,
            roots: roots,
            backlog: RecordingBacklogPolicy(highWatermarkBytes: 8_000_000, lowWatermarkBytes: 2_000_000),
            capacityProvider: provider
        )
        provider.set(0, at: roots.sessionRoot)

        do {
            try await pipeline.start(configuration)
            Issue.record("Expected T9 start to reject the low-space preflight")
        } catch let RecordingPipelineError.spacePreflightDenied(decision) {
            // The T9 pipeline rejects before ledger registration or engine creation.
            #expect(!decision.allowed)
            #expect(decision.volumes.count == 1)
        }

        #expect(!FileManager.default.fileExists(atPath: roots.indexURL.path))
        #expect((try? FileManager.default.contentsOfDirectory(atPath: roots.outputDirectory.path))?.isEmpty ?? true)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func sealAdmissionIsSingleFlightWhileCheckpointPriorityContinues() async {
        let provider = MutableGateCapacityProvider(defaultCapacity: 10_000_000_000)
        let gate = makeGate(provider: provider)

        let first = await gate.admitSeal(segmentIndex: 0, backlogBytes: 1_000)
        let second = await gate.admitSeal(segmentIndex: 1, backlogBytes: 2_000)
        #expect(first == .run)
        #expect(second == .defer(reason: "maximum concurrent seals reached"))

        let status = await gate.checkpointCommitted(makeCommit(), backlogBytes: 2_000)
        #expect(status.state == .ok)
        #expect(status.backlogBytes == 2_000)

        await gate.sealFinished(segmentIndex: 0)
        #expect(await gate.admitSeal(segmentIndex: 1, backlogBytes: 2_000) == .run)
        await gate.sealFinished(segmentIndex: 1)
    }

    @Test func backlogHysteresisDoesNotFlapBetweenWatermarks() async {
        let provider = MutableGateCapacityProvider(defaultCapacity: 10_000_000_000)
        let gate = makeGate(provider: provider, high: 10_000, low: 4_000)

        let high = await gate.checkpointCommitted(makeCommit(), backlogBytes: 10_001)
        let middle = await gate.checkpointCommitted(makeCommit(), backlogBytes: 7_000)
        let recovered = await gate.checkpointCommitted(makeCommit(), backlogBytes: 4_000)

        #expect(high.state == .low)
        #expect(middle.state == .low)
        #expect(recovered.state == .ok)
    }

    @Test func statusStreamReportsBacklogAndCheckpointAge() async {
        let provider = MutableGateCapacityProvider(defaultCapacity: 10_000_000_000)
        let instant = Date(timeIntervalSince1970: 1_000)
        let gate = makeGate(provider: provider, now: { instant })
        let stream = gate.makeStatusStream()
        var iterator = stream.makeAsyncIterator()

        _ = try? await gate.preflightStart()
        _ = await iterator.next()
        let commit = makeCommit(committedAt: instant.addingTimeInterval(-12))
        let returned = await gate.checkpointCommitted(commit, backlogBytes: 6_000)
        let streamed = await iterator.next()

        #expect(returned.backlogBytes == 6_000)
        #expect(returned.checkpointAgeSeconds == 12)
        #expect(streamed?.backlogBytes == 6_000)
        #expect(streamed?.checkpointAgeSeconds == 12)
    }

    @Test func invalidPolicyFailsClosedWithoutBlockingCapturePriority() {
        let invalid = RecordingBacklogPolicy(
            maximumConcurrentSeals: 0,
            highWatermarkBytes: 1_000,
            lowWatermarkBytes: 2_000
        )
        #expect(invalid.admit(.captureCheckpoint, backlogBytes: 1) == .stop(reason: "invalid backlog policy"))
        #expect(invalid.admit(.seal, backlogBytes: -1) == .stop(reason: "invalid backlog policy"))

        let valid = RecordingBacklogPolicy(highWatermarkBytes: 1_000, lowWatermarkBytes: 100)
        #expect(valid.admit(.captureCheckpoint, backlogBytes: 50_000) == .run)
        #expect(valid.admit(.seal, backlogBytes: 1_001) == .defer(reason: "seal backlog is above the high watermark"))
        #expect(
            valid.admit(.exportThumbnail, backlogBytes: 101)
                == .defer(reason: "optional export is below seal priority")
        )
    }

    private func makeGate(
        provider: MutableGateCapacityProvider,
        high: Int64 = 8_000_000,
        low: Int64 = 2_000_000,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> RecordingPipelineSpaceGate {
        let budget = RecordingSpaceBudget(
            configuration: RecordingStorageConfiguration(
                kind: .audio,
                layout: .mixed,
                channelCountByRole: [.mixed: 2],
                bitRate: 128_000
            ),
            capacityProvider: provider,
            recordingRoot: URL(fileURLWithPath: "/recording")
        )
        return RecordingPipelineSpaceGate(
            budget: budget,
            backlog: RecordingBacklogPolicy(highWatermarkBytes: high, lowWatermarkBytes: low),
            now: now
        )
    }

    private func makeCommit(committedAt: Date = Date()) -> CheckpointCommit {
        CheckpointCommit(
            checkpointID: UUID(),
            segmentIndex: 0,
            range: SampleRange(startSample: 0, sampleCount: 480),
            trackURLs: [.mixed: URL(fileURLWithPath: "/recording/checkpoint.m4a")],
            committedAt: committedAt
        )
    }
}

private final class MutableGateCapacityProvider: VolumeCapacityProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var defaultCapacity: Int64
    private var capacities: [String: Int64] = [:]

    init(defaultCapacity: Int64) {
        self.defaultCapacity = defaultCapacity
    }

    func availableBytes(at url: URL) throws -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        return capacities[url.standardizedFileURL.path] ?? defaultCapacity
    }

    func set(_ capacity: Int64, at url: URL) {
        lock.lock()
        capacities[url.standardizedFileURL.path] = capacity
        lock.unlock()
    }
}
