import Darwin
import Synchronization

/// The atomic backend used by the audio ring.
///
/// Production always uses ``automatic``. ``legacyForTesting`` exists only so the
/// macOS 13/14 code path can run on a newer host; it is internal and is never a
/// user-facing setting.
internal enum AudioAtomicBackendMode: Sendable, CustomStringConvertible {
    /// Uses `Synchronization.Atomic` on macOS 15+ and `OSAtomic` below it.
    case automatic
    /// Forces the public `OSAtomicAdd64Barrier` backend.
    case legacyForTesting

    var description: String {
        switch self {
        case .automatic: "automatic"
        case .legacyForTesting: "legacyForTesting"
        }
    }
}

/// A minimal atomic counter contract for ring bookkeeping.
///
/// The ring uses one of these per shared index and statistic. Operations are
/// deliberately finite: no compare-exchange retry loops and no spinning.
internal protocol AudioAtomicCounter: AnyObject {
    /// Loads the current value with acquire ordering.
    func loadAcquire() -> Int64
    /// Adds `delta` with release ordering and returns the previous value.
    @discardableResult
    func fetchAddRelease(_ delta: Int64) -> Int64
    /// Adds `delta` with acquire-release ordering and returns the previous value.
    @discardableResult
    func fetchAddAcqRel(_ delta: Int64) -> Int64
}

/// Creates atomic counters for the selected backend.
internal enum AudioAtomicCounterFactory {
    /// Returns a counter for `mode`.
    ///
    /// - Parameter mode: Production or forced legacy backend.
    /// - Returns: A counter for the selected backend.
    static func make(mode: AudioAtomicBackendMode) -> any AudioAtomicCounter {
        switch mode {
        case .legacyForTesting:
            return LegacyAudioAtomicCounter()
        case .automatic:
            if #available(macOS 15, *) {
                return ModernAudioAtomicCounter()
            }
            return LegacyAudioAtomicCounter()
        }
    }
}

@available(macOS 15, *)
private final class ModernAudioAtomicCounter: AudioAtomicCounter {
    private let value = Atomic<Int64>(0)

    func loadAcquire() -> Int64 {
        value.load(ordering: .acquiring)
    }

    func fetchAddRelease(_ delta: Int64) -> Int64 {
        value.add(delta, ordering: .releasing).oldValue
    }

    func fetchAddAcqRel(_ delta: Int64) -> Int64 {
        value.add(delta, ordering: .acquiringAndReleasing).oldValue
    }
}

private final class LegacyAudioAtomicCounter: AudioAtomicCounter {
    private let storage: UnsafeMutablePointer<Int64>

    init() {
        storage = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
        storage.initialize(to: 0)
    }

    deinit {
        storage.deinitialize(count: 1)
        storage.deallocate()
    }

    func loadAcquire() -> Int64 {
        // OSAtomicAdd64Barrier is a stronger full barrier than acquire. A zero
        // add is the public, non-underscored way to read through the same
        // barrier domain.
        OSAtomicAdd64Barrier(0, storage)
    }

    func fetchAddRelease(_ delta: Int64) -> Int64 {
        OSAtomicAdd64Barrier(delta, storage) - delta
    }

    func fetchAddAcqRel(_ delta: Int64) -> Int64 {
        OSAtomicAdd64Barrier(delta, storage) - delta
    }
}

/// A single-owner gate whose handoff carries the previous owner's private state.
///
/// Acquisition is a compare-exchange from 0 to 1 with acquire-release ordering.
/// Release stores 0 with release ordering. A failed acquisition never mutates
/// the gate, so a concurrent loser cannot decrement the winner's ownership. This
/// is the acquisition barrier that makes a producer's or consumer's private
/// cursor state visible to the next owner.
internal final class AudioOwnershipGate {
    private let storage: any AudioOwnershipStorage

    init(mode: AudioAtomicBackendMode) {
        switch mode {
        case .legacyForTesting:
            storage = LegacyAudioOwnershipStorage()
        case .automatic:
            if #available(macOS 15, *) {
                storage = ModernAudioOwnershipStorage()
            } else {
                storage = LegacyAudioOwnershipStorage()
            }
        }
    }

    /// Whether the gate is currently held.
    var isHeld: Bool {
        storage.loadAcquire() != 0
    }

    /// The largest observed ownership depth; a successful gate is depth one.
    var maxObservedDepth: Int {
        storage.maxObservedDepth()
    }

    /// Attempts to become the sole owner.
    ///
    /// - Returns: `true` when ownership was acquired, `false` when another
    ///   owner is active. A rejected attempt does not change the gate.
    func tryAcquire() -> Bool {
        guard storage.compareExchangeAcqRel(expected: 0, desired: 1) else {
            return false
        }
        storage.noteAcquired()
        return true
    }

    /// Releases ownership with release ordering.
    func release() {
        storage.storeRelease(0)
    }
}

private protocol AudioOwnershipStorage: AnyObject {
    func loadAcquire() -> Int64
    func compareExchangeAcqRel(expected: Int64, desired: Int64) -> Bool
    func storeRelease(_ value: Int64)
    func noteAcquired()
    func maxObservedDepth() -> Int
}

@available(macOS 15, *)
private final class ModernAudioOwnershipStorage: AudioOwnershipStorage {
    private let value = Atomic<Int64>(0)
    private let maxDepth = Atomic<Int64>(0)

    func loadAcquire() -> Int64 {
        value.load(ordering: .acquiring)
    }

    func compareExchangeAcqRel(expected: Int64, desired: Int64) -> Bool {
        value.compareExchange(
            expected: expected,
            desired: desired,
            ordering: .acquiringAndReleasing
        ).exchanged
    }

    func storeRelease(_ value: Int64) {
        self.value.store(value, ordering: .releasing)
    }

    func noteAcquired() {
        if maxDepth.load(ordering: .acquiring) == 0 {
            maxDepth.store(1, ordering: .releasing)
        }
    }

    func maxObservedDepth() -> Int {
        maxDepth.load(ordering: .acquiring) == 0 ? 0 : 1
    }
}

private final class LegacyAudioOwnershipStorage: AudioOwnershipStorage {
    private let storage: UnsafeMutablePointer<Int64>
    private let maxDepth: UnsafeMutablePointer<Int64>

    init() {
        storage = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
        storage.initialize(to: 0)
        maxDepth = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
        maxDepth.initialize(to: 0)
    }

    deinit {
        storage.deinitialize(count: 1)
        storage.deallocate()
        maxDepth.deinitialize(count: 1)
        maxDepth.deallocate()
    }

    func loadAcquire() -> Int64 {
        OSAtomicAdd64Barrier(0, storage)
    }

    func compareExchangeAcqRel(expected: Int64, desired: Int64) -> Bool {
        OSAtomicCompareAndSwap64Barrier(expected, desired, storage)
    }

    func storeRelease(_ value: Int64) {
        OSAtomicAdd64Barrier(value - OSAtomicAdd64Barrier(0, storage), storage)
    }

    func noteAcquired() {
        _ = OSAtomicCompareAndSwap64Barrier(0, 1, maxDepth)
    }

    func maxObservedDepth() -> Int {
        OSAtomicAdd64Barrier(0, maxDepth) == 0 ? 0 : 1
    }
}
