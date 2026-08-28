import AppKit
import SharedKit
import SwiftUI

@MainActor
enum AppWindowPresenter {
    private static let coordinator = WindowPresentationCoordinator.shared

    static func present(id: String, open: () -> Void) {
        coordinator.present(id: id, open: open)
    }

    static func register(_ window: NSWindow?, id: String) {
        coordinator.register(window, id: id)
    }
}

@MainActor
protocol ApplicationActivationControlling: AnyObject {
    var activationPolicy: NSApplication.ActivationPolicy { get }
    var isActive: Bool { get }
    var hasVisibleUserFacingWindow: Bool { get }

    func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) -> Bool
    func requestActivation()
}

@MainActor
final class SystemApplicationActivationController: ApplicationActivationControlling {
    var activationPolicy: NSApplication.ActivationPolicy {
        NSApplication.shared.activationPolicy()
    }

    var isActive: Bool {
        NSApplication.shared.isActive
    }

    var hasVisibleUserFacingWindow: Bool {
        NSApplication.shared.windows.contains { window in
            !(window is NSPanel)
                && window.styleMask.contains(.titled)
                && (window.isVisible || window.isMiniaturized)
        }
    }

    func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) -> Bool {
        NSApplication.shared.setActivationPolicy(policy)
    }

    func requestActivation() {
        if #available(macOS 14.0, *) {
            NSApplication.shared.activate()
        } else {
            NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
        }
    }
}

@MainActor
final class WindowPresentationCoordinator {
    static let shared = WindowPresentationCoordinator(
        activationController: SystemApplicationActivationController()
    )

    private final class WindowReference {
        weak var value: NSWindow?
        let token: ObjectIdentifier

        init(_ value: NSWindow) {
            self.value = value
            self.token = ObjectIdentifier(value)
        }
    }

    private struct WindowObservers {
        let didBecomeKey: NSObjectProtocol
        let willClose: NSObjectProtocol
    }

    private let activationController: ApplicationActivationControlling
    private let presentationTimeout: Duration
    #if DEBUG
    private let logger = Logger(category: "window-lifecycle", logLevel: .debug)
    #else
    private let logger = Logger(category: "window-lifecycle", logLevel: .info)
    #endif
    private var lifecycleState = WindowLifecycleState()
    private var windows: [String: WindowReference] = [:]
    private var observedWindows: [ObjectIdentifier: WindowObservers] = [:]
    private var timeoutTasks: [String: Task<Void, Never>] = [:]

    init(
        activationController: ApplicationActivationControlling,
        presentationTimeout: Duration = .seconds(3)
    ) {
        self.activationController = activationController
        self.presentationTimeout = presentationTimeout
    }

    func present(id: String, open: () -> Void) {
        purgeStaleWindows()
        logger.info(
            "present.request id=\(id) policy=\(activationController.activationPolicy.rawValue) "
                + "active=\(activationController.isActive) \(lifecycleSummary)"
        )

        if let window = registeredWindow(id: id),
           window.isVisible,
           window.isKeyWindow {
            logger.info("present.noop id=\(id) reason=already-key")
            return
        }

        let presentation = lifecycleState.beginPresentation(id: id)
        let policyChanged = ensureRegularPolicy()
        if !policyChanged {
            logger.warning("policy.regular.failed id=\(id)")
        }
        activationController.requestActivation()
        logger.info(
            "present.activate id=\(id) generation=\(presentation.generation) "
                + "new=\(presentation.isNew) policyReady=\(policyChanged)"
        )

        if let window = registeredWindow(id: id) {
            logger.info("present.front id=\(id) generation=\(presentation.generation) source=registered")
            bringToFront(window)
        } else if presentation.isNew {
            logger.info("present.open id=\(id) generation=\(presentation.generation)")
            open()
        } else {
            logger.info("present.wait id=\(id) generation=\(presentation.generation) reason=open-in-flight")
        }

        scheduleTimeoutIfNeeded(id: id, generation: presentation.generation)
    }

    func register(_ window: NSWindow?, id: String) {
        guard let window else {
            logger.info("window.register.defer id=\(id) reason=no-window")
            purgeStaleWindows()
            reevaluateActivationPolicy()
            return
        }

        let reference = WindowReference(window)
        if windows[id]?.token != reference.token {
            if let previousReference = windows[id] {
                removeObservers(token: previousReference.token)
                logger.debug("window.replace id=\(id)")
            }
            windows[id] = reference
            lifecycleState.registerWindow(id: id)
            logger.info("window.register id=\(id) \(lifecycleSummary)")
        }
        observeWindow(window, id: id, token: reference.token)

        if window.isKeyWindow {
            handleDidBecomeKey(id: id, token: reference.token)
        }

        if lifecycleState.isPresentationPending(id: id) {
            _ = ensureRegularPolicy()
            if !activationController.isActive {
                activationController.requestActivation()
                logger.info("window.activate id=\(id) source=registration")
            }
            logger.info("window.front id=\(id) source=registration")
            bringToFront(window)
        }
    }

    private func registeredWindow(id: String) -> NSWindow? {
        guard let reference = windows[id], let window = reference.value else {
            removeStaleWindow(id: id)
            return nil
        }
        return window
    }

