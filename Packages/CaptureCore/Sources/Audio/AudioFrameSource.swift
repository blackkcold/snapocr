import Dispatch
import Foundation

/// The sample layout a source ring stores.
public struct AudioSourceFormat: Sendable, Hashable {
    /// Sample rate in hertz.
    public let sampleRate: Int
    /// Channel count; source rings support mono and stereo.
    public let channelCount: Int

    /// Creates a source format.
    ///
    /// - Parameters:
    ///   - sampleRate: Sample rate in hertz.
    ///   - channelCount: Channel count.
    public init(sampleRate: Int, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    /// Whether the format can construct a source ring.
    var isRingCompatible: Bool {
        sampleRate > 0
            && sampleRate <= 768_000
            && (channelCount == 1 || channelCount == 2)
    }
}

/// One immutable source generation and its producer ring.
///
/// The generation owns the ring identity and describes the actual native source
/// format (for example 44.1 kHz mono), never a resampled session format. The
/// producer writes, the Task 6 pump resamples/reads, and a retired generation is
/// drained only after its producer has stopped and joined. A retired ring may be
/// closed with staging retained; Task 6 drains and retries `finishProducing()`.
public struct AudioSourceGeneration: Sendable {
    /// Stable identity used for preparation tokens and stale-commit checks.
    public let id: UUID
    /// Logical recording role.
    public let role: RecordingTrackRole
    /// Format of the audio stored in ``ringBuffer``.
    public let format: AudioSourceFormat
    /// Producer-owned ring for this generation.
    public let ringBuffer: AudioSourceRingBuffer

    /// Creates a generation around an existing ring.
    ///
    /// - Parameters:
    ///   - id: Stable generation identity.
    ///   - role: Logical recording role.
    ///   - format: Format of the ring's audio.
    ///   - ringBuffer: Ring constructed with the same role and format.
    public init(
        id: UUID = UUID(),
        role: RecordingTrackRole,
        format: AudioSourceFormat,
        ringBuffer: AudioSourceRingBuffer
    ) {
        self.id = id
        self.role = role
        self.format = format
        self.ringBuffer = ringBuffer
    }

    /// Creates a generation and a matching ring.
    ///
    /// - Parameters:
    ///   - role: Logical recording role.
    ///   - format: Format for the generation and ring.
    ///   - hostTicksPerSecond: Host clock ticks per second.
    ///   - capacitySeconds: Ring capacity in seconds.
    /// - Throws: ``AudioRingConfigurationError`` for an invalid format or capacity.
    public init(
        role: RecordingTrackRole,
        format: AudioSourceFormat,
        hostTicksPerSecond: UInt64,
        capacitySeconds: Double = 2.0
    ) throws {
        let ring = try AudioSourceRingBuffer(
            role: role,
            sampleRate: format.sampleRate,
            channelCount: format.channelCount,
            hostTicksPerSecond: hostTicksPerSecond,
            capacitySeconds: capacitySeconds
        )
        self.init(role: role, format: format, ringBuffer: ring)
    }
}

/// The result of preparing a source reconfiguration without committing it.
public enum AudioSourcePreparation: Sendable {
    /// A new generation is ready and may be committed.
    case prepared(AudioSourceGeneration)
    /// Preparation failed; the previous healthy generation remains active.
    case unchangedOnFailure(reason: String)
}

/// A device-level audio format change for one role.
public struct AudioDeviceChangeEvent: Sendable {
    /// Logical recording role affected by the change.
    public let role: RecordingTrackRole
    /// Opaque device identifier; callers must not encode serial numbers.
    public let deviceID: String
    /// New source format reported by the device.
    public let format: AudioSourceFormat

