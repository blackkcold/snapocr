// swiftlint:disable file_length
import Foundation
import Testing

@testable import CaptureCore

private enum EngineTestError: Error {
    case appendFailed
}

private final class EngineHostClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    var current: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ next: UInt64) {
        lock.lock()
        value = next
        lock.unlock()
    }
}

private final class EngineAuthorizer: MicrophoneAuthorizing, @unchecked Sendable {
    var state: MicrophoneAuthorizationState

    init(_ state: MicrophoneAuthorizationState) {
        self.state = state
    }

    func currentState() -> MicrophoneAuthorizationState {
        state
    }

    func requestAccess() async -> MicrophoneAuthorizationState {
        state
    }
}

private final class EngineFakeSource: AudioFrameSource, AudioSourceReconfigurationCancelling,
    @unchecked Sendable
{
    let role: RecordingTrackRole
    let format: AudioSourceFormat
    let capacitySeconds: Double
    private let hostTicksPerSecond: UInt64
    private let lock = NSLock()
    private var generation: AudioSourceGeneration
    private var running = false
    private var closed = false

    var producerJoined = true
    var startError: (any Error)?
    var framesProvider: (@Sendable () -> [[Float]])?
    var hostTimeProvider: (@Sendable () -> UInt64)?
    private var starts = 0
    private var stops = 0

    init(role: RecordingTrackRole, format: AudioSourceFormat, capacitySeconds: Double = 2.0) throws {
        self.role = role
        self.format = format
        self.capacitySeconds = capacitySeconds
        self.hostTicksPerSecond = 24_000_000
        self.generation = try AudioSourceGeneration(
            role: role,
            format: format,
            hostTicksPerSecond: hostTicksPerSecond,
            capacitySeconds: capacitySeconds
        )
    }

    var startCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return starts
    }

    var stopCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return stops
    }

    func currentGeneration() async -> AudioSourceGeneration {
        generationSnapshot()
    }

    func isRunning() async -> Bool {
        runningSnapshot()
    }

    func isProducerJoined() async -> Bool {
        producerJoined
    }

    func start() async throws {
        if let startError {
            throw startError
        }
        guard let next = beginStart() else {
            return
        }
        if let frames = framesProvider?() {
            write(frames, to: next.ringBuffer)
        }
        markRunning()
    }

    func stop() async {
        let state = takeStopState()
        guard state.wasOpen else {
            return
        }
        state.ring.requestClose()
        if producerJoined {
            _ = state.ring.finishProducing()
        }
    }

    func prepareReconfiguration(_ event: AudioDeviceChangeEvent) async -> AudioSourcePreparation {
        .unchangedOnFailure(reason: "not supported in engine tests")
    }

    func commitReconfiguration(_ generation: AudioSourceGeneration) async -> Bool {
        generationSnapshot().id == generation.id
    }

    func cancelReconfiguration(_ generationID: UUID) async {}

    func failHealth() {
        lock.lock()
        running = false
        lock.unlock()
    }

    private func runningSnapshot() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func generationSnapshot() -> AudioSourceGeneration {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    private func beginStart() -> AudioSourceGeneration? {
        lock.lock()
        defer { lock.unlock() }
        guard !running else {
            return nil
        }
        guard
            let next = try? AudioSourceGeneration(
                role: role,
                format: format,
                hostTicksPerSecond: hostTicksPerSecond,
                capacitySeconds: capacitySeconds
            )
        else {
            return nil
        }
        generation = next
        closed = false
        starts += 1
        return next
    }

    private func markRunning() {
        lock.lock()
        running = true
        lock.unlock()
    }

    private func takeStopState() -> (ring: AudioSourceRingBuffer, wasOpen: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let ring = generation.ringBuffer
        let wasOpen = !closed
        closed = true
        running = false
        stops += 1
        return (ring, wasOpen)
    }

    private func write(_ channels: [[Float]], to ring: AudioSourceRingBuffer) {
        let frames = channels.first?.count ?? 0
        let hostTime = hostTimeProvider?() ?? 0
        if channels.count == 1 {
            channels[0].withUnsafeBufferPointer { first in
                _ = ring.write(planar: [first], frameCount: frames, hostTime: hostTime)
            }
            return
        }
        channels[0].withUnsafeBufferPointer { first in
            channels[1].withUnsafeBufferPointer { second in
                _ = ring.write(planar: [first, second], frameCount: frames, hostTime: hostTime)
            }
        }
    }
}

