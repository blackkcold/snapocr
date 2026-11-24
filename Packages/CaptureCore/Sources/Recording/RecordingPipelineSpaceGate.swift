import Foundation

/// Enforces volume headroom, seal admission, and bounded space-status reporting.
public actor RecordingPipelineSpaceGate: RecordingSpaceGating {
    private static let nextCheckpointSeconds = 300.0
    private static let tailReserveSeconds = 300.0

    private let budget: RecordingSpaceBudget
    private let backlog: RecordingBacklogPolicy
    private let now: @Sendable () -> Date
    private nonisolated let statusBroadcaster = RecordingSpaceStatusBroadcaster()

    private var activeSeals: Set<Int> = []
    private var backlogPressureActive = false
    private var lowSpaceActive = false
    private var lastCheckpointAt: Date?
    private var lastBacklogBytes: Int64 = 0

    /// Creates the gate used by a recording pipeline.
    public init(
        budget: RecordingSpaceBudget,
        backlog: RecordingBacklogPolicy,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.budget = budget
        self.backlog = backlog
        self.now = now
    }

    /// Runs the initial write-volume capacity check before the pipeline starts.
    public func preflightStart() async throws -> SpaceBudgetDecision {
        let decision = try budget.preflight()
        let state: RecordingSpaceState = decision.allowed ? .ok : .blocked
        publish(RecordingSpaceStatus(
            state: state,
            requiredBytes: decision.requiredBytes,
            availableBytes: decision.availableBytes,
            backlogBytes: 0,
            checkpointAgeSeconds: checkpointAge,
            reason: decision.reason
        ))
        return decision
    }

    /// Re-evaluates safety after a durable checkpoint; invalid input fails closed.
    public func checkpointCommitted(
        _ commit: CheckpointCommit,
        backlogBytes: Int64
    ) async -> RecordingSpaceStatus {
        lastCheckpointAt = commit.committedAt
        lastBacklogBytes = backlogBytes
        updateBacklogPressure(backlogBytes)

        guard Self.isValid(commit), backlogBytes >= 0 else {
            return publishStopping(
                requiredBytes: .max,
                availableBytes: 0,
                backlogBytes: max(0, backlogBytes),
                reason: "invalid checkpoint or backlog input"
            )
        }

        let capacity = budget.capacitySnapshot()
        guard capacity.reason == nil else {
            return publishStopping(
                requiredBytes: .max,
                availableBytes: 0,
                backlogBytes: backlogBytes,
                reason: capacity.reason ?? "volume capacity is unavailable"
            )
        }
        let required = budget.requiredHeadroomBytes(
            nextCheckpointSeconds: Self.nextCheckpointSeconds,
            sealHeadroomBytes: backlogBytes,
            tailReserveSeconds: Self.tailReserveSeconds
        )
        guard required != .max, capacity.availableBytes >= required else {
            return publishStopping(
                requiredBytes: required,
                availableBytes: capacity.availableBytes,
                backlogBytes: backlogBytes,
                reason: "insufficient volume headroom for checkpoint, seal, and tail"
            )
        }

        updateLowSpace(slackBytes: capacity.availableBytes - required)
        let reason: String?
        if backlogPressureActive {
            reason = "seal backlog remains above its low watermark"
        } else if lowSpaceActive {
            reason = "volume headroom remains below its recovery watermark"
        } else {
            reason = nil
        }
        return publish(RecordingSpaceStatus(
            state: backlogPressureActive || lowSpaceActive ? .low : .ok,
            requiredBytes: required,
            availableBytes: capacity.availableBytes,
            backlogBytes: backlogBytes,
            checkpointAgeSeconds: checkpointAge,
            reason: reason
        ))
    }

    /// Admits one seal only when the single-flight and volume headroom checks allow it.
    /// High backlog may defer additional seals, but never prevents the first seal
    /// from draining an otherwise idle queue.
    public func admitSeal(segmentIndex: Int, backlogBytes: Int64) async -> RecordingSealAdmission {
        if let preflight = preflightSealAdmission(
            segmentIndex: segmentIndex,
            backlogBytes: backlogBytes
        ) {
            return preflight
        }

        let capacity = budget.capacitySnapshot()
        guard capacity.reason == nil else {
            let reason = capacity.reason ?? "volume capacity is unavailable"
            _ = publishStopping(
                requiredBytes: .max,
                availableBytes: 0,
                backlogBytes: backlogBytes,
                reason: reason
            )
            return .stop(reason: reason)
        }
        let required = budget.requiredHeadroomBytes(
            nextCheckpointSeconds: Self.nextCheckpointSeconds,
            sealHeadroomBytes: backlogBytes,
            tailReserveSeconds: Self.tailReserveSeconds
        )
        guard required != .max, capacity.availableBytes >= required else {
            let reason = "insufficient volume headroom to seal safely"
            _ = publishStopping(
                requiredBytes: required,
                availableBytes: capacity.availableBytes,
                backlogBytes: backlogBytes,
                reason: reason
            )
            return .stop(reason: reason)
        }

        if case .stop(let reason) = backlog.admit(.seal, backlogBytes: backlogBytes) {
            _ = publishStopping(
                requiredBytes: required,
                availableBytes: capacity.availableBytes,
                backlogBytes: backlogBytes,
                reason: reason
            )
            return .stop(reason: reason)
        }
        if backlogPressureActive && !activeSeals.isEmpty {
            let reason = "seal backlog is high; capture continues while the active seal drains"
            publish(RecordingSpaceStatus(
                state: .low,
                requiredBytes: required,
                availableBytes: capacity.availableBytes,
                backlogBytes: backlogBytes,
                checkpointAgeSeconds: checkpointAge,
                reason: reason
            ))
            return .defer(reason: reason)
        }

        // If the queue is already above its high watermark and no seal is running,
        // admit one operation so pressure can make progress instead of deadlocking.
        activeSeals.insert(segmentIndex)
        updateLowSpace(slackBytes: capacity.availableBytes - required)
        publish(RecordingSpaceStatus(
            state: lowSpaceActive || backlogPressureActive ? .low : .ok,
            requiredBytes: required,
            availableBytes: capacity.availableBytes,
            backlogBytes: backlogBytes,
            checkpointAgeSeconds: checkpointAge,
            reason: backlogPressureActive ? "seal backlog is draining" : nil
        ))
        return .run
    }

    private func preflightSealAdmission(
        segmentIndex: Int,
        backlogBytes: Int64
    ) -> RecordingSealAdmission? {
        guard backlog.isValid, segmentIndex >= 0, backlogBytes >= 0 else {
            return stopAdmission(
                requiredBytes: .max,
                availableBytes: 0,
                backlogBytes: max(0, backlogBytes),
                reason: "invalid seal admission input or backlog policy"
            )
        }
        lastBacklogBytes = backlogBytes
        updateBacklogPressure(backlogBytes)

        guard !activeSeals.contains(segmentIndex) else {
            let reason = "seal for segment is already admitted"
            publishCurrentStatus(reason: reason)
            return .defer(reason: reason)
        }
        guard activeSeals.count < backlog.maximumConcurrentSeals else {
            let reason = "maximum concurrent seals reached"
            publishCurrentStatus(reason: reason)
            return .defer(reason: reason)
        }
        return nil
    }

    private func stopAdmission(
        requiredBytes: Int64,
        availableBytes: Int64,
        backlogBytes: Int64,
        reason: String
    ) -> RecordingSealAdmission {
        _ = publishStopping(
            requiredBytes: requiredBytes,
            availableBytes: availableBytes,
            backlogBytes: backlogBytes,
            reason: reason
        )
        return .stop(reason: reason)
    }

    /// Releases a previously admitted seal slot and refreshes the bounded status stream.
    public func sealFinished(segmentIndex: Int) async {
        guard activeSeals.remove(segmentIndex) != nil else { return }
        publishCurrentStatus(reason: "seal finished; backlog refreshes on the next checkpoint")
    }

    /// Returns a newest-only status stream; slow consumers cannot build an unbounded queue.
    ///
    /// The stream uses `.bufferingNewest(1)`, so `yield` may return `.dropped` for a
    /// slow consumer. It reports the latest state and is not a lossless event log;
    /// do not use it to claim that no status or sample was lost.
    public nonisolated func makeStatusStream() -> AsyncStream<RecordingSpaceStatus> {
        statusBroadcaster.makeStream()
    }

    private var checkpointAge: Double {
        guard let lastCheckpointAt else { return 0 }
        let age = now().timeIntervalSince(lastCheckpointAt)
        return age.isFinite ? max(0, age) : 0
    }

    private func updateBacklogPressure(_ backlogBytes: Int64) {
        guard backlogBytes >= 0, backlog.isValid else { return }
        if backlogBytes > backlog.highWatermarkBytes {
            backlogPressureActive = true
        } else if backlogBytes <= backlog.lowWatermarkBytes {
            backlogPressureActive = false
        }
    }

    private func updateLowSpace(slackBytes: Int64) {
        if slackBytes < backlog.lowWatermarkBytes {
            lowSpaceActive = true
        } else if slackBytes > backlog.highWatermarkBytes {
            lowSpaceActive = false
        }
    }

    private func publishStopping(
        requiredBytes: Int64,
        availableBytes: Int64,
        backlogBytes: Int64,
        reason: String
    ) -> RecordingSpaceStatus {
        publish(RecordingSpaceStatus(
            state: .stopping,
            requiredBytes: requiredBytes,
            availableBytes: availableBytes,
            backlogBytes: backlogBytes,
            checkpointAgeSeconds: checkpointAge,
            reason: reason
        ))
    }

    private func publishCurrentStatus(reason: String?) {
        let capacity = budget.capacitySnapshot()
        let required = budget.requiredHeadroomBytes(
            nextCheckpointSeconds: Self.nextCheckpointSeconds,
            sealHeadroomBytes: lastBacklogBytes,
            tailReserveSeconds: Self.tailReserveSeconds
        )
        guard capacity.reason == nil, required != .max, capacity.availableBytes >= required else {
            _ = publishStopping(
                requiredBytes: required,
                availableBytes: capacity.availableBytes,
                backlogBytes: lastBacklogBytes,
                reason: capacity.reason ?? "insufficient volume headroom"
            )
            return
        }
        updateLowSpace(slackBytes: capacity.availableBytes - required)
        publish(RecordingSpaceStatus(
            state: lowSpaceActive || backlogPressureActive ? .low : .ok,
            requiredBytes: required,
            availableBytes: capacity.availableBytes,
            backlogBytes: lastBacklogBytes,
            checkpointAgeSeconds: checkpointAge,
            reason: reason ?? (backlogPressureActive ? "seal backlog remains above its low watermark" : nil)
        ))
    }

    @discardableResult
    private func publish(_ status: RecordingSpaceStatus) -> RecordingSpaceStatus {
        statusBroadcaster.yield(status)
        return status
    }

    private static func isValid(_ commit: CheckpointCommit) -> Bool {
        guard commit.segmentIndex >= 0,
              commit.range.startSample >= 0,
              commit.range.sampleCount > 0,
              !commit.trackURLs.isEmpty,
              commit.trackURLs.values.allSatisfy(\.isFileURL) else { return false }
        let (_, overflow) = commit.range.startSample.addingReportingOverflow(commit.range.sampleCount)
        return !overflow
    }
}

