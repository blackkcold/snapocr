import AppKit
import Testing

@Suite("System window focuser")
@MainActor
struct WindowFocusingTests {
    @Test("An already active app orders the window front immediately")
    func activeAppOrdersFrontImmediately() {
        let activation = FocusActivationSpy()
        activation.isActive = true
        let recorder = FrontRecorder()
        let focuser = SystemWindowFocuser(
            activation: activation,
            notificationCenter: NotificationCenter(),
            waitTimeout: .milliseconds(50),
            frontAction: recorder.record
        )
        let window = makeWindow()

        focuser.focus(window)

        #expect(recorder.calls.map(\.regardless) == [false])
        #expect(recorder.calls.map(\.window) == [ObjectIdentifier(window)])
        #expect(activation.requestActivationCount == 0)
    }

    @Test("An inactive app waits for didBecomeActive before ordering the window front")
    func inactiveAppWaitsForActivation() async throws {
        let center = NotificationCenter()
        let activation = FocusActivationSpy()
        let recorder = FrontRecorder()
        let focuser = SystemWindowFocuser(
            activation: activation,
            notificationCenter: center,
            waitTimeout: .milliseconds(300),
            frontAction: recorder.record
        )
        let window = makeWindow()

        focuser.focus(window)

        #expect(recorder.calls.isEmpty)
        #expect(activation.requestActivationCount == 1)

        activation.isActive = true
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        let fronted = await waitForFocusCondition { recorder.calls.count == 1 }

        #expect(fronted)
        #expect(recorder.calls.map(\.regardless) == [false])
        #expect(recorder.calls.map(\.window) == [ObjectIdentifier(window)])
    }

    @Test("A refused activation falls back to ordering the window front regardless")
    func refusedActivationFallsBackToVisible() async throws {
        let activation = FocusActivationSpy()
        let recorder = FrontRecorder()
        let focuser = SystemWindowFocuser(
            activation: activation,
            notificationCenter: NotificationCenter(),
            waitTimeout: .milliseconds(30),
            frontAction: recorder.record
        )
        let window = makeWindow()

        focuser.focus(window)
        #expect(recorder.calls.isEmpty)

        // The fallback fires from the activation timeout, so wait for it to fire
        // rather than for a duration that is assumed to be long enough.
        let fronted = await waitForFocusCondition { recorder.calls.count == 1 }

        #expect(fronted)
        #expect(recorder.calls.map(\.regardless) == [true])
        #expect(recorder.calls.map(\.window) == [ObjectIdentifier(window)])
    }

    @Test("A second focus does not cancel the first window's pending request")
    func secondFocusDoesNotCancelFirst() async throws {
        let center = NotificationCenter()
        let activation = FocusActivationSpy()
        let recorder = FrontRecorder()
        let focuser = SystemWindowFocuser(
            activation: activation,
            notificationCenter: center,
            waitTimeout: .milliseconds(300),
            frontAction: recorder.record
        )
        let first = makeWindow()
        let second = makeWindow()

        focuser.focus(first)
        focuser.focus(second)

        activation.isActive = true
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        let fronted = await waitForFocusCondition { recorder.calls.count == 2 }

        // 两个窗口都按请求顺序前置；最后请求的窗口最后成 key。
        #expect(fronted)
        #expect(recorder.calls.map(\.window) == [ObjectIdentifier(first), ObjectIdentifier(second)])
        #expect(recorder.calls.map(\.regardless) == [false, false])
        #expect(activation.requestActivationCount == 2)
    }

    @Test("Focusing the same window twice collapses into one front")
    func sameWindowFocusCollapses() async throws {
        let center = NotificationCenter()
        let activation = FocusActivationSpy()
        let recorder = FrontRecorder()
        let focuser = SystemWindowFocuser(
            activation: activation,
            notificationCenter: center,
            waitTimeout: .milliseconds(300),
            frontAction: recorder.record
        )
        let window = makeWindow()

        focuser.focus(window)
        focuser.focus(window)

        activation.isActive = true
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        let fronted = await waitForFocusCondition { recorder.calls.count == 1 }

        #expect(fronted)
        #expect(recorder.calls.map(\.window) == [ObjectIdentifier(window)])
        #expect(recorder.calls.map(\.regardless) == [false])
        #expect(activation.requestActivationCount == 2)
    }

    @Test("A completed focus does not fire again on a later activation")
    func completedFocusIgnoresLaterActivation() async throws {
        let center = NotificationCenter()
        let activation = FocusActivationSpy()
        let recorder = FrontRecorder()
        let focuser = SystemWindowFocuser(
            activation: activation,
            notificationCenter: center,
            waitTimeout: .milliseconds(300),
            frontAction: recorder.record
        )
        let window = makeWindow()

        focuser.focus(window)
        activation.isActive = true
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        let firstFront = await waitForFocusCondition { recorder.calls.count == 1 }
        #expect(firstFront)
        // 第一次解析把 waiter 与观察者一起清掉；等它真的清完，再发第二条。
        let cleanedUp = await waitForFocusCondition { !focuser.isObservingActivation }
        #expect(cleanedUp)

        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)

