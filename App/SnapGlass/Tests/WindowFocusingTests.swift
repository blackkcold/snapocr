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
        try await Task.sleep(for: .milliseconds(50))

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

        try await Task.sleep(for: .milliseconds(120))

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
        try await Task.sleep(for: .milliseconds(50))

        // 两个窗口都按请求顺序前置；最后请求的窗口最后成 key。
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
        try await Task.sleep(for: .milliseconds(50))

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
        try await Task.sleep(for: .milliseconds(30))
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        try await Task.sleep(for: .milliseconds(30))

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
        try await Task.sleep(for: .milliseconds(120))
        #expect(recorder.calls.map(\.regardless) == [true])

        activation.isActive = true
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        try await Task.sleep(for: .milliseconds(50))

        // 超时兜底只保可见；迟到激活时无 key 窗口 → 补一次正常前置（成 key）。
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
        try await Task.sleep(for: .milliseconds(120))
        #expect(recorder.calls.map(\.regardless) == [true])

        activation.hasKeyWindow = true
        activation.isActive = true
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        try await Task.sleep(for: .milliseconds(50))

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
        try await Task.sleep(for: .milliseconds(200))
        #expect(recorder.calls.map(\.regardless) == [true])

        activation.isActive = true
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        try await Task.sleep(for: .milliseconds(50))

        #expect(recorder.calls.map(\.regardless) == [true])
    }
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
