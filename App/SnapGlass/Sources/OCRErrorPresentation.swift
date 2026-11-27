import Foundation
import OCRCore

/// Turns an OCR failure into a sentence the user can act on.
///
/// `OCRError`'s own `errorDescription` is developer-facing and Chinese-only, and every
/// toast used to embed it. On an English, Japanese or Korean interface that reported a
/// failure in Chinese, in the middle of a screenshot flow — and it also meant the toast
/// could not say what to do about it.
///
/// The failure kind therefore picks the sentence, and the interface language picks the
/// translation. There is deliberately no "show whatever the error says" branch: the
/// engine's descriptions stay out of the interface entirely, and the diagnostic detail
/// goes to the log instead, where a developer can still read it.
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
        /// The selected engine has no data for one of the requested languages.
        ///
        /// Carries no payload: ``OCRError/languageNotSupported(_:)`` holds a developer
        /// sentence naming the pack path, which belongs in the log, not on screen.
        case languageNotInstalled
        /// The image is too large to process safely.
        case imageTooLarge(width: Int, height: Int)
        /// A recognition attempt failed for an unknown reason.
        case recognitionFailed
        /// A failure that is not an `OCRError` at all.
        case unknown
    }

    /// Classifies a failure for presentation.
    ///
    /// Every case of ``OCRError`` maps to its own kind. A catch-all arm would let a new
    /// error case silently reuse another one's sentence, which is how the original
    /// "everything looks like a generic failure" behaviour crept in.
    ///
    /// - Parameter error: The failure a capture or editor OCR pass produced.
    /// - Returns: The kind that decides the sentence.
    static func kind(of error: Error) -> Kind {
        guard let ocrError = error as? OCRError else { return .unknown }
        switch ocrError {
        case .noTextFound:
            return .noText
        case .visionRequestTimedOut:
            return .timedOut
        case .engineUnresponsive:
            return .engineUnresponsive
        case .engineUnavailable:
            return .engineUnavailable
        case .languageNotSupported:
            return .languageNotInstalled
        case .imageTooLarge(let width, let height):
            return .imageTooLarge(width: width, height: height)
        case .recognitionFailed, .confidenceTooLow:
            return .recognitionFailed
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
        case .languageNotInstalled:
            return localize("The language pack for text recognition is not installed. Download it in Settings.")
        case .imageTooLarge:
            return localize("The image is too large to recognize. Try a smaller area.")
        case .recognitionFailed, .unknown:
            return localize("Text recognition failed. Try again.")
        }
    }

    /// The diagnostic detail to log alongside a failure.
    ///
    /// The interface sentence says what the user can do; this says what actually
    /// happened, in the engine's own words. Keeping them apart is what lets the sentence
    /// be localized without losing the detail a bug report needs.
    ///
    /// - Parameter error: The failure to report.
    /// - Returns: The engine's own description, or the kind when there is none.
    static func diagnostic(for error: Error) -> String {
        error.localizedDescription
    }

    /// The message to show in the app's own language.
    ///
    /// - Parameter error: The failure to report.
    /// - Returns: The sentence to put in a toast.
    static func message(for error: Error) -> String {
        message(for: error, localize: AppLocalization.string)
    }
}
