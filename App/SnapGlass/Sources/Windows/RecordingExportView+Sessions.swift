import CaptureCore
import SwiftUI

extension RecordingExportView {
    var sessionList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sessions")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 4)
                if viewModel.isLoading || viewModel.isScanningRecoverable {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(Text("Loading recordings"))
                }
                Button {
                    Task {
                        await viewModel.loadPublishedSessions()
                        await viewModel.scanRecoverableRecordings()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(minWidth: 28, minHeight: 28)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Refresh recordings"))
            }

            recoverableSection

            if viewModel.publishedSessions.isEmpty && !viewModel.isLoading {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("No Recordings Yet")
                        .font(.headline)
                    Text("Your audio recordings will appear here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Locate recording folder") { revealRecordingRoot() }
                        .frame(minHeight: 28)
                }
                .frame(maxWidth: .infinity, minHeight: 260, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(viewModel.publishedSessions, id: \.id) { record in
                            sessionButton(record)
                        }
                    }
                }
                .frame(maxHeight: 430)
            }
        }
    }

    /// Interrupted sessions that still have media but no index entry.
    @ViewBuilder
    var recoverableSection: some View {
        if !viewModel.recoverableRecordings.isEmpty || viewModel.isScanningRecoverable {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.counterclockwise.circle")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text(AppLocalization.string("Recoverable (%d)", viewModel.recoverableRecordings.count))
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 4)
                    if viewModel.isScanningRecoverable {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(Text("Checking for unfinished recordings…"))
                    }
                }
                ForEach(viewModel.recoverableRecordings, id: \.id) { recording in
                    recoverableRow(recording)
                }
            }
            .padding(8)
            .background {
                RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08))
            }
            .accessibilityElement(children: .contain)
        }

        if let notice = viewModel.recoveryNotice {
            Label(recoveryNoticeText(notice), systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .accessibilityElement(children: .combine)
                .task {
                    try? await Task.sleep(for: .seconds(5))
                    viewModel.clearRecoveryNotice()
                }
        }
    }

    func recoverableRow(_ recording: RecoverableRecording) -> some View {
        let isBusy = viewModel.recoveringRecordingID != nil || viewModel.discardingRecordingID != nil
        let isRecovering = viewModel.recoveringRecordingID == recording.id
        let isDiscarding = viewModel.discardingRecordingID == recording.id
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: recording.kind == .audio ? "waveform" : "rectangle.dashed.badge.record")
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        recording.kind == .audio
                            ? LocalizedStringKey("Incomplete audio recording")
                            : LocalizedStringKey("Incomplete screen recording")
                    )
                    .font(.callout.weight(.medium))
                    HStack(spacing: 6) {
                        if recording.duration > 0 {
                            Text(Self.duration(recording.duration))
                                .monospacedDigit()
                        }
                        Text(recording.createdAt, style: .time)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 2)
            }
            HStack(spacing: 8) {
                if isRecovering || isDiscarding {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer(minLength: 2)
                Button("Save to list") {
                    Task { await viewModel.recoverRecording(recording.id) }
                }
                .disabled(isBusy)
                .frame(minHeight: 24)
                .accessibilityLabel(Text("Save to list"))
                Button("Delete") {
                    discardTarget = recording.id
                }
                .disabled(isBusy)
                .frame(minHeight: 24)
                .accessibilityLabel(Text("Move incomplete recording to the Trash"))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .contain)
    }

    func recoveryNoticeText(_ notice: RecordingRecoveryNotice) -> String {
        switch notice {
        case .recovered:
            AppLocalization.string("Recovered recording added to your list.")
        case .discarded:
            AppLocalization.string("Recording moved to the Trash.")
        }
    }

    func sessionButton(_ record: RecordingSessionRecord) -> some View {
        let selected = viewModel.selectedSessionID == record.id
        let duration = Self.duration(
            record.segments
                .filter { $0.state == .published }
                .reduce(0.0) { $0 + Double($1.sampleCount) / 48_000 })
        return Button {
            Task { await viewModel.selectSession(record.id) }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(record.startedAt, style: .date)
                    .font(.body.weight(.medium))
                HStack(spacing: 6) {
                    Text(record.kind == .screen ? "Video" : "Audio")
                    Text("·")
                    Text(duration)
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .padding(.horizontal, 8)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.14))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            Text(
                AppLocalization.string(
                    "Recording session %@, %@",
                    record.startedAt.formatted(date: .abbreviated, time: .shortened),
                    duration
                ))
        )
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
