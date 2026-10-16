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

    @Test("A second focus cancels the previous pending one")
    func secondFocusCancelsPrevious() async throws {
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

        #expect(recorder.calls.map(\.window) == [ObjectIdentifier(second)])
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
