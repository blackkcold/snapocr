import AppKit
import SwiftUI

/// Blocks the editor window from closing while the document has unsaved
/// annotations, covering the red traffic light and ⌘W as well as the Cancel
/// button.
///
/// SwiftUI owns the window delegate, so this installs a forwarding proxy instead
/// of replacing it: every delegate message it does not handle goes back to the
/// original delegate.
struct EditorWindowCloseGuard: NSViewRepresentable {
    let isDirty: () -> Bool
    let onBlocked: () -> Void

    func makeNSView(context: Context) -> GuardView {
        GuardView(isDirty: isDirty, onBlocked: onBlocked)
    }

    func updateNSView(_ view: GuardView, context: Context) {
        view.isDirty = isDirty
        view.onBlocked = onBlocked
        // SwiftUI may replace the window delegate; re-install if that happened.
        view.installIfNeeded()
    }

    final class GuardView: NSView {
        var isDirty: () -> Bool
        var onBlocked: () -> Void
        private var proxy: WindowDelegateProxy?

        init(isDirty: @escaping () -> Bool, onBlocked: @escaping () -> Void) {
            self.isDirty = isDirty
            self.onBlocked = onBlocked
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else {
                // The window is gone: drop the proxy from the static registry,
                // otherwise every editor window leaks one object for the
                // lifetime of the process.
                if let proxy {
                    WindowDelegateProxy.release(proxy)
                    self.proxy = nil
                }
                return
            }
            installIfNeeded()
        }

        /// Installs the delegate proxy if this window does not have one yet, and
        /// points it at the current guard view otherwise.
        func installIfNeeded() {
            guard let window else { return }
            if let existing = window.delegate as? WindowDelegateProxy {
                existing.owner = self
                proxy = existing
                return
            }
            let proxy = WindowDelegateProxy(owner: self)
            proxy.originalDelegate = window.delegate
            window.delegate = proxy
            WindowDelegateProxy.retain(proxy)
            self.proxy = proxy
        }
    }

    /// Forwards every `NSWindowDelegate` message it does not implement back to
    /// the delegate SwiftUI installed, and vetoes `windowShouldClose` while the
    /// document is dirty.
    @MainActor
    final class WindowDelegateProxy: NSObject, NSWindowDelegate {
        private static var registry: [ObjectIdentifier: WindowDelegateProxy] = [:]

        static func retain(_ proxy: WindowDelegateProxy) {
            registry[ObjectIdentifier(proxy)] = proxy
        }

        static func release(_ proxy: WindowDelegateProxy) {
            registry.removeValue(forKey: ObjectIdentifier(proxy))
        }

        func windowWillClose(_ notification: Notification) {
            WindowDelegateProxy.release(self)
            originalDelegate?.windowWillClose?(notification)
        }

        weak var owner: GuardView?
        /// Read from `responds(to:)`/`forwardingTarget(for:)`, which ObjC calls
        /// off the main actor; the delegate is only ever touched on the main
        /// thread in practice.
        nonisolated(unsafe) weak var originalDelegate: NSWindowDelegate?

        init(owner: GuardView) {
            self.owner = owner
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if let owner, owner.isDirty() {
                owner.onBlocked()
                return false
            }
            return originalDelegate?.windowShouldClose?(sender) ?? true
        }

        override func responds(to selector: Selector) -> Bool {
            if super.responds(to: selector) { return true }
            return originalDelegate?.responds(to: selector) ?? false
        }

        override func forwardingTarget(for selector: Selector) -> Any? {
            if originalDelegate?.responds(to: selector) == true {
                return originalDelegate
            }
            return super.forwardingTarget(for: selector)
        }
    }
}
