import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

/// A system-audio frame source for standalone capture or screen-session reuse.
///
/// The source owns the generation and ring, not the shared video stream. Control
/// methods are serialized by an explicit gate; audio callbacks are lock-free
/// except for the ring's own single-producer gate.
public final class SystemAudioSource: AudioFrameSource, AudioSourceReconfigurationCancelling,
    @unchecked Sendable
{
    private struct Binding {
        let generation: AudioSourceGeneration
        let box: AudioSystemCallbackBox
        let stream: (any OwnedSystemAudioStreaming)?
    }

    /// Logical recording role.
    public let role: RecordingTrackRole = .system
    private let gate = AudioControlGate()
    private let hostTicksPerSecond: UInt64
    private let capacitySeconds: Double
    private let joinTimeout: Duration
    private let factory: (any SystemAudioStreamFactory)?
    private let reuseStream: (any SystemAudioStreaming)?
    private let diagnostics: AudioSourceDiagnostics?
    private let deviceMonitor: (any AudioDeviceChangeMonitoring)?
    private let timestampMapper: AudioSourceTimestampMapper?
    private let hostClock: (@Sendable () -> UInt64)?
    private var broadcaster = AudioDeviceChangeBroadcaster()
    private var generation: AudioSourceGeneration
    private var activeBinding: Binding?
    private var preparedBinding: Binding?
    private var started = false
    private var monitorStarted = false
    private var restartNeedsFreshRing = false
    private var orphanedBindings: [Binding] = []
    private var canUseInjectedMapper = true
    #if DEBUG
        internal var admissionTestHook: (@Sendable () -> Void)?
    #endif

    /// Creates a source that reuses an existing screen session's audio output.
    ///
    /// The source only installs and removes an audio output. It never starts or
    /// stops the shared video stream.
    ///
    /// - Parameters:
    ///   - ringBuffer: Initial ring matching `format`.
    ///   - format: Ring format.
    ///   - hostTicksPerSecond: Host clock ticks per second.
    ///   - stream: Existing screen-session stream.
    ///   - diagnostics: Optional callback diagnostics.
    ///   - deviceMonitor: Optional platform device-change monitor.
    ///   - timestampMapper: Optional mapper for the shared stream's timestamps.
    ///   - hostClock: Host-clock fallback; must return the configured tick domain.
    public init(
        ringBuffer: AudioSourceRingBuffer,
        format: AudioSourceFormat,
        hostTicksPerSecond: UInt64,
        stream: any SystemAudioStreaming,
        diagnostics: AudioSourceDiagnostics? = nil,
        deviceMonitor: (any AudioDeviceChangeMonitoring)? = nil,
        timestampMapper: AudioSourceTimestampMapper? = nil,
        hostClock: (@Sendable () -> UInt64)? = nil
    ) {
        generation = AudioSourceGeneration(role: .system, format: format, ringBuffer: ringBuffer)
        self.hostTicksPerSecond = hostTicksPerSecond
        capacitySeconds = 2.0
        joinTimeout = .seconds(2)
        factory = nil
        reuseStream = stream
        self.diagnostics = diagnostics
        self.deviceMonitor = deviceMonitor
        self.timestampMapper = timestampMapper
        self.hostClock = hostClock
    }

    /// Creates an audio-only source that owns its ScreenCaptureKit stream.
    ///
    /// - Parameters:
    ///   - ringBuffer: Initial ring matching `format`.
    ///   - format: Ring format.
    ///   - hostTicksPerSecond: Host clock ticks per second.
    ///   - capacitySeconds: Ring capacity used for later generations.
    ///   - joinTimeout: How long a stop or restart waits for the retired stream to go idle.
    ///   - factory: Creates one stream per start or format change.
    ///   - diagnostics: Optional callback diagnostics.
    ///   - deviceMonitor: Optional platform device-change monitor.
    ///   - timestampMapper: Optional mapper for the owned stream's timestamps.
    ///   - hostClock: Host-clock fallback; must return the configured tick domain.
    public init(
        ringBuffer: AudioSourceRingBuffer,
        format: AudioSourceFormat,
        hostTicksPerSecond: UInt64,
        capacitySeconds: Double = 2.0,
        joinTimeout: Duration = .seconds(2),
        factory: any SystemAudioStreamFactory,
        diagnostics: AudioSourceDiagnostics? = nil,
        deviceMonitor: (any AudioDeviceChangeMonitoring)? = nil,
        timestampMapper: AudioSourceTimestampMapper? = nil,
        hostClock: (@Sendable () -> UInt64)? = nil
    ) {
        generation = AudioSourceGeneration(role: .system, format: format, ringBuffer: ringBuffer)
        self.hostTicksPerSecond = hostTicksPerSecond
        self.capacitySeconds = capacitySeconds
        self.joinTimeout = joinTimeout
        self.factory = factory
        reuseStream = nil
        self.diagnostics = diagnostics
        self.deviceMonitor = deviceMonitor
        self.timestampMapper = timestampMapper
        self.hostClock = hostClock
    }

    /// Creates an audio-only source and its first ring.
    ///
    /// - Parameters:
    ///   - format: Ring format.
    ///   - hostTicksPerSecond: Host clock ticks per second.
    ///   - capacitySeconds: Ring capacity in seconds.
    ///   - joinTimeout: How long a stop or restart waits for the retired stream to go idle.
    ///   - factory: Creates one stream per start or format change.
    ///   - diagnostics: Optional callback diagnostics.
    ///   - deviceMonitor: Optional platform device-change monitor.
    ///   - timestampMapper: Optional mapper for the owned stream's timestamps.
    ///   - hostClock: Host-clock fallback; must return the configured tick domain.
    /// - Throws: ``AudioRingConfigurationError`` for an invalid format or capacity.
    public convenience init(
        format: AudioSourceFormat,
        hostTicksPerSecond: UInt64,
        capacitySeconds: Double = 2.0,
        joinTimeout: Duration = .seconds(2),
        factory: any SystemAudioStreamFactory,
        diagnostics: AudioSourceDiagnostics? = nil,
        deviceMonitor: (any AudioDeviceChangeMonitoring)? = nil,
        timestampMapper: AudioSourceTimestampMapper? = nil,
        hostClock: (@Sendable () -> UInt64)? = nil
    ) throws {
        let ring = try AudioSourceRingBuffer(
            role: .system,
            sampleRate: format.sampleRate,
            channelCount: format.channelCount,
            hostTicksPerSecond: hostTicksPerSecond,
            capacitySeconds: capacitySeconds
        )
        self.init(
            ringBuffer: ring,
            format: format,
            hostTicksPerSecond: hostTicksPerSecond,
            capacitySeconds: capacitySeconds,
            joinTimeout: joinTimeout,
            factory: factory,
            diagnostics: diagnostics,
            deviceMonitor: deviceMonitor,
            timestampMapper: timestampMapper,
            hostClock: Self.resolvedHostClock(hostClock: hostClock, hostTicksPerSecond: hostTicksPerSecond)
        )
    }

    /// Returns a broadcast stream of platform device changes.
    ///
    /// The owning recording session forwards each event to
    /// `AudioRouteController.prepareDeviceChange(_:)`. The source starts and stops
    /// its optional monitor independently of microphone capture.
    ///
    /// - Returns: A new independent device-change stream.
    public func makeDeviceChangeStream() -> AsyncStream<AudioDeviceChangeEvent> {
        broadcaster.makeStream()
    }

    /// Returns the generation currently receiving producer frames.
    ///
    /// - Returns: The active generation, including after stop.
    public func currentGeneration() async -> AudioSourceGeneration {
        await gate.acquire()
        let value = generation
        await gate.release()
        return value
    }

    /// Returns whether the producer is running.
    ///
    /// - Returns: `true` only while the owned stream or shared output is active.
    public func isRunning() async -> Bool {
        await gate.acquire()
        let value = activeIsRunningLocked()
        await gate.release()
        return value
    }

    private func activeIsRunningLocked() -> Bool {
        guard started, let active = activeBinding else { return false }
        if let stream = active.stream {
            return stream.isRunning
        }
        return reuseStream?.isRunning ?? false
    }

    /// Returns whether every timed-out callback has joined.
    ///
    /// - Returns: `false` while an owned ring is retained for a timed-out join.
    public func isProducerJoined() async -> Bool {
        await gate.acquire()
        await reapOrphanedBindingsLocked()
        let value = orphanedBindings.isEmpty
        await gate.release()
        return value
    }

    /// Starts capture into a fresh generation.
    ///
    /// Standalone capture creates, installs, and starts one owned stream. Reuse
    /// capture only installs an audio output on the existing stream.
    ///
    /// - Throws: ``AudioSourceError`` when installation or start fails.
    public func start() async throws {
        await gate.acquire()
        do {
            try await startLocked()
            await gate.release()
        } catch {
            await gate.release()
            throw error
        }
    }

    /// Removes the output or stops the owned stream and joins admitted callbacks.
    ///
    /// The active ring is closed only after a successful join. On a timeout the
    /// binding is retained and ``isProducerJoined()`` remains `false`; callers
    /// must not treat the source as reusable until it returns `true`.
    public func stop() async {
        await gate.acquire()
        await stopLocked()
        await gate.release()
    }

    /// Prepares a format change for a standalone source.
    ///
    /// A shared screen-session stream has a fixed format, so reuse preparation
    /// returns ``AudioSourcePreparation/unchangedOnFailure(reason:)``.
    ///
    /// - Parameter event: Device change to prepare.
    /// - Returns: A prepared generation or an unchanged failure.
    public func prepareReconfiguration(_ event: AudioDeviceChangeEvent) async -> AudioSourcePreparation {
        await gate.acquire()
        let result = await prepareLocked(event)
        await gate.release()
        return result
    }

    /// Commits a prepared generation and stops the previous producer.
    ///
    /// - Parameter generation: Generation from ``prepareReconfiguration(_:)``.
    /// - Returns: Whether the generation became active.
    public func commitReconfiguration(_ generation: AudioSourceGeneration) async -> Bool {
        await gate.acquire()
        let result = await commitLocked(generation)
        await gate.release()
        return result
    }

    /// Discards a prepared generation and its new stream.
    ///
    /// - Parameter generationID: Prepared generation identity.
    public func cancelReconfiguration(_ generationID: UUID) async {
        await gate.acquire()
        if let prepared = preparedBinding, prepared.generation.id == generationID {
            preparedBinding = nil
            let joined = await stopBinding(prepared)
            if !joined {
                retainOrphanedBinding(prepared)
            }
        }
        await gate.release()
    }
}

