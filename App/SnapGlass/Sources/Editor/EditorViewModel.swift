import SwiftUI
import AppKit
import AnnotationCore
import SharedKit
import UniformTypeIdentifiers

/// View model for the annotation editor window.
///
/// Manages the annotation document lifecycle: creating documents from captured images,
/// tracking the selected tool/color/stroke, applying annotations via `AnnotationInteractor`,
/// and handling save/copy/cancel actions.
@MainActor
public final class EditorViewModel: ObservableObject {
    /// The annotation interactor for applying tools, undo/redo, and rendering.
    public let interactor: AnnotationInteractor

    /// The current annotation document, created from the captured image.
    @Published public var document: AnnotationDocument?

    /// The currently selected annotation tool.
    @Published public var selectedTool: AnnotationToolType = .rect

    /// The currently selected color for annotations.
    @Published public var selectedColor: Color = .red

    /// The stroke width for line-based tools.
    @Published public var strokeWidth: CGFloat = 3.0

    /// Whether undo is available.
    public var canUndo: Bool { document?.canUndo == true }

    /// Whether redo is available.
    public var canRedo: Bool { document?.canRedo == true }

    /// The current toast message to display.
    @Published public var toastMessage: ToastMessage?

    /// Called when the user cancels editing to close the editor window.
    public var onClose: (() -> Void)?

    private let logger = Logger(category: "editor")

    /// Creates a new editor view model.
    ///
    /// - Parameter interactor: The annotation interactor to use.
    public init(interactor: AnnotationInteractor = AnnotationInteractor()) {
        self.interactor = interactor
    }

    /// Converts the SwiftUI `Color` to a `CGColor` for the `AnnotationNode`.
    public var cgColor: CGColor {
        NSColor(selectedColor).cgColor
    }

    /// Loads a captured image into the editor, creating a new annotation document.
    ///
    /// - Parameter image: The captured background image to annotate.
    public func loadImage(_ image: CGImage) {
        document = interactor.createDocument(from: image)
        logger.info("Editor loaded image: \(image.width)×\(image.height)")
    }

    // MARK: - Annotation Operations

    /// Adds a new annotation node to the document.
    ///
    /// - Parameter node: The annotation node to add.
    public func addNode(_ node: AnnotationNode) {
        guard var doc = document else { return }
        do {
            try interactor.apply(selectedTool, to: &doc, node: node)
            document = doc
            logger.debug("Added node: \(node.tool.rawValue), id=\(node.id)")
        } catch {
            logger.error("Failed to add node: \(error.localizedDescription)")
            showToast(message: error.localizedDescription, type: .error)
        }
    }

    /// Undoes the last annotation operation.
    public func undo() {
        guard var doc = document else { return }
        do {
            try interactor.undo(&doc)
            document = doc
        } catch {
            logger.warning("Undo failed: \(error.localizedDescription)")
        }
    }

    /// Redoes the last undone annotation operation.
    public func redo() {
        guard var doc = document else { return }
        do {
            try interactor.redo(&doc)
            document = doc
        } catch {
            logger.warning("Redo failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Save / Copy / Cancel

    /// Saves the annotated image to a user-chosen file location.
    public func save() {
        guard let doc = document else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Snapshot.png"

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                let image = try self.interactor.render(doc)
                guard let destination = CGImageDestinationCreateWithURL(
                    url as CFURL, "public.png" as CFString, 1, nil
                ) else {
                    self.showToast(message: "Failed to create file", type: .error)
                    return
                }
                CGImageDestinationAddImage(destination, image, nil)
                CGImageDestinationFinalize(destination)
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

    // MARK: - Toast

    /// Shows a transient toast notification.
    ///
    /// - Parameters:
    ///   - message: The message text.
    ///   - type: The type of toast.
    public func showToast(message: String, type: ToastType) {
        toastMessage = ToastMessage(message: message, type: type)
        Task {
            try? await Task.sleep(for: .seconds(3))
            if toastMessage?.message == message {
                toastMessage = nil
            }
        }
    }
}
