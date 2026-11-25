// swiftlint:disable file_length
import AudioToolbox
import Foundation
import OSLog

/// Drives one asynchronous pump callback at a monotonic cadence.
public protocol AudioTickScheduling: Sendable {
    /// Starts delivering ticks to the handler.
    ///
    /// - Parameter handler: Async callback invoked once per control cycle.
    func start(_ handler: @escaping @Sendable () async -> Void) async

    /// Stops delivering ticks and joins the control task.
    func stop() async
}

/// The production control-task scheduler.
///
/// The task sleeps on `ContinuousClock`; it never busy-waits and never creates
/// one task per tick. A slow handler naturally backpressures the cadence.
public final class AudioContinuousTickScheduler: AudioTickScheduling, @unchecked Sendable {
    private let cadence: Duration
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    /// Creates a scheduler.
    ///
    /// - Parameter cadence: Delay between handler invocations.
    public init(cadence: Duration = .milliseconds(5)) {
        self.cadence = cadence
    }

    /// Starts the control task, replacing any previous task.
    ///
    /// - Parameter handler: Callback invoked once per cadence.
    public func start(_ handler: @escaping @Sendable () async -> Void) async {
        await stop()
        let cadence = self.cadence
        let task = Task {
            while !Task.isCancelled {
                await handler()
                do {
                    try await Task.sleep(for: cadence)
                } catch {
                    return
                }
            }
        }
        store(task)
    }

    /// Cancels and joins the control task.
    public func stop() async {
        let task = takeTask()
        task?.cancel()
        await task?.value
    }

    private func store(_ task: Task<Void, Never>) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    private func takeTask() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        let value = task
        task = nil
        return value
    }
}

/// The sources, controller, and pump that make up one recording session.
public struct AudioEngineSessionComponents: Sendable {
    /// Sources keyed by role.
    public let sources: [RecordingTrackRole: any AudioFrameSource]
    /// Route controller for this session.
    public let routeController: AudioRouteController
    /// Pump configured for this session's layout.
    public let pump: AudioMixPump

    /// Creates a session component set.
    ///
    /// - Parameters:
    ///   - sources: Sources keyed by role.
    ///   - routeController: Session route controller.
    ///   - pump: Session pump.
    public init(
        sources: [RecordingTrackRole: any AudioFrameSource],
        routeController: AudioRouteController,
        pump: AudioMixPump
    ) {
        self.sources = sources
        self.routeController = routeController
        self.pump = pump
    }
}

/// An engine configuration or lifecycle failure.
public enum AudioRecordingEngineError: Error, Equatable {
    /// A session is already starting or recording.
    case alreadyRecording
    /// No session is active.
    case notRecording
    /// The configuration cannot be produced by this engine.
    case invalidConfiguration(String)
    /// Repeated sessions need a fresh-session factory.
    case sessionFactoryUnavailable
    /// The source route could not be started or committed.
    case startFailed(String)
}

/// A control-side snapshot of engine state.
public struct AudioEngineDiagnosticsSnapshot: Sendable {
    /// Current recording lifecycle.
    public let phase: RecordingLifecycle
    /// Number of active progress streams.
    public let progressSubscriberCount: Int
    /// PCM blocks appended to the sink.
    public let sinkAppendCount: Int64
    /// Checkpoints committed to the sink.
    public let sinkCommitCount: Int64
    /// Blocks currently waiting for the sink to accept them.
    public let sinkBacklogEstimate: Int
    /// Age of the newest durable checkpoint, or `nil` before the first commit.
    public let checkpointAgeSeconds: Double?
    /// Whether stop drained every joined producer and committed the session.
    public let isStopFinalized: Bool
    /// Sources whose producer has not joined yet.
    public let pendingJoinCount: Int

