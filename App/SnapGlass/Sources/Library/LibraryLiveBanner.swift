import CaptureCore
import SwiftUI

/// A small, persistent status strip shown while a recording is being prepared,
/// captured, or saved. It keeps the library truthful without inserting a
/// half-written recording into the history list.
struct LibraryLiveRecordingBanner: View {
    @ObservedObject var captureViewModel: CaptureViewModel

    var body: some View {
        HStack(spacing: DS.Space.s8) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 7, height: 7)
                .opacity(isRecording ? 1 : 0.55)

            Text(statusText)
                .font(DS.Typography.captionStrong)

            if isRecording {
                Text(AppLocalization.string("Live"))
                    .font(DS.Typography.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            if captureViewModel.recordingStatus == .recording {
                Button("Stop") {
                    Task {
                        if captureViewModel.isAudioRecordingActive {
                            _ = await captureViewModel.stopAudioRecording()
                        } else {
                            _ = await captureViewModel.stopRecordingAndSave()
                        }
                    }
                }
                .frame(minHeight: 24)
                .buttonStyle(.bordered)
            } else if captureViewModel.recordingStatus == .starting {
                Button("Cancel") {
                    captureViewModel.cancelPendingRecordingStart()
                }
                .frame(minHeight: 24)
            }
        }
        .padding(.horizontal, DS.Space.s12)
        .padding(.vertical, DS.Space.s6)
        .background(
            Color.red.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.red.opacity(0.16), lineWidth: 0.5)
        }
        .padding(.horizontal, DS.Space.s12)
        .padding(.bottom, DS.Space.s6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(statusText))
    }

    private var isRecording: Bool {
        captureViewModel.recordingStatus == .recording
    }

    private var indicatorColor: Color {
        switch captureViewModel.recordingStatus {
        case .recording:
            return .red
        case .saving:
            return .orange
        default:
            return .secondary
        }
    }

    private var statusText: String {
        switch captureViewModel.recordingStatus {
        case .idle:
            return ""
        case .selectingSource:
            return AppLocalization.string("Choosing recording source…")
        case .countdown(let seconds):
            return AppLocalization.string("Recording starts in %@ seconds", String(seconds))
        case .starting:
            return AppLocalization.string("Starting recording…")
        case .recording:
            return captureViewModel.isAudioRecordingActive
                ? AppLocalization.string("Recording audio")
                : AppLocalization.string("Recording screen")
        case .saving:
            return AppLocalization.string("Saving recording…")
        }
    }
}
