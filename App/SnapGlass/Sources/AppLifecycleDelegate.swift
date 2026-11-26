import AppKit
import SharedKit

@MainActor
final class SnapGlassApplicationDelegate: NSObject, NSApplicationDelegate {
    enum EditorQuitChoice {
        case save
        case discard
        case cancel
    }

    weak var viewModel: CaptureViewModel?
    weak var updater: UpdaterManager?
    /// Onboarding state, used by reopen routing to decide what to surface.
    var onboarding: OnboardingRuntime?
    private var recordingQuitFlow = RecordingQuitFlow()
    private var isSavingEditorForQuit = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if AgentMode.isActive {
            AgentRuntime.start()
            return
        }
        #if DEBUG
            ShowcaseImageExporter.runIfConfigured()
        #endif
        // Warm the HUD path after launch so a first recording does not pay the
        // process's one-time SwiftUI/AppKit setup inside its first-visible window.
        // The prewarm is skipped if a recording is already preparing.
        RecordingHUDPrewarm.schedule { [weak self] in
            self?.viewModel?.isRecordingBusy != true
        }
    }

    /// Re-evaluates onboarding whenever the app comes back to the front.
    ///
    /// The tutorial's first step waits for screen-recording permission, and macOS
    /// posts no notification when the user flips that switch in System Settings. The
    /// user leaves, grants it, and returns — this is the only moment the app can
    /// notice. Evaluating is idempotent, so the extra calls cost nothing.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard !AgentMode.isActive, let onboarding else { return }
        Task { @MainActor in
            await onboarding.applicationDidBecomeActive()
        }
    }

    /// Re-opens something when the app is launched again from Finder or Spotlight.
    ///
    /// This is a menu-bar-only app (`LSUIElement`), so a second launch activates the
    /// running copy instead of opening a window. Returning `false` here is what made
    /// a double-click look like nothing happened: the app was already running, no
    /// window opened, and the only on-screen change was an 18pt icon the user had no
    /// reason to look for.
    ///
    /// Every branch below surfaces something. Nothing is silent except the agent
    /// channel, which owns its own lifecycle.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if AgentMode.isActive { return false }

        // 1. A recording is running and its controls were dismissed: bring them back.
        //    This is the one case where the user has work in flight.
        if let viewModel, viewModel.restoreRecordingControlOnReopen() {
            NSApp.activate(ignoringOtherApps: true)
            return true
        }

        NSApp.activate(ignoringOtherApps: true)

        // 2. Onboarding never finished: the user still needs to be told where the app
        //    lives, so reopen the guide rather than a settings tab.
        if let onboarding, onboarding.isFirstRun {
            onboarding.showGuideOnUserRequest()
            return true
        }

        // 3. A window is already visible: bring it forward and stop. Opening settings
        //    on top of the user's editor would be an unrequested window.
        if flag || NSApp.windows.contains(where: { $0.isVisible && !($0 is NSPanel) }) {
            NSApp.keyWindow?.makeKeyAndOrderFront(nil)
            return true
        }

        // 4. No window and the user chose to hide the Dock icon: nothing on screen
        //    explains where the app is, so show the guide's location page.
        if let onboarding, Self.dockIconModeIsHidden() {
            onboarding.showGuideOnUserRequest()
            return true
        }

        // 5. Default: open Settings, which is the window a menu-bar app normally has.
        viewModel?.openWindow?("preferences")
        return true
    }

    /// Whether the user picked the Dock icon mode that hides the app entirely.
    private static func dockIconModeIsHidden() -> Bool {
        let raw = UserDefaults.standard.string(forKey: PreferenceKeys.dockIconMode) ?? ""
        return DockIconMode(rawValue: raw) == .never
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The agent channel owns its lifecycle: it flushes its report, then quits.
        if AgentMode.isActive { return .terminateNow }
        // Sparkle already waited for unsaved edits and recordings to clear
        // before invoking its install handler. Prompting again would stall the
        // relaunch behind a modal the user cannot see.
        if updater?.isInstallingUpdate == true {
            return .terminateNow
        }
        guard let viewModel else { return .terminateNow }
        // A second ⌘Q while the save runs must not start another termination pass.
        guard !isSavingEditorForQuit else {
            viewModel.showToast(message: AppLocalization.string("Processing…"), type: .info)
            return .terminateCancel
        }

        // The close-confirmation sheet already asks about these tabs.
        if viewModel.editorWorkspace.showsCloseConfirmation {
            return .terminateCancel
        }

        if viewModel.editorWorkspace.hasAnyUnsavedChanges {
            switch promptForUnsavedAnnotations() {
            case .cancel:
                return .terminateCancel
            case .discard:
                break
            case .save:
                return saveAnnotationsThenQuit(sender: sender, viewModel: viewModel)
            }
        }

        return continueTermination(sender: sender, viewModel: viewModel)
    }

    private func promptForUnsavedAnnotations() -> EditorQuitChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = AppLocalization.string("You have unsaved annotations.")
        alert.informativeText = AppLocalization.string(
            "Save them to history before quitting? Unsaved annotations will be lost."
        )
        alert.addButton(withTitle: AppLocalization.string("Save All and Quit"))
        alert.addButton(withTitle: AppLocalization.string("Cancel"))
        alert.addButton(withTitle: AppLocalization.string("Discard and Quit"))
        // NSAlert only maps Escape to a button literally titled "Cancel"; localized titles need this.
        alert.buttons[1].keyEquivalent = "\u{1b}"

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .save
        case .alertThirdButtonReturn:
            return .discard
        default:
            return .cancel
        }
    }

    private func saveAnnotationsThenQuit(
        sender: NSApplication,
        viewModel: CaptureViewModel
    ) -> NSApplication.TerminateReply {
        isSavingEditorForQuit = true
        Task { @MainActor [weak self] in
            let saved = await viewModel.editorWorkspace.saveAllDirtyToHistory()
            guard let self else {
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            self.isSavingEditorForQuit = false
            guard saved else {
                viewModel.showToast(
                    message: AppLocalization.string("Annotations are not saved; quit cancelled"),
                    type: .error
                )
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            let reply = self.continueTermination(sender: sender, viewModel: viewModel)
            if reply != .terminateLater {
                sender.reply(toApplicationShouldTerminate: reply == .terminateNow)
            }
        }
        return .terminateLater
    }

    private func continueTermination(
        sender: NSApplication,
        viewModel: CaptureViewModel
    ) -> NSApplication.TerminateReply {
        let request = recordingQuitFlow.request(
            needsConfirmation: viewModel.needsRecordingQuitConfirmation,
            isSaving: viewModel.isRecordingSaving
        )

        switch request {
        case .terminateNow:
            return .terminateNow
        case .terminateCancel:
            return .terminateCancel
        case .confirm:
            let isAudio = viewModel.currentRecordingKind == .audio
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = AppLocalization.string(
                isAudio ? "An audio recording is in progress." : "A screen recording is in progress."
            )
            alert.informativeText = AppLocalization.string(
                isAudio
                    ? "Stop and save the audio recording before quitting?"
                    : "Stop and save the recording before quitting?"
            )
            alert.addButton(withTitle: AppLocalization.string("Stop and Save, then Quit"))
            alert.addButton(withTitle: AppLocalization.string("Cancel"))
            // Same Escape mapping as the annotation alert above.
            alert.buttons[1].keyEquivalent = "\u{1b}"

            guard alert.runModal() == .alertFirstButtonReturn else {
                recordingQuitFlow.cancel()
                return .terminateCancel
            }
        case .waitForRecording:
            viewModel.showToast(
                message: AppLocalization.string("Saving recording before quitting"),
                type: .info
            )
        }

        Task { @MainActor [weak self] in
            guard let self else {
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            let outcome = await viewModel.stopRecordingAndResolveQuit(
                reason: AppLocalization.string("Quit requested")
            )
            let shouldTerminate = self.recordingQuitFlow.complete(with: outcome)
            sender.reply(toApplicationShouldTerminate: shouldTerminate)
        }
        return .terminateLater
    }
}