    /// Creates a diagnostics snapshot.
    ///
    /// - Parameters:
    ///   - phase: Current recording lifecycle.
    ///   - progressSubscriberCount: Active progress streams.
    ///   - sinkAppendCount: Appended PCM blocks.
    ///   - sinkCommitCount: Committed checkpoints.
    ///   - sinkBacklogEstimate: Blocks waiting for the sink.
    ///   - checkpointAgeSeconds: Age of the newest checkpoint, if any.
    ///   - isStopFinalized: Whether stop fully finalized.
    ///   - pendingJoinCount: Sources whose producer has not joined.
    public init(
        phase: RecordingLifecycle,
        progressSubscriberCount: Int,
        sinkAppendCount: Int64,
        sinkCommitCount: Int64,
        sinkBacklogEstimate: Int,
        checkpointAgeSeconds: Double?,
        isStopFinalized: Bool,
        pendingJoinCount: Int
    ) {
        self.phase = phase
        self.progressSubscriberCount = progressSubscriberCount
        self.sinkAppendCount = sinkAppendCount
        self.sinkCommitCount = sinkCommitCount
        self.sinkBacklogEstimate = sinkBacklogEstimate
        self.checkpointAgeSeconds = checkpointAgeSeconds
        self.isStopFinalized = isStopFinalized
        self.pendingJoinCount = pendingJoinCount
    }
}

/// Runs real T5 sources/controller and a real T4 pump for one audio recording session.
///
/// The engine never starts platform capture itself. A composition root supplies
/// already-built sources and a controller. Tests may inject fake sources, a fake
/// host clock, and a fake scheduler while the pump, rings, policy, and factory
/// remain real. A new session always uses a fresh controller through
/// ``AudioEngineSessionComponents`` because T5 shutdown is terminal.
public final class AudioRecordingEngine: AudioRecordingControlling, @unchecked Sendable {
    private struct State {
        var phase: RecordingLifecycle = .idle
        var configuration: AudioRecordingConfiguration?
        var sessionID: UUID?
        var result: AudioRecordingResult?
        var stopTask: Task<AudioRecordingResult, Never>?
        var components: AudioEngineSessionComponents?
        var everEnabledRoles: Set<RecordingTrackRole> = []
        var lastGenerationIDs: [RecordingTrackRole: UUID] = [:]
        var failure: String?
        var sinkAppendCount: Int64 = 0
        var sinkCommitCount: Int64 = 0
        var sinkBacklog = 0
        var lastCommitDate: Date?
        var systemLevel: Float = 0
        var micLevel: Float = 0
        var lastProgressPublishedAt: ContinuousClock.Instant?
        var droppedRanges: [SampleRange] = []
        var stopFinalized = false
        var pendingJoinCount = 0
        var pendingRouteBoundary: Int64?
        var usedInitialComponents = false
    }

    private let sink: any AudioCheckpointSink & Sendable
    private let clock: AudioSampleClock
    private let scheduler: any AudioTickScheduling
    private let initialComponents: AudioEngineSessionComponents
    private let sessionFactory: (@Sendable () -> AudioEngineSessionComponents)?
    private let hostClock: @Sendable () -> UInt64
    private let joinTimeout: Duration
    private let gate = AudioControlGate()
    private let stateLock = NSLock()
    private let progress = AudioProgressBroadcaster()
    private let logger = Logger(subsystem: "com.snapglass", category: "recording.engine")
    private var state = State()

    /// Creates an engine for one recording session and later fresh sessions.
    ///
    /// - Parameters:
    ///   - sink: Durable checkpoint sink; only the Task 1 protocol is used.
    ///   - clock: Session clock whose sample zero is the recording epoch.
    ///   - sources: Sources keyed by role for the first session.
    ///   - routeController: First session route controller.
    ///   - pump: First session pump.
    ///   - scheduler: Tick scheduler; defaults to the production control task.
    ///   - sessionFactory: Fresh components for every later session.
    ///   - hostClock: Monotonic host ticks in the clock's domain.
    ///   - joinTimeout: Maximum wait for producers to join at stop.
    public init(
        sink: any AudioCheckpointSink & Sendable,
        clock: AudioSampleClock,
        sources: [RecordingTrackRole: any AudioFrameSource],
        routeController: AudioRouteController,
        pump: AudioMixPump,
        scheduler: any AudioTickScheduling = AudioContinuousTickScheduler(),
        sessionFactory: (@Sendable () -> AudioEngineSessionComponents)? = nil,
        hostClock: (@Sendable () -> UInt64)? = nil,
        joinTimeout: Duration = .seconds(2)
    ) {
        self.sink = sink
        self.clock = clock
        self.initialComponents = AudioEngineSessionComponents(
            sources: sources,
            routeController: routeController,
            pump: pump
        )
        self.sessionFactory = sessionFactory
        self.scheduler = scheduler
        self.hostClock = hostClock ?? { AudioGetCurrentHostTime() }
        self.joinTimeout = joinTimeout
    }

