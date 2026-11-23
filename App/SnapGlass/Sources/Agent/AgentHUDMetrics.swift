import Foundation

/// HUD counters observed by the real `RecordingControlPanel` in agent mode.
///
/// Normal launches only evaluate `AgentMode.isActive`; every counter update is
/// behind that static boolean. Nothing here reads or alters the presented view.
@MainActor
enum AgentHUDMetrics {
    /// Whether the counters belong to the measured scenario.
    private static var isEnabled = false
    /// Monotonic instant used as the `firstVisibleMs` origin.
    private static var origin: ContinuousClock.Instant?
    /// Milliseconds from the scenario launch to the HUD origin.
    private static var timelineOffsetMs = 0
    private static var firstVisibleAt: ContinuousClock.Instant?
    private static var firstApplyAt: ContinuousClock.Instant?
    private static var sizeThatFitsAtFirstVisible = 0
    /// Readiness instant; resizes at or after it are steady-state resizes.
    private static var recordingPhaseStartAt: ContinuousClock.Instant?
    /// Stop-request instant; resizes at or after it are finalization, not steady state.
    private static var recordingPhaseEndAt: ContinuousClock.Instant?

    /// Total `sizeThatFits` passes run by the panel.
    private(set) static var sizeThatFitsCount = 0
    /// Window frame changes actually applied.
    private(set) static var resizeCount = 0
    /// `apply(state:)` calls, including the initial present.
    private(set) static var applyCount = 0
    /// Every applied frame change, in application order.
    private(set) static var resizeRecords: [AgentResizeRecord] = []
    /// Resizes between readiness and the stop request.
    private(set) static var resizeCountRecordingPhase = 0

    /// Starts a fresh counting window from `origin`.
    ///
    /// - Parameters:
    ///   - origin: The instant the HUD latency is measured from (start request).
    ///   - timelineOrigin: The instant the report timeline is measured from (launch).
    static func begin(origin: ContinuousClock.Instant, timelineOrigin: ContinuousClock.Instant? = nil) {
        self.origin = origin
        timelineOffsetMs = timelineOrigin.map { milliseconds(from: $0, to: origin) } ?? 0
        firstVisibleAt = nil
        firstApplyAt = nil
        sizeThatFitsAtFirstVisible = 0
        sizeThatFitsCount = 0
        resizeCount = 0
        applyCount = 0
        resizeRecords = []
        resizeCountRecordingPhase = 0
        recordingPhaseStartAt = nil
        recordingPhaseEndAt = nil
        isEnabled = true
    }

    /// Stops counting, so harness warmup work cannot leak into a report.
    static func end() {
        isEnabled = false
    }

    /// Marks the first real captured sample; later resizes count as steady-state.
    static func markRecordingPhaseStart() {
        guard isEnabled else { return }
        recordingPhaseStartAt = .now
    }

    /// Marks the stop request; later resizes are finalization, not steady state.
    static func markRecordingPhaseEnd() {
        guard isEnabled else { return }
        recordingPhaseEndAt = .now
    }

    /// Samples the measurement count immediately before the first ordering front.
    static func noteFirstVisible() {
        guard isEnabled, firstVisibleAt == nil else { return }
        sizeThatFitsAtFirstVisible = sizeThatFitsCount
        firstVisibleAt = .now
    }

    /// Records one measurement pass.
    static func noteSizeThatFits() {
        guard isEnabled else { return }
        sizeThatFitsCount += 1
    }

    /// Records one applied window frame with its before/after size.
    static func noteResize(from oldSize: CGSize, to newSize: CGSize) {
        guard isEnabled else { return }
        let now = ContinuousClock.now
        resizeCount += 1
        let inRecordingPhase = isInRecordingPhase(now)
        if inRecordingPhase { resizeCountRecordingPhase += 1 }
        resizeRecords.append(
            AgentResizeRecord(
                t: milliseconds(from: origin ?? now, to: now) + timelineOffsetMs,
                from: AgentSize(width: Double(oldSize.width), height: Double(oldSize.height)),
                to: AgentSize(width: Double(newSize.width), height: Double(newSize.height)),
                recordingPhase: inRecordingPhase
            )
        )
    }

    /// Records one state application.
    static func noteApply() {
        guard isEnabled else { return }
        if firstApplyAt == nil { firstApplyAt = .now }
        applyCount += 1
    }

    /// Whether an instant falls between readiness and the stop request.
    private static func isInRecordingPhase(_ instant: ContinuousClock.Instant) -> Bool {
        guard let start = recordingPhaseStartAt, instant >= start else { return false }
        if let end = recordingPhaseEndAt { return instant < end }
        return true
    }

    /// Milliseconds from the counting origin to the first state application.
    static var firstApplyMs: Int? {
        guard let origin, let firstApplyAt else { return nil }
        return milliseconds(from: origin, to: firstApplyAt)
    }

    /// Milliseconds from scenario launch to the first state application.
    static var firstApplyTimelineMs: Int? {
        firstApplyMs.map { $0 + timelineOffsetMs }
    }

    /// Milliseconds from the counting origin to the first visible HUD frame.
    static var firstVisibleMs: Int? {
        guard let origin, let firstVisibleAt else { return nil }
        return milliseconds(from: origin, to: firstVisibleAt)
    }

    /// Milliseconds from scenario launch to the first visible HUD frame.
    static var firstVisibleTimelineMs: Int? {
        firstVisibleMs.map { $0 + timelineOffsetMs }
    }

    /// Measurement passes completed before the first visible frame.
    static var sizeThatFitsBeforeFirstVisible: Int {
        firstVisibleAt == nil ? 0 : sizeThatFitsAtFirstVisible
    }

    /// Whole milliseconds between two monotonic instants.
    static func milliseconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Int {
        let components = start.duration(to: end).components
        let seconds = max(0, components.seconds)
        let attoseconds = max(0, components.attoseconds)
        return Int(clamping: seconds * 1_000 + attoseconds / 1_000_000_000_000_000)
    }
}
