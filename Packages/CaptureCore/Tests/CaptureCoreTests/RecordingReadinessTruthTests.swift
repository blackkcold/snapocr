import Foundation
import Testing

@testable import CaptureCore

/// Regression coverage for S4: readiness may only come from real captured frames,
/// never from checkpoint coverage that the writer filled with synthesized silence.
///
/// The test is intentionally event-driven rather than window-based: the fake engine
/// keeps publishing its zero-capture phase until the test has observed the pipeline
/// forward it, and keeps publishing real frames until the test ends. Nothing depends
/// on a fixed wall-clock window, so a starved cooperative pool under the default
/// parallel test run cannot drop the phase that proves the contract.
struct RecordingReadinessTruthTests {
    /// Ledger coverage is 5 s of writer-synthesized silence; the engine reports
    /// zero real captured frames until the test explicitly releases real frames.
    @Test func checkpointCoverageNeverBecomesCapturedSamples() async throws {
        let harness = try ReadinessHarness()
        defer { harness.tearDown() }
        let engine = harness.engine
        let pipeline = harness.pipeline
        let collector = harness.collector
        let ledger = harness.ledger
        let configuration = harness.configuration
        let syntheticFrames = harness.syntheticFrames
        let realCapturedSamples = harness.realCapturedSamples

        try await pipeline.start(configuration)

        // Precondition: the ledger really holds coverage, so `facts.sampleEnd` is
        // non-zero while the engine has captured nothing. The engine signals after
        // the commit attempt, so this never polls for a state that cannot arrive.
        let coverageWritten = await engine.coverageAttempted.wait(timeout: .seconds(30))
        #expect(coverageWritten, "the synthetic checkpoint was never written")
        #expect(engine.checkpointFailure == nil)
        let facts = await ledger.progressFacts()
        #expect(facts.sampleEnd == Int64(syntheticFrames))

        // 1. While the engine reports zero real frames, the pipeline may only
        //    report zero. A non-zero value here could only come from checkpoint
        //    coverage, so it fails fast instead of waiting for a timeout.
        let firstOutcome = await collector.waitForFirst(
            [
                ("coveredZero", { $0.capturedSamples == 0 && $0.elapsedSeconds >= 4.5 }),
                ("forged", { $0.capturedSamples != 0 }),
            ],
            timeout: .seconds(30)
        )
        #expect(
            firstOutcome == "coveredZero",
            "checkpoint coverage must never raise capturedSamples; observed \(firstOutcome ?? "nothing")"
        )

        // 2. Only the engine's real counter reaches readiness (> 0). Real frames
        //    are released only after the covered-zero snapshot was observed, so the
        //    two phases can never overlap or expire before they are seen.
        engine.releaseRealSamples()
        let realOutcome = await collector.waitForFirst(
            [
                ("real", { $0.capturedSamples == realCapturedSamples }),
                ("unexpected", { $0.capturedSamples != 0 && $0.capturedSamples != realCapturedSamples }),
            ],
            timeout: .seconds(30)
        )
        #expect(
            realOutcome == "real",
            "real captured frames must reach progress unchanged; observed \(realOutcome ?? "nothing")"
        )

        let values = await collector.values
        #expect(!values.isEmpty)
        #expect(values.allSatisfy { $0.capturedSamples == 0 || $0.capturedSamples == realCapturedSamples })
        #expect(values.contains { $0.capturedSamples == 0 && $0.elapsedSeconds >= 4.5 })
        let latest = try #require(values.last)
        #expect(latest.capturedSamples == realCapturedSamples)
        // Elapsed is still driven by clock/checkpoint coverage (S4 keeps it as-is).
        #expect(latest.elapsedSeconds >= 4.5)

        _ = await pipeline.stop()
    }
}

private struct ReadinessHarness {
    let root: URL
    let engine: CheckpointCoverageEngine
    let pipeline: RecordingSessionPipeline
    let collector: ProgressCollector
    let ledger: RecordingSessionLedger
    let configuration: AudioRecordingConfiguration
    let syntheticFrames: Int
    let realCapturedSamples: Int64
    private let consumer: Task<Void, Never>

    init() throws {
        let root = TestTemporaryDirectory.root("S4-ReadinessTruth")
        let sessionID = UUID()
        let sessionRoot = root.appendingPathComponent(".SnapGlassSessions", isDirectory: true)
            .appendingPathComponent(sessionID.uuidString.lowercased(), isDirectory: true)
        let outputRoot = root.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)

