import AVFoundation
import AudioToolbox
import Foundation

/// A microphone frame source that copies the actual native Float32 input into
/// its ring without resampling.
///
/// The ring and generation describe the real input rate and channel layout
/// (44.1/48 kHz, mono/stereo). Task 6 owns final session-rate/channel and drift
/// conversion. Authorization is never requested implicitly.
public final class MicrophoneSource: AudioFrameSource, AudioSourceReconfigurationCancelling,
    @unchecked Sendable
{
    private struct Binding {
        let generation: AudioSourceGeneration
        let box: AudioMicrophoneCallbackBox
        let sourceFormat: AVAudioFormat
        let installed: Bool
    }

    /// Logical recording role.
    public let role: RecordingTrackRole = .microphone
    private let gate = AudioControlGate()
    private let authorizer: any MicrophoneAuthorizing
    private let engine: any MicrophoneCaptureEngine
    private let deviceMonitor: any AudioDeviceChangeMonitoring
    private let hostTicksPerSecond: UInt64
    private let machTicksPerSecond: UInt64
    private let capacitySeconds: Double
    private let joinTimeout: Duration
    private let diagnostics: AudioSourceDiagnostics?
    private let hostClock: (@Sendable () -> UInt64)?
    private var broadcaster = AudioDeviceChangeBroadcaster()
    private var generation: AudioSourceGeneration
    private var activeBinding: Binding?
    private var preparedBinding: Binding?
    private var started = false
    private var monitorStarted = false
    private var restartNeedsFreshRing = false
    private var orphanedBindings: [Binding] = []
    #if DEBUG
        internal var admissionTestHook: (@Sendable () -> Void)?
    #endif
    /// Creates a microphone source over a native-format ring.
    ///
    /// - Parameters:
    ///   - ringBuffer: Initial ring matching the actual input `format`.
    ///   - authorizer: Reads authorization without prompting.
    ///   - engine: Microphone engine with one tap.
    ///   - deviceMonitor: Platform device-change monitor.
    ///   - format: Actual native input format stored in the ring.
    ///   - hostTicksPerSecond: Host clock ticks per second.
    ///   - machTicksPerSecond: Native AVAudioTime host frequency.
    ///   - capacitySeconds: Ring capacity used by later generations.
    ///   - joinTimeout: How long a stop or restart waits for the retired tap to go idle.
    ///   - diagnostics: Optional callback diagnostics.
    ///   - hostClock: Host-clock fallback; must return the configured tick domain.
    public init(
        ringBuffer: AudioSourceRingBuffer,
        authorizer: any MicrophoneAuthorizing,
        engine: any MicrophoneCaptureEngine,
        deviceMonitor: any AudioDeviceChangeMonitoring,
        format: AudioSourceFormat,
        hostTicksPerSecond: UInt64,
        machTicksPerSecond: UInt64 = AudioSourceTimestampMapper.nativeHostTicksPerSecond(),
        capacitySeconds: Double = 2.0,
        joinTimeout: Duration = .seconds(2),
        diagnostics: AudioSourceDiagnostics? = nil,
        hostClock: (@Sendable () -> UInt64)? = nil
    ) {
        generation = AudioSourceGeneration(role: .microphone, format: format, ringBuffer: ringBuffer)
        self.authorizer = authorizer
        self.engine = engine
        self.deviceMonitor = deviceMonitor
        self.hostTicksPerSecond = hostTicksPerSecond
        self.machTicksPerSecond = machTicksPerSecond
        self.capacitySeconds = capacitySeconds
        self.joinTimeout = joinTimeout
        self.diagnostics = diagnostics
        self.hostClock = hostClock
    }

    /// Creates a broadcast stream of platform device changes.
    ///
    /// The owning recording session forwards each event to
    /// `AudioRouteController.prepareDeviceChange(_:)`.
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
    /// - Returns: `true` only while the tap and engine are active.
    public func isRunning() async -> Bool {
        await gate.acquire()
        let value = activeIsRunningLocked()
        await gate.release()
        return value
    }

    private func activeIsRunningLocked() -> Bool {
        started && (activeBinding?.installed ?? false) && engine.isRunning
    }

    /// Returns whether every timed-out callback has joined.
    ///
    /// - Returns: `false` while a ring is retained for a timed-out join.
    public func isProducerJoined() async -> Bool {
        await gate.acquire()
        await reapOrphanedBindingsLocked()
        let value = orphanedBindings.isEmpty
        await gate.release()
        return value
    }
    /// Starts one tap, the engine, device monitoring, and configuration monitoring.
    ///
    /// - Throws: ``AudioSourceError`` when authorization, input format, tap, engine,
    ///   or monitor start fails.
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

    /// Removes the tap, stops the engine and monitor, and joins admitted callbacks.
    ///
    /// The ring is closed only after a successful join. On a timeout the binding
    /// is retained and ``isProducerJoined()`` remains `false` until it joins.
    public func stop() async {
        await gate.acquire()
        await stopLocked()
        await gate.release()
    }

    /// Prepares a new generation from the engine's actual current format.
    ///
    /// The active tap keeps producing into the healthy generation until commit.
    ///
    /// - Parameter event: Device change to prepare.
    /// - Returns: A prepared generation or an unchanged failure.
    public func prepareReconfiguration(_ event: AudioDeviceChangeEvent) async -> AudioSourcePreparation {
        await gate.acquire()
        let result = await prepareLocked(event)
        await gate.release()
        return result
    }
    /// Swaps the tap to the prepared native format, restarting a stopped engine.
    ///
    /// - Parameter generation: Generation from ``prepareReconfiguration(_:)``.
    /// - Returns: Whether the tap swap succeeded and the old producer joined.
    public func commitReconfiguration(_ generation: AudioSourceGeneration) async -> Bool {
        await gate.acquire()
        let result = await commitLocked(generation)
        await gate.release()
        return result
    }

    /// Discards a prepared generation without touching the active tap.
    ///
    /// - Parameter generationID: Prepared generation identity.
    public func cancelReconfiguration(_ generationID: UUID) async {
        await gate.acquire()
        if let prepared = preparedBinding, prepared.generation.id == generationID {
            preparedBinding = nil
            finalizeGeneration(prepared.generation)
        }
        await gate.release()
    }
}