    /// Starts a session with the supplied configuration.
    ///
    /// - Parameter configuration: Immutable session settings.
    /// - Throws: ``AudioRecordingEngineError`` when the session cannot start.
    public func start(_ configuration: AudioRecordingConfiguration) async throws {
        try validate(configuration)
        await gate.acquire()
        guard canStartLocked() else {
            await gate.release()
            throw AudioRecordingEngineError.alreadyRecording
        }
        setPhase(.preparing)
        do {
            let components = try takeComponentsLocked()
            try await beginSessionLocked(configuration, components: components)
            setPhase(.recording)
            await gate.release()
            publishProgress()
        } catch {
            await cleanupFailedStartLocked()
            setPhase(.failedRecoverable)
            await gate.release()
            throw Self.engineError(from: error)
        }
    }

    /// Stops capture, drains joined tails, commits, and returns one idempotent result.
    ///
    /// - Returns: The final recording result.
    public func stop() async -> AudioRecordingResult {
        let task = stopTaskLocked()
        return await task.value
    }

    /// Applies a source route at the next pump boundary.
    ///
    /// - Parameter event: Requested route change.
    /// - Returns: Whether the effective route was committed.
    public func applyRoute(_ event: RouteEvent) async -> RouteCommitResult {
        guard event.atSample >= 0 else {
            return .unchanged(reason: "sample position must be nonnegative")
        }
        guard currentPhaseLocked() == .recording else {
            return .unchanged(reason: "recording is not active")
        }
        await gate.acquire()
        guard currentPhaseLocked() == .recording, let components = currentComponentsLocked() else {
            await gate.release()
            return .unchanged(reason: "recording is not active")
        }
        do {
            let preparation = await components.routeController.prepare(event.mode)
            guard case .prepared = preparation.result else {
                await gate.release()
                if case .unchangedOnFailure(let reason) = preparation.result {
                    return .unchanged(reason: reason)
                }
                return .unchanged(reason: "route preparation failed")
            }
            guard currentPhaseLocked() == .recording else {
                _ = await components.routeController.cancelPendingPreparation()
                await gate.release()
                return .unchanged(reason: "recording stopped during preparation")
            }
            try await drainDueTicksLocked(components)
            let boundary = max(event.atSample, components.pump.nextSampleIndex)
            let commitEvent = RouteEvent(
                atSample: boundary,
                mode: preparation.effectiveMode,
                deviceID: event.deviceID
            )
            let result = await components.routeController.commit(
                commitEvent,
                preparationID: preparation.preparationID
            )
            guard case .committed = result else {
                await gate.release()
                return result
            }
            let roles = await components.routeController.currentEffectiveRoles()
            let inputs = await buildInputsLocked(
                components: components,
                effectiveRoles: roles,
                boundary: boundary
            )
            try components.pump.updateInputs(inputs)
            mergeRolesLocked(roles)
            stateLock.withLock {
                state.lastGenerationIDs = inputs.generationIDs
                let next = components.pump.nextSampleIndex
                state.pendingRouteBoundary = boundary > next ? boundary : nil
            }
            await gate.release()
            publishProgress()
            return result
        } catch {
            recordFailureLocked(error)
            await gate.release()
            return .unchanged(reason: "route update failed: \(error)")
        }
    }

    /// Creates a new bounded progress stream for one observer.
    ///
    /// - Returns: A stream that terminates when the session finishes.
    public func makeProgressStream() -> AsyncStream<RecordingProgress> {
        progress.makeStream()
    }

    /// A control-side snapshot; fields are not required to describe one instant.
    public var diagnostics: AudioEngineDiagnosticsSnapshot {
        let snapshot = stateSnapshot()
        let age = snapshot.lastCommitDate.map { Date().timeIntervalSince($0) }
        return AudioEngineDiagnosticsSnapshot(
            phase: snapshot.phase,
            progressSubscriberCount: progress.subscriberCount,
            sinkAppendCount: snapshot.sinkAppendCount,
            sinkCommitCount: snapshot.sinkCommitCount,
            sinkBacklogEstimate: snapshot.sinkBacklog,
            checkpointAgeSeconds: age,
            isStopFinalized: snapshot.stopFinalized,
            pendingJoinCount: snapshot.pendingJoinCount
        )
    }

