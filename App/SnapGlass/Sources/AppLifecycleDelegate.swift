import AppKit

@MainActor
final class SnapGlassApplicationDelegate: NSObject, NSApplicationDelegate {
    enum EditorQuitChoice {
        case save
        case discard
        case cancel
    }

    weak var viewModel: CaptureViewModel?
    weak var updater: UpdaterManager?
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

    /// Re-opens the recording controls when the app is launched again from Finder or Spotlight.
    ///
    /// This is a menu-bar-only app (`LSUIElement`), so a second launch activates the
    /// running copy instead of opening a window. Without this, a hidden or dismissed
    /// recording panel would be unreachable while capture is still running.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if AgentMode.isActive { return false }
        guard let viewModel, viewModel.restoreRecordingControlOnReopen() else {
            return false
        }
        NSApp.activate(ignoringOtherApps: true)
        return true
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