extension MicrophoneSource {
    private func recoverFromNativeStopLocked() async throws {
        guard started, !activeIsRunningLocked() else { return }
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
        if let hostClock {
            return hostClock
        }
        let hostTicksPerSecond = self.hostTicksPerSecond
        return {
            AudioSourceTimestampMapper.hostTicks(
                fromMachTicks: AudioGetCurrentHostTime(),
                machTicksPerSecond: AudioSourceTimestampMapper.nativeHostTicksPerSecond(),
                hostTicksPerSecond: hostTicksPerSecond
            )
        }
    }

    private func makeStartBinding() throws -> (AVAudioFormat, AudioMicrophoneCallbackBox) {
        guard let sourceFormat = engine.currentFormat,
            let actual = Self.audioSourceFormat(sourceFormat),
            actual == generation.format,
            sourceFormat.commonFormat == .pcmFormatFloat32
        else {
            throw AudioSourceError.invalidFormat
        }
        guard
            let box = AudioMicrophoneCallbackBox(
                generation: generation,
                sourceFormat: sourceFormat,
                diagnostics: diagnostics,
                hostClock: resolvedHostClock(),
                hostTicksPerSecond: hostTicksPerSecond,
                machTicksPerSecond: machTicksPerSecond,
                gate: makeGate()
            )
        else {
            throw AudioSourceError.invalidFormat
        }
        return (sourceFormat, box)
    }
    private func startLocked() async throws {
        try await recoverFromNativeStopLocked()
        guard !started else { return }
        let state = authorizer.currentState()
        guard state == .authorized else {
            throw AudioSourceError.microphoneNotAuthorized(state)
        }
        await reapOrphanedBindingsLocked()
        guard orphanedBindings.isEmpty else {
            throw AudioSourceError.unavailable("previous producer has not joined")
        }
        if restartNeedsFreshRing {
            let restartFormat =
                engine.currentFormat
                .flatMap(Self.audioSourceFormat)
                ?? generation.format
            generation = try AudioSourceGeneration(
                role: .microphone,
                format: restartFormat,
                hostTicksPerSecond: hostTicksPerSecond,
                capacitySeconds: capacitySeconds
            )
            restartNeedsFreshRing = false
        }
        let sourceFormat: AVAudioFormat
        let box: AudioMicrophoneCallbackBox
        do {
            (sourceFormat, box) = try makeStartBinding()
        } catch {
            await failStartLocked()
            throw error
        }
        do {
            try engine.installTap(format: sourceFormat, handler: Self.makeHandler(box: box))
        } catch {
            await failStartLocked(box: box, sourceFormat: sourceFormat)
            throw error
        }
        do {
            try engine.start()
        } catch {
            engine.removeTap()
            await failStartLocked(box: box, sourceFormat: sourceFormat)
            throw error
        }
        do {
            try beginMonitoring()
        } catch {
            engine.removeTap()
            engine.stop()
            await failStartLocked(box: box, sourceFormat: sourceFormat)
            throw error
        }
        activeBinding = Binding(
            generation: generation,
            box: box,
            sourceFormat: sourceFormat,
            installed: true
        )
        started = true
    }