    /// Re-reads effective roles and generations without waiting for the periodic check.
    internal func refreshInputsForTesting() async {
        await gate.acquire()
        guard currentPhaseLocked() == .recording, let components = currentComponentsLocked() else {
            await gate.release()
            return
        }
        await refreshInputsLocked(components)
        await gate.release()
    }
}

extension AudioRecordingEngine {
    private func validate(_ configuration: AudioRecordingConfiguration) throws {
        guard configuration.sampleRate == 48_000 else {
            throw AudioRecordingEngineError.invalidConfiguration("session sample rate must be 48000")
        }
        for (role, channels) in configuration.channelCountByRole {
            guard role == .system || role == .microphone || role == .mixed else {
                throw AudioRecordingEngineError.invalidConfiguration("unsupported role \(role)")
            }
            guard channels == 1 || channels == 2 else {
                throw AudioRecordingEngineError.invalidConfiguration("channel count must be one or two")
            }
        }
    }

    private func takeComponentsLocked() throws -> AudioEngineSessionComponents {
        let usedInitial = stateLock.withLock { state.usedInitialComponents }
        if !usedInitial {
            stateLock.withLock {
                state.usedInitialComponents = true
                state.components = initialComponents
                state.sessionID = UUID()
                state.failure = nil
                state.sinkAppendCount = 0
                state.sinkCommitCount = 0
                state.sinkBacklog = 0
                state.lastCommitDate = nil
                state.systemLevel = 0
                state.micLevel = 0
                state.lastProgressPublishedAt = nil
                state.droppedRanges = []
                state.stopFinalized = false
                state.pendingJoinCount = 0
                state.pendingRouteBoundary = nil
                state.everEnabledRoles = []
                state.lastGenerationIDs = [:]
                state.result = nil
                state.stopTask = nil
            }
            progress.reset()
            return initialComponents
        }
        guard let sessionFactory else {
            throw AudioRecordingEngineError.sessionFactoryUnavailable
        }
        let components = sessionFactory()
        stateLock.withLock {
            state.components = components
            state.sessionID = UUID()
            state.failure = nil
            state.sinkAppendCount = 0
            state.sinkCommitCount = 0
            state.sinkBacklog = 0
            state.lastCommitDate = nil
            state.systemLevel = 0
            state.micLevel = 0
            state.lastProgressPublishedAt = nil
            state.droppedRanges = []
            state.stopFinalized = false
            state.pendingJoinCount = 0
            state.pendingRouteBoundary = nil
            state.everEnabledRoles = []
            state.lastGenerationIDs = [:]
            state.result = nil
            state.stopTask = nil
        }
        progress.reset()
        return components
    }

    private func beginSessionLocked(
        _ configuration: AudioRecordingConfiguration,
        components: AudioEngineSessionComponents
    ) async throws {
        stateLock.withLock {
            state.configuration = configuration
        }
        let preparation = await components.routeController.prepare(configuration.mode)
        guard case .prepared = preparation.result else {
            if case .unchangedOnFailure(let reason) = preparation.result {
                throw AudioRecordingEngineError.startFailed(reason)
            }
            throw AudioRecordingEngineError.startFailed("route preparation failed")
        }
        let commitEvent = RouteEvent(
            atSample: 0,
            mode: preparation.effectiveMode,
            deviceID: nil
        )
        let commit = await components.routeController.commit(
            commitEvent,
            preparationID: preparation.preparationID
        )
        guard case .committed = commit else {
            throw AudioRecordingEngineError.startFailed("initial route commit failed")
        }
        let roles = await components.routeController.currentEffectiveRoles()
        let inputs = await buildInputsLocked(components: components, effectiveRoles: roles, boundary: 0)
        components.pump.start()
        try components.pump.updateInputs(inputs)
        mergeRolesLocked(roles)
        stateLock.withLock {
            state.lastGenerationIDs = inputs.generationIDs
        }
        guard currentPhaseLocked() == .preparing else {
            throw AudioRecordingEngineError.startFailed("recording was stopped during start")
        }
        await scheduler.start { [weak self] in
            await self?.runTick()
        }
        guard currentPhaseLocked() == .preparing else {
            throw AudioRecordingEngineError.startFailed("recording was stopped during start")
        }
    }

