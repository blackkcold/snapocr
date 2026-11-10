import AppKit
import SharedKit
import SwiftUI

enum RecordingControlPanelState: Equatable {
    case countdown(Int)
    case starting
    case recording
    case saving
}

private struct RecordingControlPanelView: View {
    let state: RecordingControlPanelState
    let onCancel: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            statusIndicator

            VStack(alignment: .leading, spacing: 3) {
                Text(statusTitle)
                    .font(.headline)
                statusSubtitle
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            switch state {
            case .countdown:
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
            case .recording:
                Button("Stop and Save", action: onStop)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            case .starting, .saving:
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .frame(width: 350, height: 76)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.2), radius: 14, y: 5)
        .padding(4)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch state {
        case .countdown(let seconds):
            Text("\(seconds)")
                .font(.system(size: 27, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.orange)
                .frame(width: 36)
        case .starting, .recording, .saving:
            Circle()
                .fill(state == .recording ? Color.red : Color.orange)
                .frame(width: 11, height: 11)
                .frame(width: 36)
        }
    }

    private var statusTitle: LocalizedStringKey {
        switch state {
        case .countdown(let seconds): "Starting in \(seconds) seconds"
        case .starting: "Starting recording…"
        case .recording: "Recording"
        case .saving: "Saving recording…"
        }
    }

    @ViewBuilder
    private var statusSubtitle: some View {
        switch state {
        case .countdown:
            Text("Choose Cancel to stop before recording starts.")
        case .starting:
            Text("Preparing the recording stream.")
        case .recording:
            Text("The recording is saved when you stop.")
        case .saving:
            Text("Finalizing and publishing the MP4.")
        }
    }
}

@MainActor
final class RecordingControlPanel: NSPanel {
    private var hostingView: NSHostingView<RecordingControlPanelView>?
    private let onCancel: () -> Void
    private let onStop: () -> Void

    var excludedWindowIDs: Set<CGWindowID> {
        guard windowNumber > 0 else { return [] }
        return [CGWindowID(windowNumber)]
    }

    init(
        on screen: NSScreen?,
        onCancel: @escaping () -> Void,
        onStop: @escaping () -> Void
    ) {
        self.onCancel = onCancel
        self.onStop = onStop
        let panelSize = NSSize(width: 358, height: 84)
        let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 900, height: 700)
        let origin = NSPoint(
            x: visibleFrame.maxX - panelSize.width - 18,
            y: visibleFrame.maxY - panelSize.height - 18
        )

        super.init(
            contentRect: NSRect(origin: origin, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        sharingType = ShowcaseMode.isEnabled ? .readOnly : .none
        let hostingView = NSHostingView(rootView: makeRootView(state: .countdown(3)))
        self.hostingView = hostingView
        contentView = hostingView
    }

    func present(state: RecordingControlPanelState) {
        update(state: state)
        orderFrontRegardless()
    }

    func update(state: RecordingControlPanelState) {
        hostingView?.rootView = makeRootView(state: state)
    }

    func dismiss() {
        orderOut(nil)
    }

    private func makeRootView(state: RecordingControlPanelState) -> RecordingControlPanelView {
        RecordingControlPanelView(
            state: state,
            onCancel: onCancel,
            onStop: onStop
        )
    }
}
