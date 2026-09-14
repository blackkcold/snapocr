import AppKit
import AnnotationCore
import HistoryCore
import SharedKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - EditorViewModel Save / Copy / Cancel / Toast

extension EditorViewModel {
    static let defaultHistorySaver:
        @Sendable (CGImage, EditorHistorySaveMode, UUID?) async throws -> Void = { image, mode, sourceEntryID in
        let history = try HistoryActor.sharedResult().get()
        switch mode {
        case .newRecord:
            try await history.saveCapture(
                image: image, textContent: "", ocrConfidence: 0,
                captureMode: "edited"
            )
        case .overwriteOriginal:
            guard let sourceEntryID else {
                throw HistoryError.entryNotFound(id: UUID())
            }
            try await history.replaceImage(id: sourceEntryID, image: image)
        }
    }

    /// Writes the annotated image to history as a new record or as an
    /// overwrite of the originating capture.
    public func saveToHistory(mode: EditorHistorySaveMode) async {
        guard let doc = document else { return }
        if mode == .overwriteOriginal && sourceEntryID == nil {
            showToast(
                message: String(
                    localized: "No original record to overwrite; save as a new record instead"
                ),
                type: .error
            )
            return
        }
        do {
            let image = try interactor.render(doc)
            try await historySaver(image, mode, sourceEntryID)
            let message: String = switch mode {
            case .newRecord: String(localized: "Saved to history")
            case .overwriteOriginal: String(localized: "History updated; original kept for restore")
            }
            showToast(message: message, type: .success)
            logger.info("Editor image saved to history (mode: \(mode))")
        } catch {
            showToast(message: "History save failed: \(error.localizedDescription)", type: .error)
        }
    }
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
