import CaptureCore
import SwiftUI

/// How the measurement view is sized by its hosting controller.
enum RecordingControlPanelMeasureSizing: Equatable {
    /// Sizes to its ideal content width and height; used for the width pass.
    case ideal
    /// Lays out at an exact width with unlimited height; used for the height pass.
    case fixedWidth(CGFloat)
}

/// A layout-only twin of `RecordingControlPanelView`, rendered from a signature.
///
/// It shares the live view's labels, fonts, paddings, and control sizes, but every
/// effect that could start real work is replaced by a static stand-in: a solid
/// background instead of `glassEffect`, a 16 × 16 placeholder instead of `ProgressView`,
/// fixed-width meter bars instead of `GeometryReader`, and no `.animation`. Measuring it
/// therefore never starts a glass render, an implicit animation, or a geometry pass.
///
/// It also renders every changing value at its widest form
/// (`RecordingHUDWorstCaseText`), which is what makes one measurement valid for the
/// whole time the state is on screen.
struct RecordingControlPanelMeasureView: View {
    let signature: RecordingHUDLayoutSignature
    let sizing: RecordingControlPanelMeasureSizing
    /// Height of the scrollable reason column an expanded failure needs, when already known.
    let failureScrollHeight: CGFloat?

    var body: some View {
        surface
            .background(Color.black)
            .modifier(MeasureSizingModifier(sizing: sizing))
            .environment(\.locale, AppLocalization.locale())
    }

    /// The same row and padding as the live surface, so the measured size is the drawn size.
    private var surface: some View {
        HStack(spacing: 8) {
            content
        }
        .padding(.horizontal, 12)
        .padding(.vertical, verticalPadding)
    }

    private var verticalPadding: CGFloat {
        switch signature.content {
        case .preparing, .starting: 6
        default: 0
        }
    }