private final class EngineFakeScheduler: AudioTickScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable () async -> Void)?
    private var starts = 0
    private var stops = 0

    var startCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return starts
    }

    var stopCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return stops
    }

    func start(_ handler: @escaping @Sendable () async -> Void) async {
        store(handler)
    }

    func stop() async {
        clearHandler()
    }

    func runOnce() async {
        let handler = currentHandler()
        await handler?()
    }

    private func store(_ handler: @escaping @Sendable () async -> Void) {
        lock.lock()
        self.handler = handler
        starts += 1
        lock.unlock()
    }

    private func clearHandler() {
        lock.lock()
        handler = nil
        stops += 1
        lock.unlock()
    }

    private func currentHandler() -> (@Sendable () async -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return handler
    }
}

private actor RecordingEngineSink: AudioCheckpointSink {
    private(set) var blocks: [AudioPCMBlock] = []
    private(set) var commits = 0
    private var failAtBlock: Int?

    func failAppends(at index: Int) {
        failAtBlock = index
    }

    func append(_ block: AudioPCMBlock) async throws {
        if let failAtBlock, blocks.count >= failAtBlock {
            throw EngineTestError.appendFailed
        }
        blocks.append(block)
    }

    func commitCheckpoint() async throws -> CheckpointCommit {
        commits += 1
        return CheckpointCommit(
            checkpointID: UUID(),
            segmentIndex: commits - 1,
            range: SampleRange(startSample: 0, sampleCount: 0),
            trackURLs: [.mixed: URL(fileURLWithPath: "/tmp/test.caf")],
            committedAt: Date()
        )
    }
}

