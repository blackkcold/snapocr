import Foundation

/// An actionable value found in recognized text.
public enum OCRTextAction: Equatable, Sendable {
    /// A web link that can be opened directly.
    case openURL(URL)
    /// An email address that can start a new message.
    case composeEmail(String)
    /// A short numeric code, such as a one-time verification code.
    case copyCode(String)
}

/// Finds links, email addresses, and six-digit codes in recognized text.
///
/// Results are ordered by usefulness: links first, then email addresses, then
/// codes. Duplicates are removed so a repeated value does not produce two actions.
public enum OCRTextActionDetector {
    /// Scans recognized text for actionable values.
    ///
    /// - Parameter text: The text produced by OCR.
    /// - Returns: Every actionable value in priority order; empty when the text
    ///   contains nothing worth offering.
    public static func candidates(in text: String) -> [OCRTextAction] {
        guard !text.isEmpty else { return [] }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var actions: [OCRTextAction] = []

        for raw in matches(pattern: #"https?://[^\s<>"'）】]+"#, in: text, range: fullRange) {
            let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}>"))
            guard let url = URL(string: trimmed), !actions.contains(.openURL(url)) else { continue }
            actions.append(.openURL(url))
        }

        for address in matches(
            pattern: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
            in: text,
            range: fullRange
        ) {
            let action = OCRTextAction.composeEmail(address)
            guard !actions.contains(action) else { continue }
            actions.append(action)
        }

        for code in matches(pattern: #"(?<!\d)\d{6}(?!\d)"#, in: text, range: fullRange) {
            let action = OCRTextAction.copyCode(code)
            guard !actions.contains(action) else { continue }
            actions.append(action)
        }

        return actions
    }

    private static func matches(
        pattern: String,
        in text: String,
        range: NSRange
    ) -> [String] {
        guard
            let expression = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            )
        else { return [] }

        return expression.matches(in: text, options: [], range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }
}
