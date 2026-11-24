import AppKit
import CaptureCore
import OSLog
import SharedKit
import SwiftUI

/// What the floating recording control panel shows.
enum RecordingControlPanelState: Equatable {
    case preparing(kind: RecordingKind, phase: RecordingPreparationPhase)
    case countdown(Int)
    case starting(kind: RecordingKind, phase: RecordingStartPhase)
    case recording(startedAt: Date)
    case saving(kind: RecordingKind, fileName: String?, isBeforeQuit: Bool)
    case audioRecording(RecordingHUDPresentation, expanded: Bool, silenceWarning: Bool)
    case audioFinalizing(savedSegments: Int, previewReady: Bool, previewPlaying: Bool)
    case audioFinished(savedSegments: Int, outputURL: URL?, previewReady: Bool, previewPlaying: Bool)
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
    var onToggleAudioDetails: () -> Void
    var onPreview: () -> Void
    var onStopPreview: () -> Void
    var onOpenLatest: (URL?) -> Void
    var onOpenRecordings: () -> Void
    var onJoinExport: () -> Void
}

/// Observable state shared with the hosted SwiftUI view.
///
/// The panel updates this model instead of replacing `rootView`, so hover and timer state survive
/// every status tick.
@MainActor
final class RecordingControlPanelModel: ObservableObject {
    @Published var state: RecordingControlPanelState
    @Published var surfaceOpacity: Double
    @Published var hoverRestore: Bool
    /// Whether a persistent failure shows its full reason instead of one truncated line.
    @Published var failureExpanded = false
    /// Height of the scrollable reason column when the expanded error is too tall for the card.
    @Published var failureScrollHeight: CGFloat?

    /// Called after a change that alters the view's measured height, such as expanding a failure.
    var onLayoutChange: (@MainActor () -> Void)?

    init(state: RecordingControlPanelState, surfaceOpacity: Double, hoverRestore: Bool) {
        self.state = state
        self.surfaceOpacity = surfaceOpacity
        self.hoverRestore = hoverRestore
    }

    /// Expands or collapses the failure reason and asks the panel to remeasure.
    func toggleFailureExpansion() {
        failureExpanded.toggle()
        onLayoutChange?()
    }
}

/// The four-language text shared by the live HUD and its measurement view.
///
/// Both views resolve the same keys, so a measured size always matches what the live
/// capsule renders. Resetting a key here updates the size and the presentation together.
enum RecordingHUDLabels {
    /// The preparation step text for one capture kind.
    ///
    /// - Parameters:
    ///   - kind: The capture kind of the session.
    ///   - phase: The preparation step being shown.
    /// - Returns: The localized label.
    static func preparation(kind: RecordingKind, phase: RecordingPreparationPhase) -> String {
        switch phase {
        case .checkingPermission:
            if kind == .audio {
                return AppLocalization.string("Checking microphone access…")
            }
            return AppLocalization.string("Checking screen recording access…")
        case .waitingForAuthorization:
            return AppLocalization.string("Waiting for recording access…")
        case .loadingSources:
            return AppLocalization.string("Loading recording sources…")
        case .choosingSource:
            return AppLocalization.string("Waiting for a source selection…")
        case .verifyingDestination:
            return AppLocalization.string("Checking the recording folder…")
        }
    }

    /// Maps the truthful start stage to the four-language keys.
    ///
    /// `startingScreenWriter` is an in-flight start, not a preparation step; the
    /// first-frame phase only claims that the writer has not accepted a frame yet.
    ///
    /// - Parameter phase: The start stage being shown.
    /// - Returns: The localized label.
    static func starting(phase: RecordingStartPhase) -> String {
        switch phase {
        case .startingAudioPipeline:
            AppLocalization.string("Starting audio recording…")
        case .awaitingFirstAudioSample:
            AppLocalization.string("Waiting for the first audio sample…")
        case .startingScreenWriter:
            AppLocalization.string("Starting screen recording…")
        case .awaitingFirstVideoFrame:
            AppLocalization.string("Waiting for the first frame to be written…")
        }
    }

    /// The label for the audio sources being captured.
    ///
    /// - Parameter mode: The audio sources of the session.
    /// - Returns: The localized label.
    static func audioMode(_ mode: AudioSourceMode) -> String {
        switch mode {
        case .system: AppLocalization.string("System Audio")
        case .microphone: AppLocalization.string("Microphone")
        case .systemAndMicrophone: AppLocalization.string("System Audio + Microphone")
        case .none: AppLocalization.string("No Audio")
        }
    }

