import SwiftUI

/// A sketch of the menu bar with the camera icon highlighted.
///
/// Drawn rather than screenshotted: the real icon position depends on how many
/// other menu-bar items the user runs, so a screenshot would show the wrong place
/// for almost everyone.
struct MenuBarDiagram: View {
    /// Width the diagram may use.
    var width: CGFloat = 420

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.s10) {
                // Placeholder app menu titles, dimmed so they read as "other apps".
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(.secondary.opacity(0.22))
                        .frame(width: [26, 34, 30][index], height: 6)
                }
                Spacer(minLength: 0)
                // Other menu-bar items, dimmed.
                ForEach(0..<6, id: \.self) { _ in
                    Circle()
                        .fill(.secondary.opacity(0.22))
                        .frame(width: 8, height: 8)
                }
                // The highlighted camera icon.
                ZStack {
                    RoundedRectangle(cornerRadius: DS.Corner.c6)
                        .fill(Color.accentColor.opacity(0.18))
                        .frame(width: 26, height: 20)
                    Image(systemName: "camera.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                Circle()
                    .fill(.secondary.opacity(0.22))
                    .frame(width: 8, height: 8)
            }
            .padding(.horizontal, DS.Space.s10)
            .frame(height: 28)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: DS.Corner.c6))
            .overlay(alignment: .bottom) {
                // The pointer, so the highlight is unambiguous.
                Triangle()
                    .fill(Color.accentColor.opacity(0.55))
                    .frame(width: 10, height: 6)
                    .offset(x: 78, y: 6)
            }

            // The desktop below, to show the menu bar is the top edge.
            RoundedRectangle(cornerRadius: DS.Corner.c8)
                .fill(.quaternary.opacity(0.16))
                .frame(height: 52)
                .padding(.top, DS.Space.s10)
        }
        .frame(width: width)
        // Every shape here is decoration; the page's text carries the meaning. Without
        // this, VoiceOver would read out a string of anonymous capsules and circles.
        .accessibilityHidden(true)
    }
}

/// A downward-pointing triangle.
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// Selection → shelf → any app, as three connected steps.
struct CaptureFlowDiagram: View {
    /// Width the diagram may use.
    var width: CGFloat = 440

    private var steps: [(symbol: String, caption: String)] {
        [
            ("viewfinder", AppLocalization.string("Select an area")),
            ("rectangle.on.rectangle", AppLocalization.string("It lands in the shelf")),
            ("arrow.up.forward.app", AppLocalization.string("Drag it anywhere")),
        ]
    }

    var body: some View {
        HStack(spacing: DS.Space.s8) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                VStack(spacing: DS.Space.s6) {
                    ZStack {
                        RoundedRectangle(cornerRadius: DS.Corner.c10)
                            .fill(.quaternary.opacity(0.28))
                            .frame(width: 72, height: 56)
                        Image(systemName: step.symbol)
                            .font(.system(size: 22, weight: .regular))
                            .foregroundStyle(Color.accentColor)
                    }
                    Text(step.caption)
                        .font(DS.Typography.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(width: 92)
                }
                if index < steps.count - 1 {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, DS.Space.s16)
                }
            }
        }
        .frame(width: width)
        // Decorative only: the three captions inside are read as one description
        // below, so the shapes and arrows must not be announced individually.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text(LocalizedStringKey("Select an area, it lands in the shelf, then drag it into any app."))
        )
    }
}

/// The recording control strip, as it appears near the menu bar.
struct RecordingDiagram: View {
    /// Width the diagram may use.
    var width: CGFloat = 420

    var body: some View {
        HStack(spacing: DS.Space.s12) {
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.9))
                    .frame(width: 22, height: 22)
                Circle()
                    .fill(.white)
                    .frame(width: 7, height: 7)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("00:12")
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                Text(AppLocalization.string("Screen and audio"))
                    .font(DS.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack(spacing: DS.Space.s10) {
                ForEach(["mic.fill", "speaker.wave.2.fill", "stop.fill"], id: \.self) { symbol in
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, DS.Space.s14)
        .frame(width: width, height: 44)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: DS.Corner.c12))
    }
}
