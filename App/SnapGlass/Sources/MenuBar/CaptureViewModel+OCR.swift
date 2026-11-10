import AppKit
import BarcodeCore
import CaptureCore
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
                presentOCRActionSuggestion(for: result.text)
            }
            return result
        } catch {
            showToast(message: AppLocalization.string("OCR failed: %@", error.localizedDescription), type: .error)
            return nil
        }
    }

    /// Offers one action for the most useful thing in the recognized text, so a
    /// link, address, or verification code does not have to be selected by hand.
    private func presentOCRActionSuggestion(for text: String) {
        guard let action = OCRTextActionDetector.candidates(in: text).first else {
            showToast(message: AppLocalization.string("OCR completed"), type: .success)
            return
        }

        switch action {
        case .openURL(let url):
            showToast(
                message: AppLocalization.string("Link found in text"),
                type: .info,
                actionLabel: AppLocalization.string("Open")
            ) {
                NSWorkspace.shared.open(url)
            }
        case .composeEmail(let address):
            showToast(
                message: AppLocalization.string("Email found in text"),
                type: .info,
                actionLabel: AppLocalization.string("Send Email")
            ) {
                guard let url = URL(string: "mailto:\(address)") else { return }
                NSWorkspace.shared.open(url)
            }
        case .copyCode(let code):
            showToast(
                message: AppLocalization.string("Code found in text"),
                type: .info,
                actionLabel: AppLocalization.string("Copy Code")
            ) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
            }
        }
    }

    func writeImageToClipboard(_ image: CGImage) async -> Bool {
        do {
            try await ClipboardWriter.write(image: image)
            return true
        } catch {
            logger.warning("Clipboard write failed: \(error.localizedDescription)")
            return false
        }
    }

    func detectBarcodesForSuggestion(in image: CGImage) async -> [BarcodeResult] {
        do {
            return try await barcodeEngine.detect(in: image, types: [])
        } catch {
            logger.warning("Automatic barcode hint failed: \(error.localizedDescription)")
            return []
        }
    }

    /// 动作栏「重新识别」：实时重截选区。
    ///
    /// 遮罩面板已设 `sharingType = .none`，把自己排除在截图之外；
    /// 区域路径返回的已经是裁好的图，这里不需要再做任何裁剪。
    func recaptureRegionForBarcodeScan(_ quartzRect: CGRect) async -> CGImage? {
        do {
            let result = try await captureWithoutScreenshotShelf(
                mode: CaptureCore.CaptureMode.area(quartzRect),
                options: CaptureOptions(includeCursor: false, highResolution: true)
            )
            return result.image
        } catch {
            logger.warning("Barcode rescan capture failed: \(error.localizedDescription)")
            return nil
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