        let indexURL = root.appendingPathComponent("recording-index.json")
        let ledger = try RecordingSessionLedger(
            sessionRoot: sessionRoot, indexURL: indexURL, sessionID: sessionID
        )
        let configuration = AudioRecordingConfiguration(
            kind: .audio, mode: .system, layout: .mixed, sampleRate: 48_000,
            channelCountByRole: [.mixed: 1], bitRate: 96_000
        )
        let coordinator = try SegmentedWriterCoordinator(plan: AudioSegmentPlan()) { boundary in
            let directory = sessionRoot.appendingPathComponent(
                String(format: "segment-%08d", boundary.index), isDirectory: true
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            return try RecordingCheckpointWriter(
                directory: directory,
                sessionRoot: sessionRoot,
                segment: boundary,
                sampleRate: 48_000,
                roles: [.mixed]
            )
        }
        let sealService = RecordingSealService(publicationHooks: [LedgerPublicationHook(ledger: ledger)])

        let syntheticFrames = 240_000  // 5 s of writer-synthesized silence
        let realCapturedSamples: Int64 = 4_800
        let engine = CheckpointCoverageEngine(
            sessionID: sessionID,
            checkpointFrames: syntheticFrames,
            realCapturedSamples: realCapturedSamples
        )
        let pipeline = try RecordingSessionPipeline(
            roots: RecordingPipelineRoots(
                sessionRoot: root, indexURL: indexURL, outputDirectory: outputRoot
            ),
            ledger: ledger, coordinator: coordinator, sealService: sealService,
            engineFactory: { _, sink, _ in engine.attach(sink: sink) }
        )

        let stream = pipeline.makeProgressStream()
        let collector = ProgressCollector()
        let consumer = Task {
            for await value in stream {
                await collector.append(value)
            }
        }

        self.root = root
        self.engine = engine
        self.pipeline = pipeline
        self.collector = collector
        self.ledger = ledger
        self.configuration = configuration
        self.syntheticFrames = syntheticFrames
        self.realCapturedSamples = realCapturedSamples
        self.consumer = consumer
    }

    func tearDown() {
        consumer.cancel()
        engine.stopEmitting()
        try? FileManager.default.removeItem(at: root)
    }
}

/// A one-shot cross-task signal.
///
/// Waits are event-driven; the timeout exists only so a regression cannot hang the
/// test run forever. A timeout consumes the signal, which fails the assertion that
/// depends on it.
private final class AsyncSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    var isSignaled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return signaled
    }

    func signal() {
        lock.lock()
        guard !signaled else {
            lock.unlock()
            return
        }
        signaled = true
        let waiters = self.waiters
        self.waiters = []
        lock.unlock()
        waiters.forEach { $0.resume(returning: true) }
    }

    func wait(timeout: Duration) async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            if signaled {
                lock.unlock()
                continuation.resume(returning: true)
                return
            }
            waiters.append(continuation)
            lock.unlock()
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.expireWaiters()
            }
        }
    }

    private func expireWaiters() {
        lock.lock()
        guard !signaled else {
            lock.unlock()
            return
        }
        signaled = true
        let waiters = self.waiters
        self.waiters = []
        lock.unlock()
        waiters.forEach { $0.resume(returning: false) }
    }
}

/// Collects pipeline progress snapshots and resumes waiters as soon as a matching
/// snapshot is appended: no polling, so CPU starvation only delays the append that
/// carries the fact, it cannot make the test miss a fixed observation window.
private actor ProgressCollector {
    private struct Candidate: Sendable {
        let label: String
        let predicate: @Sendable (RecordingProgress) -> Bool
    }

    private struct Waiter {
        let candidates: [Candidate]
        let continuation: CheckedContinuation<String?, Never>
    }

    private(set) var values: [RecordingProgress] = []
    private var waiters: [UUID: Waiter] = [:]

    func append(_ value: RecordingProgress) {
        values.append(value)
        for (id, waiter) in waiters {
            guard let match = waiter.candidates.first(where: { $0.predicate(value) }) else { continue }
            waiters[id] = nil
            waiter.continuation.resume(returning: match.label)
        }
    }

    /// Waits until one of `candidates` matches, returning its label.
    ///
    /// The timeout is a failsafe only; the normal path resolves on `append`.
    func waitForFirst(
        _ candidates: [(label: String, predicate: @Sendable (RecordingProgress) -> Bool)],
        timeout: Duration
    ) async -> String? {
        let prepared = candidates.map { Candidate(label: $0.label, predicate: $0.predicate) }
        if let match = prepared.first(where: { candidate in
            values.contains(where: candidate.predicate)
        }) {
            return match.label
        }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            waiters[id] = Waiter(candidates: prepared, continuation: continuation)
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.expire(id)
            }
        }
    }

    private func expire(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(returning: nil)
    }
}

/// An engine whose writer path produces checkpoint coverage (synthesized silence)
/// while its real capture counter stays zero until it is explicitly released.
private final class CheckpointCoverageEngine: AudioRecordingControlling, @unchecked Sendable {
    /// Resolves once the synthetic checkpoint write has been attempted.
    let coverageAttempted = AsyncSignal()
    /// Resolves when the test releases the real-frame phase.
    let realPhaseRelease = AsyncSignal()

