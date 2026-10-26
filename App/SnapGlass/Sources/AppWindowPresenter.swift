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

    /// The window currently registered for `id`, if it is still alive.
    static func window(id: String) -> NSWindow? {
        coordinator.registeredWindow(id: id)
    }
}

@MainActor
protocol ApplicationActivationControlling: AnyObject {
    var activationPolicy: NSApplication.ActivationPolicy { get }
    var isActive: Bool { get }
    var hasVisibleUserFacingWindow: Bool { get }
    /// Whether any window currently holds the keyboard key slot. Late focus repairs consult
    /// this so they never steal focus from a window the user has already started using.
    var hasKeyWindow: Bool { get }

    func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) -> Bool
    func requestActivation()
    func deactivate()
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

    var hasKeyWindow: Bool {
        NSApplication.shared.keyWindow != nil
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

    func deactivate() {
        NSApplication.shared.deactivate()
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
