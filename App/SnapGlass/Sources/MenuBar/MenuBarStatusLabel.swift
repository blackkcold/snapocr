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
    var hasFailure: Bool = false
    /// A verified update is waiting; the dot is only shown when no recording
    /// indicator occupies the slot.
    var hasUpdate: Bool = false

    private var indicator: RecordingMenuBarIndicator {
        status.menuBarIndicator(isCapturing: isCapturing, hasFailure: hasFailure)
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: indicator.systemImage)
                .font(.system(size: 14, weight: .regular))

            if indicator.showsRecordingDot {
                recordingDot
            } else if hasUpdate {
                updateDot
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
        if hasUpdate && !indicator.showsRecordingDot {
            return Text("Update available")
        }
        switch indicator {
        case .camera:
            return Text("")
        case .capturing:
            return Text("Capturing")
        case .preparing:
            return Text("Preparing the recording stream.")
        case .recording:
            return Text("Recording")
        case .saving:
            return Text("Saving Recording…")
        case .failed:
            return Text("Recording failed")
        }
    }

    private var updateDot: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 5, height: 5)
            .accessibilityHidden(true)
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