    private let sessionID: UUID
    private let checkpointFrames: Int
    private let realCapturedSamples: Int64

    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<RecordingProgress>.Continuation] = [:]
    private var latest: RecordingProgress?
    private var emissionTask: Task<Void, Never>?
    private var storedCheckpointFailure: String?

    /// How often each phase republishes. Well below the pipeline's 100 ms publish
    /// throttle, so every throttle window gets a fresh snapshot to consider.
    private static let publishInterval = Duration.milliseconds(50)

    init(sessionID: UUID, checkpointFrames: Int, realCapturedSamples: Int64) {
        self.sessionID = sessionID
        self.checkpointFrames = checkpointFrames
        self.realCapturedSamples = realCapturedSamples
    }

    var checkpointFailure: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedCheckpointFailure
    }

    /// Binds the pipeline's real sink, exactly as the production engine factory does.
    func attach(sink: any AudioCheckpointSink & Sendable) -> any AudioRecordingControlling & Sendable {
        self.sink = sink
        return self
    }

    private var sink: (any AudioCheckpointSink & Sendable)?

    /// Releases the real-frame phase; the zero phase continues until this is called.
    func releaseRealSamples() {
        realPhaseRelease.signal()
    }

    /// Stops emission so an assertion failure cannot leave a timer running.
    func stopEmitting() {
        lock.lock()
        let task = emissionTask
        emissionTask = nil
        lock.unlock()
        task?.cancel()
    }

    func start(_ configuration: AudioRecordingConfiguration) async throws {
        guard let sink else { throw RecordingCheckpointError.emptyCheckpoint }
        let frames = checkpointFrames
        let sessionID = sessionID
        let real = realCapturedSamples
        emissionTask = Task { [weak self] in
            do {
                try await Self.writeSyntheticCoverage(frames: frames, sink: sink)
            } catch {
                self?.storeCheckpointFailure(String(describing: error))
            }
            self?.coverageAttempted.signal()

            // Phase 1: report zero real frames until the test confirms the pipeline
            // forwarded a covered-zero snapshot. There is no time window here, so
            // starvation can delay the phase but never make it disappear.
            while !Task.isCancelled {
                self?.publish(capturedSamples: 0)
                if self?.realPhaseRelease.isSignaled == true { break }
                do {
                    try await Task.sleep(for: Self.publishInterval)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }

            // Phase 2: report the real counter until the test ends. Also window-free.
            while !Task.isCancelled {
                self?.publish(capturedSamples: real)
                do {
                    try await Task.sleep(for: Self.publishInterval)
                } catch {
                    return
                }
            }
        }
    }

    func stop() async -> AudioRecordingResult {
        stopEmitting()
        return AudioRecordingResult(
            sessionID: sessionID,
            kind: .audio,
            layout: .mixed,
            segmentCount: 0,
            droppedRanges: [],
            checkpointAge: 0,
            failure: nil
        )
    }

    func applyRoute(_ event: RouteEvent) async -> RouteCommitResult {
        .unchanged(reason: "test engine has no routes")
    }

    nonisolated func makeProgressStream() -> AsyncStream<RecordingProgress> {
        let id = UUID()
        let stream = AsyncStream<RecordingProgress>(bufferingPolicy: .bufferingNewest(8)) { continuation in
            lock.lock()
            continuations[id] = continuation
            if let latest { continuation.yield(latest) }
            lock.unlock()
            continuation.onTermination = { [weak self] _ in self?.remove(id) }
        }
        return stream
    }

    private func publish(capturedSamples: Int64) {
        let value = RecordingProgress(
            sessionID: sessionID,
            elapsedSeconds: 0,
            savedSegments: 0,
            checkpointAgeSeconds: 0,
            droppedSamples: 0,
            capturedSamples: capturedSamples
        )
        lock.lock()
        latest = value
        let targets = Array(continuations.values)
        lock.unlock()
        targets.forEach { $0.yield(value) }
    }

    private func remove(_ id: UUID) {
        lock.lock()
        continuations[id] = nil
        lock.unlock()
    }

    private func storeCheckpointFailure(_ message: String) {
        lock.lock()
        storedCheckpointFailure = message
        lock.unlock()
    }

    /// Writes one contiguous block of digital silence and commits it, which is
    /// what the real writer does for a silent span between captured ticks.
    private static func writeSyntheticCoverage(
        frames: Int,
        sink: any AudioCheckpointSink & Sendable
    ) async throws {
        let block = AudioPCMBlock(
            role: .mixed,
            range: SampleRange(startSample: 0, sampleCount: Int64(frames)),
            sampleRate: 48_000,
            channelCount: 1,
            frameCount: frames,
            hostTime: 0,
            channels: [[Float](repeating: 0, count: frames)],
            isSilence: true
        )
        try await sink.append(block)
        _ = try await sink.commitCheckpoint()
    }
}
