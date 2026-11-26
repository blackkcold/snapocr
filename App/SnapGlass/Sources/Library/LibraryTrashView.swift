import AppKit
import HistoryCore
import LibraryCore
import SwiftUI

struct LibraryTrashView: View {
    @ObservedObject var viewModel: LibraryViewModel
    @State private var pendingDelete: HistoryTrashEntry?
    @State private var showEmptyConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.s8) {
                Text("Deleted screenshots are kept here for 30 days.")
                    .font(DS.Typography.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Empty Trash") {
                    showEmptyConfirmation = true
                }
                .disabled(viewModel.trashEntries.isEmpty)
            }
            .padding(.horizontal, DS.Space.s12)
            .padding(.vertical, DS.Space.s8)

            if viewModel.trashEntries.isEmpty {
                LibraryTrashEmptyState()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.trashEntries) { item in
                            LibraryTrashRow(
                                viewModel: viewModel,
                                item: item,
                                onDelete: { pendingDelete = item }
                            )
                            Divider().opacity(0.5).padding(.leading, 62)
                        }
                    }
                    .padding(.horizontal, DS.Space.s12)
                }
            }
        }
        .confirmationDialog(
            Text("Delete this screenshot permanently?"),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingDelete {
                Button("Delete Permanently", role: .destructive) {
                    self.pendingDelete = nil
                    Task { await viewModel.deleteTrashEntry(pendingDelete) }
                }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        }
        .confirmationDialog(
            Text("Empty Recently Deleted?"),
            isPresented: $showEmptyConfirmation,
            titleVisibility: .visible
        ) {
            Button("Empty Trash", role: .destructive) {
                Task { await viewModel.emptyTrash() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes every screenshot in Recently Deleted.")
        }
    }
}

private struct LibraryTrashRow: View {
    @ObservedObject var viewModel: LibraryViewModel
    let item: HistoryTrashEntry
    let onDelete: () -> Void
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: DS.Space.s10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 44, height: 44)
            .clipped()

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DS.Typography.bodyStrong)
                    .lineLimit(1)
                Text(
                    AppLocalization.string(
                        "Deleted %@",
                        item.deletedAt.formatted(date: .abbreviated, time: .shortened)
                    )
                )
                .font(DS.Typography.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Restore") {
                Task { await viewModel.restoreTrashEntry(item) }
            }
            .frame(minHeight: 28)

            Button("Delete Permanently", role: .destructive, action: onDelete)
                .frame(minHeight: 28)
        }
        .padding(.horizontal, 7)
        .frame(minHeight: 56)
        .task(id: item.id) {
            thumbnail = await viewModel.trashThumbnail(for: item.entry)
        }
    }

    private var title: String {
        item.entry.sourceWindowTitle
            ?? item.entry.sourceAppName
            ?? AppLocalization.string("Screenshot")
    }
}

private struct LibraryTrashEmptyState: View {
    var body: some View {
        VStack(spacing: DS.Space.s10) {
            Image(systemName: "trash")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text("Recently Deleted is empty")
                .font(DS.Typography.title)
            Text("Deleted screenshots appear here and can be restored for 30 days.")
                .font(DS.Typography.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
