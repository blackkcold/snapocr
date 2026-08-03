import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: generate-dmg-background.swift OUTPUT.png\n".utf8))
    exit(1)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let pointSize = NSSize(width: 800, height: 500)
let scale = 2

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(pointSize.width) * scale,
    pixelsHigh: Int(pointSize.height) * scale,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    FileHandle.standardError.write(Data("Unable to create DMG background bitmap.\n".utf8))
    exit(1)
}

bitmap.size = pointSize
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

let bounds = NSRect(origin: .zero, size: pointSize)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.035, green: 0.055, blue: 0.11, alpha: 1),
    NSColor(calibratedRed: 0.06, green: 0.16, blue: 0.29, alpha: 1),
    NSColor(calibratedRed: 0.035, green: 0.32, blue: 0.44, alpha: 1),
])
gradient?.draw(in: bounds, angle: 18)

NSColor.white.withAlphaComponent(0.035).setFill()
for row in 0..<7 {
    for column in 0..<11 where (row + column).isMultiple(of: 3) {
        let rect = NSRect(
            x: CGFloat(column) * 82 - 20,
            y: CGFloat(row) * 76 - 18,
            width: 120,
            height: 120
        )
        NSBezierPath(ovalIn: rect).fill()
    }
}

let centered = NSMutableParagraphStyle()
centered.alignment = .center

let titleAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 38, weight: .bold),
    .foregroundColor: NSColor.white,
    .paragraphStyle: centered,
]
NSString(string: "SnapGlass").draw(
    in: NSRect(x: 160, y: 408, width: 480, height: 52),
    withAttributes: titleAttributes
)

let subtitleAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 16, weight: .medium),
    .foregroundColor: NSColor.white.withAlphaComponent(0.72),
    .paragraphStyle: centered,
]
NSString(string: "Capture clearly. Install simply.").draw(
    in: NSRect(x: 160, y: 376, width: 480, height: 28),
    withAttributes: subtitleAttributes
)

let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 310, y: 245))
arrow.line(to: NSPoint(x: 490, y: 245))
arrow.move(to: NSPoint(x: 468, y: 263))
arrow.line(to: NSPoint(x: 490, y: 245))
arrow.line(to: NSPoint(x: 468, y: 227))
arrow.lineWidth = 5
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
NSColor.white.withAlphaComponent(0.78).setStroke()
arrow.stroke()

let hintAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
    .foregroundColor: NSColor.white.withAlphaComponent(0.78),
    .paragraphStyle: centered,
]
NSString(string: "Drag SnapGlass to Applications").draw(
    in: NSRect(x: 240, y: 116, width: 320, height: 28),
    withAttributes: hintAttributes
)

NSGraphicsContext.restoreGraphicsState()

guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("Unable to encode DMG background PNG.\n".utf8))
    exit(1)
}

try pngData.write(to: outputURL, options: .atomic)
