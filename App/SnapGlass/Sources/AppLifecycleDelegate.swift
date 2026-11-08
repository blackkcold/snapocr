import AppKit

@MainActor
final class SnapGlassApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var viewModel: CaptureViewModel?
    private var isWaitingForRecordingToFinish = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let viewModel, viewModel.needsRecordingQuitConfirmation else { return .terminateNow }
        guard !isWaitingForRecordingToFinish else { return .terminateCancel }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = AppLocalization.string("A screen recording is in progress.")
        alert.informativeText = AppLocalization.string("Stop and save the recording before quitting?")
        alert.addButton(withTitle: AppLocalization.string("Stop and Save, then Quit"))
        alert.addButton(withTitle: AppLocalization.string("Cancel"))

        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }

        isWaitingForRecordingToFinish = true
        Task { @MainActor [weak self] in
            guard let self, let viewModel = self.viewModel else {
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            let didSave = await viewModel.stopRecordingAndSave(
                reason: AppLocalization.string("Quit requested")
            )
            self.isWaitingForRecordingToFinish = false
            sender.reply(toApplicationShouldTerminate: didSave)
        }
        return .terminateLater
    }
}
