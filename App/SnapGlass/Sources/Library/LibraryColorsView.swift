import SwiftUI

// MARK: - Colors

struct LibraryColorsView: View {
    @ObservedObject var viewModel: LibraryViewModel

    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 200), spacing: DS.Space.s12, alignment: .top)
    ]

    var body: some View {
        if viewModel.colorEntries.isEmpty {
            LibraryEmptyState(
                icon: "paintpalette",
                title: "No colors yet",
                message: "Colors sampled with the eyedropper appear here.",
                primaryTitle: nil,
                primaryAction: nil,
                secondaryTitle: nil,
                secondaryAction: nil
            )
        } else {
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: DS.Space.s12) {
                    ForEach(viewModel.colorEntries) { entry in
                        ColorHistoryCard(entry: entry) {
                            viewModel.copyColor(entry)
                        } onDelete: {
                            Task { await viewModel.deleteColor(entry) }
                        }
                    }
                }
                .padding(DS.Space.s12)
            }
        }
    }
}
