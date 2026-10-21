import AppKit

/// Brings a window to the front and makes it key, coordinating with application activation.
///
/// Implementations must not assume the process is already active: macOS 14+ treats
/// `NSApplication.activate()` as a *request* that the system applies asynchronously and may
/// refuse, so ordering the window front in the same runloop tick as the request is unreliable.
@MainActor
protocol WindowFocusing: AnyObject {
    /// Requests application activation, then brings `window` to the front and makes it key
    /// once the app is actually active. If activation is not granted within the wait timeout,
    /// falls back to ordering the window front so it is at least visible.
    ///
    /// Requests for different windows do not cancel one another: every requested window is
    /// ordered front in request order once the app is active, so the most recent request ends
    /// up with the keyboard focus.
    func focus(_ window: NSWindow)
}

/// Activation stage of a `SystemWindowFocuser` waiter.
private enum WaiterStage {
    /// Still inside the activation wait; orders front normally on activation.
    case awaitingActivation
    /// The activation wait timed out and the window was forced front for visibility.
    /// Only repaired (made key) when activation arrives within the grace period.
    case awaitingLateActivation
}

/// Default `WindowFocusing` implementation driven by `NSApplication.didBecomeActiveNotification`.
///
/// Subscribes to `didBecomeActive` **before** requesting activation, so windows are ordered
/// front only after the process is genuinely active — never in the same tick as the request.
/// This removes the race that made the second open lose focus (the first open happened to be
/// delayed by SwiftUI window creation, which hid the race).
///
/// Every requested window keeps its own waiter, so one request no longer discards another
/// pending one. A waiter whose activation wait times out falls back to `orderFrontRegardless`
/// (visible, possibly not key) and stays armed for a bounded grace period: if the late
/// `didBecomeActive` arrives while no window has claimed the key slot, the window gets one
/// more normal front so it can become key. The grace period then expires silently, so stale
/// waiters cannot steal focus from windows the user starts using later.
@MainActor
final class SystemWindowFocuser: WindowFocusing {
    /// Performs the actual window ordering. `regardless` adds `orderFrontRegardless` so the
    /// window is at least visible even when the app could not become active (fallback only).
    typealias FrontAction = @MainActor (NSWindow, Bool) -> Void

    /// One requested window waiting for the app to become active.
    private struct Waiter {
        weak var window: NSWindow?
        let token: ObjectIdentifier
        var stage: WaiterStage
        var timeoutTask: Task<Void, Never>?
    }

    private let activation: ApplicationActivationControlling
    private let notificationCenter: NotificationCenter
    private let waitTimeout: Duration
    private let graceTimeout: Duration
    private let frontAction: FrontAction

    private var activationObserver: NSObjectProtocol?
    /// One waiter per requested window, in request order. The most recent request is ordered
    /// front last, so it ends up key.
    private var waiters: [Waiter] = []

    init(
        activation: ApplicationActivationControlling,
        notificationCenter: NotificationCenter = .default,
        waitTimeout: Duration = .milliseconds(500),
        graceTimeout: Duration = .milliseconds(1500),
        frontAction: @escaping FrontAction = SystemWindowFocuser.performFront
    ) {
        self.activation = activation
        self.notificationCenter = notificationCenter
        self.waitTimeout = waitTimeout
        self.graceTimeout = graceTimeout
        self.frontAction = frontAction
    }

    func focus(_ window: NSWindow) {
        let token = ObjectIdentifier(window)
        // 同窗重复请求只刷新自身的等待，不影响其他窗口的等待。
        removeWaiter(token: token)

        if activation.isActive {
            resolveWaiters()
            frontAction(window, false)
            return
        }

        observeActivationIfNeeded()
        waiters.append(Waiter(window: window, token: token, stage: .awaitingActivation, timeoutTask: nil))
        activation.requestActivation()

        if activation.isActive {
            resolveWaiters()
            return
        }

        armActivationTimeout(for: token)
    }

    /// Orders `window` front. Deminiaturizes first so a minimized window is restored.
    static func performFront(_ window: NSWindow, regardless: Bool) {
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        if regardless {
            window.orderFrontRegardless()
        }
    }

    private func observeActivationIfNeeded() {
        guard activationObserver == nil else { return }
        activationObserver = notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.resolveWaiters()
            }
        }
    }

    private func removeObserverIfIdle() {
        guard waiters.isEmpty, let observer = activationObserver else { return }
        notificationCenter.removeObserver(observer)
        activationObserver = nil
    }

    /// Orders every requested window front now that the app is active, in request order.
    ///
    /// Waiters still inside their activation wait are fronted unconditionally. Waiters whose
    /// wait already timed out (window forced visible) are repaired only when the key slot is
    /// still free — otherwise the late repair would steal focus from the window the user has
    /// just started using, or from a fresher request that claimed the key first.
    private func resolveWaiters() {
        guard !waiters.isEmpty else { return }

        let resolved = waiters
        waiters.removeAll()
        removeObserverIfIdle()

        let hasKeyWindow = activation.hasKeyWindow
        for waiter in resolved {
            waiter.timeoutTask?.cancel()
            guard let window = waiter.window else { continue }
            switch waiter.stage {
            case .awaitingActivation:
                frontAction(window, false)
            case .awaitingLateActivation:
                if window.isVisible && !hasKeyWindow {
                    frontAction(window, false)
                }
            }
        }
    }

    private func armActivationTimeout(for token: ObjectIdentifier) {
        let delay = waitTimeout
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.activationTimeoutFired(for: token)
        }
        store(task, for: token)
    }

    private func armGraceTimeout(for token: ObjectIdentifier) {
        let delay = graceTimeout
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.removeWaiter(token: token)
        }
        store(task, for: token)
    }

    private func store(_ task: Task<Void, Never>, for token: ObjectIdentifier) {
        guard let index = waiters.firstIndex(where: { $0.token == token }) else {
            task.cancel()
            return
        }
        waiters[index].timeoutTask?.cancel()
        waiters[index].timeoutTask = task
    }

    private func activationTimeoutFired(for token: ObjectIdentifier) {
        guard let index = waiters.firstIndex(where: { $0.token == token }) else { return }
        guard let window = waiters[index].window else {
            dropWaiter(at: index)
            return
        }
        waiters[index].stage = .awaitingLateActivation
        waiters[index].timeoutTask = nil
        frontAction(window, true)
        armGraceTimeout(for: token)
    }

    private func removeWaiter(token: ObjectIdentifier) {
        if let index = waiters.firstIndex(where: { $0.token == token }) {
            waiters[index].timeoutTask?.cancel()
            waiters.remove(at: index)
        }
        removeObserverIfIdle()
    }

    private func dropWaiter(at index: Int) {
        waiters[index].timeoutTask?.cancel()
        waiters.remove(at: index)
        removeObserverIfIdle()
    }
}