extension SystemAudioSource {
    private func startLocked() async throws {
        try await recoverFromNativeStopLocked()
        guard !started else { return }
        await reapOrphanedBindingsLocked()
        guard orphanedBindings.isEmpty else {
            throw AudioSourceError.unavailable("previous producer has not joined")
        }
        if let timestampMapper, timestampMapper.hostTicksPerSecond != hostTicksPerSecond {
            throw AudioSourceError.invalidHostTimebase
        }
        if restartNeedsFreshRing {
            generation = try AudioSourceGeneration(
                role: .system,
                format: generation.format,
                hostTicksPerSecond: hostTicksPerSecond,
                capacitySeconds: capacitySeconds
            )
            restartNeedsFreshRing = false
        }
        let box = AudioSystemCallbackBox(
            generation: generation,
            hostTicksPerSecond: hostTicksPerSecond,
            diagnostics: diagnostics,
            timestampMapper: canUseInjectedMapper ? timestampMapper : nil,
            hostClock: resolvedHostClock(),
            gate: makeGate()
        )
        canUseInjectedMapper = false
        let handler = Self.makeHandler(box: box)

        if let reuseStream {
            do {
                try reuseStream.installAudioOutput(handler)
            } catch {
                await failStartLocked(box: box)
                throw error
            }
            do {
                try startMonitor()
            } catch {
                await reuseStream.removeAudioOutput()
                await failStartLocked(box: box)
                throw error
            }
            activeBinding = Binding(generation: generation, box: box, stream: nil)
            started = true
            return
        }

        let stream: any OwnedSystemAudioStreaming
        do {
            stream = try await startOwnedStream(handler: handler)
        } catch {
            await failStartLocked(box: box)
            throw error
        }
        do {
            try startMonitor()
        } catch {
            await stream.removeAudioOutput()
            await stream.stopCapture()
            await failStartLocked(box: box)
            throw error
        }
        activeBinding = Binding(generation: generation, box: box, stream: stream)
        started = true
    }

