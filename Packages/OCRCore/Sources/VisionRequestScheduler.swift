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
/// A timed-out request cannot be aborted, so its thread is already lost. The slot is
/// therefore spent rather than returned to the pool: pretending it came back would let
/// the real thread count climb past the ceiling the next time the same image is asked
/// for. Once every slot has been spent the engine counts as unresponsive and later
/// calls fail immediately instead of queueing behind threads that will never return.
///
/// Nothing here can reclaim a leaked thread — Vision offers no way to abort a `perform`.
/// The honest consequence is that recovering from a fully leaked engine needs a restart,
/// which is what ``OCRError/engineUnresponsive`` tells the user.
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
    /// bounded by that timeout, so a healthy pool drains a waiter within roughly one
    /// timeout: a shorter budget would report "engine unresponsive, restart" during
    /// ordinary concurrent use and send the user to restart a working app. Twice the
    /// request timeout means at least two full generations of work failed to admit the
    /// waiter, which is contention no queue drains from.
    static let defaultCapacityTimeout: Duration = .seconds(60)

    /// The scheduler shared by every engine in the process.
    ///
    /// Bounding has to be process-wide to mean anything: a per-engine limit would let
    /// four engines hold four threads each.
    static let shared = VisionRequestScheduler()

    private let capacity: Int
    private let requestTimeout: Duration
    private let capacityTimeout: Duration

    /// Slots whose request has not finished yet.
    private var granted = 0
    /// Slots whose request timed out and whose thread never came back.
    private var leaked = 0
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
        /// Requests still running under their own caller.
        let granted: Int
        /// Requests that timed out and never released their thread.
        let leaked: Int
        /// Blocked threads right now: `granted + leaked`.
        let liveThreads: Int
        /// Highest number of slots held at the same time since launch.
        let peakGranted: Int
        /// Whether every slot is spent and new requests fail immediately.
        let unresponsive: Bool
    }

    /// The current state of the pool.
    var snapshot: Snapshot {
        Snapshot(
            capacity: capacity,
            granted: granted,
            leaked: leaked,
            liveThreads: granted + leaked,
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
    /// what the machine is doing. Slot accounting follows the thread rather than the
    /// caller, so a cancelled call never frees capacity that is still busy.
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
                    guard lease.abandon() else { return }
                    self.noteLeak()
                    lease.fail(OCRError.visionRequestTimedOut(timeout: requestTimeout))
                }

                // Detached so a blocked thread is never attributed to the caller's
                // isolation, and so the operation keeps running after the caller stops
                // caring: the thread is already spent either way.
                Task.detached { [weak self] in
                    defer { timeout.cancel() }
                    do {
                        let lines = try await operation()
                        if lease.finish() {
                            await self?.release()
                        }
                        lease.succeed(lines)
                    } catch {
                        if lease.finish() {
                            await self?.release()
                        }
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
        // A leaked request still occupies a real thread, so the ceiling applies to
        // threads, not to bookkeeping: live threads are `granted + leaked`.
        if granted + leaked < capacity {
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

    /// Returns a slot whose work finished.
    ///
    /// A waiting caller takes the slot directly, so the count does not dip and come
    /// back between them.
    private func release() {
        guard !waiters.isEmpty else {
            granted = max(0, granted - 1)
            return
        }
        let waiter = waiters.removeFirst()
        waiter.continuation.resume()
    }

    private func noteLeak() {
        granted = max(0, granted - 1)
        leaked += 1
        guard leaked >= capacity, !unresponsive else { return }
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

    /// Exactly-once bookkeeping for one granted slot.
    ///
    /// Two independent questions have to be answered once each: does the caller still
    /// need its result, and does the slot still need to be accounted for. They are not
    /// the same question — a cancelled caller still holds a busy thread — so they are
    /// tracked separately instead of sharing one "done" flag.
    private final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<[OCRLine], any Error>?
        private var pending: Result<[OCRLine], any Error>?
        private var callerServed = false
        private var settled = false
        private var finished = false

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

        /// Marks the work as returned; true when the slot still has to be released.
        func finish() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            finished = true
            guard !settled else { return false }
            settled = true
            return true
        }

        /// Marks the request as timed out; true when its slot must count as leaked.
        ///
        /// Returns false when the work already finished, because the slot was then
        /// released normally and no thread was lost.
        func abandon() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !finished, !settled else { return false }
            settled = true
            return true
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