    private func beginMonitoring() throws {
        if broadcaster.isFinished {
            broadcaster = AudioDeviceChangeBroadcaster()
        }
        try deviceMonitor.start { [broadcaster] event in
            broadcaster.yield(event)
        }
        monitorStarted = true
        if let monitor = engine as? any MicrophoneConfigurationChangeMonitoring {
            monitor.setConfigurationChangeHandler { [weak self] in
                Task {
                    await self?.handleConfigurationChange()
                }
            }
        }
    }

    private func stopLocked() async {
        if monitorStarted {
            deviceMonitor.stop()
            monitorStarted = false
        }
        if let monitor = engine as? any MicrophoneConfigurationChangeMonitoring {
            monitor.setConfigurationChangeHandler(nil)
        }
        if let prepared = preparedBinding {
            preparedBinding = nil
            finalizeGeneration(prepared.generation)
        }
        if started, let active = activeBinding {
            activeBinding = nil
            started = false
            restartNeedsFreshRing = true
            active.box.gate.beginStop()
            if active.installed {
                engine.removeTap()
                engine.stop()
            }
            let joined = await active.box.gate.waitUntilIdle(timeout: joinTimeout)
            if joined {
                finalizeGeneration(active.generation)
            } else {
                retainOrphanedBinding(active)
            }
            broadcaster.finish()
            await reapOrphanedBindingsLocked()
            return
        }
        broadcaster.finish()
        await reapOrphanedBindingsLocked()
    }
    private func prepareLocked(_ event: AudioDeviceChangeEvent) async -> AudioSourcePreparation {
        await reapOrphanedBindingsLocked()
        guard orphanedBindings.isEmpty else {
            return .unchangedOnFailure(reason: "previous producer has not joined")
        }
        guard started else {
            return .unchangedOnFailure(reason: "microphone source is not started")
        }
        guard event.role == .microphone else {
            return .unchangedOnFailure(reason: "device role does not match source")
        }
        guard event.format.isRingCompatible else {
            return .unchangedOnFailure(reason: "unsupported device format")
        }
        guard let current = engine.currentFormat,
            let actual = Self.audioSourceFormat(current),
            actual == event.format,
            current.commonFormat == .pcmFormatFloat32
        else {
            return .unchangedOnFailure(reason: "device event does not match current input format")
        }
        if let prepared = preparedBinding {
            preparedBinding = nil
            finalizeGeneration(prepared.generation)
        }
        let newGeneration: AudioSourceGeneration
        do {
            newGeneration = try AudioSourceGeneration(
                role: .microphone,
                format: event.format,
                hostTicksPerSecond: hostTicksPerSecond,
                capacitySeconds: capacitySeconds
            )
        } catch {
            return .unchangedOnFailure(reason: "cannot construct source ring")
        }
        guard
            let box = AudioMicrophoneCallbackBox(
                generation: newGeneration,
                sourceFormat: current,
                diagnostics: diagnostics,
                hostClock: resolvedHostClock(),
                hostTicksPerSecond: hostTicksPerSecond,
                machTicksPerSecond: machTicksPerSecond,
                gate: makeGate()
            )
        else {
            finalizeGeneration(newGeneration)
            return .unchangedOnFailure(reason: "cannot build callback binding")
        }
        preparedBinding = Binding(
            generation: newGeneration,
            box: box,
            sourceFormat: current,
            installed: false
        )
        return .prepared(newGeneration)
    }