    private func recoverFromNativeStopLocked() async throws {
        guard started, !activeIsRunningLocked() else { return }
        if reuseStream != nil {
            await stopLocked()
            throw AudioSourceError.unavailable("shared stream is not running")
        }
        await stopLocked()
        guard orphanedBindings.isEmpty else {
            throw AudioSourceError.unavailable("previous producer has not joined")
        }
    }

    private func makeGate() -> AudioCallbackGate {
        #if DEBUG
            AudioCallbackGate(admissionHook: admissionTestHook)
        #else
            AudioCallbackGate()
        #endif
    }

    private func resolvedHostClock() -> @Sendable () -> UInt64 {
        Self.resolvedHostClock(hostClock: hostClock, hostTicksPerSecond: hostTicksPerSecond)
    }

    private static func resolvedHostClock(
        hostClock: (@Sendable () -> UInt64)?,
        hostTicksPerSecond: UInt64
    ) -> @Sendable () -> UInt64 {
        if let hostClock {
            return hostClock
        }
        return {
            AudioSourceTimestampMapper.hostTicks(
                fromMachTicks: AudioGetCurrentHostTime(),
                machTicksPerSecond: AudioSourceTimestampMapper.nativeHostTicksPerSecond(),
                hostTicksPerSecond: hostTicksPerSecond
            )
        }
    }

