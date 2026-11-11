import AppKit
import CaptureCore
import SharedKit
import SwiftUI

/// What the floating recording control panel shows.
enum RecordingControlPanelState: Equatable {
    case countdown(Int)
    case starting
    case recording(startedAt: Date)
    case saving(fileName: String?)
    case failure(RecordingControlPanelFailure)
    case notice(String)
}

/// A persistent recording failure the panel can act on.
struct RecordingControlPanelFailure: Equatable {
    let reason: String
    let canRetry: Bool
    let partialURL: URL?
}

/// User actions the panel forwards to the session controller.
struct RecordingControlPanelActions {
    var onCancel: () -> Void
    var onStop: () -> Void
    var onRetry: () -> Void
    var onReveal: (URL?) -> Void
    var onDismiss: () -> Void
    var onHideWhileSaving: () -> Void
    var onCornerChange: (RecordingHUDCorner) -> Void
}

/// Observable state shared with the hosted SwiftUI view.
///
/// The panel updates this model instead of replacing `rootView`, so hover and timer state survive
/// every status tick.
@MainActor
private final class RecordingControlPanelModel: ObservableObject {
    @Published var state: RecordingControlPanelState
    @Published var surfaceOpacity: Double
    @Published var hoverRestore: Bool

    init(state: RecordingControlPanelState, surfaceOpacity: Double, hoverRestore: Bool) {
        self.state = state
        self.surfaceOpacity = surfaceOpacity
        self.hoverRestore = hoverRestore
    }
}

private struct RecordingControlPanelView: View {
    @ObservedObject var model: RecordingControlPanelModel
    let actions: RecordingControlPanelActions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    @State private var pulsing = false

    private var size: CGSize {
        switch model.state {
        case .countdown: RecordingHUDMetrics.countdownSize
        case .starting, .recording: RecordingHUDMetrics.recordingSize
        case .saving: RecordingHUDMetrics.savingSize
        case .failure: RecordingHUDMetrics.failureSize
        case .notice: RecordingHUDMetrics.noticeSize
        }
    }

    private var surfaceOpacity: Double {
        if model.hoverRestore, hovered { return 1 }
        return min(max(model.surfaceOpacity, RecordingHUDPreferences.opacityRange.lowerBound), 1)
    }

