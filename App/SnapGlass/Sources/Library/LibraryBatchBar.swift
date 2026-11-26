import SwiftUI

// MARK: - Batch bar

struct LibraryBatchBar: View {
    @ObservedObject var viewModel: LibraryViewModel

    var body: some View {
        HStack(spacing: DS.Space.s8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(AppLocalization.string("%@ selected", String(viewModel.selectionCount)))
                    .font(DS.Typography.captionStrong)
                Text(librarySize(viewModel.selectionByteSize))
                    .font(DS.Typography.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.leading, 4)

            Spacer(minLength: 6)

            Button {
                Task {
                    let allFavourite = viewModel.selectionItems.allSatisfy(\.isFavourite)
                    await viewModel.setFavouriteForSelection(!allFavourite)
                }
            } label: {
                Label("Favourite", systemImage: "star")
            }
            .buttonStyle(.borderless)

            Button {
                viewModel.isShowingExportSheet = true
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)

            if viewModel.canGroupSelection {
                Button {
                    Task { await viewModel.groupSelection() }
                } label: {
                    Label("Group", systemImage: "rectangle.3.group")
                }
                .buttonStyle(.borderless)
            }

            Button {
                viewModel.isShowingMergeSheet = true
            } label: {
                Label("Merge", systemImage: "square.stack.3d.up")
            }
            .buttonStyle(.borderless)
            .disabled(!viewModel.canMergeSelection)
            .help(
                viewModel.canMergeSelection
                    ? "Merge the selected recording"
                    : "Select one complete recording with multiple segments")

            Button(role: .destructive) {
                viewModel.requestDeleteSelection()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .buttonStyle(.borderless)

            Button("Cancel") {
                viewModel.cancelSelection()
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, DS.Space.s12)
        .padding(.vertical, DS.Space.s8)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
    }
}