    @ViewBuilder
    private var content: some View {
        switch signature.content {
        case let .preparing(kind, phase):
            spinnerPlaceholder
            stepText(RecordingHUDLabels.preparation(kind: kind, phase: phase))
            Spacer(minLength: 4)
            cancelButton
        case .countdown:
            countdownBadge
            Text("Starting in \(RecordingHUDWorstCaseText.countdownSeconds) seconds")
                .font(.system(size: DS.Typography.t12, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .layoutPriority(1)
            Spacer(minLength: 4)
            cancelButton
        case let .starting(_, phase):
            spinnerPlaceholder
            stepText(RecordingHUDLabels.starting(phase: phase))
            Spacer(minLength: 4)
            cancelButton
        case .recording:
            recordingRow
        case let .saving(kind, showsFileName, isBeforeQuit):
            spinnerPlaceholder
            Text(RecordingHUDLabels.saving(kind: kind, isBeforeQuit: isBeforeQuit))
                .font(.system(size: DS.Typography.t12, weight: .medium))
                .lineLimit(1)
            if showsFileName {
                // The live row truncates the name at 64 pt, so any name wider than that
                // measures the same width.
                Text(verbatim: "recording-file.mov")
                    .font(.system(size: DS.Typography.t11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 64)
            }
            Spacer(minLength: 2)
            closeButton
        case let .audioRecording(mode, expanded, silenceWarning):
            audioRecordingRow(mode: mode, expanded: expanded, silenceWarning: silenceWarning)
        case let .audioFinalizing(previewReady, previewPlaying):
            audioFinalizingRow(previewReady: previewReady, previewPlaying: previewPlaying)
        case let .audioFinished(showsPreview, previewPlaying, offersRecordingsList):
            audioFinishedRow(
                showsPreview: showsPreview,
                previewPlaying: previewPlaying,
                offersRecordingsList: offersRecordingsList
            )
        case let .failure(expanded, canRetry, reason):
            failureRow(expanded: expanded, canRetry: canRetry, reason: reason)
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

    private func stepText(_ value: String) -> some View {
        Text(value)
            .font(.system(size: DS.Typography.t12, weight: .medium))
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
    }

    @ViewBuilder
    private var recordingRow: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 10, height: 10)
        Text(verbatim: RecordingHUDWorstCaseText.duration)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .frame(minWidth: 56, alignment: .leading)
        Rectangle()
            .fill(.primary.opacity(0.15))
            .frame(width: 1, height: 18)
        stopButton
    }

    @ViewBuilder
    private func audioRecordingRow(
        mode: AudioSourceMode,
        expanded: Bool,
        silenceWarning: Bool
    ) -> some View {
        Circle()
            .fill(Color.red)
            .frame(width: 8, height: 8)
        Text(verbatim: RecordingHUDWorstCaseText.duration)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .frame(minWidth: 38, alignment: .leading)
        VStack(alignment: .leading, spacing: 3) {
            meterBar
            meterBar
        }
        VStack(alignment: .leading, spacing: 1) {
            Button(
                action: {},
                label: {
                    Text(
                        expanded
                            ? AppLocalization.string(
                                "%d saved · current segment %d",
                                RecordingHUDWorstCaseText.savedSegments,
                                RecordingHUDWorstCaseText.segmentNumber
                            )
                            : AppLocalization.string(
                                "Segment %d",
                                RecordingHUDWorstCaseText.segmentNumber
                            )
                    )
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                }
            )
            .buttonStyle(.plain)

            if expanded {
                Text(RecordingHUDLabels.audioMode(mode))
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

    private func audioFinalizingRow(previewReady: Bool, previewPlaying: Bool) -> some View {
        HStack(spacing: 8) {
            spinnerPlaceholder
            VStack(alignment: .leading, spacing: 1) {
                Text("Organizing recording…")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Text(makeSegmentCountText())
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
    }

    /// The saved-segment line, measured at the widest count the HUD can draw.
    private func makeSegmentCountText() -> String {
        AppLocalization.string("%d segments saved", RecordingHUDWorstCaseText.savedSegments)
    }

    private func audioFinishedRow(
        showsPreview: Bool,
        previewPlaying: Bool,
        offersRecordingsList: Bool
    ) -> some View {
        HStack(spacing: 7) {
            if offersRecordingsList {
                actionButton("Open Recordings")
            } else {
                actionButton("Open")
            }
            actionButton("Show in Finder")
            actionButton("Combine & Export")
            if showsPreview {
                previewButton(isPlaying: previewPlaying)
            }
            closeWhileSavingButton
        }
    }

    @ViewBuilder
    private func failureRow(expanded: Bool, canRetry: Bool, reason: String) -> some View {
        if expanded {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    failureIcon
                    if let failureScrollHeight {
                        ScrollView(.vertical, showsIndicators: true) {
                            expandedFailureText(reason)
                        }
                        .frame(height: failureScrollHeight)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        expandedFailureText(reason)
                    }
                }
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    failureActions(canRetry: canRetry, expanded: true)
                }
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            failureIcon
            Text(reason)
                .font(.system(size: DS.Typography.t12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: 4)
            failureActions(canRetry: canRetry, expanded: false)
        }
    }

    private func expandedFailureText(_ reason: String) -> some View {
        Text(reason)
            .font(.system(size: DS.Typography.t12, weight: .medium))
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
    }

    @ViewBuilder
    private func failureActions(canRetry: Bool, expanded: Bool) -> some View {
        if canRetry {
            Button("Retry", action: {})
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
                .tint(.red)
                .fixedSize()
        }

        Button(
            action: {},
            label: {
                Image(systemName: "folder")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(.primary.opacity(0.08)))
            }
        )
        .buttonStyle(.plain)
        .fixedSize()

        Button(
            action: {},
            label: {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(.primary.opacity(0.08)))
            }
        )
        .buttonStyle(.plain)
        .fixedSize()

        Button(
            action: {},
            label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(.primary.opacity(0.08)))
            }
        )
        .buttonStyle(.plain)
        .fixedSize()
    }

    private func actionButton(_ title: LocalizedStringKey) -> some View {
        Button(title, action: {})
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .frame(minHeight: 28)
    }

    private func previewButton(isPlaying: Bool) -> some View {
        Button(
            action: {},
            label: {
                Label(
                    isPlaying ? "Stop preview" : "Preview",
                    systemImage: isPlaying ? "stop.fill" : "play.fill"
                )
                .labelStyle(.titleAndIcon)
                .font(.system(size: 10, weight: .medium))
            }
        )
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .frame(minHeight: 28)
    }

    /// A fixed stand-in for `ProgressView`, which would run an indeterminate animation.
    private var spinnerPlaceholder: some View {
        Color.clear
            .frame(width: 16, height: 16)
    }

    private var countdownBadge: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 2)
            Text("\(RecordingHUDWorstCaseText.countdownSeconds)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.orange)
        }
        .frame(width: 20, height: 20)
    }

    /// A fixed bar where the live view draws a `GeometryReader`-driven level.
    private var meterBar: some View {
        Capsule()
            .fill(Color.accentColor.opacity(0.3))
            .frame(width: 30, height: 3)
    }

    private var cancelButton: some View {
        Button(
            action: {},
            label: {
                Text("Cancel")
                    .font(.system(size: DS.Typography.t12, weight: .medium))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.primary.opacity(0.08)))
            }
        )
        .buttonStyle(.plain)
        .fixedSize()
    }

    private var stopButton: some View {
        Button(
            action: {},
            label: {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.red)
                    .frame(width: 28, height: 28)
                    .overlay {
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(.white)
                            .frame(width: 8, height: 8)
                    }
            }
        )
        .buttonStyle(.plain)
        .fixedSize()
    }

    private var closeButton: some View {
        Button(
            action: {},
            label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(.primary.opacity(0.08)))
            }
        )
        .buttonStyle(.plain)
    }

    private var closeWhileSavingButton: some View {
        Button(
            action: {},
            label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(.primary.opacity(0.08)))
            }
        )
        .buttonStyle(.plain)
    }

    private var failureIcon: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.red)
    }
}

/// Applies one measurement role to the measure view's surface.
private struct MeasureSizingModifier: ViewModifier {
    let sizing: RecordingControlPanelMeasureSizing

    func body(content: Content) -> some View {
        switch sizing {
        case .ideal:
            content.fixedSize(horizontal: true, vertical: true)
        case let .fixedWidth(width):
            content.frame(width: width, alignment: .leading)
        }
    }
}
