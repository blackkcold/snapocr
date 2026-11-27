import Foundation
import OCRCore

/// Turns an OCR failure into a sentence the user can act on.
///
/// `OCRError`'s own `errorDescription` is developer-facing and Chinese-only, and every
/// toast used to embed it. On an English, Japanese or Korean interface that reported a
/// timeout in Chinese, in the middle of a screenshot flow — and it also meant the toast
/// could not say what to do about it.
///
/// The failure kind therefore picks the sentence, and the interface language picks the
/// translation. Only an unrecognised failure falls back to its own description.
enum OCRErrorPresentation {
    /// What the user is told, independent of language.
    enum Kind: Equatable {
        /// The image genuinely holds no readable text.
        case noText
        /// One Vision request outlived its timeout.
        case timedOut
        /// Every engine thread is stuck; only a restart recovers.
        case engineUnresponsive
        /// The selected engine cannot run on this machine.
        case engineUnavailable
        /// Anything else: shown with its own description.
        case other
    }

    /// Classifies a failure for presentation.
    ///
    /// - Parameter error: The failure a capture or editor OCR pass produced.
    /// - Returns: The kind that decides the sentence; `nil` when it is not an ``OCRError``.
    static func kind(of error: Error) -> Kind? {
        guard let ocrError = error as? OCRError else { return nil }
        switch ocrError {
        case .noTextFound:
            return .noText
        case .visionRequestTimedOut:
            return .timedOut
        case .engineUnresponsive:
            return .engineUnresponsive
        case .engineUnavailable:
            return .engineUnavailable
        case .recognitionFailed, .confidenceTooLow, .languageNotSupported, .imageTooLarge:
            return .other
        }
    }

    /// The message to show, with the translation supplied by the caller.
    ///
    /// `localize` is injected the same way `AppLocalization.recordingErrorDescription`
    /// takes one, so a test can assert which sentence was chosen without depending on
    /// which language bundle the test host happens to run under.
    ///
    /// - Parameters:
    ///   - error: The failure to report.
    ///   - localize: Resolves a `Localizable.strings` key in the app's language.
    /// - Returns: The sentence to put in a toast.
    static func message(for error: Error, localize: (String) -> String) -> String {
        switch kind(of: error) {
        case .noText:
            return localize("No text found")
        case .timedOut:
            return localize("Text recognition timed out. Try again with a smaller area.")
        case .engineUnresponsive:
            return localize("Text recognition stopped responding. Restart SnapGlass and try again.")
        case .engineUnavailable:
            return localize("The selected text recognition engine is unavailable.")
        case .other, .none:
            // 和 `AppLocalization.string(_:_:)` 一样走格式串，让译文可以调整占位符位置。
            return String(format: localize("OCR failed: %@"), error.localizedDescription)
        }
    }

    /// The message to show in the app's own language.
    ///
    /// - Parameter error: The failure to report.
    /// - Returns: The sentence to put in a toast.
    static func message(for error: Error) -> String {
        message(for: error, localize: AppLocalization.string)
    }
}
