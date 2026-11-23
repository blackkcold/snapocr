import AppKit
import SwiftUI

/// Bridges the zoom controls in the toolbar to the canvas `NSView`.
///
/// The canvas owns the zoom maths; this only forwards commands and publishes the
/// current scale so the toolbar label stays in sync.
@MainActor
final class CanvasZoomController: ObservableObject {
    /// Upper bound for zoom relative to fit. Large captures need well over 8×
    /// to reach one image pixel per point in a normal window (a 6K screenshot
    /// needs roughly 10–13×).
    static let maximumScale: CGFloat = 32

    /// Zoom relative to the fit-to-window size; 1 means the whole image is visible.
    @Published private(set) var scale: CGFloat = 1
    /// Scale relative to the image's own pixels, which is what "100%" refers to.
    @Published private(set) var pixelScale: CGFloat = 1

    weak var canvas: EditableAnnotationCanvasNSView?

    /// True while the image is shown at fit-to-window size.
    var isFit: Bool { scale <= 1.0001 }

    func attach(_ canvas: EditableAnnotationCanvasNSView?) {
        self.canvas = canvas
    }

    func canvasDidChangeZoom(scale: CGFloat, pixelScale: CGFloat) {
        self.scale = scale
        self.pixelScale = pixelScale
    }

    func zoomIn() {
        canvas?.zoomIn()
    }

    func zoomOut() {
        canvas?.zoomOut()
    }

    func fit() {
        canvas?.resetZoom()
    }

    func actualSize() {
        canvas?.actualSizeZoom()
    }

    /// Copies the canvas's OCR text selection, if there is one.
    ///
    /// - Returns: `true` when text was copied, so the caller can fall back to
    ///   copying the image.
    func copyOCRSelectionIfPossible() -> Bool {
        canvas?.copySelectedOCRTextIfPossible() ?? false
    }
}
