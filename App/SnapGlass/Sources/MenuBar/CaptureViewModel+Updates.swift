import AppKit
import SharedKit
import SwiftUI

// MARK: - CaptureViewModel Update Handling

extension CaptureViewModel {
    func presentUpdate(_ release: UpdateRelease) async {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = AppLocalization.string("SnapGlass %@ is Available", release.tagName)
        let notes = release.releaseNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.informativeText = notes.isEmpty
            ? AppLocalization.string("A new version is ready to download.")
            : String(notes.prefix(1_500))
        alert.addButton(withTitle: AppLocalization.string("Download Update"))
        alert.addButton(withTitle: AppLocalization.string("View on GitHub"))
        alert.addButton(withTitle: AppLocalization.string("Later"))

        if #available(macOS 14.0, *) {
            NSApplication.shared.activate()
        } else {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            await download(release)
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(release.releasePageURL)
        default:
            break
        }
    }

    private func download(_ release: UpdateRelease) async {
        isDownloadingUpdate = true
        defer { isDownloadingUpdate = false }
        do {
            let fileURL = try await updateService.download(release)
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            presentInformationAlert(
                title: AppLocalization.string("Update Downloaded"),
                message: AppLocalization.string(
                    "%@ passed SHA-256 verification and is ready in Downloads.",
                    fileURL.lastPathComponent
                )
            )
        } catch {
            presentInformationAlert(
                title: AppLocalization.string("Update Download Failed"),
                message: error.localizedDescription,
                style: .warning
            )
        }
    }

    func presentInformationAlert(
        title: String,
        message: String,
        style: NSAlert.Style = .informational
    ) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: AppLocalization.string("OK"))
        if #available(macOS 14.0, *) {
            NSApplication.shared.activate()
        } else {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        alert.runModal()
    }
}
