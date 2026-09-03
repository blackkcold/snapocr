import AppKit
import SharedKit
import SwiftUI

// MARK: - CaptureViewModel Update Handling

extension CaptureViewModel {
    func presentUpdate(_ release: UpdateRelease) async {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(
            format: NSLocalizedString("SnapGlass %@ is Available", comment: "Available update title"),
            release.tagName
        )
        let notes = release.releaseNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.informativeText = notes.isEmpty
            ? NSLocalizedString("A new version is ready to download.", comment: "Empty release notes")
            : String(notes.prefix(1_500))
        alert.addButton(withTitle: NSLocalizedString("Download Update", comment: "Download update button"))
        alert.addButton(withTitle: NSLocalizedString("View on GitHub", comment: "Open release page button"))
        alert.addButton(withTitle: NSLocalizedString("Later", comment: "Dismiss update button"))

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
                title: NSLocalizedString("Update Downloaded", comment: "Update download title"),
                message: String(
                    format: NSLocalizedString(
                        "%@ passed SHA-256 verification and is ready in Downloads.",
                        comment: "Verified update message"
                    ),
                    fileURL.lastPathComponent
                )
            )
        } catch {
            presentInformationAlert(
                title: NSLocalizedString("Update Download Failed", comment: "Update download error title"),
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
        alert.addButton(withTitle: NSLocalizedString("OK", comment: "Alert confirmation"))
        if #available(macOS 14.0, *) {
            NSApplication.shared.activate()
        } else {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        alert.runModal()
    }
}
