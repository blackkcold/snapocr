import AppKit
import SwiftUI

@MainActor
enum AppWindowPresenter {
    static func present(id: String, open: () -> Void) {
        if AppWindowRegistry.shared.bringToFront(id: id) {
            return
        }

        open()
        Task { @MainActor in
            for delay in [50, 150, 350] {
                try? await Task.sleep(for: .milliseconds(delay))
                if AppWindowRegistry.shared.bringToFront(id: id) {
                    return
                }
            }
        }
    }
}

@MainActor
private final class AppWindowRegistry {
    static let shared = AppWindowRegistry()

    private final class WeakWindow {
        weak var value: NSWindow?

        init(_ value: NSWindow?) {
            self.value = value
        }
    }

    private var windows: [String: WeakWindow] = [:]

    func register(_ window: NSWindow?, id: String) {
        if let window {
            windows[id] = WeakWindow(window)
        } else if windows[id]?.value == nil {
            windows[id] = nil
        }
    }

    @discardableResult
    func bringToFront(id: String) -> Bool {
        guard let window = windows[id]?.value else {
            windows[id] = nil
            return false
        }

        NSApplication.shared.setActivationPolicy(.accessory)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApplication.shared.activate(ignoringOtherApps: true)
        return true
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
        AppWindowRegistry.shared.register(window, id: registrationID)
    }
}