    var body: some View {
        HStack(spacing: 8) {
            content
        }
        .padding(.horizontal, 12)
        .frame(width: size.width, height: size.height)
        .glassSurface(
            Capsule(style: .continuous),
            elevation: .floating,
            castsShadow: false,
            surfaceOpacity: surfaceOpacity
        )
        .contentShape(Capsule(style: .continuous))
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: DS.Motion.fast), value: hovered)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case let .countdown(seconds):
            countdown(seconds)
        case .starting:
            spinner
            Text("Starting recording…")
                .font(.system(size: DS.Typography.t12, weight: .medium))
                .lineLimit(1)
        case let .recording(startedAt):
            recording(startedAt: startedAt)
        case let .saving(fileName):
            saving(fileName: fileName)
        case let .failure(failure):
            failureView(failure)
        case let .notice(text):
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: DS.Typography.t12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
        }
    }

    @ViewBuilder
    private func countdown(_ seconds: Int) -> some View {
        ZStack {
            Circle()
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 2)
            Text("\(seconds)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.orange)
        }
        .frame(width: 20, height: 20)

        Text("Starting in \(seconds) seconds")
            .font(.system(size: DS.Typography.t12, weight: .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.9)
            .layoutPriority(1)

        Spacer(minLength: 4)

        Button(action: actions.onCancel) {
            Text("Cancel")
                .font(.system(size: DS.Typography.t12, weight: .medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help("Cancel Recording Countdown")
        .accessibilityLabel(Text("Cancel Recording Countdown"))
    }

    @ViewBuilder
    private func recording(startedAt: Date) -> some View {
        Circle()
            .fill(Color.red)
            .frame(width: 10, height: 10)
            .opacity(reduceMotion ? 1 : (pulsing ? 0.4 : 1))
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                value: pulsing
            )
            .onAppear { pulsing = !reduceMotion }
            .accessibilityHidden(true)

        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(RecordingHUDTimeFormatter.string(elapsed: context.date.timeIntervalSince(startedAt)))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .frame(minWidth: 44, alignment: .leading)

        Rectangle()
            .fill(.primary.opacity(0.15))
            .frame(width: 1, height: 18)

        stopButton
    }

    @ViewBuilder
    private func saving(fileName: String?) -> some View {
        spinner
        Text("Saving recording…")
            .font(.system(size: DS.Typography.t12, weight: .medium))
            .lineLimit(1)

        if let fileName {
            Text(fileName)
                .font(.system(size: DS.Typography.t11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 64)
        }

        Spacer(minLength: 2)

        Button(action: actions.onHideWhileSaving) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help("Close")
        .accessibilityLabel(Text("Close"))
    }

    @ViewBuilder
    private func failureView(_ failure: RecordingControlPanelFailure) -> some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.red)

        Text(failure.reason)
            .font(.system(size: DS.Typography.t12, weight: .medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .layoutPriority(1)

        Spacer(minLength: 4)

        if failure.canRetry {
            Button("Retry", action: actions.onRetry)
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
                .tint(.red)
        }

        Button { actions.onReveal(failure.partialURL) } label: {
            Image(systemName: "folder")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help("Show in Finder")
        .accessibilityLabel(Text("Show in Finder"))

        Button(action: actions.onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help("Close")
        .accessibilityLabel(Text("Close"))
    }

    private var stopButton: some View {
        Button(action: actions.onStop) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.red)
                .frame(width: 22, height: 22)
                .overlay {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(.white)
                        .frame(width: 8, height: 8)
                }
        }
        .buttonStyle(.plain)
        .help("Stop and Save")
        .accessibilityLabel(Text("Stop and Save"))
    }

    private var spinner: some View {
        ProgressView()
            .controlSize(.small)
            .frame(width: 16, height: 16)
    }
}

/// Floating capsule that reports and controls one screen recording.
///
/// The window is exactly the size of the capsule and relies on the system window shadow
/// (`hasShadow = true`), so the shadow is drawn outside the window and can never be clipped by the
/// frame. Opacity applies to the surface only; text keeps full contrast.
@MainActor
final class RecordingControlPanel: NSPanel, NSWindowDelegate {
    private let actions: RecordingControlPanelActions
    private let model: RecordingControlPanelModel
    private let hostingView: NSHostingView<RecordingControlPanelView>
    private var screenFrame: CGRect
    private var corner: RecordingHUDCorner
    private var isProgrammaticMove = false
    private var snapTask: Task<Void, Never>?

    var excludedWindowIDs: Set<CGWindowID> {
        guard windowNumber > 0 else { return [] }
        return [CGWindowID(windowNumber)]
    }

    init(
        on screen: NSScreen?,
        corner: RecordingHUDCorner,
        opacity: Double,
        hoverRestore: Bool,
        actions: RecordingControlPanelActions
    ) {
        let screenFrame = screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let model = RecordingControlPanelModel(
            state: .countdown(3),
            surfaceOpacity: opacity,
            hoverRestore: hoverRestore
        )
        let hostingView = NSHostingView(rootView: RecordingControlPanelView(model: model, actions: actions))
        let size = RecordingHUDMetrics.countdownSize
        let origin = RecordingHUDPlacement.origin(for: corner, size: size, in: screenFrame)

        self.actions = actions
        self.model = model
        self.hostingView = hostingView
        self.screenFrame = screenFrame
        self.corner = corner

        super.init(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        sharingType = ShowcaseMode.isEnabled ? .readOnly : .none
        delegate = self
        contentView = hostingView
    }

    override func orderFrontRegardless() {
        super.orderFrontRegardless()
        // `sharingType` is per-window and can be reset by ordering.
        sharingType = ShowcaseMode.isEnabled ? .readOnly : .none
    }

    /// Borderless panels must keep their exact frame near screen edges.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    func present(state: RecordingControlPanelState) {
        update(state: state)
        orderFrontRegardless()
    }

    func update(state: RecordingControlPanelState) {
        guard model.state != state else { return }
        model.state = state
        resize(for: state)
    }

    func updateAppearance(opacity: Double, hoverRestore: Bool) {
        model.surfaceOpacity = opacity
        model.hoverRestore = hoverRestore
    }

    func dismiss() {
        snapTask?.cancel()
        snapTask = nil
        orderOut(nil)
    }

    func windowDidMove(_ notification: Notification) {
        guard !isProgrammaticMove else { return }
        snapTask?.cancel()
        snapTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.snapToCorner()
        }
    }

    private func snapToCorner() {
        let newCorner = RecordingHUDPlacement.nearestCorner(
            to: frame.origin,
            size: frame.size,
            in: screenFrame
        )
        if newCorner != corner {
            corner = newCorner
            actions.onCornerChange(newCorner)
        }
        let origin = RecordingHUDPlacement.origin(for: corner, size: frame.size, in: screenFrame)
        guard origin != frame.origin else { return }
        isProgrammaticMove = true
        setFrameOrigin(origin)
        isProgrammaticMove = false
    }

    private func resize(for state: RecordingControlPanelState) {
        let size = Self.size(for: state)
        guard frame.size != size else { return }
        let origin = RecordingHUDPlacement.origin(for: corner, size: size, in: screenFrame)
        isProgrammaticMove = true
        setFrame(CGRect(origin: origin, size: size), display: true)
        isProgrammaticMove = false
    }

    private static func size(for state: RecordingControlPanelState) -> CGSize {
        switch state {
        case .countdown: RecordingHUDMetrics.countdownSize
        case .starting, .recording: RecordingHUDMetrics.recordingSize
        case .saving: RecordingHUDMetrics.savingSize
        case .failure: RecordingHUDMetrics.failureSize
        case .notice: RecordingHUDMetrics.noticeSize
        }
    }
}
