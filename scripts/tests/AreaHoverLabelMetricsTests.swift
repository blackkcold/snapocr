import AppKit

@main
@MainActor
enum AreaHoverLabelMetricsTests {
    static func main() {
        let hex = "#FF00AA"
        let expectedHex = (hex as NSString).size(withAttributes: AreaHoverLabelMetrics.primaryAttributes)
        guard AreaHoverLabelMetrics.hexSize(for: hex) == expectedHex else {
            fputs("hex label geometry changed\n", stderr)
            exit(1)
        }

        let rgbLabels = [
            "rgb(0, 0, 0)", "rgb(1, 2, 3)", "rgb(10, 2, 3)",
            "rgb(10, 20, 3)", "rgb(100, 20, 3)", "rgb(100, 200, 3)",
            "rgb(100, 200, 30)", "rgb(255, 255, 255)",
        ]
        for label in rgbLabels {
            let expected = (label as NSString).size(withAttributes: AreaHoverLabelMetrics.secondaryAttributes)
            guard AreaHoverLabelMetrics.rgbSize(for: label) == expected else {
                fputs("RGB label geometry changed: \(label)\n", stderr)
                exit(1)
            }
        }
        print("AreaHoverLabelMetrics geometry verified for hex and RGB lengths 12–18")
    }
}
