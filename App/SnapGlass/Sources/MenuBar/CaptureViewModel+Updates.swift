import Foundation
import SharedKit

// MARK: - CaptureViewModel Update Handling

extension CaptureViewModel {
    /// Downloads and verifies the selected release, then publishes the ready state.
    ///
    /// This never opens an alert: a menu-bar app may be inactive when the
    /// download finishes, and a modal would block in the background.
    func downloadUpdate(_ release: UpdateRelease) {
        guard !isDownloadingUpdate else { return }
        updateCheckState = .downloading(release)

        Task {
            do {
                let fileURL = try await updateService.download(release)
                logger.info("update.downloaded path=\(fileURL.path)")
                updateCheckState = .readyToInstall(release, fileURL)
            } catch {
                logger.error("update.download.failed \(error.localizedDescription)")
                updateCheckState = .downloadFailed(release, error.localizedDescription)
            }
        }
    }

    /// Hands a verified DMG to the installer and quits on success.
    ///
    /// Only the explicit "Open Installer" action reaches this path, so the
    /// quit is user-initiated. Unsaved editor work still keeps the app alive.
    func installDownloadedUpdate(_ release: UpdateRelease, at fileURL: URL) {
        guard updateCheckState == .readyToInstall(release, fileURL) else { return }

        Task {
            switch await updateInstallHandoff.run(dmgURL: fileURL) {
            case .openedInstaller:
                logger.info("update.installer.opened path=\(fileURL.lastPathComponent)")
            case .deferredForUnsavedWork:
                logger.warning("update.install.deferred unsaved-editor")
                showToast(
                    message: AppLocalization.string(
                        "Update downloaded. Save your edits, then open the installer again."
                    ),
                    type: .info
                )
            case .ignored:
                logger.info("update.install.ignored duplicate-handoff")
            case .failed(let diagnostic):
                logger.error("update.installer.failed \(diagnostic)")
                showToast(
                    message: AppLocalization.string(
                        "Unable to open the update installer. The DMG is in Downloads."
                    ),
                    type: .error
                )
            }
        }
    }
}