    private func commitLocked(_ newGeneration: AudioSourceGeneration) async -> Bool {
        guard started else { return false }
        if newGeneration.id == generation.id {
            return activeIsRunningLocked()
        }
        guard let prepared = preparedBinding, prepared.generation.id == newGeneration.id,
            let active = activeBinding
        else {
            return false
        }
        preparedBinding = nil
        guard let current = engine.currentFormat,
            let actual = Self.audioSourceFormat(current),
            actual == prepared.generation.format,
            current.commonFormat == .pcmFormatFloat32
        else {
            finalizeGeneration(prepared.generation)
            return false
        }
        active.box.gate.beginStop()
        engine.removeTap()
        do {
            try engine.installTap(
                format: prepared.sourceFormat,
                handler: Self.makeHandler(box: prepared.box)
            )
            if !engine.isRunning {
                try engine.start()
            }
        } catch {
            await rollbackFailedCommit(active: active, prepared: prepared)
            return false
        }
        activeBinding = Binding(
            generation: prepared.generation,
            box: prepared.box,
            sourceFormat: prepared.sourceFormat,
            installed: true
        )
        generation = prepared.generation
        let joined = await active.box.gate.waitUntilIdle(timeout: joinTimeout)
        if joined {
            finalizeGeneration(active.generation)
        } else {
            retainOrphanedBinding(active)
        }
        return true
    }

    private func rollbackFailedCommit(active: Binding, prepared: Binding) async {
        let joined = await active.box.gate.waitUntilIdle(timeout: joinTimeout)
        prepared.box.gate.beginStop()
        let preparedJoined = await prepared.box.gate.waitUntilIdle(timeout: joinTimeout)
        if joined {
            if restoreTap(
                generation: active.generation,
                sourceFormat: active.sourceFormat
            ) {
                activeBinding = Binding(
                    generation: active.generation,
                    box: active.box,
                    sourceFormat: active.sourceFormat,
                    installed: true
                )
                started = true
            } else {
                activeBinding = nil
                started = false
                restartNeedsFreshRing = true
                finalizeGeneration(active.generation)
            }
        } else {
            activeBinding = nil
            started = false
            restartNeedsFreshRing = true
            retainOrphanedBinding(active)
        }
        if preparedJoined {
            finalizeGeneration(prepared.generation)
        } else {
            retainOrphanedBinding(prepared)
        }
    }
    @discardableResult
    private func restoreTap(
        generation: AudioSourceGeneration,
        sourceFormat: AVAudioFormat
    ) -> Bool {
        guard
            let box = AudioMicrophoneCallbackBox(
                generation: generation,
                sourceFormat: sourceFormat,
                diagnostics: diagnostics,
                hostClock: resolvedHostClock(),
                hostTicksPerSecond: hostTicksPerSecond,
                machTicksPerSecond: machTicksPerSecond,
                gate: makeGate()
            )
        else {
            return false
        }
        do {
            try engine.installTap(format: sourceFormat, handler: Self.makeHandler(box: box))
            if !engine.isRunning {
                try engine.start()
            }
            activeBinding = Binding(
                generation: generation,
                box: box,
                sourceFormat: sourceFormat,
                installed: true
            )
            return true
        } catch {
            activeBinding = nil
            started = false
            restartNeedsFreshRing = true
            return false
        }
    }