    /// The saving label, kept as a localization key so the injected locale resolves it.
    ///
    /// - Parameters:
    ///   - kind: The capture kind being saved.
    ///   - isBeforeQuit: Whether the save runs as part of quitting.
    /// - Returns: The localization key.
    static func saving(kind: RecordingKind, isBeforeQuit: Bool) -> LocalizedStringKey {
        if isBeforeQuit { return "Saving recording before quitting" }
        return kind == .audio ? "Saving audio recording" : "Saving screen recording"
    }
}

struct RecordingControlPanelView: View {
    @ObservedObject var model: RecordingControlPanelModel
    let actions: RecordingControlPanelActions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var hovered = false
    @State private var pulsing = false

    private var surfaceOpacity: Double {
        if model.hoverRestore, hovered { return 1 }
        return min(max(model.surfaceOpacity, RecordingHUDPreferences.opacityRange.lowerBound), 1)
    }

    var body: some View {
        if usesTallShape {
            decorated(
                RoundedRectangle(
                    cornerRadius: RecordingHUDMetrics.tallCornerRadius,
                    style: .continuous
                )
            )
        } else {
            decorated(Capsule(style: .continuous))
        }
    }

    /// A multi-line error would be clipped by a capsule of the same height, so it uses a
    /// rounded rectangle; every single-line state keeps the capsule silhouette.
    private var usesTallShape: Bool {
        guard case .failure = model.state else { return false }
        return model.failureExpanded
    }

