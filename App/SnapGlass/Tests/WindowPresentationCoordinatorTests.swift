import AppKit
import Testing

@Suite("Window presentation coordinator")
@MainActor
struct WindowPresentationCoordinatorTests {
    @Test("A visible user-facing window prevents accessory downgrade after timeout")
    func visibleWindowPreventsAccessoryDowngrade() async throws {
        let activationController = ActivationControllerSpy(
            activationPolicy: .accessory,
            hasVisibleUserFacingWindow: true
        )
        let coordinator = WindowPresentationCoordinator(
            activationController: activationController,
            presentationTimeout: .milliseconds(10),
            notificationCenter: NotificationCenter()
        )
        var openCount = 0

        coordinator.present(id: "editor") {
            openCount += 1
        }
        try await Task.sleep(for: .milliseconds(50))

        #expect(openCount == 1)
        #expect(activationController.policyChanges == [.regular])
        #expect(activationController.activationPolicy == .regular)
    }

    @Test("An idle app without visible windows returns to accessory policy after timeout")
    func noVisibleWindowAllowsAccessoryDowngrade() async throws {
        let activationController = ActivationControllerSpy(
            activationPolicy: .accessory,
            hasVisibleUserFacingWindow: false
        )
        let coordinator = WindowPresentationCoordinator(
            activationController: activationController,
            presentationTimeout: .milliseconds(10),
            notificationCenter: NotificationCenter()
        )

        coordinator.present(id: "editor") {}
        try await Task.sleep(for: .milliseconds(50))

        #expect(activationController.policyChanges == [.regular, .accessory])
        #expect(activationController.activationPolicy == .accessory)
        #expect(activationController.deactivateCount == 1)
    }

    @Test("Downgrading to accessory deactivates the app to drop the Dock icon")
    func accessoryDowngradeDeactivatesApp() async throws {
        let activationController = ActivationControllerSpy(
            activationPolicy: .accessory,
            hasVisibleUserFacingWindow: false
        )
        let coordinator = WindowPresentationCoordinator(
            activationController: activationController,
            presentationTimeout: .milliseconds(10),
            notificationCenter: NotificationCenter()
        )

        coordinator.present(id: "editor") {}
        try await Task.sleep(for: .milliseconds(50))

        #expect(activationController.deactivateCount == 1)
    }

    @Test("A deferred downgrade is retried after the visible window disappears")
    func deferredDowngradeRetriesAfterWindowDisappears() async throws {
        let activationController = ActivationControllerSpy(
            activationPolicy: .accessory,
            hasVisibleUserFacingWindow: true
        )
        let coordinator = WindowPresentationCoordinator(
            activationController: activationController,
            presentationTimeout: .milliseconds(10),
            notificationCenter: NotificationCenter()
        )

        coordinator.present(id: "editor") {}
        try await Task.sleep(for: .milliseconds(50))
        activationController.hasVisibleUserFacingWindow = false
        coordinator.register(nil, id: "editor")

        #expect(activationController.policyChanges == [.regular, .accessory])
        #expect(activationController.activationPolicy == .accessory)
    }

    @Test("A deferred downgrade retries on its own until the closing window disappears")
    func deferredDowngradeRetriesWithoutRegisterCall() async throws {
        let center = NotificationCenter()
        let activationController = ActivationControllerSpy(
            activationPolicy: .regular,
            hasVisibleUserFacingWindow: true
        )
        let coordinator = WindowPresentationCoordinator(
            activationController: activationController,
            presentationTimeout: .milliseconds(10),
            notificationCenter: center,
            reevaluateRetryInterval: .milliseconds(20),
            reevaluateRetryBudget: .milliseconds(600)
        )
        let window = makeCoordinatorWindow()
        coordinator.register(window, id: "history")

        // 关闭瞬间窗口仍标记可见（orderOut 未完成）：
        // 单拍重算会在这里永久放弃降级。
        // 用通知模拟 AppKit 关闭事件；不要对测试自建 NSWindow 调 close()——
        // isReleasedWhenClosed 会让 ARC 下的窗口被二次释放（objc_release 崩溃）。
        center.post(name: NSWindow.willCloseNotification, object: window)
        try await Task.sleep(for: .milliseconds(30))
        activationController.hasVisibleUserFacingWindow = false
        try await Task.sleep(for: .milliseconds(300))

        #expect(activationController.policyChanges == [.accessory])
        #expect(activationController.activationPolicy == .accessory)
        #expect(activationController.deactivateCount == 1)
    }

