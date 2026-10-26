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
                message: AppLocalization.string("No original record to overwrite; save as a new record instead"),
                type: .error
            )
            return
        }
        do {
            let image = try interactor.render(doc)
            try await historySaver(image, mode, sourceEntryID)
            let message: String = switch mode {
            case .newRecord: AppLocalization.string("Saved to history")
            case .overwriteOriginal: AppLocalization.string("History updated; original kept for restore")
            }
            showToast(message: message, type: .success)
            markSaved()
            logger.info("Editor image saved to history (mode: \(mode))")
        } catch {
            showToast(
                message: AppLocalization.string("History save failed: %@", error.localizedDescription),
                type: .error
            )
        }
    }
    /// Saves the annotated image to a user-chosen file location.
    ///
    /// - Parameter onCompleted: Called with `true` once the file was written and
    ///   `false` when the user cancelled the panel. The close confirmation uses
    ///   it to close only after a successful write.
    public func save(onCompleted: ((Bool) -> Void)? = nil) {
        guard let doc = document else {
            onCompleted?(false)
            return
        }
        let configuredFormat = ImageFileFormat(
            rawValue: UserDefaults.standard.string(forKey: PreferenceKeys.captureImageFormat)
                ?? PreferenceDefaults.captureImageFormat
        ) ?? .png
        let format = ImageEncoder.containsTransparency(doc.baseImage) ? ImageFileFormat.png : configuredFormat
        let panel = NSSavePanel()
        // Both formats are offered; the file extension the user picks decides
        // how the image is encoded.
        panel.allowedContentTypes = [.png, .jpeg]
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "Snapshot.\(format.fileExtension)"
        panel.directoryURL = Self.lastSaveDirectory

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else {
                onCompleted?(false)
                return
            }
            Self.lastSaveDirectory = url.deletingLastPathComponent()
            let extensionName = url.pathExtension.lowercased()
            let outputFormat: ImageFileFormat =
                (extensionName == "jpg" || extensionName == "jpeg") ? .jpeg : .png
            do {
                var image = try self.interactor.render(doc)
                if outputFormat == .jpeg {
                    image = Self.flattenedOnWhite(image)
                }
                let quality = UserDefaults.standard.object(forKey: PreferenceKeys.captureJPEGQuality) == nil
                    ? PreferenceDefaults.captureJPEGQuality
                    : UserDefaults.standard.double(forKey: PreferenceKeys.captureJPEGQuality)
                try ImageEncoder.write(image, to: url, format: outputFormat, jpegQuality: quality)
                self.showToast(message: AppLocalization.string("Saved to %@", url.lastPathComponent), type: .success)
                self.markSaved()
                self.logger.info("Saved annotated image to \(url.path())")
                onCompleted?(true)
            } catch {
                self.showToast(
                    message: AppLocalization.string("Save failed: %@", error.localizedDescription),
                    type: .error
                )
                onCompleted?(false)
            }
        }
    }

    /// Remembers the last folder so repeat saves do not start from scratch.
    private static var lastSaveDirectory: URL? {
        get {
            guard let path = UserDefaults.standard.string(forKey: PreferenceKeys.editorSaveDirectory) else {
                return nil
            }
            return URL(fileURLWithPath: path)
        }
        set {
            UserDefaults.standard.set(newValue?.path, forKey: PreferenceKeys.editorSaveDirectory)
        }
    }

    /// JPEG cannot store transparency; flatten onto white so alpha does not
    /// turn into black fringes.
    static func flattenedOnWhite(_ image: CGImage) -> CGImage {
        guard ImageEncoder.containsTransparency(image) else { return image }
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage() ?? image
    }

    /// Renders the annotated image and copies it to the system clipboard.
    ///
    /// An OCR text selection on the canvas wins, so ⌘C keeps behaving like a
    /// text copy whenever the user has actually selected text.
    public func copyContextually() {
        if canvasZoom.copyOCRSelectionIfPossible() { return }
        copyToClipboard()
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
            showToast(message: AppLocalization.string("Copied to clipboard"), type: .success)
            logger.info("Copied annotated image to clipboard")
        } catch {
            showToast(message: AppLocalization.string("Copy failed: %@", error.localizedDescription), type: .error)
        }
    }

    /// Cancels editing and signals the editor window to close.
    public func cancel() {
        requestClose()
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
