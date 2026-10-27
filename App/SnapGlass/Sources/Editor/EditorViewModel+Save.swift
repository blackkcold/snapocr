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
        if isEnteringText { commitTextEntry() }
        // 裁剪合成期间文档仍是裁剪前的快照，此时保存会写出缺了裁剪的图。
        guard !isApplyingCrop else {
            showToast(message: AppLocalization.string("Processing…"), type: .info)
            return
        }
        guard let doc = document else { return }
        if mode == .overwriteOriginal && sourceEntryID == nil {
            showToast(
                message: AppLocalization.string("No original record to overwrite; save as a new record instead"),
                type: .error
            )
            return
        }
        guard !isWritingImage else { return }
        isWritingImage = true
        defer { isWritingImage = false }
        do {
            let image = try await Self.renderOffMain(doc)
            try await historySaver(image, mode, sourceEntryID)
            let message: String = switch mode {
            case .newRecord: AppLocalization.string("Saved to history")
            case .overwriteOriginal: AppLocalization.string("History updated; original kept for restore")
            }
            showToast(message: message, type: .success)
            markSaved(document: doc)
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
        if isEnteringText { commitTextEntry() }
        guard !isApplyingCrop else {
            showToast(message: AppLocalization.string("Processing…"), type: .info)
            return
        }
        guard let doc = document else {
            onCompleted?(false)
            return
        }
        guard !isWritingImage else {
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

        isWritingImage = true
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else {
                self?.isWritingImage = false
                onCompleted?(false)
                return
            }
            guard let self else {
                onCompleted?(false)
                return
            }
            self.finishSaving(document: doc, url: url, onCompleted: onCompleted)
        }
    }

    /// Encodes and writes the chosen file in one background pass.
    ///
    /// Kept out of `save` so the save-panel completion stays within the
    /// project's function-length limit.
    private func finishSaving(
        document: AnnotationDocument,
        url: URL,
        onCompleted: ((Bool) -> Void)?
    ) {
        Self.lastSaveDirectory = url.deletingLastPathComponent()
        let extensionName = url.pathExtension.lowercased()
        let outputFormat: ImageFileFormat =
            (extensionName == "jpg" || extensionName == "jpeg") ? .jpeg : .png
        let quality = UserDefaults.standard.object(forKey: PreferenceKeys.captureJPEGQuality) == nil
            ? PreferenceDefaults.captureJPEGQuality
            : UserDefaults.standard.double(forKey: PreferenceKeys.captureJPEGQuality)

        Task { [weak self] in
            do {
                try await Self.writeRenderedDocument(
                    document,
                    to: url,
                    format: outputFormat,
                    jpegQuality: quality
                )
                guard let self else { return }
                self.isWritingImage = false
                self.showToast(
                    message: AppLocalization.string("Saved to %@", url.lastPathComponent),
                    type: .success
                )
                self.markSaved(document: document)
                self.logger.info("Saved annotated image to \(url.path())")
                onCompleted?(true)
            } catch {
                guard let self else { return }
                self.isWritingImage = false
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
    nonisolated static func flattenedOnWhite(_ image: CGImage) -> CGImage {
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

    /// Renders the annotated image on a background thread.
    ///
    /// Full-resolution compositing of a 5K capture takes long enough to be
    /// visible as a main-thread freeze, so callers await this instead of
    /// calling `interactor.render` directly on the UI actor.
    nonisolated static func renderOffMain(_ document: AnnotationDocument) async throws -> CGImage {
        try await Task.detached(priority: .userInitiated) {
            try AnnotationInteractor().render(document)
        }.value
    }

    /// Renders, optionally flattens, encodes and writes in one background pass.
    nonisolated static func writeRenderedDocument(
        _ document: AnnotationDocument,
        to url: URL,
        format: ImageFileFormat,
        jpegQuality: Double
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            var image = try AnnotationInteractor().render(document)
            if format == .jpeg {
                image = EditorViewModel.flattenedOnWhite(image)
            }
            try ImageEncoder.write(image, to: url, format: format, jpegQuality: jpegQuality)
        }.value
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
        guard !isApplyingCrop else {
            showToast(message: AppLocalization.string("Processing…"), type: .info)
            return
        }
        if isEnteringText { commitTextEntry() }
        guard let doc = document, !isWritingImage else { return }
        isWritingImage = true
        Task { [weak self] in
            do {
                let image = try await Self.renderOffMain(doc)
                guard let self else { return }
                try await ClipboardWriter.write(image: image)
                self.isWritingImage = false
                self.showToast(message: AppLocalization.string("Copied to clipboard"), type: .success)
                self.logger.info("Copied annotated image to clipboard")
            } catch {
                guard let self else { return }
                self.isWritingImage = false
                self.showToast(
                    message: AppLocalization.string("Copy failed: %@", error.localizedDescription),
                    type: .error
                )
            }
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
        guard toastDeduplicator.shouldPresent(message) else { return }
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