private final class RecordingSpaceStatusBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<RecordingSpaceStatus>.Continuation] = [:]
    private var latest: RecordingSpaceStatus?

    func makeStream() -> AsyncStream<RecordingSpaceStatus> {
        let id = UUID()
        let pair = AsyncStream.makeStream(
            of: RecordingSpaceStatus.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        lock.lock()
        continuations[id] = pair.continuation
        let current = latest
        lock.unlock()

        pair.continuation.onTermination = { [weak self] _ in self?.remove(id) }
        if let current { pair.continuation.yield(current) }
        return pair.stream
    }

    func yield(_ status: RecordingSpaceStatus) {
        lock.lock()
        latest = status
        let targets = Array(continuations.values)
        lock.unlock()
        for target in targets { target.yield(status) }
    }

    private func remove(_ id: UUID) {
        lock.lock()
        continuations[id] = nil
        lock.unlock()
    }
}

public extension RecordingAudioPipelineFactory {
    /// Builds the production audio pipeline with the real URL capacity provider by default.
    ///
    /// The factory stays synchronous and no longer runs a preflight itself. The
    /// app calls it on its recording setup queue so directory creation and ledger
    /// initialization stay off the main actor; ``RecordingSessionPipeline/start(_:)``
    /// remains the single preflight gate through `spaceGate.preflightStart()`.
    /// Only the destination that actually receives bytes is registered; a
    /// directory with no writer is never part of the budget.
    static func makeSpaceGated(
        configuration: AudioRecordingConfiguration,
        roots: RecordingPipelineRoots,
        expectedVolumeUUID: String? = nil,
        backlog: RecordingBacklogPolicy,
        capacityProvider: any VolumeCapacityProviding = URLVolumeCapacityProvider(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws -> RecordingSessionPipeline {
        let storageConfiguration = RecordingStorageConfiguration(audioConfiguration: configuration)
        let budget = RecordingSpaceBudget(
            configuration: storageConfiguration,
            capacityProvider: capacityProvider,
            recordingRoot: roots.sessionRoot,
            expectedVolumeUUID: expectedVolumeUUID
        )
        let gate = RecordingPipelineSpaceGate(budget: budget, backlog: backlog, now: now)
        return try RecordingAudioPipelineFactory.make(
            configuration: configuration,
            roots: roots,
            spaceGate: gate
        )
    }
}
