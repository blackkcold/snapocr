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
        // Wait for the timeout itself instead of outwaiting it: the assertions below
        // only mean something once the timeout is known to have run.
        let timedOut = await waitForCoordinatorCondition { coordinator.pendingPresentationCount == 0 }
        #expect(timedOut)

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
        let downgraded = await waitForCoordinatorCondition {
            activationController.deactivateCount == 1
        }
        #expect(downgraded)

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
        let downgraded = await waitForCoordinatorCondition { activationController.deactivateCount == 1 }
        #expect(downgraded)

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
        // The first timeout has to run while the window still counts as visible, or
        // the deferred path this test covers is never entered.
        let timedOut = await waitForCoordinatorCondition { coordinator.pendingPresentationCount == 0 }
        #expect(timedOut)

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
        // The close must be handled while the window still reports itself visible,
        // or the bounded retry this test covers is never entered.
        let waiting = await waitForCoordinatorCondition { coordinator.reevaluateWaitCount >= 1 }
        #expect(waiting)
        activationController.hasVisibleUserFacingWindow = false
        let downgraded = await waitForCoordinatorCondition {
            activationController.activationPolicy == .accessory
        }
        #expect(downgraded)

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
        // The rescue focus happens inside the timeout, so wait for the timeout
        // rather than for a duration that is supposed to cover it.
        let rescued = await waitForCoordinatorCondition { focuser.focusedWindows.count == 2 }
        #expect(rescued)

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
        // The rescue only exists inside the timeout, so wait for the timeout to have
        // run before asserting that it skipped focusing.
        let timedOut = await waitForCoordinatorCondition { coordinator.pendingPresentationCount == 0 }
        #expect(timedOut)

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
        let closed = await waitForCoordinatorCondition { coordinator.trackedWindowCounts.mapped == 0 }
        #expect(closed)
        #expect(activation.policyChanges.isEmpty)

        // SwiftUI 复用同一 NSWindow 重开，且不再调用 register()。
        window.orderFront(nil)
        coordinator.present(id: "history") {}
        let presented = await waitForCoordinatorCondition { coordinator.pendingPresentationCount == 0 }
        #expect(presented)
        #expect(activation.policyChanges.isEmpty)

        for round in 1...2 {
            // 关闭完成：全程不再 register()，只靠协调器级关闭监听。
            activation.hasVisibleUserFacingWindow = false
            center.post(name: NSWindow.willCloseNotification, object: window)
            let downgraded = await waitForCoordinatorCondition {
                activation.deactivateCount == round
            }
            #expect(downgraded)
            #expect(activation.activationPolicy == .accessory)
            #expect(activation.deactivateCount == round)

            // 重开：只靠成为 key 恢复映射（SwiftUI 同样不会再次注册）。
            activation.hasVisibleUserFacingWindow = true
            window.orderFront(nil)
            center.post(name: NSWindow.didBecomeKeyNotification, object: window)
            let restored = await waitForCoordinatorCondition {
                activation.activationPolicy == .regular
            }
            #expect(restored)
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
        // The close is handled in a task, so wait for it instead of outwaiting it.
        let closeHandled = await waitForCoordinatorCondition {
            coordinator.handledApplicationNotificationCount >= 1
        }
        #expect(closeHandled)

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
        let firstCloseHandled = await waitForCoordinatorCondition {
            coordinator.handledApplicationNotificationCount >= 1
        }
        #expect(firstCloseHandled)
        #expect(activation.policyChanges.isEmpty)
        #expect(activation.activationPolicy == .regular)

        activation.hasVisibleUserFacingWindow = false
        center.post(name: NSWindow.willCloseNotification, object: history)
        let downgraded = await waitForCoordinatorCondition {
            activation.activationPolicy == .accessory
        }
        #expect(downgraded)

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
        // The close must be handled while the window still reports itself visible,
        // or the bounded retry this test covers is never entered.
        let waiting = await waitForCoordinatorCondition { coordinator.reevaluateWaitCount >= 1 }
        #expect(waiting)
        #expect(activation.policyChanges.isEmpty)

        // 之后不触发任何调用：降级只能来自重算任务自身的有界等待。
        activation.hasVisibleUserFacingWindow = false
        let downgraded = await waitForCoordinatorCondition {
            activation.activationPolicy == .accessory
        }
        #expect(downgraded)

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
        // "Exactly once" only holds once every posted notification has been handled
        // and no queued work is left that could still downgrade a second time.
        let settled = await waitForCoordinatorCondition {
            coordinator.handledApplicationNotificationCount >= 4 && !coordinator.hasPendingWork
        }
        #expect(settled)

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

        for round in 0..<3 {
            center.post(name: NSWindow.willCloseNotification, object: window)
            // Each post is handled in a task; wait for it and for the bounded
            // reevaluate it schedules, instead of sleeping a guessed duration.
            let closedInTime = await waitForCoordinatorCondition {
                coordinator.handledApplicationNotificationCount >= round * 2 + 1
                    && !coordinator.hasPendingWork
                    && coordinator.trackedWindowCounts.mapped == 0
            }
            #expect(closedInTime)
            let closed = coordinator.trackedWindowCounts
            #expect(closed.mapped == 0)
            #expect(closed.observed == 0)
            // 弱身份记录保留下来，第二次关闭才能认出“还是那扇窗”；但只保留一份。
            #expect(closed.known == 1)

            center.post(name: NSWindow.didBecomeKeyNotification, object: window)
            let reopenedInTime = await waitForCoordinatorCondition {
                coordinator.handledApplicationNotificationCount >= round * 2 + 2
                    && coordinator.trackedWindowCounts.mapped == 1
            }
            #expect(reopenedInTime)
            let reopened = coordinator.trackedWindowCounts
            #expect(reopened.mapped == 1)
            #expect(reopened.known == 1)
            #expect(reopened.observed == 1)
        }
    }
}

/// Waits until a fact the coordinator reaches asynchronously becomes true.
///
/// The suite used to sleep a few milliseconds longer than the presentation
/// timeout and then assert. That ties the assertion to the main actor being
/// scheduled inside a 5× margin, which a loaded runner can miss: the timeout task
/// then never runs before the sleep ends and the test reports a missing downgrade
/// that the product would have performed. Polling for the observable removes the
/// margin without weakening what is asserted.
///
/// - Parameters:
///   - timeout: How long the condition may take before it counts as never true.
///   - condition: The fact to observe; read on the main actor, so it may touch
///     the spies directly.
/// - Returns: Whether the condition became true within the timeout.
@MainActor
private func waitForCoordinatorCondition(
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