    /// Creates a device change event.
    ///
    /// - Parameters:
    ///   - role: Logical recording role.
    ///   - deviceID: Opaque device identifier.
    ///   - format: New source format.
    public init(role: RecordingTrackRole, deviceID: String, format: AudioSourceFormat) {
        self.role = role
        self.deviceID = deviceID
        self.format = format
    }
}

/// A platform audio frame source with a two-phase reconfiguration contract.
public protocol AudioFrameSource: AnyObject, Sendable {
    /// Logical recording role produced by the source.
    var role: RecordingTrackRole { get }
    /// Returns the generation currently receiving producer frames.
    ///
    /// - Returns: The active generation.
    func currentGeneration() async -> AudioSourceGeneration
    /// Starts capture into the active generation.
    ///
    /// - Throws: ``AudioSourceError`` when capture cannot start.
    func start() async throws
    /// Returns whether the source producer is currently running.
    ///
    /// - Returns: `true` only while capture is active and its generation is open.
    func isRunning() async -> Bool
    /// Stops capture, joins the producer, and closes the active ring.
    func stop() async
    /// Whether every retired producer has joined and may be handed to Task 6.
    ///
    /// - Returns: `false` while a timed-out callback join retains an owned ring.
    func isProducerJoined() async -> Bool
    /// Prepares a device or format reconfiguration without committing it.
    ///
    /// - Parameter event: Device change to prepare.
    /// - Returns: A prepared generation or an unchanged failure.
    func prepareReconfiguration(_ event: AudioDeviceChangeEvent) async -> AudioSourcePreparation
    /// Commits a prepared generation.
    ///
    /// - Parameter generation: Generation returned by ``prepareReconfiguration(_:)``.
    /// - Returns: Whether the generation became active.
    func commitReconfiguration(_ generation: AudioSourceGeneration) async -> Bool
}

/// Optional cancellation seam for sources with an outstanding preparation.
///
/// The route controller owns supersession and calls this before a new
/// preparation. A source that does not conform has no cancellable preparation.
public protocol AudioSourceReconfigurationCancelling: AnyObject, Sendable {
    /// Discards an uncommitted generation and all resources created for it.
    ///
    /// - Parameter generationID: Identity returned by ``AudioFrameSource/prepareReconfiguration(_:)``.
    func cancelReconfiguration(_ generationID: UUID) async
}

/// A source lifecycle failure.
public enum AudioSourceError: Error, Equatable, Sendable {
    /// The requested format cannot construct a ring.
    case invalidFormat
    /// The host timebase cannot be represented by the ring.
    case invalidHostTimebase
    /// Microphone access is unavailable; callers must not prompt implicitly.
    case microphoneNotAuthorized(MicrophoneAuthorizationState)
    /// A platform object could not install its callback.
    case installFailed(String)
    /// A platform capture object could not start.
    case startFailed(String)
    /// A required platform resource is unavailable.
    case unavailable(String)
}

/// Serializes asynchronous control operations for one source or controller.
///
/// The gate is an explicit state machine: an actor alone is reentrant across
/// `await`, so the busy flag and waiter queue make the critical section exclusive.
internal actor AudioControlGate {
    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var busy = false
    private var nextID: UInt64 = 0
    private var waiters: [Waiter] = []
    private var cancelledIDs: Set<UInt64> = []

    func acquire() async {
        if !busy {
            busy = true
            return
        }
        let id = takeID()
        _ = await withCheckedContinuation { continuation in
            waiters.append(Waiter(id: id, continuation: continuation))
        }
    }

    /// Acquires the gate but reports `false` when the waiting task is cancelled.
    func acquireCancellable() async -> Bool {
        if Task.isCancelled {
            return false
        }
        if !busy {
            busy = true
            return true
        }
        let id = takeID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if cancelledIDs.remove(id) != nil {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
        cancelledIDs.remove(id)
        if acquired, Task.isCancelled {
            release()
            return false
        }
        return acquired
    }

    func release() {
        if waiters.isEmpty {
            busy = false
            cancelledIDs.removeAll()
            return
        }
        let waiter = waiters.removeFirst()
        cancelledIDs.remove(waiter.id)
        waiter.continuation.resume(returning: true)
    }

    private func cancel(_ id: UInt64) {
        guard busy else { return }
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(returning: false)
            return
        }
        if cancelledIDs.count >= 64 {
            cancelledIDs.remove(cancelledIDs.first ?? id)
        }
        cancelledIDs.insert(id)
    }

    private func takeID() -> UInt64 {
        defer { nextID += 1 }
        return nextID
    }
}

/// Rejects callbacks that begin after a producer stop has started.
///
/// The callback path only performs two acquire loads and two release adds; it
/// never waits. `stop()` polls the active count after removing the platform
/// callback, so an in-flight callback always finishes before the ring closes.
internal final class AudioCallbackGate: @unchecked Sendable {
    private let stopping: any AudioAtomicCounter
    private let handlerLock = NSLock()
    private let idleSignal = DispatchSemaphore(value: 0)
    #if DEBUG
        private let admissionHook: (@Sendable () -> Void)?

        init(admissionHook: (@Sendable () -> Void)? = nil) {
            stopping = AudioAtomicCounterFactory.make(mode: .automatic)
            self.admissionHook = admissionHook
        }
    #else
        init() {
            stopping = AudioAtomicCounterFactory.make(mode: .automatic)
        }
    #endif

    func enter() -> Bool {
        if stopping.loadAcquire() != 0 {
            return false
        }
        guard handlerLock.try() else {
            return false
        }
        #if DEBUG
            admissionHook?()
        #endif
        if stopping.loadAcquire() != 0 {
            handlerLock.unlock()
            idleSignal.signal()
            return false
        }
        return true
    }

    func leave() {
        handlerLock.unlock()
        idleSignal.signal()
    }

    func beginStop() {
        stopping.fetchAddRelease(1)
    }

    /// Waits until no callback owns the handler lock.
    ///
    /// After `beginStop()`, every later `enter()` either sees the stop flag or
    /// loses the try-lock. A successful try-lock is therefore the quiescence
    /// proof; no independently published counter is consulted.
    ///
    /// - Parameter timeout: Maximum join duration.
    /// - Returns: `true` when quiescent; `false` when a callback still owns the
    ///   admission lock at the deadline.
    func waitUntilIdle(timeout: Duration = .seconds(2)) async -> Bool {
        if probeIdle() {
            return true
        }
        return await Task.detached { [self] in
            waitSynchronously(timeout: timeout)
        }.value
    }

    private func probeIdle() -> Bool {
        if handlerLock.try() {
            handlerLock.unlock()
            return true
        }
        return false
    }

    private func waitSynchronously(timeout: Duration) -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            if probeIdle() {
                return true
            }
            if clock.now >= deadline {
                return false
            }
            _ = idleSignal.wait(timeout: .now() + .milliseconds(5))
        }
    }
}
