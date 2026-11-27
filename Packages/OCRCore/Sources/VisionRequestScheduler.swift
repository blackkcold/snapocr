import Foundation

/// Runs Vision text requests under a bounded number of blocked threads.
///
/// `VNImageRequestHandler.perform` blocks the calling thread synchronously and cannot
/// be cancelled. Moving it off the cooperative pool stops one request from starving
/// every other async task, but it bounds nothing on its own: a screenshot with many
/// tiles, or a user asking for OCR from several windows, can spawn blocked threads
/// without limit, and a request that never returns keeps its thread forever.
///
/// This type makes two things true:
///
/// - At most `capacity` requests hold a thread at once, so the number of lost threads
///   has a ceiling instead of growing with usage.
/// - A request that outlives `requestTimeout` is reported to its caller instead of
///   hanging the UI forever.
///
/// A timed-out request cannot be aborted, so its thread stays busy. That is why the
/// slot is accounted by the thread rather than by the caller: the slot is released when
/// the work actually returns, not when the deadline fires. A request that comes back
/// after its deadline therefore gives its capacity back, and only threads that never
/// return stay counted. When every slot is held by a thread past its deadline the engine
/// counts as unresponsive and later calls fail immediately instead of queueing behind
/// threads that may never return; if those threads do come back, the pool recovers on
/// its own instead of demanding a restart.
actor VisionRequestScheduler {
    /// How many Vision requests may hold a blocked thread at once.
    ///
    /// The tiled pipeline recognises at most three tiles concurrently; the extra slot
    /// keeps a single-image request from queueing behind a full tile set, and leaves a
    /// little headroom for the rescue pass a large canvas may trigger.
    static let defaultCapacity = 4

    /// How long one request may run before its caller is told it timed out.
    ///
    /// This is a hang detector, not a performance gate: real recognition is far below
    /// it. It bounds one request, not one screenshot — the rescue pass and the `.fast`
    /// safety net are separate requests, so a pathological image can still take longer
    /// than this in total. A whole-capture budget would be a different change.
    static let defaultRequestTimeout: Duration = .seconds(30)

    /// How long a request may wait for a free slot before its caller is told the engine
    /// is stuck.
    ///
    /// Must stay comfortably above ``defaultRequestTimeout``. Every granted request is
    /// bounded by that timeout, so a healthy pool frees a slot within roughly one
    /// timeout of granting it: a shorter budget would report "engine unresponsive,
    /// restart" during ordinary concurrent use and send the user to restart a working
    /// app. This is a backstop for a pool that stopped making progress, not a
    /// performance gate.
    static let defaultCapacityTimeout: Duration = .seconds(60)

    /// The scheduler shared by every engine in the process.
    ///
    /// Bounding has to be process-wide to mean anything: a per-engine limit would let
    /// four engines hold four threads each.
    static let shared = VisionRequestScheduler()

    private let capacity: Int
    private let requestTimeout: Duration
    private let capacityTimeout: Duration

    /// Threads held by a request right now, whether or not they are past their deadline.
    ///
    /// This is the number the ceiling applies to. Overdue threads are still counted:
    /// Vision cannot abort them, so the machine really is still working.
    private var granted = 0
    /// Of `granted`, the requests that outlived `requestTimeout` and have not returned.
    ///
    /// A request leaves this count when its thread comes back, so a slow-but-finished
    /// recognition never permanently costs capacity.
    private var overdue = 0
    private var unresponsive = false
    private var waiters: [Waiter] = []

    /// Highest number of slots held at the same time, for tests and diagnostics.
    private(set) var peakGranted = 0

    init(
        capacity: Int = VisionRequestScheduler.defaultCapacity,
        requestTimeout: Duration = VisionRequestScheduler.defaultRequestTimeout,
        capacityTimeout: Duration = VisionRequestScheduler.defaultCapacityTimeout
    ) {
        self.capacity = max(1, capacity)
        self.requestTimeout = requestTimeout
        self.capacityTimeout = capacityTimeout
    }

    // MARK: - 诊断

    /// A point-in-time view of the pool, for tests and log lines.
    struct Snapshot: Sendable, Equatable {
        /// Maximum threads the pool may occupy.
        let capacity: Int
        /// Threads held by a request right now, on time or overdue.
        let granted: Int
        /// Of `granted`, the requests past their deadline that have not returned.
        let overdue: Int
        /// Highest number of slots held at the same time since launch.
        let peakGranted: Int
        /// Whether every held thread is past its deadline, so new requests fail fast.
        let unresponsive: Bool
    }

    /// The current state of the pool.
    var snapshot: Snapshot {
        Snapshot(
            capacity: capacity,
            granted: granted,
            overdue: overdue,
            peakGranted: peakGranted,
            unresponsive: unresponsive
        )
    }

    /// The request timeout this scheduler applies.
    var timeout: Duration { requestTimeout }

    // MARK: - 执行

    /// Runs one request while holding a slot.
    ///
    /// The operation is abandoned rather than cancelled on timeout, because Vision
    /// cannot stop a `perform`: cancelling would only change what the caller sees, not
    /// what the machine is doing. The slot follows the thread, not the caller, so a
    /// cancelled call never frees capacity that is still busy, and a timed-out call does
    /// not permanently spend capacity its thread later gives back.
    ///
    /// - Parameter operation: The blocking work; one slot is held for its whole duration.
    /// - Returns: The lines the operation produced.
    /// - Throws: ``OCRError/visionRequestTimedOut(timeout:)`` when it outlives the
    ///   request timeout, ``OCRError/engineUnresponsive`` when no slot can be had,
    ///   `CancellationError` when the caller stopped waiting, or the operation's error.
    func run(_ operation: @escaping @Sendable () async throws -> [OCRLine]) async throws -> [OCRLine] {
        try await acquire()

        let lease = Lease()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[OCRLine], any Error>) in
                lease.install(continuation)

                // A caller cancelled before it got here is not waiting for this result;
                // the work still runs and still releases its slot when the thread returns.
                if Task.isCancelled {
                    lease.fail(CancellationError())
                }

                let timeout = Task { [requestTimeout] in
                    try? await Task.sleep(for: requestTimeout)
                    guard !Task.isCancelled else { return }
                    // The deadline only speaks for a thread that has not come back. If
                    // the work returned first, its result stands and no slot is overdue:
                    // deciding both questions under one lock is what keeps a request
                    // that returned on the boundary from being booked as a lost thread.
                    guard lease.claimTimeout() == .stillRunning else { return }
                    self.noteOverdue()
                    lease.fail(OCRError.visionRequestTimedOut(timeout: requestTimeout))
                }

                // Detached so a blocked thread is never attributed to the caller's
                // isolation, and so the operation keeps running after the caller stops
                // caring: the thread is already spent either way.
                Task.detached { [weak self] in
                    defer { timeout.cancel() }
                    do {
                        let lines = try await operation()
                        await self?.release(lease.finish())
                        lease.succeed(lines)
                    } catch {
                        await self?.release(lease.finish())
                        lease.fail(error)
                    }
                }
            }
        } onCancel: {
            lease.fail(CancellationError())
        }
    }

    // MARK: - 槽位

    private func acquire() async throws {
        try Task.checkCancellation()
        guard !unresponsive else { throw OCRError.engineUnresponsive }
        if granted < capacity {
            granted += 1
            peakGranted = max(peakGranted, granted)
            return
        }
        try await waitForSlot()
    }

    private func waitForSlot() async throws {
        let id = UUID()
        let deadline = Task { [capacityTimeout] in
            try? await Task.sleep(for: capacityTimeout)
            guard !Task.isCancelled else { return }
            self.failWaiter(id, with: OCRError.engineUnresponsive)
        }
        defer { deadline.cancel() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.failWaiter(id, with: CancellationError()) }
        }
    }

    /// Returns a slot whose thread has come back.
    ///
    /// A waiting caller takes the slot directly, so the count does not dip and come
    /// back between them.
    ///
    /// - Parameter completion: Whether the work returned on time, or after its deadline.
    private func release(_ completion: Completion) {
        if completion == .clearOverdue {
            overdue = max(0, overdue - 1)
            // A thread that came back means the pool is not exhausted any more. Holding
            // the verdict would keep demanding a restart for an engine that recovered.
            if unresponsive, overdue < capacity {
                unresponsive = false
            }
        }
        guard !waiters.isEmpty else {
            granted = max(0, granted - 1)
            return
        }
        let waiter = waiters.removeFirst()
        waiter.continuation.resume()
    }

    /// Records that one held thread has passed its deadline without returning.
    private func noteOverdue() {
        overdue += 1
        guard overdue >= capacity, !unresponsive else { return }
        unresponsive = true
        let stuck = waiters
        waiters.removeAll()
        for waiter in stuck {
            waiter.continuation.resume(throwing: OCRError.engineUnresponsive)
        }
    }

    private func failWaiter(_ id: UUID, with error: any Error) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: error)
    }

    // MARK: - 内部类型

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    /// How a returned thread has to be accounted for.
    private enum Completion: Sendable, Equatable {
        /// The work returned within its deadline; release the slot normally.
        case release
        /// The work returned after its deadline; release the slot and clear the
        /// overdue mark the deadline recorded.
        case clearOverdue
    }

    /// What the deadline found when it arrived.
    private enum TimeoutClaim: Sendable, Equatable {
        /// The work had not returned: its thread is held and is now overdue.
        case stillRunning
        /// The work had already returned: its result stands and nothing is owed.
        case alreadyReturned
    }

    /// Exactly-once bookkeeping for one granted slot.
    ///
    /// Two independent questions have to be answered exactly once, and they are not the
    /// same question: does the caller still need its result, and did the thread come
    /// back on time. A cancelled caller still holds a busy thread; a timed-out caller
    /// still gets its thread back eventually. They are tracked separately instead of
    /// sharing one "done" flag.
    private final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<[OCRLine], any Error>?
        private var pending: Result<[OCRLine], any Error>?
        private var callerServed = false
        private var returned = false
        private var timedOut = false

        /// Hands over the continuation, delivering an outcome that arrived first.
        func install(_ continuation: CheckedContinuation<[OCRLine], any Error>) {
            lock.lock()
            if let pending {
                self.pending = nil
                callerServed = true
                lock.unlock()
                Self.resume(continuation, with: pending)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func succeed(_ lines: [OCRLine]) { deliver(.success(lines)) }

        func fail(_ error: any Error) { deliver(.failure(error)) }

        /// Marks the thread as returned, and says how to account for the slot.
        ///
        /// Called exactly once by the work, whether it succeeded or failed.
        func finish() -> Completion {
            lock.lock()
            defer { lock.unlock() }
            returned = true
            return timedOut ? .clearOverdue : .release
        }

        /// Claims the request for its deadline.
        ///
        /// - Returns: ``TimeoutClaim/stillRunning`` when the thread is still held and the
        ///   deadline now owns the outcome; ``TimeoutClaim/alreadyReturned`` when the work
        ///   came back first, in which case the deadline must do nothing at all.
        func claimTimeout() -> TimeoutClaim {
            lock.lock()
            defer { lock.unlock() }
            guard !returned else { return .alreadyReturned }
            timedOut = true
            return .stillRunning
        }

        private func deliver(_ result: Result<[OCRLine], any Error>) {
            lock.lock()
            guard !callerServed else {
                lock.unlock()
                return
            }
            guard let continuation else {
                pending = result
                lock.unlock()
                return
            }
            self.continuation = nil
            callerServed = true
            lock.unlock()
            Self.resume(continuation, with: result)
        }

        private static func resume(
            _ continuation: CheckedContinuation<[OCRLine], any Error>,
            with result: Result<[OCRLine], any Error>
        ) {
            switch result {
            case .success(let lines):
                continuation.resume(returning: lines)
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }
}
