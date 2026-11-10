import AppKit

@MainActor
final class SnapGlassApplicationDelegate: NSObject, NSApplicationDelegate {
    enum EditorQuitChoice {
        case save
        case discard
        case cancel
    }

    weak var viewModel: CaptureViewModel?
    private var recordingQuitFlow = RecordingQuitFlow()
    private var isSavingEditorForQuit = false

    func applicationDidFinishLaunching(_ notification: Notification) {
#if DEBUG
        ShowcaseImageExporter.runIfConfigured()
#endif
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
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
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = AppLocalization.string("A screen recording is in progress.")
            alert.informativeText = AppLocalization.string("Stop and save the recording before quitting?")
            alert.addButton(withTitle: AppLocalization.string("Stop and Save, then Quit"))
            alert.addButton(withTitle: AppLocalization.string("Cancel"))
            // Same Escape mapping as the annotation alert above.
            alert.buttons[1].keyEquivalent = "\u{1b}"

            guard alert.runModal() == .alertFirstButtonReturn else {
                recordingQuitFlow.cancel()
                return .terminateCancel
            }
        case .waitForRecording:
            break
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
