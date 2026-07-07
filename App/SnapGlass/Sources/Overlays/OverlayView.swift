import SwiftUI

enum OverlayCaptureMode: String, CaseIterable {
    case area
    case window
    case fullscreen
    case scroll
}

struct CaptureToolbarView: View {
    @Binding var mode: OverlayCaptureMode

    var body: some View {
        HStack(spacing: 12) {
            ForEach(OverlayCaptureMode.allCases, id: \.self) { captureMode in
                Button(action: { mode = captureMode }) {
                    Image(systemName: iconFor(mode: captureMode))
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func iconFor(mode: OverlayCaptureMode) -> String {
        switch mode {
        case .area: return "rectangle.dashed"
        case .window: return "macwindow"
        case .fullscreen: return "rectangle.fill"
        case .scroll: return "rectangle.stack"
        }
    }
}
