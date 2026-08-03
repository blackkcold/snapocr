import Foundation

/// Selects decoded barcode content that can be offered as a one-click copy action.
public enum BarcodeCopyCandidate {
    /// Returns the decoded payload only when exactly one non-empty barcode was detected.
    ///
    /// - Parameter results: Barcode detection results for one image.
    /// - Returns: The original payload when it is the sole usable result; otherwise `nil`.
    public static func singlePayload(from results: [BarcodeResult]) -> String? {
        guard results.count == 1, let payload = results.first?.payload else { return nil }
        guard !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return payload
    }
}