    private func startOwnedStream(
        handler: @escaping @Sendable (CMSampleBuffer) -> Void
    ) async throws -> any OwnedSystemAudioStreaming {
        guard let factory else {
            throw AudioSourceError.unavailable("system source has no stream factory")
        }
        let stream = try await factory.makeStream()
        do {
            try stream.installAudioOutput(handler)
        } catch {
            await stream.removeAudioOutput()
            throw error
        }
        do {
            try await stream.startCapture()
        } catch {
            await stream.removeAudioOutput()
            await stream.stopCapture()
            throw error
        }
        return stream
    }

    private func startMonitor() throws {
        guard let deviceMonitor else { return }
        if broadcaster.isFinished {
            broadcaster = AudioDeviceChangeBroadcaster()
        }
        do {
            try deviceMonitor.start { [broadcaster] event in
                broadcaster.yield(event)
            }
            monitorStarted = true
        } catch {
            throw error
        }
    }

    private func stopLocked() async {
        if monitorStarted {
            deviceMonitor?.stop()
            monitorStarted = false
        }
        if let prepared = preparedBinding {
            preparedBinding = nil
            let joined = await stopBinding(prepared)
            if !joined {
                retainOrphanedBinding(prepared)
            }
        }
        if started, let active = activeBinding {
            activeBinding = nil
            started = false
            restartNeedsFreshRing = true
            let joined = await stopBinding(active)
            if !joined {
                retainOrphanedBinding(active)
            }
        }
        broadcaster.finish()
        await reapOrphanedBindingsLocked()
    }

    private func preparePreflight(_ event: AudioDeviceChangeEvent) async -> String? {
        await reapOrphanedBindingsLocked()
        guard orphanedBindings.isEmpty else {
            return "previous producer has not joined"
        }
        guard started, reuseStream == nil, factory != nil else {
            return "shared stream format is fixed"
        }
        guard event.role == .system else {
            return "device role does not match source"
        }
        guard event.format.isRingCompatible else {
            return "unsupported device format"
        }
        if let timestampMapper, timestampMapper.hostTicksPerSecond != hostTicksPerSecond {
            return "timestamp mapper domain mismatch"
        }
        if let prepared = preparedBinding {
            preparedBinding = nil
            let joined = await stopBinding(prepared)
            if !joined {
                retainOrphanedBinding(prepared)
                return "previous producer has not joined"
            }
        }
        return nil
    }

    private func prepareLocked(_ event: AudioDeviceChangeEvent) async -> AudioSourcePreparation {
        if let reason = await preparePreflight(event) {
            return .unchangedOnFailure(reason: reason)
        }
        let newGeneration: AudioSourceGeneration
        do {
            newGeneration = try AudioSourceGeneration(
                role: .system,
                format: event.format,
                hostTicksPerSecond: hostTicksPerSecond,
                capacitySeconds: capacitySeconds
            )
        } catch {
            return .unchangedOnFailure(reason: "cannot construct source ring")
        }
        canUseInjectedMapper = false
        let box = AudioSystemCallbackBox(
            generation: newGeneration,
            hostTicksPerSecond: hostTicksPerSecond,
            diagnostics: diagnostics,
            timestampMapper: nil,
            hostClock: resolvedHostClock(),
            gate: makeGate()
        )
        switch await startReplacement(box: box, generation: newGeneration) {
        case .success(let stream):
            preparedBinding = Binding(
                generation: newGeneration,
                box: box,
                stream: stream
            )
            return .prepared(newGeneration)
        case .failure(let reason):
            return .unchangedOnFailure(reason: reason)
        }
    }