    private func ensureRegularPolicy() -> Bool {
        if activationController.activationPolicy == .regular {
            return true
        }
        let result = activationController.setActivationPolicy(.regular)
        logger.info("policy.regular result=\(result)")
        return result
    }

    private func bringToFront(_ window: NSWindow) {
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func observeWindow(_ window: NSWindow, id: String, token: ObjectIdentifier) {
        guard observedWindows[token] == nil else { return }

        let didBecomeKey = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleDidBecomeKey(id: id, token: token)
            }
        }

        let willClose = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleWillClose(id: id, token: token)
            }
        }

        observedWindows[token] = WindowObservers(
            didBecomeKey: didBecomeKey,
            willClose: willClose
        )
    }

    private func handleDidBecomeKey(id: String, token: ObjectIdentifier) {
        guard windows[id]?.token == token else {
            logger.debug("window.key.ignored id=\(id) reason=stale")
            return
        }
        lifecycleState.completePresentation(id: id)
        cancelTimeout(id: id)
        logger.info("window.key id=\(id) \(lifecycleSummary)")
    }

    private func handleWillClose(id: String, token: ObjectIdentifier) {
        removeObservers(token: token)

        if windows[id]?.token == token {
            windows[id] = nil
            lifecycleState.unregisterWindow(id: id)
            lifecycleState.completePresentation(id: id)
            cancelTimeout(id: id)
            logger.info("window.close id=\(id) \(lifecycleSummary)")
        } else {
            logger.debug("window.close.ignored id=\(id) reason=stale")
        }

        Task { @MainActor [weak self] in
            await Task.yield()
            self?.purgeStaleWindows()
            self?.reevaluateActivationPolicy()
        }
    }

    private func scheduleTimeoutIfNeeded(id: String, generation: Int) {
        guard lifecycleState.isCurrentPresentation(id: id, generation: generation) else { return }
        guard timeoutTasks[id] == nil else { return }

        timeoutTasks[id] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: self?.presentationTimeout ?? .seconds(3))
            } catch {
                return
            }
            guard let self else { return }
            self.handlePresentationTimeout(id: id, generation: generation)
        }
    }

    private func handlePresentationTimeout(id: String, generation: Int) {
        guard lifecycleState.isCurrentPresentation(id: id, generation: generation) else {
            timeoutTasks[id] = nil
            return
        }

        lifecycleState.completePresentation(id: id, generation: generation)
        timeoutTasks[id] = nil
        logger.warning("present.timeout id=\(id) generation=\(generation) \(lifecycleSummary)")
        purgeStaleWindows()
        reevaluateActivationPolicy()
    }

    private func cancelTimeout(id: String) {
        timeoutTasks.removeValue(forKey: id)?.cancel()
    }

    private func purgeStaleWindows() {
        let staleIDs = windows.compactMap { id, reference in
            reference.value == nil ? id : nil
        }

        for id in staleIDs {
            removeStaleWindow(id: id)
        }
    }

    private func removeStaleWindow(id: String) {
        guard let reference = windows.removeValue(forKey: id) else { return }
        lifecycleState.unregisterWindow(id: id)
        removeObservers(token: reference.token)
        logger.info("window.remove-stale id=\(id) \(lifecycleSummary)")
    }

    private func removeObservers(token: ObjectIdentifier) {
        guard let observers = observedWindows.removeValue(forKey: token) else { return }
        NotificationCenter.default.removeObserver(observers.didBecomeKey)
        NotificationCenter.default.removeObserver(observers.willClose)
    }

    private func reevaluateActivationPolicy() {
        guard lifecycleState.shouldUseAccessoryPolicy else {
            logger.debug("policy.accessory.defer \(lifecycleSummary)")
            return
        }
        guard !activationController.hasVisibleUserFacingWindow else {
            logger.info("policy.accessory.defer reason=visible-window \(lifecycleSummary)")
            return
        }
        if activationController.activationPolicy != .accessory {
            let result = activationController.setActivationPolicy(.accessory)
            if result {
                logger.info("policy.accessory result=true")
            } else {
                logger.warning("policy.accessory result=false")
            }
        }
    }

    private var lifecycleSummary: String {
        let registered = lifecycleState.registeredWindowIDs.sorted().joined(separator: ",")
        let pending = lifecycleState.pendingPresentations
            .map { "\($0.key):\($0.value)" }
            .sorted()
            .joined(separator: ",")
        return "registered=[\(registered)] pending=[\(pending)]"
    }
}

struct AppWindowRegistrationView: NSViewRepresentable {
    let id: String

    func makeNSView(context: Context) -> AppWindowRegistrationNSView {
        AppWindowRegistrationNSView(id: id)
    }

    func updateNSView(_ view: AppWindowRegistrationNSView, context: Context) {
        view.registrationID = id
        view.registerWindow()
    }
}

final class AppWindowRegistrationNSView: NSView {
    var registrationID: String

    init(id: String) {
        self.registrationID = id
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        self.registrationID = ""
        super.init(coder: coder)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerWindow()
    }

    func registerWindow() {
        guard !registrationID.isEmpty else { return }
        AppWindowPresenter.register(window, id: registrationID)
    }
}