private actor BlockingEngineSink: AudioCheckpointSink {
    private var started = false
    private var blocking = true
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func append(_ block: AudioPCMBlock) async throws {
        guard blocking else {
            return
        }
        if !started {
            started = true
            startedWaiter?.resume()
            startedWaiter = nil
        }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilAppending() async {
        if started {
            return
        }
        await withCheckedContinuation { continuation in
            startedWaiter = continuation
        }
    }

    func release() {
        blocking = false
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func commitCheckpoint() async throws -> CheckpointCommit {
        CheckpointCommit(
            checkpointID: UUID(),
            segmentIndex: 0,
            range: SampleRange(startSample: 0, sampleCount: 0),
            trackURLs: [.mixed: URL(fileURLWithPath: "/tmp/test.caf")],
            committedAt: Date()
        )
    }
}

// swiftlint:disable:next type_body_length
struct AudioRecordingEngineTests {
    private let sampleRate = 48_000
    private let hostTicksPerSecond: UInt64 = 24_000_000

    private func clock() -> AudioSampleClock {
        AudioSampleClock(
            epochHostTime: 0,
            hostTicksPerSecond: hostTicksPerSecond,
            sampleRate: sampleRate
        )
    }

    private func hostTime(forSample sample: Int64) -> UInt64 {
        UInt64(sample) * hostTicksPerSecond / UInt64(sampleRate)
    }

    private func frames(_ value: Float, count: Int, channels: Int = 1) -> [[Float]] {
        (0..<channels).map { _ in [Float](repeating: value, count: count) }
    }

    private func configuration(
        mode: AudioSourceMode,
        layout: AudioOutputLayout
    ) -> AudioRecordingConfiguration {
        let roles: Set<RecordingTrackRole> =
            mode == .systemAndMicrophone ? [.system, .microphone] : [.system]
        let channels = Dictionary(uniqueKeysWithValues: roles.map { ($0, 1) })
        return AudioRecordingConfiguration(
            kind: .audio,
            mode: mode,
            layout: layout,
            sampleRate: sampleRate,
            channelCountByRole: channels.merging([.mixed: 1]) { first, _ in first },
            bitRate: 128_000
        )
    }

    private func pump(layout: AudioOutputLayout) -> AudioMixPump {
        AudioMixPump(
            clock: clock(),
            policy: AudioMixPolicy(sampleRate: sampleRate),
            layout: layout,
            blockFrames: 480,
            channelCountByRole: [.system: 1, .microphone: 1, .mixed: 1]
        )
    }

    // swiftlint:disable:next function_parameter_count
    private func engine(
        sink: any AudioCheckpointSink & Sendable,
        sources: [RecordingTrackRole: any AudioFrameSource],
        controller: AudioRouteController,
        layout: AudioOutputLayout,
        hostClock: EngineHostClock,
        scheduler: EngineFakeScheduler,
        sessionFactory: (@Sendable () -> AudioEngineSessionComponents)? = nil
    ) -> AudioRecordingEngine {
        AudioRecordingEngine(
            sink: sink,
            clock: clock(),
            sources: sources,
            routeController: controller,
            pump: pump(layout: layout),
            scheduler: scheduler,
            sessionFactory: sessionFactory,
            hostClock: { hostClock.current },
            joinTimeout: .milliseconds(80)
        )
    }

    @Test func startAndStopRecordRealPumpBlocksAndCommit() async throws {
        let host = EngineHostClock()
        let scheduler = EngineFakeScheduler()
        let sink = RecordingEngineSink()
        let system = try EngineFakeSource(
            role: .system,
            format: AudioSourceFormat(sampleRate: 48_000, channelCount: 1)
        )
        system.framesProvider = { [self] in frames(0.25, count: 480) }
        system.hostTimeProvider = { host.current }
        let sources: [RecordingTrackRole: any AudioFrameSource] = [.system: system]
        let authorizer = EngineAuthorizer(.authorized)
        let controller = AudioRouteController(authorizer: authorizer, sources: sources)
        let engine = engine(
            sink: sink,
            sources: sources,
            controller: controller,
            layout: .mixed,
            hostClock: host,
            scheduler: scheduler
        )

        try await engine.start(configuration(mode: .system, layout: .mixed))
        #expect(engine.diagnostics.phase == .recording)
        host.set(hostTime(forSample: 480))
        await scheduler.runOnce()

        let recorded = await sink.blocks
        #expect(recorded.count == 1)
        #expect(recorded[0].range == SampleRange(startSample: 0, sampleCount: 480))
        #expect(recorded[0].role == .mixed)

        let result = await engine.stop()
        let commits = await sink.commits
        #expect(result.failure == nil)
        #expect(result.segmentCount == 1)
        #expect(commits == 1)
        #expect(system.startCount == 1)
        #expect(system.stopCount == 1)
        #expect(scheduler.stopCount == 1)
        #expect(engine.diagnostics.phase == .finished)
    }

    @Test func stopIsIdempotentAndReturnsTheSameResult() async throws {
        let host = EngineHostClock()
        let scheduler = EngineFakeScheduler()
        let sink = RecordingEngineSink()
        let system = try EngineFakeSource(
            role: .system,
            format: AudioSourceFormat(sampleRate: 48_000, channelCount: 1)
        )
        system.framesProvider = { [self] in frames(0.1, count: 480) }
        system.hostTimeProvider = { host.current }
        let sources: [RecordingTrackRole: any AudioFrameSource] = [.system: system]
        let controller = AudioRouteController(authorizer: EngineAuthorizer(.authorized), sources: sources)
        let engine = engine(
            sink: sink,
            sources: sources,
            controller: controller,
            layout: .mixed,
            hostClock: host,
            scheduler: scheduler
        )

        try await engine.start(configuration(mode: .system, layout: .mixed))
        let first = await engine.stop()
        let second = await engine.stop()

        #expect(first == second)
        #expect(system.stopCount == 1)
        let commits = await sink.commits
        #expect(commits <= 1)
    }

    @Test func repeatedUserSessionUsesFreshControllerFactory() async throws {
        let host = EngineHostClock()
        let scheduler = EngineFakeScheduler()
        let sink = RecordingEngineSink()
        let system = try EngineFakeSource(
            role: .system,
            format: AudioSourceFormat(sampleRate: 48_000, channelCount: 1)
        )
        system.framesProvider = { [self] in frames(0.3, count: 480) }
        system.hostTimeProvider = { host.current }
        let sources: [RecordingTrackRole: any AudioFrameSource] = [.system: system]
        let authorizer = EngineAuthorizer(.authorized)
        let sessionFactory: @Sendable () -> AudioEngineSessionComponents = { [self] in
            AudioEngineSessionComponents(
                sources: sources,
                routeController: AudioRouteController(authorizer: authorizer, sources: sources),
                pump: pump(layout: .mixed)
            )
        }
        let controller = AudioRouteController(authorizer: authorizer, sources: sources)
        let engine = engine(
            sink: sink,
            sources: sources,
            controller: controller,
            layout: .mixed,
            hostClock: host,
            scheduler: scheduler,
            sessionFactory: sessionFactory
        )

        try await engine.start(configuration(mode: .system, layout: .mixed))
        host.set(hostTime(forSample: 480))
        await scheduler.runOnce()
        let first = await engine.stop()
        try await engine.start(configuration(mode: .system, layout: .mixed))
        host.set(hostTime(forSample: 960))
        await scheduler.runOnce()
        let second = await engine.stop()

        #expect(first.sessionID != second.sessionID)
        #expect(system.startCount == 2)
        #expect(system.stopCount >= 2)
    }

    @Test func duplicateStartWhileRecordingThrows() async throws {
        let host = EngineHostClock()
        let scheduler = EngineFakeScheduler()
        let sink = RecordingEngineSink()
        let system = try EngineFakeSource(
            role: .system,
            format: AudioSourceFormat(sampleRate: 48_000, channelCount: 1)
        )
        let sources: [RecordingTrackRole: any AudioFrameSource] = [.system: system]
        let controller = AudioRouteController(authorizer: EngineAuthorizer(.authorized), sources: sources)
        let engine = engine(
            sink: sink,
            sources: sources,
            controller: controller,
            layout: .mixed,
            hostClock: host,
            scheduler: scheduler
        )
        try await engine.start(configuration(mode: .system, layout: .mixed))

        await #expect(throws: AudioRecordingEngineError.alreadyRecording) {
            try await engine.start(configuration(mode: .system, layout: .mixed))
        }
        _ = await engine.stop()
    }

    @Test func routeCommitsAtPumpBoundaryWithoutPremixingNewSource() async throws {
        let host = EngineHostClock()
        let scheduler = EngineFakeScheduler()
        let sink = RecordingEngineSink()
        let system = try EngineFakeSource(
            role: .system,
            format: AudioSourceFormat(sampleRate: 48_000, channelCount: 1)
        )
        let microphone = try EngineFakeSource(
            role: .microphone,
            format: AudioSourceFormat(sampleRate: 48_000, channelCount: 1)
        )
        system.framesProvider = { [self] in frames(0.2, count: 480 * 4) }
        microphone.framesProvider = { [self] in frames(-0.4, count: 480 * 4) }
        system.hostTimeProvider = { host.current }
        microphone.hostTimeProvider = { host.current }
        let sources: [RecordingTrackRole: any AudioFrameSource] = [.system: system, .microphone: microphone]
        let controller = AudioRouteController(authorizer: EngineAuthorizer(.authorized), sources: sources)
        let engine = engine(
            sink: sink,
            sources: sources,
            controller: controller,
            layout: .separateTracks,
            hostClock: host,
            scheduler: scheduler
        )

        try await engine.start(configuration(mode: .system, layout: .separateTracks))
        host.set(hostTime(forSample: 480))
        await scheduler.runOnce()
        let firstBlocks = await sink.blocks
        #expect(firstBlocks.count == 1)
        #expect(firstBlocks[0].role == .system)

        let result = await engine.applyRoute(RouteEvent(atSample: 480, mode: .systemAndMicrophone, deviceID: nil))
        #expect(result == .committed(atSample: 480))

        host.set(hostTime(forSample: 960))
        await scheduler.runOnce()
        let blocks = await sink.blocks
        #expect(blocks.count >= 3)
        let last = blocks.suffix(2)
        #expect(Set(last.map(\.role)) == [.system, .microphone])
        #expect(last.allSatisfy { $0.range == SampleRange(startSample: 480, sampleCount: 480) })
        _ = await engine.stop()
    }

    @Test func failedRouteLeavesPreviousRouteUntouched() async throws {
        let host = EngineHostClock()
        let scheduler = EngineFakeScheduler()
        let sink = RecordingEngineSink()
        let system = try EngineFakeSource(
            role: .system,
            format: AudioSourceFormat(sampleRate: 48_000, channelCount: 1)
        )
        let microphone = try EngineFakeSource(
            role: .microphone,
            format: AudioSourceFormat(sampleRate: 48_000, channelCount: 1)
        )
        system.framesProvider = { [self] in frames(0.2, count: 480 * 3) }
        system.hostTimeProvider = { host.current }
        let sources: [RecordingTrackRole: any AudioFrameSource] = [.system: system, .microphone: microphone]
        let controller = AudioRouteController(authorizer: EngineAuthorizer(.denied), sources: sources)
        let engine = engine(
            sink: sink,
            sources: sources,
            controller: controller,
            layout: .separateTracks,
            hostClock: host,
            scheduler: scheduler
        )

        try await engine.start(configuration(mode: .system, layout: .separateTracks))
        let result = await engine.applyRoute(RouteEvent(atSample: 480, mode: .microphone, deviceID: nil))
        guard case .unchanged = result else {
            Issue.record("expected unchanged route")
            return
        }
        host.set(hostTime(forSample: 480))
        await scheduler.runOnce()
        let blocks = await sink.blocks
        #expect(Set(blocks.map(\.role)) == [.system])
        _ = await engine.stop()
    }

    @Test func sourceFailureLeavesHealthyRoleRecording() async throws {
        let host = EngineHostClock()
        let scheduler = EngineFakeScheduler()
        let sink = RecordingEngineSink()
        let system = try EngineFakeSource(
            role: .system,
            format: AudioSourceFormat(sampleRate: 48_000, channelCount: 1)
        )
        let microphone = try EngineFakeSource(
            role: .microphone,
            format: AudioSourceFormat(sampleRate: 48_000, channelCount: 1)
        )
        system.framesProvider = { [self] in frames(0.2, count: 480 * 4) }
        microphone.framesProvider = { [self] in frames(-0.4, count: 480 * 4) }
        system.hostTimeProvider = { host.current }
        microphone.hostTimeProvider = { host.current }
        let sources: [RecordingTrackRole: any AudioFrameSource] = [.system: system, .microphone: microphone]
        let controller = AudioRouteController(authorizer: EngineAuthorizer(.authorized), sources: sources)
        let engine = engine(
            sink: sink,
            sources: sources,
            controller: controller,
            layout: .separateTracks,
            hostClock: host,
            scheduler: scheduler
        )

        try await engine.start(configuration(mode: .systemAndMicrophone, layout: .separateTracks))
        host.set(hostTime(forSample: 480))
        await scheduler.runOnce()
        microphone.failHealth()
        await engine.refreshInputsForTesting()

        host.set(hostTime(forSample: 960))
        await scheduler.runOnce()
        let blocks = await sink.blocks
        let last = Array(blocks.suffix(2))
        let systemBlock = try #require(last.first { $0.role == .system })
        let microphoneBlock = try #require(last.first { $0.role == .microphone })
        #expect(systemBlock.isSilence == false)
        #expect(microphoneBlock.isSilence)
        #expect(microphoneBlock.frameCount == systemBlock.frameCount)
        _ = await engine.stop()
    }

    @Test func sinkFailureDoesNotReportSavedAudio() async throws {
        let host = EngineHostClock()
        let scheduler = EngineFakeScheduler()
        let sink = RecordingEngineSink()
        await sink.failAppends(at: 0)
        let system = try EngineFakeSource(
            role: .system,
            format: AudioSourceFormat(sampleRate: 48_000, channelCount: 1)
        )
        system.framesProvider = { [self] in frames(0.2, count: 480) }
        system.hostTimeProvider = { host.current }
        let sources: [RecordingTrackRole: any AudioFrameSource] = [.system: system]
        let controller = AudioRouteController(authorizer: EngineAuthorizer(.authorized), sources: sources)
        let engine = engine(
            sink: sink,
            sources: sources,
            controller: controller,
            layout: .mixed,
            hostClock: host,
            scheduler: scheduler
        )

        try await engine.start(configuration(mode: .system, layout: .mixed))
        host.set(hostTime(forSample: 480))
        await scheduler.runOnce()
        let result = await engine.stop()

        #expect(result.failure != nil)
        #expect(result.segmentCount == 0)
        let commits = await sink.commits
        #expect(commits == 0)
    }

    @Test func unjoinedProducerIsNotFinalizedAndNotReportedSaved() async throws {
        let host = EngineHostClock()
        let scheduler = EngineFakeScheduler()
        let sink = RecordingEngineSink()
        let system = try EngineFakeSource(
            role: .system,
            format: AudioSourceFormat(sampleRate: 48_000, channelCount: 1)
        )
        system.producerJoined = false
        system.framesProvider = { [self] in frames(0.2, count: 480) }
        system.hostTimeProvider = { host.current }
        let sources: [RecordingTrackRole: any AudioFrameSource] = [.system: system]
        let controller = AudioRouteController(authorizer: EngineAuthorizer(.authorized), sources: sources)
        let engine = engine(
            sink: sink,
            sources: sources,
            controller: controller,
            layout: .mixed,
            hostClock: host,
            scheduler: scheduler
        )

        try await engine.start(configuration(mode: .system, layout: .mixed))
        host.set(hostTime(forSample: 480))
        await scheduler.runOnce()
        let result = await engine.stop()

        #expect(result.failure != nil)
        #expect(result.segmentCount == 0)
        let commits = await sink.commits
        #expect(commits == 0)
    }

    @Test func progressStreamsArePerSubscriberAndTerminateOnStop() async throws {
        let host = EngineHostClock()
        let scheduler = EngineFakeScheduler()
        let sink = RecordingEngineSink()
        let system = try EngineFakeSource(
            role: .system,
            format: AudioSourceFormat(sampleRate: 48_000, channelCount: 1)
        )
        system.framesProvider = { [self] in frames(0.2, count: 480 * 3) }
        system.hostTimeProvider = { host.current }
        let sources: [RecordingTrackRole: any AudioFrameSource] = [.system: system]
        let controller = AudioRouteController(authorizer: EngineAuthorizer(.authorized), sources: sources)
        let engine = engine(
            sink: sink,
            sources: sources,
            controller: controller,
            layout: .mixed,
            hostClock: host,
            scheduler: scheduler
        )
        let first = engine.makeProgressStream()
        let second = engine.makeProgressStream()
        #expect(engine.diagnostics.progressSubscriberCount == 2)

        try await engine.start(configuration(mode: .system, layout: .mixed))
        host.set(hostTime(forSample: 480))
        await scheduler.runOnce()
        _ = await engine.stop()

        async let firstValues = collect(first)
        async let secondValues = collect(second)
        let values = await (firstValues, secondValues)
        #expect(values.0.isEmpty == false)
        #expect(values.1.isEmpty == false)
        #expect(engine.diagnostics.progressSubscriberCount == 0)
    }

    @Test func sinkBackpressureIsVisibleInDiagnostics() async throws {
        let host = EngineHostClock()
        let scheduler = EngineFakeScheduler()
        let sink = BlockingEngineSink()
        let system = try EngineFakeSource(
            role: .system,
            format: AudioSourceFormat(sampleRate: 48_000, channelCount: 1)
        )
        system.framesProvider = { [self] in frames(0.2, count: 480) }
        system.hostTimeProvider = { host.current }
        let sources: [RecordingTrackRole: any AudioFrameSource] = [.system: system]
        let controller = AudioRouteController(authorizer: EngineAuthorizer(.authorized), sources: sources)
        let engine = engine(
            sink: sink,
            sources: sources,
            controller: controller,
            layout: .mixed,
            hostClock: host,
            scheduler: scheduler
        )
        try await engine.start(configuration(mode: .system, layout: .mixed))
        host.set(hostTime(forSample: 480))

        let tick = Task { await scheduler.runOnce() }
        await sink.waitUntilAppending()
        #expect(engine.diagnostics.sinkBacklogEstimate == 1)
        await sink.release()
        await tick.value
        _ = await engine.stop()
        #expect(engine.diagnostics.sinkBacklogEstimate == 0)
    }

    @Test func stopDrainsRetainedStagingTailBeforeCommit() async throws {
        let host = EngineHostClock()
        let scheduler = EngineFakeScheduler()
        let sink = RecordingEngineSink()
        let system = try EngineFakeSource(
            role: .system,
            format: AudioSourceFormat(sampleRate: 48_000, channelCount: 1),
            capacitySeconds: 0.0501
        )
        system.framesProvider = { [self] in frames(0.2, count: 2_405) }
        system.hostTimeProvider = { host.current }
        let sources: [RecordingTrackRole: any AudioFrameSource] = [.system: system]
        let controller = AudioRouteController(authorizer: EngineAuthorizer(.authorized), sources: sources)
        let engine = engine(
            sink: sink,
            sources: sources,
            controller: controller,
            layout: .mixed,
            hostClock: host,
            scheduler: scheduler
        )

        try await engine.start(configuration(mode: .system, layout: .mixed))
        host.set(hostTime(forSample: 480))
        await scheduler.runOnce()
        let result = await engine.stop()

        let blocks = await sink.blocks
        let totalFrames = blocks.reduce(0) { $0 + $1.frameCount }
        #expect(result.failure == nil)
        #expect(totalFrames == 2_405)
        #expect(blocks.allSatisfy { $0.range.sampleCount == Int64($0.frameCount) })
    }

    @Test func futureRouteBoundaryIsNotPreemptedByHealthRefresh() async throws {
        let host = EngineHostClock()
        let scheduler = EngineFakeScheduler()
        let sink = RecordingEngineSink()
        let system = try EngineFakeSource(
            role: .system,
            format: AudioSourceFormat(sampleRate: 48_000, channelCount: 1)
        )
        let microphone = try EngineFakeSource(
            role: .microphone,
            format: AudioSourceFormat(sampleRate: 48_000, channelCount: 1)
        )
        system.framesProvider = { [self] in frames(0.2, count: 480 * 6) }
        microphone.framesProvider = { [self] in frames(-0.4, count: 480 * 6) }
        system.hostTimeProvider = { host.current }
        microphone.hostTimeProvider = { host.current }
        let sources: [RecordingTrackRole: any AudioFrameSource] = [.system: system, .microphone: microphone]
        let controller = AudioRouteController(authorizer: EngineAuthorizer(.authorized), sources: sources)
        let engine = engine(
            sink: sink,
            sources: sources,
            controller: controller,
            layout: .separateTracks,
            hostClock: host,
            scheduler: scheduler
        )

        try await engine.start(configuration(mode: .system, layout: .separateTracks))
        host.set(hostTime(forSample: 480))
        await scheduler.runOnce()
        let result = await engine.applyRoute(
            RouteEvent(atSample: 960, mode: .systemAndMicrophone, deviceID: nil)
        )
        #expect(result == .committed(atSample: 960))
        await engine.refreshInputsForTesting()

        host.set(hostTime(forSample: 960))
        await scheduler.runOnce()
        let beforeBoundary = await sink.blocks
        #expect(beforeBoundary.count == 2)
        #expect(beforeBoundary.last?.role == .system)
        #expect(beforeBoundary.last?.range == SampleRange(startSample: 480, sampleCount: 480))

        host.set(hostTime(forSample: 1_440))
        await scheduler.runOnce()
        let all = await sink.blocks
        #expect(all.count == 4)
        #expect(all[2].role == .system)
        #expect(Set(all.suffix(2).map(\.role)) == [.system, .microphone])
        #expect(all.suffix(2).allSatisfy { $0.range == SampleRange(startSample: 960, sampleCount: 480) })
        _ = await engine.stop()
    }

    @Test func startFailureCleansUpBeforeThrowing() async throws {
        let host = EngineHostClock()
        let scheduler = EngineFakeScheduler()
        let sink = RecordingEngineSink()
        let system = try EngineFakeSource(
            role: .system,
            format: AudioSourceFormat(sampleRate: 48_000, channelCount: 1)
        )
        system.startError = AudioSourceError.startFailed("synthetic")
        let sources: [RecordingTrackRole: any AudioFrameSource] = [.system: system]
        let controller = AudioRouteController(authorizer: EngineAuthorizer(.authorized), sources: sources)
        let engine = engine(
            sink: sink,
            sources: sources,
            controller: controller,
            layout: .mixed,
            hostClock: host,
            scheduler: scheduler
        )

        await #expect(throws: AudioRecordingEngineError.self) {
            try await engine.start(configuration(mode: .system, layout: .mixed))
        }
        #expect(scheduler.startCount == 0)
        #expect(engine.diagnostics.phase == .failedRecoverable)
    }

    private func collect(_ stream: AsyncStream<RecordingProgress>) async -> [RecordingProgress] {
        var values: [RecordingProgress] = []
        var iterator = stream.makeAsyncIterator()
        while let value = await iterator.next() {
            values.append(value)
            if values.count >= 16 {
                break
            }
        }
        return values
    }
}