    @Test("A presentation timeout gives the still-visible unkeyed window one last focus")
    func presentationTimeoutRefocusesVisibleUnkeyedWindow() async throws {
        let activation = ActivationControllerSpy(activationPolicy: .accessory, hasVisibleUserFacingWindow: true)
        let focuser = FocuserSpy()
        let coordinator = WindowPresentationCoordinator(
            activationController: activation,
            presentationTimeout: .milliseconds(10),
            notificationCenter: NotificationCenter(),
            focuser: focuser
        )
        let window = makeCoordinatorWindow()
        window.orderFront(nil)

        coordinator.present(id: "editor") {}
        coordinator.register(window, id: "editor")
        try await Task.sleep(for: .milliseconds(80))

        #expect(focuser.focusedWindows == [ObjectIdentifier(window), ObjectIdentifier(window)])
        #expect(activation.policyChanges == [.regular])
    }

    @Test("A presentation timeout does not refocus while the app is inactive")
    func presentationTimeoutSkipsRescueWhileInactive() async throws {
        let activation = ActivationControllerSpy(activationPolicy: .accessory, hasVisibleUserFacingWindow: true)
        let focuser = FocuserSpy()
        let coordinator = WindowPresentationCoordinator(
            activationController: activation,
            presentationTimeout: .milliseconds(10),
            notificationCenter: NotificationCenter(),
            focuser: focuser
        )
        let window = makeCoordinatorWindow()
        window.orderFront(nil)

        coordinator.present(id: "editor") {}
        coordinator.register(window, id: "editor")
        activation.isActive = false
        try await Task.sleep(for: .milliseconds(80))

        #expect(focuser.focusedWindows == [ObjectIdentifier(window)])
    }

    @Test("An open window without a registered window is opened once")
    func noWindowOpensOnce() {
        let activation = ActivationControllerSpy(activationPolicy: .regular, hasVisibleUserFacingWindow: true)
        let focuser = FocuserSpy()
        let coordinator = WindowPresentationCoordinator(
            activationController: activation,
            presentationTimeout: .milliseconds(10),
            notificationCenter: NotificationCenter(),
            focuser: focuser
        )
        var openCount = 0

        coordinator.present(id: "editor") { openCount += 1 }

        #expect(openCount == 1)
        #expect(focuser.focusedWindows.isEmpty)
    }

    @Test("A second present while opening in flight does not open again")
    func inFlightPresentationDoesNotReopen() {
        let activation = ActivationControllerSpy(activationPolicy: .regular, hasVisibleUserFacingWindow: true)
        let focuser = FocuserSpy()
        let coordinator = WindowPresentationCoordinator(
            activationController: activation,
            presentationTimeout: .milliseconds(10),
            notificationCenter: NotificationCenter(),
            focuser: focuser
        )
        var openCount = 0

        coordinator.present(id: "editor") { openCount += 1 }
        coordinator.present(id: "editor") { openCount += 1 }

        #expect(openCount == 1)
    }

    @Test("A live registered window is focused instead of reopened")
    func liveWindowIsFocused() {
        let activation = ActivationControllerSpy(activationPolicy: .regular, hasVisibleUserFacingWindow: true)
        activation.isActive = true
        let focuser = FocuserSpy()
        let coordinator = WindowPresentationCoordinator(
            activationController: activation,
            presentationTimeout: .milliseconds(10),
            notificationCenter: NotificationCenter(),
            focuser: focuser
        )
        let window = makeCoordinatorWindow()
        window.orderFront(nil)
        coordinator.register(window, id: "history")
        var openCount = 0

        coordinator.present(id: "history") { openCount += 1 }

        #expect(openCount == 0)
        #expect(focuser.focusedWindows == [ObjectIdentifier(window)])
    }

    @Test("A registered but hidden window is stale and reopened")
    func hiddenWindowIsStaleAndReopened() {
        let activation = ActivationControllerSpy(activationPolicy: .regular, hasVisibleUserFacingWindow: true)
        let focuser = FocuserSpy()
        let coordinator = WindowPresentationCoordinator(
            activationController: activation,
            presentationTimeout: .milliseconds(10),
            notificationCenter: NotificationCenter(),
            focuser: focuser
        )
        let window = makeCoordinatorWindow()
        coordinator.register(window, id: "history")
        var openCount = 0

        coordinator.present(id: "history") { openCount += 1 }

        #expect(openCount == 1)
        #expect(focuser.focusedWindows.isEmpty)
    }

    // MARK: - 关闭事件可靠性回归

