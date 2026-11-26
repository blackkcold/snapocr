import LibraryCore
import SwiftUI

struct LibraryStorageSheet: View {
    @ObservedObject var viewModel: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var days = 90
    @State private var showConfirmation = false

    private var candidateCount: Int {
        viewModel.retentionCandidateCount(olderThanDays: days)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s12) {
            Text("Recording Storage")
                .font(DS.Typography.title)

            HStack {
                Text("Recordings")
                Spacer()
                Text(
                    AppLocalization.string(
                        "%@ items · %@",
                        String(viewModel.recordingSessionCount),
                        librarySize(viewModel.recordingLibraryByteSize)
                    )
                )
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            .font(DS.Typography.body)

            Text("Old recordings move to the Trash. Favourites and offline recordings are kept.")
                .font(DS.Typography.caption)
                .foregroundStyle(.secondary)

            Picker("Delete recordings older than", selection: $days) {
                Text("30 days").tag(30)
                Text("90 days").tag(90)
                Text("180 days").tag(180)
                Text("365 days").tag(365)
            }
            .pickerStyle(.segmented)

            Text(
                candidateCount == 0
                    ? AppLocalization.string("No recordings are older than this.")
                    : AppLocalization.string(
                        "%@ recording(s) will move to the Trash.",
                        String(candidateCount)
                    )
            )
            .font(DS.Typography.body)
            .foregroundStyle(candidateCount == 0 ? .secondary : .primary)

            if viewModel.isCleaningRecordings {
                ProgressView("Moving recordings to the Trash…")
                    .controlSize(.small)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .disabled(viewModel.isCleaningRecordings)
                Button("Clean Up…", role: .destructive) {
                    showConfirmation = true
                }
                .disabled(candidateCount == 0 || viewModel.isCleaningRecordings)
            }
        }
        .padding(DS.Space.s20)
        .frame(width: 460)
        .confirmationDialog(
            Text(
                AppLocalization.string(
                    "Move %@ recording(s) to the Trash?",
                    String(candidateCount)
                )),
            isPresented: $showConfirmation,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                Task {
                    await viewModel.cleanupRecordings(olderThanDays: days)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .interactiveDismissDisabled(viewModel.isCleaningRecordings)
    }
}
