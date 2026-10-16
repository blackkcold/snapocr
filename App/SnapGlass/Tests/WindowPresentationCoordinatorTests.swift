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
            presentationTimeout: .milliseconds(10)
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
            presentationTimeout: .milliseconds(10)
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
            presentationTimeout: .milliseconds(10)
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
            presentationTimeout: .milliseconds(10)
        )

        coordinator.present(id: "editor") {}
        try await Task.sleep(for: .milliseconds(50))
        activationController.hasVisibleUserFacingWindow = false
        coordinator.register(nil, id: "editor")

        #expect(activationController.policyChanges == [.regular, .accessory])
        #expect(activationController.activationPolicy == .accessory)
    }

    @Test("An open window without a registered window is opened once")
    func noWindowOpensOnce() {
        let activation = ActivationControllerSpy(activationPolicy: .regular, hasVisibleUserFacingWindow: true)
        let focuser = FocuserSpy()
        let coordinator = WindowPresentationCoordinator(
            activationController: activation,
            presentationTimeout: .milliseconds(10),
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
            focuser: focuser
        )
        let window = makeCoordinatorWindow()
        coordinator.register(window, id: "history")
        var openCount = 0

        coordinator.present(id: "history") { openCount += 1 }

        #expect(openCount == 1)
        #expect(focuser.focusedWindows.isEmpty)
    }
}

@MainActor
private func makeCoordinatorWindow() -> NSWindow {
    NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
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