    @Test("A reused window's later closes are observed without registering again")
    func reusedWindowCloseIsObservedWithoutReregistering() async throws {
        let center = NotificationCenter()
        let activation = ActivationControllerSpy(
            activationPolicy: .regular,
            hasVisibleUserFacingWindow: true
        )
        let coordinator = WindowPresentationCoordinator(
            activationController: activation,
            presentationTimeout: .milliseconds(20),
            notificationCenter: center,
            reevaluateRetryInterval: .milliseconds(20),
            reevaluateRetryBudget: .milliseconds(200)
        )
        let window = makeCoordinatorWindow()
        window.orderFront(nil)
        coordinator.register(window, id: "history")

        // 第一轮关闭：逐窗口观察被清理，但协调器级监听必须继续工作。
        center.post(name: NSWindow.willCloseNotification, object: window)
        try await Task.sleep(for: .milliseconds(60))
        #expect(activation.policyChanges.isEmpty)

        // SwiftUI 复用同一 NSWindow 重开，且不再调用 register()。
        window.orderFront(nil)
        coordinator.present(id: "history") {}
        try await Task.sleep(for: .milliseconds(80))
        #expect(activation.policyChanges.isEmpty)

        for round in 1...2 {
            // 关闭完成：全程不再 register()，只靠协调器级关闭监听。
            activation.hasVisibleUserFacingWindow = false
            center.post(name: NSWindow.willCloseNotification, object: window)
            try await Task.sleep(for: .milliseconds(300))
            #expect(activation.activationPolicy == .accessory)
            #expect(activation.deactivateCount == round)

            // 重开：只靠成为 key 恢复映射（SwiftUI 同样不会再次注册）。
            activation.hasVisibleUserFacingWindow = true
            window.orderFront(nil)
            center.post(name: NSWindow.didBecomeKeyNotification, object: window)
            try await Task.sleep(for: .milliseconds(40))
            #expect(activation.activationPolicy == .regular)
        }
    }

    @Test("A late close from a replaced window does not clear the live mapping")
    func staleWindowCloseDoesNotUnregisterReplacement() async throws {
        let center = NotificationCenter()
        let activation = ActivationControllerSpy(activationPolicy: .regular, hasVisibleUserFacingWindow: true)
        activation.isActive = true
        let focuser = FocuserSpy()
        let coordinator = WindowPresentationCoordinator(
            activationController: activation,
            presentationTimeout: .milliseconds(20),
            notificationCenter: center,
            focuser: focuser
        )
        let oldWindow = makeCoordinatorWindow()
        let newWindow = makeCoordinatorWindow()
        coordinator.register(oldWindow, id: "editor")
        coordinator.register(newWindow, id: "editor")
        newWindow.orderFront(nil)

        center.post(name: NSWindow.willCloseNotification, object: oldWindow)
        try await Task.sleep(for: .milliseconds(80))

        var openCount = 0
        coordinator.present(id: "editor") { openCount += 1 }

        #expect(openCount == 0)
        #expect(focuser.focusedWindows.last == ObjectIdentifier(newWindow))
    }

    @Test("Closing one of several windows keeps the app regular until the last one closes")
    func visibleSiblingPreventsAccessoryDowngrade() async throws {
        let center = NotificationCenter()
        let activation = ActivationControllerSpy(activationPolicy: .regular, hasVisibleUserFacingWindow: true)
        let coordinator = WindowPresentationCoordinator(
            activationController: activation,
            presentationTimeout: .milliseconds(20),
            notificationCenter: center,
            reevaluateRetryInterval: .milliseconds(20),
            reevaluateRetryBudget: .milliseconds(200)
        )
        let preferences = makeCoordinatorWindow()
        let history = makeCoordinatorWindow()
        coordinator.register(preferences, id: "preferences")
        coordinator.register(history, id: "history")

        center.post(name: NSWindow.willCloseNotification, object: preferences)
        try await Task.sleep(for: .milliseconds(80))
        #expect(activation.policyChanges.isEmpty)
        #expect(activation.activationPolicy == .regular)

        activation.hasVisibleUserFacingWindow = false
        center.post(name: NSWindow.willCloseNotification, object: history)
        try await Task.sleep(for: .milliseconds(300))

        #expect(activation.policyChanges == [.accessory])
        #expect(activation.deactivateCount == 1)
    }

