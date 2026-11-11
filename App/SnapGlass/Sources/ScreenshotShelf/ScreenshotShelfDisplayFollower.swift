import AppKit
import CaptureCore

/// Polls the pointer's display and asks the manager to hand the shelf over.
///
/// A 0.25 s poll is enough for a Dock-like handoff without a global event monitor, which
/// would require extra permissions. The shelf only moves after the pointer has **changed
/// displays** and rested there briefly: a shelf placed on the capture's display is not
/// yanked away just because the pointer happens to be on another display.
@MainActor
final class ScreenshotShelfDisplayFollower {
    /// A display the shelf can move to, reduced to the data the follower needs.
    ///
    /// Keeping this independent of `NSScreen` lets tests drive the follower with a fixed
    /// clock, fake display layout, and a fake pointer.
    struct Display: Equatable {
        let id: CGDirectDisplayID
        let frame: CGRect
    }

    private let interval: TimeInterval = 0.25
    private let settleDelay: TimeInterval = 0.18
    private let followCooldown: TimeInterval = 0.6
    private let displayProvider: () -> [Display]
    private let pointerLocationProvider: () -> CGPoint
    private let now: () -> Date
    private var loopTask: Task<Void, Never>?
    private var lastObservedPointerDisplayID: CGDirectDisplayID?
    private var candidateDisplayID: CGDirectDisplayID?
    private var candidateSince: Date?
    private var lastFollowAt: Date?
    private var isRunning = false

    /// The display the shelf is currently committed to.
    var shelfDisplayID: () -> CGDirectDisplayID? = { nil }
    /// Whether the shelf is in a state that may be moved right now.
    var canFollow: () -> Bool = { false }
    /// Called after the pointer has settled on a different display.
    var onFollow: ((CGDirectDisplayID) -> Void)?

    init(
        displayProvider: @escaping () -> [Display] = {
            NSScreen.screens.compactMap { screen in
                guard let id = ScreenshotShelfScreenResolver.displayID(for: screen) else {
                    return nil
                }
                return Display(id: id, frame: screen.frame)
            }
        },
        pointerLocationProvider: @escaping () -> CGPoint = { NSEvent.mouseLocation },
        now: @escaping () -> Date = Date.init
    ) {
        self.displayProvider = displayProvider
        self.pointerLocationProvider = pointerLocationProvider
        self.now = now
    }

    /// Starts observing the pointer. `baselineDisplayID` is the display the pointer was on
    /// when the shelf settled; a follow requires the pointer to leave it.
    func start(baselineDisplayID: CGDirectDisplayID? = nil) {
        guard !isRunning else { return }
        // A single display has nothing to follow; the screen-parameter observer restarts
        // the follower when another display is connected.
        guard displayProvider().count > 1 else { return }
        isRunning = true
        reset(baselineDisplayID: baselineDisplayID ?? currentPointerDisplayID())
        loopTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self.interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    func stop() {
        isRunning = false
        loopTask?.cancel()
        loopTask = nil
        lastObservedPointerDisplayID = nil
        candidateDisplayID = nil
        candidateSince = nil
    }

    /// Re-baselines after a capture, a manual show, or a screen-parameter change.
    ///
    /// Pass the display the pointer is on right now. Clearing the candidate means the
    /// shelf stays where it was placed until the pointer actually changes displays.
    func reset(baselineDisplayID: CGDirectDisplayID?) {
        lastObservedPointerDisplayID = baselineDisplayID ?? currentPointerDisplayID()
        candidateDisplayID = nil
        candidateSince = nil
    }

    private func tick() {
        handleTick(now: now())
    }

    /// One poll. Internal so tests can drive the timing without sleeping.
    func handleTick(now: Date) {
        let displays = displayProvider()
        guard displays.count > 1 else {
            candidateDisplayID = nil
            candidateSince = nil
            return
        }
        guard let pointerDisplayID = currentPointerDisplayID(from: displays) else { return }

        guard pointerDisplayID == lastObservedPointerDisplayID else {
            // The pointer entered a different display. Start (or restart) the settle window.
            lastObservedPointerDisplayID = pointerDisplayID
            candidateDisplayID = pointerDisplayID
            candidateSince = now
            guard canFollow() else {
                candidateDisplayID = nil
                candidateSince = nil
                return
            }
            return
        }

        guard candidateDisplayID == pointerDisplayID,
              let candidateSince,
              now.timeIntervalSince(candidateSince) >= settleDelay,
              pointerDisplayID != shelfDisplayID(),
              canFollow() else { return }
        if let lastFollowAt, now.timeIntervalSince(lastFollowAt) < followCooldown {
            return
        }
        lastFollowAt = now
        candidateDisplayID = nil
        onFollow?(pointerDisplayID)
    }

    private func currentPointerDisplayID() -> CGDirectDisplayID? {
        currentPointerDisplayID(from: displayProvider())
    }

    private func currentPointerDisplayID(from displays: [Display]) -> CGDirectDisplayID? {
        guard !displays.isEmpty else { return nil }
        guard let index = ScreenshotShelfDisplayFollowPolicy.nearestDisplayIndex(
            for: pointerLocationProvider(),
            displayFrames: displays.map(\.frame)
        ) else { return nil }
        return displays[index].id
    }
}
