import AppKit
import CaptureCore
import SharedKit
import SwiftUI

extension RecordingControlPanelView {
    func audioRecording(
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

    func audioFinalizing(
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

    func audioFinished(
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
}
