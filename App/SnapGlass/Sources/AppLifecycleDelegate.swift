import AppKit

@MainActor
final class SnapGlassApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var viewModel: CaptureViewModel?
    private var recordingQuitFlow = RecordingQuitFlow()

    func applicationDidFinishLaunching(_ notification: Notification) {
#if DEBUG
        ShowcaseImageExporter.runIfConfigured()
#endif
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let viewModel else { return .terminateNow }
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
