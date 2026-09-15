import AppKit
import BarcodeCore
import OCRCore
import SharedKit
import SwiftUI

// MARK: - CaptureViewModel OCR / Clipboard Helpers

extension CaptureViewModel {
    /// Performs OCR on the specified image.
    ///
    /// - Parameter image: The image to perform OCR on.
    func performOCR(on image: CGImage, copyToClipboard: Bool) async -> OCRResult? {
        do {
            let options = Self.currentOCROptions()
            let result = try await ocrPipeline.recognize(image, options: options)
            if result.text.isEmpty {
                showToast(message: AppLocalization.string("No text found"), type: .info)
            } else if copyToClipboard {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.text, forType: .string)
                showToast(message: AppLocalization.string("Text copied to clipboard"), type: .success)
            } else {
                showToast(message: AppLocalization.string("OCR completed"), type: .success)
            }
            return result
        } catch {
            showToast(message: AppLocalization.string("OCR failed: %@", error.localizedDescription), type: .error)
            return nil
        }
    }

    func writeImageToClipboard(_ image: CGImage) -> Bool {
        let nsImage = NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.writeObjects([nsImage])
    }

    func detectBarcodesForSuggestion(in image: CGImage) async -> [BarcodeResult] {
        do {
            return try await barcodeEngine.detect(in: image, types: [])
        } catch {
            logger.warning("Automatic barcode hint failed: \(error.localizedDescription)")
            return []
        }
    }

    func showBarcodeCopySuggestion(payload: String) {
        showToast(
            message: AppLocalization.string("One barcode detected"),
            type: .info,
            actionLabel: AppLocalization.string("Copy Content")
        ) { [weak self] in
            self?.copyBarcodePayload(payload)
        }
    }

    private func copyBarcodePayload(_ payload: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload, forType: .string)
        showToast(
            message: AppLocalization.string("Barcode copied to clipboard"),
            type: .success
        )
    }
}
