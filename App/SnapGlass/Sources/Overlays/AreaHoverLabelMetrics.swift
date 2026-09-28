import AppKit

@MainActor
enum AreaHoverLabelMetrics {
    static let primaryAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
        .foregroundColor: NSColor.white,
    ]

    static let secondaryAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
        .foregroundColor: NSColor.white.withAlphaComponent(0.7),
    ]

    private static let cachedHexSize = ("#000000" as NSString).size(withAttributes: primaryAttributes)
    private static let cachedRGBSizes: [CGSize] = (12...18).map { length in
        (String(repeating: "0", count: length) as NSString).size(withAttributes: secondaryAttributes)
    }

    static func hexSize(for text: String) -> CGSize {
        guard text.hasPrefix("#"), text.utf16.count == 7 else {
            return (text as NSString).size(withAttributes: primaryAttributes)
        }
        return cachedHexSize
    }

    static func rgbSize(for text: String) -> CGSize {
        let length = text.utf16.count
        guard text.hasPrefix("rgb("), text.hasSuffix(")"), (12...18).contains(length) else {
            return (text as NSString).size(withAttributes: secondaryAttributes)
        }
        return cachedRGBSizes[length - 12]
    }
}