    @Test("A close that arrives while the window is still visible downgrades once it disappears")
    func closeWhileStillVisibleDefersThenDowngrades() async throws {
        let center = NotificationCenter()
        let activation = ActivationControllerSpy(activationPolicy: .regular, hasVisibleUserFacingWindow: true)
        let coordinator = WindowPresentationCoordinator(
            activationController: activation,
            presentationTimeout: .milliseconds(20),
            notificationCenter: center,
            reevaluateRetryInterval: .milliseconds(20),
            reevaluateRetryBudget: .milliseconds(600)
        )
        let window = makeCoordinatorWindow()
        coordinator.register(window, id: "editor")

        center.post(name: NSWindow.willCloseNotification, object: window)
        try await Task.sleep(for: .milliseconds(60))
        #expect(activation.policyChanges.isEmpty)

        // 之后不触发任何调用：降级只能来自重算任务自身的有界等待。
        activation.hasVisibleUserFacingWindow = false
        try await Task.sleep(for: .milliseconds(400))

        #expect(activation.policyChanges == [.accessory])
        #expect(activation.deactivateCount == 1)
    }

    @Test("Repeated key and close notifications neither duplicate registration nor downgrade twice")
    func repeatedKeyAndCloseNotificationsDowngradeOnce() async throws {
        let center = NotificationCenter()
        let activation = ActivationControllerSpy(activationPolicy: .regular, hasVisibleUserFacingWindow: false)
        let focuser = FocuserSpy()
        let coordinator = WindowPresentationCoordinator(
            activationController: activation,
            presentationTimeout: .milliseconds(20),
            notificationCenter: center,
            focuser: focuser
        )
        let window = makeCoordinatorWindow()
        coordinator.register(window, id: "editor")

        center.post(name: NSWindow.didBecomeKeyNotification, object: window)
        center.post(name: NSWindow.didBecomeKeyNotification, object: window)
        center.post(name: NSWindow.willCloseNotification, object: window)
        center.post(name: NSWindow.willCloseNotification, object: window)
        try await Task.sleep(for: .milliseconds(300))

        #expect(activation.policyChanges.filter { $0 == .accessory }.count == 1)
        #expect(activation.deactivateCount == 1)
        #expect(focuser.focusedWindows.isEmpty)
    }

    @Test("Repeated open/close cycles do not accumulate identity records or observers")
    func repeatedCyclesDoNotAccumulateTrackedState() async throws {
        let center = NotificationCenter()
        let activation = ActivationControllerSpy(activationPolicy: .regular, hasVisibleUserFacingWindow: true)
        let coordinator = WindowPresentationCoordinator(
            activationController: activation,
            presentationTimeout: .milliseconds(20),
            notificationCenter: center,
            reevaluateRetryInterval: .milliseconds(20),
            reevaluateRetryBudget: .milliseconds(100)
        )
        let window = makeCoordinatorWindow()
        window.orderFront(nil)
        coordinator.register(window, id: "history")

        let registered = coordinator.trackedWindowCounts
        #expect(registered.mapped == 1)
        #expect(registered.known == 1)
        #expect(registered.observed == 1)

        for _ in 0..<3 {
            center.post(name: NSWindow.willCloseNotification, object: window)
            try await Task.sleep(for: .milliseconds(60))
            let closed = coordinator.trackedWindowCounts
            #expect(closed.mapped == 0)
            #expect(closed.observed == 0)
            // 弱身份记录保留下来，第二次关闭才能认出“还是那扇窗”；但只保留一份。
            #expect(closed.known == 1)

            center.post(name: NSWindow.didBecomeKeyNotification, object: window)
            try await Task.sleep(for: .milliseconds(40))
            let reopened = coordinator.trackedWindowCounts
            #expect(reopened.mapped == 1)
            #expect(reopened.known == 1)
            #expect(reopened.observed == 1)
        }
    }
}

@MainActor
private func makeCoordinatorWindow() -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    // ARC 管理下的测试窗口：close() 时避免二次释放。
    window.isReleasedWhenClosed = false
    return window
}

@MainActor
private final class FocuserSpy: WindowFocusing {
    private(set) var focusedWindows: [ObjectIdentifier] = []

    func focus(_ window: NSWindow) {
        focusedWindows.append(ObjectIdentifier(window))
    }
}

@MainActor
private final class ActivationControllerSpy: ApplicationActivationControlling {
    var activationPolicy: NSApplication.ActivationPolicy
    var isActive = false
    var hasVisibleUserFacingWindow: Bool
    var hasKeyWindow = false
    private(set) var policyChanges: [NSApplication.ActivationPolicy] = []
    private(set) var deactivateCount = 0

    init(
        activationPolicy: NSApplication.ActivationPolicy,
        hasVisibleUserFacingWindow: Bool
    ) {
        self.activationPolicy = activationPolicy
        self.hasVisibleUserFacingWindow = hasVisibleUserFacingWindow
    }

    func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) -> Bool {
        activationPolicy = policy
        policyChanges.append(policy)
        return true
    }

    func requestActivation() {
        isActive = true
    }

    func deactivate() {
        isActive = false
        deactivateCount += 1
    }
}