    private enum ReplacementResult {
        case success(any OwnedSystemAudioStreaming)
        case failure(String)
    }

    private func startReplacement(
        box: AudioSystemCallbackBox,
        generation newGeneration: AudioSourceGeneration
    ) async -> ReplacementResult {
        guard let factory else {
            finalizeGeneration(newGeneration)
            return .failure("system source has no stream factory")
        }
        let stream: any OwnedSystemAudioStreaming
        do {
            stream = try await factory.makeStream()
        } catch {
            finalizeGeneration(newGeneration)
            return .failure("cannot create replacement stream")
        }
        do {
            try stream.installAudioOutput(Self.makeHandler(box: box))
        } catch {
            await stream.removeAudioOutput()
            await rejectReplacement(box: box, generation: newGeneration)
            return .failure("cannot install replacement audio output")
        }
        do {
            try await stream.startCapture()
        } catch {
            await stream.removeAudioOutput()
            await stream.stopCapture()
            await rejectReplacement(box: box, generation: newGeneration)
            return .failure("cannot start replacement stream")
        }
        return .success(stream)
    }

    private func rejectReplacement(
        box: AudioSystemCallbackBox,
        generation: AudioSourceGeneration
    ) async {
        box.gate.beginStop()
        if await box.gate.waitUntilIdle(timeout: joinTimeout) {
            finalizeGeneration(generation)
        } else {
            retainOrphanedBinding(
                Binding(generation: generation, box: box, stream: nil)
            )
        }
    }

    private func commitLocked(_ newGeneration: AudioSourceGeneration) async -> Bool {
        guard started else { return false }
        if newGeneration.id == generation.id {
            return activeIsRunningLocked()
        }
        guard let prepared = preparedBinding, prepared.generation.id == newGeneration.id else {
            return false
        }
        preparedBinding = nil
        let old = activeBinding
        generation = prepared.generation
        activeBinding = prepared
        if let old {
            let joined = await stopBinding(old)
            if !joined {
                retainOrphanedBinding(old)
            }
        }
        return true
    }

    private func stopBinding(_ binding: Binding) async -> Bool {
        binding.box.gate.beginStop()
        if let stream = binding.stream {
            await stream.removeAudioOutput()
            await stream.stopCapture()
        } else if let reuseStream {
            await reuseStream.removeAudioOutput()
        }
        let joined = await binding.box.gate.waitUntilIdle(timeout: joinTimeout)
        if joined {
            finalizeGeneration(binding.generation)
        }
        return joined
    }

    private func retainOrphanedBinding(_ binding: Binding) {
        orphanedBindings.append(binding)
    }

    private func reapOrphanedBindingsLocked() async {
        var remaining: [Binding] = []
        for binding in orphanedBindings {
            if await binding.box.gate.waitUntilIdle(timeout: .milliseconds(1)) {
                finalizeGeneration(binding.generation)
            } else {
                remaining.append(binding)
            }
        }
        orphanedBindings = remaining
    }

    private func failStartLocked(box: AudioSystemCallbackBox? = nil) async {
        if let box {
            box.gate.beginStop()
            if !(await box.gate.waitUntilIdle(timeout: joinTimeout)) {
                retainOrphanedBinding(
                    Binding(generation: generation, box: box, stream: nil)
                )
                restartNeedsFreshRing = true
                return
            }
        }
        finalizeGeneration(generation)
        restartNeedsFreshRing = true
    }

    private func finalizeGeneration(_ generation: AudioSourceGeneration) {
        generation.ringBuffer.requestClose()
        _ = generation.ringBuffer.finishProducing()
    }

    private static func makeHandler(
        box: AudioSystemCallbackBox
    ) -> @Sendable (CMSampleBuffer) -> Void {
        let gate = box.gate
        return { [box] sampleBuffer in
            guard gate.enter() else { return }
            defer { gate.leave() }
            box.handle(sampleBuffer)
        }
    }
}
