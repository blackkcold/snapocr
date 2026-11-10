import CaptureCore
import SwiftUI

/// Menu-bar label for SnapGlass.
///
/// The recording dot is deliberately drawn in SwiftUI rather than baked into a symbol so the
/// label keeps system sizing and accessibility behaviour. A filled record glyph and a separate
/// saving glyph still distinguish the states if the system flattens custom colours to a template.
struct MenuBarStatusLabel: View {
    let status: RecordingSessionStatus
    let isCapturing: Bool

    private var indicator: RecordingMenuBarIndicator {
        status.menuBarIndicator(isCapturing: isCapturing)
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: indicator.systemImage)
                .font(.system(size: 14, weight: .regular))

            if indicator.showsRecordingDot {
                recordingDot
            } else {
                // Keep the slot reserved so the status item does not shift when a recording
                // starts or stops.
                Color.clear
                    .frame(width: 5, height: 5)
            }
        }
        .frame(width: 28, height: 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("SnapGlass"))
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: Text {
        switch indicator {
        case .camera:
            Text("")
        case .capturing:
            Text("Capturing")
        case .preparing:
            Text("Preparing the recording stream.")
        case .recording:
            Text("Recording")
        case .saving:
            Text("Saving Recording…")
        }
    }

    private var recordingDot: some View {
        Circle()
            .fill(.red)
            .frame(width: 5, height: 5)
            .overlay {
                Circle()
                    .strokeBorder(.white.opacity(0.65), lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }
}
