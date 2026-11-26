import AppKit
import CaptureCore
import SharedKit
import SwiftUI

/// Shows the menu-bar coach and decides which form it takes.
///
/// Three constraints shape this type:
///
/// - The panel must not appear while a capture is running. The area-selection
///   overlay sits at `.screenSaver` level, so a coach shown then is invisible while
///   still counting as shown — permanently lost.
/// - It must not appear in the same frame the guide closes, or it competes with the
///   window teardown for the key slot and lands off-screen.
/// - When the screen has no room, it degrades instead of disappearing. A first-run
///   user who sees nothing has no way to learn the app is running.
@MainActor
final class MenuBarCoachPresenter {
    /// Delay between the guide closing and the coach appearing.
    static let presentationDelay: Duration = .milliseconds(250)
    /// Delay before retrying while a capture is still running.
    static let busyRetryDelay: Duration = .milliseconds(800)

    private var panel: MenuBarCoachPanel?
    private var pendingTask: Task<Void, Never>?
    /// Set when the coach was wanted but the app was busy.
    private var isPending = false

    /// Installed by the app to report capture state.
    var isCapturing: () -> Bool = { false }
    /// Called when the coach has actually been shown, so the flag is only written
    /// for a real presentation.
    var onShown: () -> Void = {}
    /// Invoked by the tutorial variant's button.
    var onTryIt: () -> Void = {}

    /// Requests the coach after the usual delay.
    ///
    /// - Parameter content: What the coach should say.
    func schedule(_ content: MenuBarCoachContent = .location) {
        pendingTask?.cancel()
        pendingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.presentationDelay)
            guard !Task.isCancelled else { return }
            self?.presentWhenIdle(content)
        }
    }

    /// Presents the coach immediately, because the user asked for it.
    ///
    /// Re-summoning never writes the shown flag: "Where is SnapGlass?" must work any
    /// number of times.
    func presentOnUserRequest() {
        pendingTask?.cancel()
        show(.location, recordsShown: false)
    }

    /// Consumes a request that could not be shown earlier.
    ///
    /// Called when the capture finishes.
    func flushIfPending() {
        guard isPending else { return }
        isPending = false
        schedule()
    }

    /// Dismisses the coach if it is on screen.
    func dismiss() {
        pendingTask?.cancel()
        pendingTask = nil
        panel?.dismiss()
        panel = nil
    }

    private func presentWhenIdle(_ content: MenuBarCoachContent) {
        if isCapturing() {
            // Keep the intent and try again after the capture; showing now would put
            // the panel under the selection overlay and burn the flag.
            isPending = true
            pendingTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.busyRetryDelay)
                guard !Task.isCancelled else { return }
                self?.flushIfPending()
            }
            return
        }
        show(content, recordsShown: true)
    }

    private func show(_ content: MenuBarCoachContent, recordsShown: Bool) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        let layout = Self.resolveLayout(on: screen)
        if layout == .announcement {
            // L3: no room for any panel. Announce through VoiceOver so the
            // information still reaches someone, and leave the flag unwritten so a
            // larger display gets the panel next time.
            announce()
            return
        }

        dismiss()
        let panel = MenuBarCoachPanel(
            content: content,
            layout: layout,
            onTryIt: { [weak self] in
                self?.dismiss()
                self?.onTryIt()
            },
            onOpenControlCenter: {
                guard
                    let url = URL(
                        string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension"
                    )
                else { return }
                NSWorkspace.shared.open(url)
            },
            onDismiss: { [weak self] in self?.panel = nil }
        )
        self.panel = panel
        panel.present(on: screen, layout: layout)
        if recordsShown {
            onShown()
        }
    }

    /// Chooses the coach form for a screen.
    ///
    /// - Parameter screen: The display that will host the panel.
    /// - Returns: The strongest form whose minimum area fits.
    static func resolveLayout(on screen: NSScreen) -> CoachLayout {
        let visible = ScreenshotShelfGeometry.effectiveVisibleFrame(
            visibleFrame: screen.visibleFrame,
            screenFrame: screen.frame
        )
        return CoachLayoutResolver.resolve(width: visible.width, height: visible.height)
    }

    private func announce() {
        // VoiceOver announcements travel through the application element with the
        // text in `userInfo`; there is no element to create for a transient message.
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: AppLocalization.string("SnapGlass is in the menu bar, top right."),
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }
}