    private func cleanupFailedStartLocked() async {
        await scheduler.stop()
        if let components = currentComponentsLocked() {
            components.pump.stop()
            _ = await components.routeController.shutdown()
        }
        stateLock.withLock {
            state.failure = state.failure ?? "session start failed"
        }
    }

    private func buildInputsLocked(
        components: AudioEngineSessionComponents,
        effectiveRoles: Set<RecordingTrackRole>,
        boundary: Int64?
    ) async -> AudioPumpInputs {
        var rings: [RecordingTrackRole: AudioSourceRingBuffer] = [:]
        var formats: [RecordingTrackRole: AudioSourceFormat] = [:]
        var generations: [RecordingTrackRole: UUID] = [:]
        for role in effectiveRoles {
            guard role == .system || role == .microphone,
                let generation = await components.routeController.currentGeneration(for: role)
            else {
                continue
            }
            rings[role] = generation.ringBuffer
            formats[role] = generation.format
            generations[role] = generation.id
        }
        let everEnabled = stateSnapshot().everEnabledRoles.union(effectiveRoles)
        return AudioPumpInputs(
            rings: rings,
            formatsByRole: formats,
            activeRoles: effectiveRoles,
            everEnabledRoles: everEnabled,
            generationIDs: generations,
            routeBoundarySample: boundary
        )
    }

    private func mergeRolesLocked(_ roles: Set<RecordingTrackRole>) {
        stateLock.withLock {
            state.everEnabledRoles.formUnion(roles)
        }
    }

    private func runTick() async {
        guard currentPhaseLocked() == .recording else {
            return
        }
        guard await gate.acquireCancellable() else {
            return
        }
        guard currentPhaseLocked() == .recording, let components = currentComponentsLocked() else {
            await gate.release()
            return
        }
        do {
            try await drainDueTicksLocked(components)
        } catch {
            recordFailureLocked(error)
        }
        await gate.release()
    }

    private func drainDueTicksLocked(_ components: AudioEngineSessionComponents) async throws {
        for _ in 0..<16 {
            guard stateSnapshot().failure == nil else {
                return
            }
            guard let tick = try components.pump.nextTick(for: hostClock()) else {
                return
            }
            try await appendTickLocked(tick)
            if shouldCheckHealthLocked() {
                await refreshInputsLocked(components)
            }
        }
    }

    private func appendTickLocked(_ tick: AudioPumpTick) async throws {
        for role in [RecordingTrackRole.mixed, .system, .microphone] {
            guard let block = tick.blocks[role] else {
                continue
            }
            stateLock.withLock {
                state.sinkBacklog += 1
            }
            do {
                try await sink.append(block)
            } catch {
                stateLock.withLock {
                    state.sinkBacklog = max(0, state.sinkBacklog - 1)
                }
                throw error
            }
            stateLock.withLock {
                state.sinkBacklog = max(0, state.sinkBacklog - 1)
                state.sinkAppendCount += 1
                if !tick.gapFramesByRole.isEmpty {
                    state.droppedRanges.append(tick.range)
                }
            }
        }
        stateLock.withLock {
            state.systemLevel = tick.systemLevel
            state.micLevel = tick.micLevel
        }
        publishProgress()
    }

    private func shouldCheckHealthLocked() -> Bool {
        stateLock.withLock {
            let should = state.sinkAppendCount % 10 == 0
            return should
        }
    }

    private func refreshInputsLocked(_ components: AudioEngineSessionComponents) async {
        if let boundary = stateSnapshot().pendingRouteBoundary {
            if components.pump.nextSampleIndex < boundary {
                return
            }
            stateLock.withLock {
                state.pendingRouteBoundary = nil
            }
        }
        let roles = await components.routeController.currentEffectiveRoles()
        let generations = await currentGenerationIDs(components: components, roles: roles)
        let unchanged = stateLock.withLock {
            roles == Set(state.lastGenerationIDs.keys) && generations == state.lastGenerationIDs
        }
        if unchanged {
            return
        }
        let inputs = await buildInputsLocked(
            components: components,
            effectiveRoles: roles,
            boundary: nil
        )
        do {
            try components.pump.updateInputs(inputs)
            mergeRolesLocked(roles)
            stateLock.withLock {
                state.lastGenerationIDs = inputs.generationIDs
            }
            publishProgress()
        } catch {
            recordFailureLocked(error)
        }
    }

