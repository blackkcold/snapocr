import AppKit
import AnnotationCore
import SharedKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - EditorViewModel Save / Copy / Cancel / Toast

extension EditorViewModel {
    /// Saves the annotated image to a user-chosen file location.
    public func save() {
        guard let doc = document else { return }
        let configuredFormat = ImageFileFormat(
            rawValue: UserDefaults.standard.string(forKey: PreferenceKeys.captureImageFormat)
                ?? PreferenceDefaults.captureImageFormat
        ) ?? .png
        let format = ImageEncoder.containsTransparency(doc.baseImage) ? ImageFileFormat.png : configuredFormat
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .png ? .png : .jpeg]
        panel.nameFieldStringValue = "Snapshot.\(format.fileExtension)"

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                let image = try self.interactor.render(doc)
                let quality = UserDefaults.standard.object(forKey: PreferenceKeys.captureJPEGQuality) == nil
                    ? PreferenceDefaults.captureJPEGQuality
                    : UserDefaults.standard.double(forKey: PreferenceKeys.captureJPEGQuality)
                try ImageEncoder.write(image, to: url, format: format, jpegQuality: quality)
                self.showToast(message: "Saved to \(url.lastPathComponent)", type: .success)
                self.logger.info("Saved annotated image to \(url.path())")
            } catch {
                self.showToast(message: "Save failed: \(error.localizedDescription)", type: .error)
            }
        }
    }

    /// Renders the annotated image and copies it to the system clipboard.
    public func copyToClipboard() {
        guard let doc = document else { return }
        do {
            let image = try interactor.render(doc)
            let nsImage = NSImage(
                cgImage: image,
                size: NSSize(width: image.width, height: image.height)
            )
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([nsImage])
            showToast(message: "Copied to clipboard", type: .success)
            logger.info("Copied annotated image to clipboard")
        } catch {
            showToast(message: "Copy failed: \(error.localizedDescription)", type: .error)
        }
    }

    /// Cancels editing and signals the editor window to close.
    public func cancel() {
        logger.info("Editor cancelled")
        onClose?()
    }

    /// Shows a transient toast notification.
    ///
    /// - Parameters:
    ///   - message: The message text.
    ///   - type: The type of toast.
    public func showToast(message: String, type: ToastType) {
        let toast = ToastMessage(message: message, type: type)
        toastMessage = toast
        Task {
            try? await Task.sleep(for: .seconds(3))
            if toastMessage?.id == toast.id {
                toastMessage = nil
            }
        }
    }
}