    private func decorated<S: InsettableShape>(_ shape: S) -> some View {
        sizedSurface
            .glassSurface(
                shape,
                elevation: .floating,
                castsShadow: false,
                surfaceOpacity: surfaceOpacity
            )
            .contentShape(shape)
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: DS.Motion.fast), value: hovered)
            .accessibilityElement(children: .contain)
            .environment(\.locale, AppLocalization.locale())
    }

    /// Fills the window frame produced by the panel's size cache.
    ///
    /// Sizing happens in `RecordingControlPanelMeasureView`; this view only presents.
    @ViewBuilder
    private var sizedSurface: some View {
        if centersContent {
            // No internal spacer: split the spare width on both sides so the
            // measured capsule stays visually centered in the minimum width.
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                surface
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            surface.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    /// States without their own spacer keep the old centered capsule look.
    private var centersContent: Bool {
        switch model.state {
        case .recording, .notice, .audioRecording, .audioFinalizing, .audioFinished:
            true
        case .preparing, .countdown, .starting, .saving, .failure:
            false
        }
    }

    private var surface: some View {
        HStack(spacing: 8) {
            content
        }
        .padding(.horizontal, 12)
        .padding(.vertical, surfaceVerticalPadding)
    }

    /// Multi-line preparing/starting rows need breathing room; the stable recording
    /// capsule keeps zero vertical padding so its 40 pt height never changes.
    private var surfaceVerticalPadding: CGFloat {
        switch model.state {
        case .preparing, .starting: 6
        case .countdown, .recording, .saving, .audioRecording, .audioFinalizing, .audioFinished, .failure, .notice: 0
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case let .preparing(kind, phase):
            preparing(kind: kind, phase: phase)
        case let .countdown(seconds):
            countdown(seconds)
        case let .starting(_, phase):
            starting(phase: phase)
        case let .recording(startedAt):
            recording(startedAt: startedAt)
        case let .saving(kind, fileName, isBeforeQuit):
            saving(kind: kind, fileName: fileName, isBeforeQuit: isBeforeQuit)
        case let .audioRecording(presentation, expanded, silenceWarning):
            audioRecording(presentation, expanded: expanded, silenceWarning: silenceWarning)
        case let .audioFinalizing(savedSegments, previewReady, previewPlaying):
            audioFinalizing(savedSegments: savedSegments, previewReady: previewReady, previewPlaying: previewPlaying)
        case let .audioFinished(savedSegments, outputURL, previewReady, previewPlaying):
            audioFinished(
                savedSegments: savedSegments,
                outputURL: outputURL,
                previewReady: previewReady,
                previewPlaying: previewPlaying
            )
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
    private func preparing(kind: RecordingKind, phase: RecordingPreparationPhase) -> some View {
        spinner
        Text(RecordingHUDLabels.preparation(kind: kind, phase: phase))
            .font(.system(size: DS.Typography.t12, weight: .medium))
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
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
        .fixedSize()
        .help("Cancel Recording")
        .accessibilityLabel(Text("Cancel Recording"))
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
        .fixedSize()
        .help("Cancel Recording Countdown")
        .accessibilityLabel(Text("Cancel Recording Countdown"))
    }

    @ViewBuilder
    private func starting(phase: RecordingStartPhase) -> some View {
        spinner
        Text(RecordingHUDLabels.starting(phase: phase))
            .font(.system(size: DS.Typography.t12, weight: .medium))
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
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
        .fixedSize()
        .help("Cancel Recording")
        .accessibilityLabel(Text("Cancel Recording"))
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
            elapsedText(context.date.timeIntervalSince(startedAt))
        }
        .frame(minWidth: 56, alignment: .leading)

        Rectangle()
            .fill(.primary.opacity(0.15))
            .frame(width: 1, height: 18)
            .accessibilityHidden(true)

        stopButton
    }

    /// Renders the elapsed label.
    ///
    /// The width is reserved for `RecordingHUDWorstCaseText.duration` by the measurement
    /// view, so a ticking clock never resizes the window.
    private func elapsedText(_ elapsed: TimeInterval) -> some View {
        let value = RecordingHUDTimeFormatter.string(elapsed: elapsed)
        return Text(value)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .accessibilityLabel(Text("Elapsed recording time"))
            .accessibilityValue(Text(value))
    }

    @ViewBuilder
    private func saving(kind: RecordingKind, fileName: String?, isBeforeQuit: Bool) -> some View {
        spinner
        Text(RecordingHUDLabels.saving(kind: kind, isBeforeQuit: isBeforeQuit))
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

    private func audioRecording(
        _ source: RecordingHUDPresentation,
        expanded: Bool,
        silenceWarning: Bool
    ) -> some View {
        let presentation = source.resolvingAccessibility(
            reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency
        )
        let segmentNumber = presentation.segmentIndex + 1
        let elapsed = RecordingHUDTimeFormatter.string(elapsed: floor(presentation.duration))

        return HStack(spacing: 7) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)

            Text(elapsed)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(minWidth: 38, alignment: .leading)
                .accessibilityLabel(Text("Elapsed recording time"))
                .accessibilityValue(Text(elapsed))

            VStack(alignment: .leading, spacing: 3) {
                audioMeter(level: presentation.systemLevel, color: .accentColor)
                audioMeter(level: presentation.micLevel, color: .green)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Button(action: actions.onToggleAudioDetails) {
                    Text(
                        expanded
                            ? AppLocalization.string(
                                "%d saved · current segment %d",
                                presentation.savedCount,
                                segmentNumber
                            )
                            : AppLocalization.string("Segment %d", segmentNumber)
                    )
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help(AppLocalization.string("Show saved segment count and current segment"))
                .accessibilityLabel(Text(AppLocalization.string("Recording segment %d", segmentNumber)))
                .accessibilityValue(Text(AppLocalization.string("%d segments saved", presentation.savedCount)))

                if expanded {
                    Text(RecordingHUDLabels.audioMode(presentation.mode))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if silenceWarning {
                Label("No sound detected", systemImage: "speaker.slash.fill")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.orange)
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
            }

            stopButton
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Recording audio"))
        .accessibilityValue(Text(AppLocalization.string(
            "Audio recording status: %@ · %d saved · Segment %d",
            elapsed,
            presentation.savedCount,
            segmentNumber
        )))
    }

    private func audioMeter(level: Float, color: Color) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(level == 0 ? 0.3 : 0.18))
                Capsule()
                    .fill(color.opacity(level == 0 ? 0.3 : 1))
                    .frame(width: geometry.size.width * CGFloat(level))
            }
        }
        .frame(width: 30, height: 3)
        .accessibilityHidden(true)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: level)
    }

    private func audioFinalizing(
        savedSegments: Int,
        previewReady: Bool,
        previewPlaying: Bool
    ) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text("Organizing recording…")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Text(AppLocalization.string("%d segments saved", savedSegments))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if previewReady {
                previewButton(isPlaying: previewPlaying)
            } else {
                Text("Preparing preview…")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            closeWhileSavingButton
        }
        .accessibilityElement(children: .contain)
    }

    private func audioFinished(
        savedSegments: Int,
        outputURL: URL?,
        previewReady: Bool,
        previewPlaying: Bool
    ) -> some View {
        HStack(spacing: 7) {
            if savedSegments > 1 {
                Button("Open Recordings", action: actions.onOpenRecordings)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .frame(minHeight: 28)
            } else {
                Button("Open") { actions.onOpenLatest(outputURL) }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .frame(minHeight: 28)
                    .disabled(outputURL == nil)
            }

            Button("Show in Finder") { actions.onReveal(outputURL) }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .frame(minHeight: 28)
                .disabled(outputURL == nil)

            Button("Combine & Export", action: actions.onJoinExport)
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .frame(minHeight: 28)
                .disabled(savedSegments < 2)

            if previewReady {
                previewButton(isPlaying: previewPlaying)
            }
            closeWhileSavingButton
        }
        .accessibilityElement(children: .contain)
    }

    private func previewButton(isPlaying: Bool) -> some View {
        Button(action: isPlaying ? actions.onStopPreview : actions.onPreview) {
            Label(
                previewLabel(isPlaying: isPlaying),
                systemImage: isPlaying ? "stop.fill" : "play.fill"
            )
            .labelStyle(.titleAndIcon)
            .font(.system(size: 10, weight: .medium))
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .frame(minHeight: 28)
        .accessibilityLabel(Text(audioPreviewAccessibilityLabel(isPlaying: isPlaying)))
    }

    /// A ternary of string literals can lose its localization key; return the key explicitly.
    private func previewLabel(isPlaying: Bool) -> LocalizedStringKey {
        isPlaying ? "Stop preview" : "Preview"
    }

    private func audioPreviewAccessibilityLabel(isPlaying: Bool) -> LocalizedStringKey {
        isPlaying ? "Stop audio preview" : "Preview recording"
    }

    private var closeWhileSavingButton: some View {
        Button(action: actions.onHideWhileSaving) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 28, height: 28)
                .background(Circle().fill(.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help("Close")
        .accessibilityLabel(Text("Close"))
    }

    @ViewBuilder
    private func failureView(_ failure: RecordingControlPanelFailure) -> some View {
        if model.failureExpanded {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    failureIcon
                    if let scrollHeight = model.failureScrollHeight {
                        ScrollView(.vertical, showsIndicators: true) {
                            expandedFailureText(failure)
                        }
                        .frame(height: scrollHeight)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        expandedFailureText(failure)
                    }
                }
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    failureActions(failure, expanded: true)
                }
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            failureIcon
            Text(failure.reason)
                .font(.system(size: DS.Typography.t12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
                .help(failure.reason)
                .accessibilityLabel(Text(failure.reason))

            Spacer(minLength: 4)

            failureActions(failure, expanded: false)
        }
    }

    private var failureIcon: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.red)
            .accessibilityHidden(true)
    }

    private func expandedFailureText(_ failure: RecordingControlPanelFailure) -> some View {
        Text(failure.reason)
            .font(.system(size: DS.Typography.t12, weight: .medium))
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
            .accessibilityLabel(Text(failure.reason))
    }

    private func errorDetailsLabel(expanded: Bool) -> LocalizedStringKey {
        expanded ? "Hide Error Details" : "Show Error Details"
    }

    @ViewBuilder
    private func failureActions(_ failure: RecordingControlPanelFailure, expanded: Bool) -> some View {
        if failure.canRetry {
            Button("Retry", action: actions.onRetry)
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
                .tint(.red)
                .fixedSize()
        }

        Button { actions.onReveal(failure.partialURL) } label: {
            Image(systemName: "folder")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Show in Finder")
        .accessibilityLabel(Text("Show in Finder"))

        Button { model.toggleFailureExpansion() } label: {
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(errorDetailsLabel(expanded: expanded))
        .accessibilityLabel(Text(errorDetailsLabel(expanded: expanded)))

        Button(action: actions.onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Close")
        .accessibilityLabel(Text("Close"))
    }

    private var stopButton: some View {
        Button(action: actions.onStop) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.red)
                .frame(width: 28, height: 28)
                .overlay {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(.white)
                        .frame(width: 8, height: 8)
                }
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Stop and Save")
        .accessibilityLabel(Text("Stop and Save"))
    }

    private var spinner: some View {
        ProgressView()
            .controlSize(.small)
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
    }
}