    private func handleConfigurationChange() async {
        await gate.acquire()
        if started, let format = engine.currentFormat,
            let actual = Self.audioSourceFormat(format)
        {
            broadcaster.yield(
                AudioDeviceChangeEvent(
                    role: .microphone,
                    deviceID: "engine:current",
                    format: actual
                )
            )
        }
        await gate.release()
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

    private func failStartLocked(
        box: AudioMicrophoneCallbackBox? = nil,
        sourceFormat: AVAudioFormat? = nil
    ) async {
        if let box {
            box.gate.beginStop()
            if !(await box.gate.waitUntilIdle(timeout: joinTimeout)) {
                if let sourceFormat {
                    retainOrphanedBinding(
                        Binding(
                            generation: generation,
                            box: box,
                            sourceFormat: sourceFormat,
                            installed: false
                        )
                    )
                }
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
    private static func audioSourceFormat(_ format: AVAudioFormat) -> AudioSourceFormat? {
        guard format.sampleRate > 0,
            format.channelCount == 1 || format.channelCount == 2
        else {
            return nil
        }
        return AudioSourceFormat(
            sampleRate: Int(format.sampleRate.rounded()),
            channelCount: Int(format.channelCount)
        )
    }

    private static func makeHandler(
        box: AudioMicrophoneCallbackBox
    ) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        let gate = box.gate
        return { [box] buffer, time in
            guard gate.enter() else { return }
            defer { gate.leave() }
            box.handle(buffer, time: time)
        }
    }
}

/// The callback-side raw microphone binding; it owns one gate and one scratch
/// pointer array. It never converts or resamples.
private final class AudioMicrophoneCallbackBox: @unchecked Sendable {
    let generation: AudioSourceGeneration
    let gate: AudioCallbackGate
    private let diagnostics: AudioSourceDiagnostics?
    private let hostClock: @Sendable () -> UInt64
    private let hostTicksPerSecond: UInt64
    private let machTicksPerSecond: UInt64
    private var planarPointers: [UnsafeBufferPointer<Float>]
    init?(
        generation: AudioSourceGeneration,
        sourceFormat: AVAudioFormat,
        diagnostics: AudioSourceDiagnostics?,
        hostClock: @escaping @Sendable () -> UInt64,
        hostTicksPerSecond: UInt64,
        machTicksPerSecond: UInt64,
        gate: AudioCallbackGate
    ) {
        guard sourceFormat.commonFormat == .pcmFormatFloat32,
            let actual = MicrophoneSourceFormat.format(sourceFormat),
            actual == generation.format
        else {
            return nil
        }
        self.generation = generation
        self.diagnostics = diagnostics
        self.hostClock = hostClock
        self.hostTicksPerSecond = hostTicksPerSecond
        self.machTicksPerSecond = machTicksPerSecond
        self.gate = gate
        planarPointers = Array(
            repeating: UnsafeBufferPointer(start: nil, count: 0),
            count: generation.format.channelCount
        )
    }

    func handle(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        let started = diagnostics == nil ? 0 : DispatchTime.now().uptimeNanoseconds
        let frameCount = Int(buffer.frameLength)
        let hostTime =
            time.isHostTimeValid
            ? AudioSourceTimestampMapper.hostTicks(
                fromMachTicks: time.hostTime,
                machTicksPerSecond: machTicksPerSecond,
                hostTicksPerSecond: hostTicksPerSecond
            )
            : hostClock()
        var accepted = 0
        var dropped = 0
        var gap = 0
        var reason: RingDropReason?
        let gapBefore = generation.ringBuffer.stats.gapFrames

        if frameCount > 0, Self.isValid(buffer, for: generation.format) {
            if let result = write(buffer, frameCount: frameCount, hostTime: hostTime) {
                accepted = result.acceptedFrames
                dropped = result.droppedFrames
                reason = result.reason
            } else {
                dropped = frameCount
                reason = .invalidFormat
            }
        } else if frameCount > 0 {
            dropped = frameCount
            reason = .invalidFormat
        }
        let gapAfter = generation.ringBuffer.stats.gapFrames
        gap = max(0, Int(gapAfter - gapBefore))
        guard let diagnostics else { return }
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        diagnostics.recordCallback(
            durationNanos: Int64(min(elapsed, UInt64(Int64.max))),
            acceptedFrames: accepted,
            droppedFrames: dropped,
            gapFrames: gap,
            dropReason: reason
        )
    }

    private static func isValid(_ buffer: AVAudioPCMBuffer, for format: AudioSourceFormat) -> Bool {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
            buffer.format.sampleRate == Double(format.sampleRate),
            buffer.format.channelCount == AVAudioChannelCount(format.channelCount)
        else {
            return false
        }
        return true
    }

    private func write(
        _ buffer: AVAudioPCMBuffer,
        frameCount: Int,
        hostTime: UInt64
    ) -> RingWriteResult? {
        let channelCount = generation.format.channelCount
        if buffer.format.isInterleaved {
            let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            guard list.count == 1,
                list[0].mNumberChannels == UInt32(channelCount),
                let data = list[0].mData?.assumingMemoryBound(to: Float.self),
                Int(list[0].mDataByteSize) >= frameCount * channelCount * MemoryLayout<Float>.size
            else {
                return nil
            }
            let interleaved = UnsafeBufferPointer<Float>(
                start: data,
                count: frameCount * channelCount
            )
            return generation.ringBuffer.write(
                interleaved: interleaved,
                frameCount: frameCount,
                hostTime: hostTime
            )
        }
        guard let data = buffer.floatChannelData else { return nil }
        for channel in 0..<channelCount {
            planarPointers[channel] = UnsafeBufferPointer(start: data[channel], count: frameCount)
        }
        return generation.ringBuffer.write(
            planar: planarPointers,
            frameCount: frameCount,
            hostTime: hostTime
        )
    }
}
private enum MicrophoneSourceFormat {
    static func format(_ format: AVAudioFormat) -> AudioSourceFormat? {
        guard format.sampleRate > 0,
            format.channelCount == 1 || format.channelCount == 2
        else {
            return nil
        }
        return AudioSourceFormat(
            sampleRate: Int(format.sampleRate.rounded()),
            channelCount: Int(format.channelCount)
        )
    }
}
