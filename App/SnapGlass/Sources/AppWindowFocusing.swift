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
    func focus(_ window: NSWindow)
}

/// Default `WindowFocusing` implementation driven by `NSApplication.didBecomeActiveNotification`.
///
/// Subscribes to `didBecomeActive` **before** requesting activation, so the window is ordered
/// front only after the process is genuinely active — never in the same tick as the request.
/// This removes the race that made the second open lose focus (the first open happened to be
/// delayed by SwiftUI window creation, which hid the race).
@MainActor
final class SystemWindowFocuser: WindowFocusing {
    /// Performs the actual window ordering. `regardless` adds `orderFrontRegardless` so the
    /// window is at least visible even when the app could not become active (fallback only).
    typealias FrontAction = @MainActor (NSWindow, Bool) -> Void

    private let activation: ApplicationActivationControlling
    private let notificationCenter: NotificationCenter
    private let waitTimeout: Duration
    private let frontAction: FrontAction

    private var activationObserver: NSObjectProtocol?
    private var timeoutTask: Task<Void, Never>?
    private weak var pendingWindow: NSWindow?

    init(
        activation: ApplicationActivationControlling,
        notificationCenter: NotificationCenter = .default,
        waitTimeout: Duration = .milliseconds(500),
        frontAction: @escaping FrontAction = SystemWindowFocuser.performFront
    ) {
        self.activation = activation
        self.notificationCenter = notificationCenter
        self.waitTimeout = waitTimeout
        self.frontAction = frontAction
    }

    func focus(_ window: NSWindow) {
        cancelWaiter()

        if activation.isActive {
            frontAction(window, false)
            return
        }

        pendingWindow = window
        observeActivation()
        activation.requestActivation()

        if activation.isActive {
            didActivate()
            return
        }

        timeoutTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: self.waitTimeout)
            } catch {
                return
            }
            self.didTimeout()
        }
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

    private func observeActivation() {
        guard activationObserver == nil else { return }
        activationObserver = notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.didActivate()
            }
        }
    }

    private func didActivate() {
        guard let window = pendingWindow else {
            cancelWaiter()
            return
        }
        cancelWaiter()
        frontAction(window, false)
    }

    private func didTimeout() {
        guard let window = pendingWindow else { return }
        cancelWaiter()
        frontAction(window, true)
    }

    private func cancelWaiter() {
        if let activationObserver {
            notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        timeoutTask?.cancel()
        timeoutTask = nil
        pendingWindow = nil
    }
}