    private func currentGenerationIDs(
        components: AudioEngineSessionComponents,
        roles: Set<RecordingTrackRole>
    ) async -> [RecordingTrackRole: UUID] {
        var values: [RecordingTrackRole: UUID] = [:]
        for role in roles {
            if let generation = await components.routeController.currentGeneration(for: role) {
                values[role] = generation.id
            }
        }
        return values
    }
}

extension AudioRecordingEngine {
    private func stopTaskLocked() -> Task<AudioRecordingResult, Never> {
        stateLock.withLock {
            if let task = state.stopTask {
                return task
            }
            let task = Task { [weak self] in
                guard let self else {
                    return AudioRecordingResult(
                        sessionID: UUID(),
                        kind: .audio,
                        layout: .mixed,
                        segmentCount: 0,
                        droppedRanges: [],
                        checkpointAge: 0,
                        failure: "engine was released"
                    )
                }
                return await self.performStop()
            }
            state.stopTask = task
            return task
        }
    }

    private func performStop() async -> AudioRecordingResult {
        setPhase(.stopping)
        await scheduler.stop()
        await gate.acquire()
        let components = currentComponentsLocked()
        var failure = stateSnapshot().failure
        var joined = true
        var retired: [AudioSourceGeneration] = []
        if let components {
            _ = await components.routeController.cancelPendingPreparation()
            joined = await components.routeController.shutdown()
            retired = await components.routeController.takeRetiredGenerations()
            if !joined {
                await waitForProducers(components)
                joined = await components.routeController.shutdown()
                retired += await components.routeController.takeRetiredGenerations()
            }
            components.pump.stop()
            let joinedIDs = Set(retired.map(\.id))
            do {
                let ticks = try components.pump.drainForStop(joinedGenerationIDs: joinedIDs)
                for tick in ticks {
                    try await appendTickLocked(tick)
                }
            } catch {
                failure = failure ?? "tail drain failed: \(error)"
            }
            let pending = await countPendingProducers(components)
            let appendCount = stateSnapshot().sinkAppendCount
            if appendCount > 0, joined, pending == 0, failure == nil {
                do {
                    _ = try await sink.commitCheckpoint()
                    stateLock.withLock {
                        state.sinkCommitCount += 1
                        state.lastCommitDate = Date()
                        state.stopFinalized = true
                    }
                } catch {
                    failure = "checkpoint commit failed: \(error)"
                }
            } else if failure == nil, !joined || pending > 0 {
                failure = "producer did not join before finalization"
            }
            stateLock.withLock {
                state.pendingJoinCount = pending
                state.stopFinalized = joined && pending == 0 && failure == nil
            }
        }
        if components != nil, !joined, failure == nil {
            failure = "producer did not join before finalization"
        }
        if components == nil, failure == nil {
            failure = "no recording session was active"
        }
        let result = makeResultLocked(failure: failure)
        await gate.release()
        publishFinalProgress()
        setResultLocked(result)
        setPhase(.finished)
        return result
    }