        #expect(recorder.calls.count == 1)
    }

    @Test("A late activation within the grace period gives the visible window one more front")
    func lateActivationRepairsKeyAfterTimeout() async throws {
        let center = NotificationCenter()
        let activation = FocusActivationSpy()
        let recorder = FrontRecorder()
        let focuser = SystemWindowFocuser(
            activation: activation,
            notificationCenter: center,
            waitTimeout: .milliseconds(30),
            graceTimeout: .milliseconds(600),
            frontAction: recorder.record
        )
        let window = makeWindow()
        window.orderFront(nil)

        focuser.focus(window)
        // 等超时兜底真的触发，而不是睡一段「应该够」的时长。
        let fellBack = await waitForFocusCondition { recorder.calls.count == 1 }
        #expect(fellBack)
        #expect(recorder.calls.map(\.regardless) == [true])

        activation.isActive = true
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        let repaired = await waitForFocusCondition { recorder.calls.count == 2 }

        // 超时兜底只保可见；迟到激活时无 key 窗口 → 补一次正常前置（成 key）。
        #expect(repaired)
        #expect(recorder.calls.map(\.regardless) == [true, false])
        #expect(recorder.calls.map(\.window) == [ObjectIdentifier(window), ObjectIdentifier(window)])
    }

    @Test("A late activation does not steal the key from a window that already has it")
    func lateActivationDoesNotStealKey() async throws {
        let center = NotificationCenter()
        let activation = FocusActivationSpy()
        let recorder = FrontRecorder()
        let focuser = SystemWindowFocuser(
            activation: activation,
            notificationCenter: center,
            waitTimeout: .milliseconds(30),
            graceTimeout: .milliseconds(600),
            frontAction: recorder.record
        )
        let window = makeWindow()
        window.orderFront(nil)

        focuser.focus(window)
        let fellBack = await waitForFocusCondition { recorder.calls.count == 1 }
        #expect(fellBack)
        #expect(recorder.calls.map(\.regardless) == [true])

        activation.hasKeyWindow = true
        activation.isActive = true
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        // The window already has the key slot, so the late activation must not front it
        // again. Waiting for the observer to be gone proves the notification was
        // processed and the waiter consumed, instead of assuming a duration was enough.
        let handled = await waitForFocusCondition { !focuser.isObservingActivation }
        #expect(handled)

        #expect(recorder.calls.map(\.regardless) == [true])
    }

    @Test("A late repair opportunity expires with the grace period")
    func graceExpiryDropsLateRepair() async throws {
        let center = NotificationCenter()
        let activation = FocusActivationSpy()
        let recorder = FrontRecorder()
        let focuser = SystemWindowFocuser(
            activation: activation,
            notificationCenter: center,
            waitTimeout: .milliseconds(30),
            graceTimeout: .milliseconds(60),
            frontAction: recorder.record
        )
        let window = makeWindow()
        window.orderFront(nil)

        focuser.focus(window)
        // This used to sleep 200ms over a 30ms + 60ms chain — a 2.22x margin that a
        // loaded runner can miss. Wait for the chain to actually finish instead: the
        // waiter is gone and the observer is removed only when both timers have fired.
        let expired = await waitForFocusCondition { !focuser.isObservingActivation }
        #expect(expired)
        #expect(focuser.waiterCount == 0)
        #expect(recorder.calls.map(\.regardless) == [true])

        activation.isActive = true
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        // Nothing is listening any more, so there is no processed state to wait for: the
        // point of the assertion is that no repair happens. Give the posted notification
        // a chance to be handled before concluding it did nothing.
        try await Task.sleep(for: .milliseconds(50))

        #expect(recorder.calls.map(\.regardless) == [true])
    }
}

/// Polls a fact the focuser owns instead of sleeping a duration assumed to be long enough.
///
/// The old tests waited 30–200 ms and then asserted; the margins against the timers they
/// exercised were 2.22x–10x, and `app-tests` is a required check, so a loaded runner could
/// turn a slow timer into a red build. Every condition below is a value the production type
/// already tracks (or, in `#if DEBUG`, exposes for exactly this), so the wait ends as soon as
/// the fact is true and fails only when it never becomes true.
///
/// - Parameters:
///   - timeout: How long the condition may take before it counts as never true.
///   - condition: The fact to observe; read on the main actor.
/// - Returns: Whether the condition became true within the timeout.
@MainActor
private func waitForFocusCondition(
    timeout: Duration = .seconds(5),
    _ condition: () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

@MainActor
private func makeWindow() -> NSWindow {
    NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
}

@MainActor
private final class FocusActivationSpy: ApplicationActivationControlling {
    var activationPolicy: NSApplication.ActivationPolicy = .regular
    var isActive = false
    var hasVisibleUserFacingWindow = false
    var hasKeyWindow = false
    private(set) var requestActivationCount = 0

    func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) -> Bool {
        activationPolicy = policy
        return true
    }

    func requestActivation() {
        // Simulates asynchronous activation: the app is *not* active until the test says so.
        requestActivationCount += 1
    }

    func deactivate() {
        isActive = false
    }
}

@MainActor
private final class FrontRecorder {
    struct Call {
        let window: ObjectIdentifier
        let regardless: Bool
    }

    private(set) var calls: [Call] = []

    func record(_ window: NSWindow, _ regardless: Bool) {
        calls.append(Call(window: ObjectIdentifier(window), regardless: regardless))
    }
}
