#if DEBUG
import AppKit
import SwiftUI
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

// MARK: - Showcase artwork

struct DemoThumbnailView: View {
    let index: Int

    var body: some View {
        ZStack {
            LinearGradient(
                colors: palette,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            content
        }
        .frame(width: 960, height: 600)
    }

    @ViewBuilder
    private var content: some View {
        switch index % 3 {
        case 0:
            ReceiptArtwork()
        case 1:
            CodeArtwork()
        default:
            DashboardArtwork()
        }
    }

    private var palette: [Color] {
        switch index % 3 {
        case 0:
            [
                Color(red: 0.16, green: 0.35, blue: 0.76),
                Color(red: 0.36, green: 0.22, blue: 0.78),
            ]
        case 1:
            [
                Color(red: 0.55, green: 0.25, blue: 0.72),
                Color(red: 0.24, green: 0.47, blue: 0.62),
            ]
        default:
            [
                Color(red: 0.84, green: 0.42, blue: 0.22),
                Color(red: 0.72, green: 0.25, blue: 0.35),
            ]
        }
    }
}

struct ReceiptArtwork: View {
    var body: some View {
        HStack {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 16) {
                Text("ORDER #4821")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("482 193")
                    .font(.system(size: 88, weight: .bold, design: .monospaced))
                    .foregroundStyle(.black)
                Text("Pickup code")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                Divider()
                Label("snapglass.app/pickup", systemImage: "link")
                    .font(.system(size: 20))
                Label("hello@snapglass.app", systemImage: "envelope")
                    .font(.system(size: 20))
            }
            .padding(40)
            .frame(width: 620, height: 460, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.white)
            )
            .shadow(color: .black.opacity(0.22), radius: 24, y: 12)
            Spacer(minLength: 0)
        }
        .padding(40)
    }
}

struct CodeArtwork: View {
    private let lines: [(text: String, color: Color)] = [
        ("struct Capture {", .purple),
        ("  let mode: CaptureMode", .blue),
        ("  let display: CGDirectDisplayID", .blue),
        ("", .clear),
        ("  func start() async throws {", .purple),
        ("    try await writer.begin()", .green),
        ("    try await stream.start()", .green),
        ("  }", .purple),
        ("}", .purple),
    ]

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text("SnapGlass")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                ForEach(["Sources", "Tests", "Docs"], id: \.self) { item in
                    Text(item)
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(width: 220, alignment: .leading)
            .background(.black.opacity(0.28))

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(lines.enumerated()), id: \.offset) { item in
                    Text(item.element.text.isEmpty ? " " : item.element.text)
                        .font(.system(size: 20, design: .monospaced))
                        .foregroundStyle(item.element.color)
                }
                Spacer(minLength: 0)
            }
            .padding(30)
        }
        .frame(width: 860, height: 520)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.black.opacity(0.72))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.12))
        }
        .shadow(color: .black.opacity(0.3), radius: 24, y: 12)
    }
}

struct DashboardArtwork: View {
    private let bars: [CGFloat] = [72, 104, 86, 138, 116, 158, 132]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Overview")
                    .font(.system(size: 24, weight: .bold))
                Spacer(minLength: 0)
                Text("Last 7 days")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(Array(bars.enumerated()), id: \.offset) { item in
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.accentColor.opacity(0.75))
                        .frame(width: 34, height: item.element)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 160, alignment: .bottom)
            HStack(spacing: 12) {
                StatTile(title: "Captures", value: "128")
                StatTile(title: "OCR", value: "96")
                StatTile(title: "Recordings", value: "12")
            }
        }
        .padding(28)
        .frame(width: 760, height: 480, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white)
        )
        .shadow(color: .black.opacity(0.22), radius: 24, y: 12)
        .foregroundStyle(.black)
    }
}

struct StatTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.black.opacity(0.05))
        )
    }
}

struct DemoEditorView: View {
    private let bars: [CGFloat] = [72, 104, 86, 138, 116, 158, 132]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(.red).frame(width: 10, height: 10)
                Circle().fill(.yellow).frame(width: 10, height: 10)
                Circle().fill(.green).frame(width: 10, height: 10)
                Spacer(minLength: 0)
                Text("snapglass.app/overview")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .frame(height: 38)
            .background(.white.opacity(0.9))

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("SnapGlass")
                        .font(.system(size: 20, weight: .bold))
                    ForEach(["Overview", "Captures", "OCR", "Recordings", "Settings"], id: \.self) {
                        Text($0)
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(24)
                .frame(width: 210, alignment: .leading)
                .background(.black.opacity(0.04))

                VStack(alignment: .leading, spacing: 22) {
                    Text("Overview")
                        .font(.system(size: 30, weight: .bold))
                    HStack(spacing: 14) {
                        StatTile(title: "Captures", value: "128")
                        StatTile(title: "OCR", value: "96")
                        StatTile(title: "Recordings", value: "12")
                    }
                    HStack(alignment: .bottom, spacing: 12) {
                        ForEach(Array(bars.enumerated()), id: \.offset) { item in
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.accentColor.opacity(0.75))
                                .frame(width: 44, height: item.element)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(height: 220, alignment: .bottom)
                }
                .padding(30)
            }
        }
        .frame(width: 1200, height: 800)
        .background(Color(red: 0.96, green: 0.96, blue: 0.97))
        .foregroundStyle(.black)
    }
}

struct RecordingStageView: View {
    let windowImage: NSImage
    let model: RecordingControlPanelModel
    let actions: RecordingControlPanelActions

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.05, blue: 0.09),
                    Color(red: 0.08, green: 0.10, blue: 0.18),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(nsImage: windowImage)
                .resizable()
                .scaledToFit()
                .frame(width: 860, height: 540)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.red.opacity(0.9), lineWidth: 2)
                }
                .shadow(color: .black.opacity(0.5), radius: 28, y: 16)

            VStack {
                Spacer(minLength: 0)
                RecordingControlPanelView(model: model, actions: actions)
                    .frame(width: 420, height: 56)
                    .padding(.bottom, 34)
            }
        }
        .frame(width: 1200, height: 760)
    }
}
#endif