    private func waitForProducers(_ components: AudioEngineSessionComponents) async {
        let deadline = ContinuousClock.now.advanced(by: joinTimeout)
        while ContinuousClock.now < deadline {
            let pending = await countPendingProducers(components)
            if pending == 0 {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func countPendingProducers(_ components: AudioEngineSessionComponents) async -> Int {
        var pending = 0
        for source in components.sources.values where !(await source.isProducerJoined()) {
            pending += 1
        }
        return pending
    }

    private func makeResultLocked(failure: String?) -> AudioRecordingResult {
        let snapshot = stateSnapshot()
        let configuration = snapshot.configuration
        let age = snapshot.lastCommitDate.map { Date().timeIntervalSince($0) } ?? 0
        return AudioRecordingResult(
            sessionID: snapshot.sessionID ?? UUID(),
            kind: configuration?.kind ?? .audio,
            layout: configuration?.layout ?? .mixed,
            segmentCount: Int(snapshot.sinkCommitCount),
            droppedRanges: snapshot.droppedRanges,
            checkpointAge: age,
            failure: failure
        )
    }

    private func publishFinalProgress() {
        publishProgress()
        progress.finish()
    }
}

extension AudioRecordingEngine {
    private func canStartLocked() -> Bool {
        switch currentPhaseLocked() {
        case .idle, .finished, .failedRecoverable:
            return true
        default:
            return false
        }
    }

    private func currentComponentsLocked() -> AudioEngineSessionComponents? {
        stateSnapshot().components
    }

    private func stateSnapshot() -> State {
        stateLock.withLock { state }
    }

    private func currentPhaseLocked() -> RecordingLifecycle {
        stateSnapshot().phase
    }

    private func setPhase(_ phase: RecordingLifecycle) {
        stateLock.withLock {
            state.phase = phase
        }
    }

    private func setResultLocked(_ result: AudioRecordingResult) {
        stateLock.withLock {
            state.result = result
        }
    }

    private func recordFailureLocked(_ error: any Error) {
        let message = String(describing: error)
        stateLock.withLock {
            if state.failure == nil {
                state.failure = message
            }
        }
        // A tick failure silently stops every later tick. Without this line the session
        // looks like "waiting forever" with no diagnostic anywhere.
        logger.error("audio tick failed: \(message, privacy: .public)")
    }

    private func publishProgress() {
        let shouldPublish = stateLock.withLock { () -> Bool in
            let now = ContinuousClock.now
            if let last = state.lastProgressPublishedAt,
                last.duration(to: now) < .milliseconds(100)
            {
                return false
            }
            state.lastProgressPublishedAt = now
            return true
        }
        guard shouldPublish else { return }
        let snapshot = stateSnapshot()
        guard let sessionID = snapshot.sessionID, snapshot.configuration != nil else {
            return
        }
        let nextSample = snapshot.components?.pump.nextSampleIndex ?? 0
        let capturedSamples = snapshot.components?.pump.capturedSourceFrameCount ?? 0
        let dropped = snapshot.components?.pump.diagnostics.gapFramesByRole.values.reduce(0, +) ?? 0
        let age = snapshot.lastCommitDate.map { Date().timeIntervalSince($0) } ?? 0
        progress.publish(
            RecordingProgress(
                sessionID: sessionID,
                elapsedSeconds: Double(nextSample) / 48_000,
                // The engine only owns checkpoint commits; P3's pipeline replaces this
                // with the ledger's count of actually published segments.
                savedSegments: 0,
                checkpointAgeSeconds: age,
                droppedSamples: dropped,
                systemLevel: snapshot.systemLevel,
                micLevel: snapshot.micLevel,
                capturedSamples: capturedSamples
            )
        )
    }

    private static func engineError(from error: any Error) -> AudioRecordingEngineError {
        if let error = error as? AudioRecordingEngineError {
            return error
        }
        return .startFailed(String(describing: error))
    }
}

private final class AudioProgressBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<RecordingProgress>.Continuation] = [:]
    private var finished = false
    private let maximumSubscribers = 32

    var subscriberCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return continuations.count
    }

    func reset() {
        lock.lock()
        finished = false
        lock.unlock()
    }

    func makeStream() -> AsyncStream<RecordingProgress> {
        lock.lock()
        if finished || continuations.count >= maximumSubscribers {
            lock.unlock()
            return AsyncStream { continuation in
                continuation.finish()
            }
        }
        let id = UUID()
        var captured: AsyncStream<RecordingProgress>.Continuation?
        let stream = AsyncStream<RecordingProgress>(bufferingPolicy: .bufferingNewest(8)) {
            captured = $0
        }
        guard let continuation = captured else {
            lock.unlock()
            return stream
        }
        continuations[id] = continuation
        lock.unlock()
        continuation.onTermination = { [weak self] _ in
            self?.remove(id)
        }
        return stream
    }

    func publish(_ progress: RecordingProgress) {
        lock.lock()
        let values = Array(continuations.values)
        lock.unlock()
        for continuation in values {
            continuation.yield(progress)
        }
    }

    func finish() {
        lock.lock()
        let values = Array(continuations.values)
        continuations.removeAll()
        finished = true
        lock.unlock()
        for continuation in values {
            continuation.finish()
        }
    }

    private func remove(_ id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        lock.unlock()
    }
}
