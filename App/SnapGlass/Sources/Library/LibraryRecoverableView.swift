import SwiftUI

// MARK: - Recoverable

struct LibraryRecoverableView: View {
    @ObservedObject var viewModel: LibraryViewModel

    var body: some View {
        if viewModel.recoverable.isEmpty {
            LibraryEmptyState(
                icon: "checkmark.circle",
                title: "Nothing to recover",
                message: "Interrupted recordings that still have media appear here.",
                primaryTitle: nil,
                primaryAction: nil,
                secondaryTitle: nil,
                secondaryAction: nil
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.s8) {
                    ForEach(viewModel.recoverable) { recording in
                        HStack(spacing: DS.Space.s10) {
                            Image(
                                systemName: recording.kind == .audio
                                    ? "waveform" : "rectangle.dashed.badge.record"
                            )
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(
                                    recording.kind == .audio
                                        ? "Incomplete audio recording"
                                        : "Incomplete screen recording"
                                )
                                .font(DS.Typography.bodyStrong)
                                Text(recording.createdAt, format: .dateTime.year().month().day().hour().minute())
                                    .font(DS.Typography.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Save to library") {
                                Task { await viewModel.recover(recording) }
                            }
                            Button("Move to Trash") {
                                Task { await viewModel.discard(recording) }
                            }
                        }
                        .padding(DS.Space.s10)
                        .background(
                            Color.orange.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                    }
                }
                .padding(DS.Space.s12)
            }
        }
    }
}
