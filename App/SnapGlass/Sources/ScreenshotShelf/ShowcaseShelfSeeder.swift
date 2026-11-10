#if DEBUG
import AppKit
import CoreGraphics
import SharedKit

/// Fills the screenshot shelf with demo cards when the app is launched for UI
/// capture. Debug builds only, and only with `SNAPGLASS_SHOWCASE=1`; a normal
/// launch never reaches this code path.
@MainActor
enum ShowcaseShelfSeeder {
    static func schedule(manager: ScreenshotShelfManager) {
        guard ShowcaseMode.isEnabled else { return }
        guard ProcessInfo.processInfo.environment["SNAPGLASS_SHOWCASE_OUT"] == nil else { return }

        let state = ProcessInfo.processInfo.environment["SNAPGLASS_SHOWCASE_STATE"] ?? "shelf"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            for index in 0..<3 {
                guard let image = makeImage(index: index) else { continue }
                _ = manager.captureCompleted(image)
            }
            manager.showcaseHoldOpen()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                switch state {
                case "drag":
                    manager.showcaseBeginDrag(index: 1)
                case "keyboard":
                    manager.showcaseFocus(index: 1)
                default:
                    break
                }
            }
        }
    }

    private static func makeImage(index: Int) -> CGImage? {
        let width = 960
        let height = 600
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }

        let palettes: [(start: CGColor, end: CGColor)] = [
            (
                CGColor(red: 0.16, green: 0.35, blue: 0.76, alpha: 1),
                CGColor(red: 0.36, green: 0.22, blue: 0.78, alpha: 1)
            ),
            (
                CGColor(red: 0.55, green: 0.25, blue: 0.72, alpha: 1),
                CGColor(red: 0.24, green: 0.47, blue: 0.62, alpha: 1)
            ),
            (
                CGColor(red: 0.84, green: 0.42, blue: 0.22, alpha: 1),
                CGColor(red: 0.72, green: 0.25, blue: 0.35, alpha: 1)
            ),
        ]
        let palette = palettes[index % palettes.count]

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        if let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [palette.start, palette.end] as CFArray,
            locations: [0, 1]
        ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: height),
                end: CGPoint(x: width, y: 0),
                options: []
            )
        }

        context.setFillColor(CGColor(gray: 1, alpha: 0.16))
        context.fill(CGRect(x: 0, y: height - 44, width: width, height: 44))
        context.fill(CGRect(x: 56, y: 120, width: 380, height: 26))
        context.fill(CGRect(x: 56, y: 176, width: 620, height: 18))
        context.fill(CGRect(x: 56, y: 216, width: 520, height: 18))
        context.fill(CGRect(x: 56, y: 300, width: 848, height: 200))

        return context.makeImage()
    }
}
#endif
