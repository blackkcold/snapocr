import AudioToolbox
import Foundation

/// Bridges the seal service's pre-publish hook to the session ledger.
public struct LedgerPublicationHook: SegmentPublicationHooking {
    private let ledger: RecordingSessionLedger

    /// Creates a hook that journals intents for `ledger`.
    public init(ledger: RecordingSessionLedger) { self.ledger = ledger }

    /// Records the publish intent before any product file is moved.
    ///
    /// - Parameter candidate: The staged product and the coverage it promises.
    /// - Throws: A ledger error when the intent cannot be journaled.
    public func beforePublish(_ candidate: SegmentPublicationCandidate) async throws {
        let intent = RecordingPublishIntent(
            segmentID: candidate.segmentID,
            segmentIndex: candidate.segmentIndex,
            reservedFinalURL: candidate.reservedFinalURL,
            stagingURL: candidate.stagingURL,
            isDirectory: candidate.isDirectory,
            contentHashes: candidate.contentHashes,
            effectiveRange: candidate.effectiveRange,
            coverage: candidate.coverage
        )
        try await ledger.recordPublishIntent(intent)
    }
}

enum SealSignal: Sendable {
    case closed(Int)
    case retry
}

/// The production session composition root: real T5/T6 engine, T7 CAF writer, T8 seal, T9 journal.
public actor RecordingSessionPipeline: AudioRecordingControlling {
    /// The session's durable journal, shared with preview and recovery callers.
    public nonisolated let ledger: RecordingSessionLedger

    let roots: RecordingPipelineRoots
    let coordinator: SegmentedWriterCoordinator
    let sealService: RecordingSealService
    let spaceGate: (any RecordingSpaceGating)?
    private let engineFactory:
        @Sendable (
            AudioRecordingConfiguration,
            any AudioCheckpointSink & Sendable,
            AudioSampleClock
        ) throws -> any AudioRecordingControlling & Sendable
    private let expectedConfiguration: AudioRecordingConfiguration?
    private let fileManager: RecordingSendableFileManager
    var activeConfiguration: AudioRecordingConfiguration?
    let diagnosticBroadcaster = RecordingDiagnosticBroadcaster()
    private let progressBroadcaster = RecordingProgressBroadcaster()
    private let previewReadyBroadcaster = RecordingPreviewReadyBroadcaster()

    private var engine: (any AudioRecordingControlling & Sendable)?
    var checkpointSink: LedgerCheckpointSink?
    private var timerTask: Task<Void, Never>?
    private var sealWorkerTask: Task<Void, Never>?
    private var spaceStatusTask: Task<Void, Never>?
    private var engineProgressTask: Task<Void, Never>?
    var sealContinuation: AsyncStream<SealSignal>.Continuation?
    var sealQueue: [Int] = []
    var deferredSealIndices: Set<Int> = []
    var processingSeal = false
    private var engineProgress: RecordingProgress?
    private var lastProgressPublishedAt: ContinuousClock.Instant?
    private var startedAt: Date?
    private var started = false
    private var starting = false
    private var stopping = false
    private var spaceSafeStopRequested = false
    private var lastSpaceState: RecordingSpaceState?
    var pipelineFailure: String?
    private var stopTask: Task<AudioRecordingResult, Never>?
    private var lastResult: AudioRecordingResult?

    /// Creates a pipeline bound to one session's roots, journal, and seal service.
    ///
    /// - Parameters:
    ///   - roots: Session, index, and output roots.
    ///   - ledger: The journal that owns durable session state.
    ///   - coordinator: Segmented writer that produces checkpoints and segment bundles.
    ///   - sealService: Service that seals and publishes staged products.
    ///   - spaceGate: Optional start-time and ongoing space policy.
    ///   - engineFactory: Builds the audio engine that feeds the checkpoint sink.
    /// - Throws: `RecordingPipelineError.invalidConfiguration` when a root is not
    ///   a file URL.
    public init(
        roots: RecordingPipelineRoots,
        ledger: RecordingSessionLedger,
        coordinator: SegmentedWriterCoordinator,
        sealService: RecordingSealService,
        spaceGate: (any RecordingSpaceGating)? = nil,
        engineFactory:
            @escaping @Sendable (
                AudioRecordingConfiguration,
                any AudioCheckpointSink & Sendable,
                AudioSampleClock
            ) throws -> any AudioRecordingControlling & Sendable
    ) throws {
        guard roots.sessionRoot.isFileURL, roots.outputDirectory.isFileURL,
            roots.indexURL.isFileURL
        else { throw RecordingPipelineError.invalidConfiguration }
        self.roots = roots
        self.ledger = ledger
        self.coordinator = coordinator
        self.sealService = sealService
        self.spaceGate = spaceGate
        self.engineFactory = engineFactory
        self.expectedConfiguration = nil
        self.fileManager = RecordingSendableFileManager(.default)
    }

    init(
        roots: RecordingPipelineRoots,
        ledger: RecordingSessionLedger,
        coordinator: SegmentedWriterCoordinator,
        sealService: RecordingSealService,
        spaceGate: (any RecordingSpaceGating)?,
        engineFactory:
            @escaping @Sendable (
                AudioRecordingConfiguration,
                any AudioCheckpointSink & Sendable,
                AudioSampleClock
            ) throws -> any AudioRecordingControlling & Sendable,
        expectedConfiguration: AudioRecordingConfiguration?,
        fileManager: RecordingSendableFileManager
    ) throws {
        guard roots.sessionRoot.isFileURL, roots.outputDirectory.isFileURL,
            roots.indexURL.isFileURL
        else { throw RecordingPipelineError.invalidConfiguration }
        self.roots = roots
        self.ledger = ledger
        self.coordinator = coordinator
        self.sealService = sealService
        self.spaceGate = spaceGate
        self.engineFactory = engineFactory
        self.expectedConfiguration = expectedConfiguration
        self.fileManager = fileManager
    }

    /// Starts a 48 kHz audio session and wires its journal and seal workers.
    ///
    /// The pipeline validates the configuration, runs the space preflight, creates
    /// the session root, registers the session record, then starts the engine. The
    /// checkpoint sink batches audio into ticks and journals durable checkpoints on
    /// the checkpoint cadence, while the seal worker publishes closed segments in
    /// the background.
    ///
    /// - Parameter configuration: The requested audio configuration.
    /// - Throws: `RecordingPipelineError.alreadyStarted` when a session is active
    ///   or stopping, `RecordingPipelineError.invalidConfiguration` when the
    ///   configuration is not a 48 kHz audio session, and
    ///   `RecordingPipelineError.spacePreflightDenied` when the space gate refuses
    ///   the start. File-system and engine errors propagate unchanged.
    public func start(_ configuration: AudioRecordingConfiguration) async throws {
        guard !started, stopTask == nil else { throw RecordingPipelineError.alreadyStarted }
        guard configuration.kind == .audio, configuration.sampleRate == 48_000,
            configuration.mode != .none,
            expectedConfiguration == nil || expectedConfiguration == configuration
        else { throw RecordingPipelineError.invalidConfiguration }
        if let spaceGate {
            let decision = try await spaceGate.preflightStart()
            guard decision.allowed else {
                throw RecordingPipelineError.spacePreflightDenied(decision)
            }
        }
        try prepareSessionRoot()
        activeConfiguration = configuration
        let startDate = Date()
        try await ledger.register(
            RecordingSessionRecord(
                id: ledger.sessionID,
                kind: configuration.kind,
                layout: configuration.layout,
                startedAt: startDate,
                segments: []
            ))
        startedAt = startDate
        lastProgressPublishedAt = nil
        starting = true

        let (stream, continuation) = AsyncStream.makeStream(
            of: SealSignal.self,
            bufferingPolicy: .bufferingNewest(64)
        )
        sealContinuation = continuation
        let previewReadyBroadcaster = self.previewReadyBroadcaster
        let sink = LedgerCheckpointSink(
            coordinator: coordinator,
            ledger: ledger,
            spaceGate: spaceGate,
            onSegmentClosed: { index, checkpointID in
                continuation.yield(.closed(index))
                if let checkpointID { previewReadyBroadcaster.yield(.checkpoint(checkpointID)) }
            },
            onSpaceStatus: { [weak self] status in await self?.receiveSpaceStatus(status) }
        )
        checkpointSink = sink
        sealWorkerTask = Task(priority: .utility) { [weak self] in
            await self?.consumeSealSignals(stream)
        }
        if let spaceGate {
            let statuses = spaceGate.makeStatusStream()
            spaceStatusTask = Task(priority: .utility) { [weak self] in
                for await status in statuses {
                    guard !Task.isCancelled else { break }
                    await self?.receiveSpaceStatus(status)
                }
            }
        }
        let ticksPerSecond = AudioSourceTimestampMapper.nativeHostTicksPerSecond()
        let clock = AudioSampleClock(
            epochHostTime: AudioGetCurrentHostTime(),
            hostTicksPerSecond: ticksPerSecond,
            sampleRate: configuration.sampleRate
        )
        try await startEngine(configuration, sink: sink, clock: clock, continuation: continuation)
    }

    /// Builds the engine, starts it, and wires its progress stream.
    ///
    /// On failure the seal stream and space-status task are torn down in the
    /// same order the caller used before this step was extracted.
    private func startEngine(
        _ configuration: AudioRecordingConfiguration,
        sink: LedgerCheckpointSink,
        clock: AudioSampleClock,
        continuation: AsyncStream<SealSignal>.Continuation
    ) async throws {
        do {
            let newEngine = try engineFactory(configuration, sink, clock)
            try await newEngine.start(configuration)
            engine = newEngine
            started = true
            starting = false
            diagnosticBroadcaster.yield(.init(phase: .sessionStarted, sessionID: ledger.sessionID))
            let progress = newEngine.makeProgressStream()
            engineProgressTask = Task { [weak self] in
                for await value in progress {
                    guard !Task.isCancelled else { break }
                    await self?.acceptEngineProgress(value)
                }
            }
            startCheckpointTimer()
            scheduleSpaceSafeStopIfNeeded()
            await publishProgress()
        } catch {
            starting = false
            spaceSafeStopRequested = false
            continuation.finish()
            await sealWorkerTask?.value
            sealWorkerTask = nil
            spaceStatusTask?.cancel()
            spaceStatusTask = nil
            throw error
        }
    }

    /// Stops capture, drains the final checkpoints, and returns the session result.
    ///
    /// Repeated calls return the same result instead of stopping twice. The final
    /// segment is closed and journaled before the result is built, so the reported
    /// segment count and checkpoint age reflect durable state.
    ///
    /// - Returns: The final outcome, including any pipeline failure summary.
    public func stop() async -> AudioRecordingResult {
        if let result = lastResult { return result }
        if let stopTask { return await stopTask.value }
        let task = Task { [weak self] in
            guard let self else {
                return AudioRecordingResult(
                    sessionID: UUID(), kind: .audio, layout: .mixed,
                    segmentCount: 0, droppedRanges: [], checkpointAge: 0,
                    failure: "recording pipeline was released"
                )
            }
            return await self.performStop()
        }
        stopTask = task
        return await task.value
    }

    /// Applies a source-route change at its sample position.
    ///
    /// - Parameter event: The route change to apply.
    /// - Returns: The engine's commit result, or `.unchanged` when no engine is active.
    public func applyRoute(_ event: RouteEvent) async -> RouteCommitResult {
        guard let engine else { return .unchanged(reason: "recording pipeline is not active") }
        return await engine.applyRoute(event)
    }

    /// Creates a progress stream that replays the latest snapshot to a new subscriber.
    ///
    /// Updates are throttled to roughly ten per second while capture runs.
    ///
    /// - Returns: A stream of progress snapshots.
    public nonisolated func makeProgressStream() -> AsyncStream<RecordingProgress> {
        progressBroadcaster.makeStream()
    }

    /// Creates a stream of media that became safe to preview.
    ///
    /// Every closed checkpoint is announced as a `PreviewTarget.checkpoint` value;
    /// the stream finishes when the session stops.
    ///
    /// - Returns: A stream of preview targets.
    public nonisolated func makePreviewReadyStream() -> AsyncStream<PreviewTarget> {
        previewReadyBroadcaster.makeStream()
    }

    /// Creates a stream of lifecycle diagnostics for this session.
    ///
    /// Subscribers see only events emitted after they subscribe; the stream carries
    /// no media paths or samples.
    ///
    /// - Returns: A stream of diagnostic events.
    public func makeDiagnosticsStream() -> AsyncStream<RecordingPipelineDiagnosticEvent> {
        diagnosticBroadcaster.makeStream()
    }

    /// Returns the session state currently journaled by the ledger.
    ///
    /// - Returns: The projected session record.
    /// - Throws: A ledger error when the journal cannot be projected.
    public func snapshot() async throws -> RecordingSessionRecord { try await ledger.snapshot() }

    /// Creates a preview service bound to this session's ledger.
    ///
    /// - Returns: A service that issues read-only preview leases.
    public func makePreviewService() -> RecordingPreviewService {
        RecordingPreviewService(ledger: ledger, fileManager: fileManager)
    }

    /// Returns the most recent published audio file for the completion HUD.
    public func latestPublishedFileURL() async -> URL? {
        guard let record = try? await ledger.snapshot(),
            let segment = record.segments
                .filter({ $0.state == .published })
                .max(by: { $0.index < $1.index }),
            let relativePath = segment.files.values.sorted().first
        else { return nil }
        return try? RecordingLedgerFileSystem.resolve(relativePath, under: roots.outputDirectory)
    }

    /// Publishes a segment from its durable intent after an interrupted seal.
    ///
    /// The product is resolved from the recorded intent, verified as a publication
    /// candidate, published, and journaled as a published segment. A recovered
    /// diagnostic is emitted so observers can refresh their session list.
    ///
    /// - Parameter segmentID: Identity of the segment to publish.
    /// - Returns: The sealed segment that was published.
    /// - Throws: A ledger error when the intent or candidate is missing or invalid,
    ///   and a seal-service error when publication fails.
    public func resumePublish(segmentID: UUID) async throws -> SealedSegment {
        let intent = try await ledger.publishIntent(segmentID: segmentID)
        let candidate = try await ledger.segmentPublicationCandidate(segmentID: segmentID)
        let result = try await sealService.publishPrepared(candidate)
        try await ledger.markPublished(try makePublishedRecord(result, intent: intent, coverage: candidate.coverage))
        diagnosticBroadcaster.yield(
            .init(
                phase: .recovered, sessionID: ledger.sessionID,
                segmentIndex: result.index,
                range: RecordingSampleRange(
                    startSample: result.effectiveRange.startSample,
                    sampleCount: result.effectiveRange.sampleCount
                )
            ))
        await publishProgress()
        return result
    }

    /// Explicit retry entry point for commits retained after a journal failure.
    public func retryPendingJournal() async throws {
        try await checkpointSink?.retryPendingJournal()
        await publishProgress()
    }

    private func performStop() async -> AudioRecordingResult {
        stopping = true
        timerTask?.cancel()
        await timerTask?.value
        timerTask = nil
        let engineResult: AudioRecordingResult
        if let engine {
            engineResult = await engine.stop()
        } else {
            engineResult = AudioRecordingResult(
                sessionID: ledger.sessionID, kind: .audio, layout: .mixed,
                segmentCount: 0, droppedRanges: [], checkpointAge: 0,
                failure: started ? "engine unavailable" : "recording pipeline was not started"
            )
        }
        do {
            try await checkpointSink?.finishTail()
        } catch {
            pipelineFailure = pipelineFailure ?? "final journal/segment close failed: \(error)"
        }
        sealContinuation?.finish()
        sealContinuation = nil
        await sealWorkerTask?.value
        sealWorkerTask = nil
        spaceStatusTask?.cancel()
        spaceStatusTask = nil
        engineProgressTask?.cancel()
        engineProgressTask = nil

        let record = (try? await ledger.snapshot())
        let publishedCount = record?.segments.filter { $0.state == .published }.count ?? 0
        let facts = await checkpointSink?.checkpointFacts()
        let age = facts?.committedAt.map { max(0, Date().timeIntervalSince($0)) } ?? 0
        let failure = pipelineFailure ?? engineResult.failure
        let result = AudioRecordingResult(
            sessionID: ledger.sessionID,
            kind: engineResult.kind,
            layout: engineResult.layout,
            segmentCount: publishedCount,
            droppedRanges: engineResult.droppedRanges,
            checkpointAge: age,
            failure: failure
        )
        lastResult = result
        stopping = false
        await publishProgress()
        previewReadyBroadcaster.finish()
        return result
    }

    private func prepareSessionRoot() throws {
        let sessionRoot = ledger.sessionRoot
        let sessionsRoot = sessionRoot.deletingLastPathComponent()
        do {
            let canonicalParent = try RecordingLedgerFileSystem.canonicalDirectory(sessionsRoot, create: false)
            guard canonicalParent.path == sessionsRoot.standardizedFileURL.path else {
                throw RecordingPipelineError.invalidConfiguration
            }
            _ = try RecordingLedgerFileSystem.validateChild(
                sessionRoot, under: sessionsRoot, allowingMissing: true
            )
            if !fileManager.value.fileExists(atPath: sessionRoot.path) {
                try fileManager.value.createDirectory(
                    at: sessionRoot, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            _ = try RecordingLedgerFileSystem.validateChild(sessionRoot, under: sessionsRoot)
            guard RecordingLedgerFileSystem.isDirectory(sessionRoot) else {
                throw RecordingPipelineError.invalidConfiguration
            }
        } catch {
            throw RecordingPipelineError.invalidConfiguration
        }
    }

    private func receiveSpaceStatus(_ status: RecordingSpaceStatus) {
        if lastSpaceState != status.state {
            lastSpaceState = status.state
            diagnosticBroadcaster.yield(
                .init(
                    phase: .spaceStateChanged,
                    sessionID: ledger.sessionID
                ))
        }
        switch status.state {
        case .stopping:
            requestSpaceSafeStop(reason: status.reason ?? "recording space is no longer safe")
        case .blocked where started || starting:
            requestSpaceSafeStop(reason: status.reason ?? "recording space gate blocked the active session")
        case .ok, .low, .blocked:
            break
        }
        signalSealRetry()
    }

    func requestSpaceSafeStop(reason: String) {
        guard !spaceSafeStopRequested, lastResult == nil else { return }
        spaceSafeStopRequested = true
        pipelineFailure = pipelineFailure ?? "recording space gate requested safe stop: \(reason)"
        scheduleSpaceSafeStopIfNeeded()
    }

    private func scheduleSpaceSafeStopIfNeeded() {
        guard spaceSafeStopRequested, started, !starting, stopTask == nil, lastResult == nil else { return }
        Task { [weak self] in _ = await self?.stop() }
    }

    /// How often the pipeline journals a durable audio checkpoint.
    ///
    /// Ten seconds bounds how much audio an interrupted session can lose, which is
    /// what makes the recovery list worth showing. It is deliberately independent
    /// of `RecordingSegmentPolicy.maximumCheckpointAge` (300 s): that value is the
    /// target coverage a segment must reach before the seal step may close it,
    /// while this interval only decides how often a recovery point becomes
    /// durable. Shortening this interval changes no seal, planner, or space-gate
    /// constant.
    public static let checkpointIntervalSeconds: Int64 = 10

    private func startCheckpointTimer() {
        timerTask = Task(priority: .utility) { [weak self] in
            let clock = ContinuousClock()
            while !Task.isCancelled {
                do { try await clock.sleep(for: .seconds(Self.checkpointIntervalSeconds)) } catch { break }
                guard !Task.isCancelled else { break }
                await self?.checkpointTimerFired()
            }
        }
    }

    private func checkpointTimerFired() async {
        guard let checkpointSink, !stopping else { return }
        do {
            let commits = try await checkpointSink.commitReadyCheckpoints()
            for commit in commits {
                diagnosticBroadcaster.yield(
                    .init(
                        phase: .checkpointCommitted,
                        sessionID: ledger.sessionID,
                        segmentIndex: commit.segmentIndex,
                        range: RecordingSampleRange(
                            startSample: commit.range.startSample,
                            sampleCount: commit.range.sampleCount
                        )
                    ))
            }
            await publishProgress()
        } catch {
            pipelineFailure = pipelineFailure ?? "checkpoint journal deferred: \(error)"
        }
        sealContinuation?.yield(.retry)
    }

    private func acceptEngineProgress(_ value: RecordingProgress) async {
        engineProgress = value
        await publishProgress()
    }

    func publishProgress() async {
        guard let startDate = startedAt else { return }
        let facts = await ledger.progressFacts()
        let now = ContinuousClock.now
        if let last = lastProgressPublishedAt,
            last.duration(to: now) < .milliseconds(100)
        {
            return
        }
        lastProgressPublishedAt = now
        let elapsed = max(
            Double(facts.sampleEnd) / 48_000,
            engineProgress?.elapsedSeconds ?? 0,
            max(0, Date().timeIntervalSince(startDate))
        )
        let checkpointAge = facts.committedAt.map { max(0, Date().timeIntervalSince($0)) } ?? 0
        progressBroadcaster.yield(
            RecordingProgress(
                sessionID: ledger.sessionID,
                elapsedSeconds: elapsed,
                savedSegments: facts.publishedCount,
                checkpointAgeSeconds: checkpointAge,
                droppedSamples: engineProgress?.droppedSamples ?? 0,
                systemLevel: engineProgress?.systemLevel ?? 0,
                micLevel: engineProgress?.micLevel ?? 0,
                capturedSamples: engineProgress?.capturedSamples ?? 0
            ))
    }
}

private final class RecordingProgressBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<RecordingProgress>.Continuation] = [:]
    private var latest: RecordingProgress?

    func makeStream() -> AsyncStream<RecordingProgress> {
        lock.lock()
        defer { lock.unlock() }
        guard continuations.count < 32 else {
            return AsyncStream { $0.finish() }
        }
        let id = UUID()
        let stream = AsyncStream<RecordingProgress>(bufferingPolicy: .bufferingNewest(8)) { continuation in
            continuations[id] = continuation
            if let latest { continuation.yield(latest) }
            continuation.onTermination = { [weak self] _ in self?.remove(id) }
        }
        return stream
    }

    func yield(_ value: RecordingProgress) {
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
}

private final class RecordingPreviewReadyBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<PreviewTarget>.Continuation] = [:]
    private var latest: PreviewTarget?
    private var finished = false

    func makeStream() -> AsyncStream<PreviewTarget> {
        lock.lock()
        defer { lock.unlock() }
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: PreviewTarget.self,
            bufferingPolicy: .bufferingNewest(8)
        )
        if let latest { continuation.yield(latest) }
        guard !finished else {
            continuation.finish()
            return stream
        }
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in self?.remove(id) }
        return stream
    }

    func yield(_ target: PreviewTarget) {
        lock.lock()
        latest = target
        let targets = Array(continuations.values)
        lock.unlock()
        targets.forEach { $0.yield(target) }
    }

    func finish() {
        lock.lock()
        finished = true
        let targets = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        targets.forEach { $0.finish() }
    }

    private func remove(_ id: UUID) {
        lock.lock()
        continuations[id] = nil
        lock.unlock()
    }
}

final class RecordingDiagnosticBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<RecordingPipelineDiagnosticEvent>.Continuation] = [:]

    func makeStream() -> AsyncStream<RecordingPipelineDiagnosticEvent> {
        lock.lock()
        defer { lock.unlock() }
        guard continuations.count < 16 else { return AsyncStream { $0.finish() } }
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in self?.remove(id) }
        }
    }

    func yield(_ event: RecordingPipelineDiagnosticEvent) {
        lock.lock()
        let targets = Array(continuations.values)
        lock.unlock()
        targets.forEach { $0.yield(event) }
    }

    private func remove(_ id: UUID) {
        lock.lock()
        continuations[id] = nil
        lock.unlock()
    }
}
