import CaptureCore
import SwiftUI

/// Menu-bar label for SnapGlass.
///
/// ControlCenter renders this label in a remote status-item scene, not in the
/// app's own window. It must stay static: no `TimelineView`, no timers, and no
/// width change when a recording starts. A live timeline here blocks the main
/// thread on the remote scene's fence (observed as a hang immediately after the
/// `.recording` transition). The elapsed time belongs in the popover instead.
///
/// The recording dot is deliberately drawn in SwiftUI rather than baked into a
/// symbol so the label keeps system sizing and accessibility behaviour. A filled
/// record glyph and a separate saving glyph still distinguish the states if the
/// system flattens custom colours to a template.
struct MenuBarStatusLabel: View {
    let status: RecordingSessionStatus
    let isCapturing: Bool
    /// The active recording kind, when one is preparing, recording, or saving.
    var recordingKind: RecordingKind?
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
        .frame(minWidth: 28)
        .frame(height: 18)
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
            return recordingKind == .audio
                ? Text("Preparing audio recording")
                : Text("Preparing screen recording")
        case .recording:
            return recordingKind == .audio ? Text("Recording audio") : Text("Recording screen")
        case .saving:
            return recordingKind == .audio
                ? Text("Saving audio recording")
                : Text("Saving screen recording")
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
