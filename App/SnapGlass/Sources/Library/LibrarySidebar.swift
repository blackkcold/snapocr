import LibraryCore
import SwiftUI

// MARK: - Sidebar

struct LibrarySidebar: View {
    @ObservedObject var viewModel: LibraryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Library")
                .font(DS.Typography.title)
                .padding(.horizontal, DS.Space.s8)
                .padding(.top, DS.Space.s4)

            sidebarSection("Library")
            row(.all, icon: "square.grid.2x2", title: "All")
            row(.favourites, icon: "star", title: "Favourites")

            sidebarSection("Types")
            row(.screenshots, icon: "photo", title: "Screenshots")
            row(.audio, icon: "waveform", title: "Audio")
            row(.video, icon: "rectangle.dashed.badge.record", title: "Video")

            sidebarSection("Other")
            row(.colors, icon: "paintpalette", title: "Colors")
            row(.recentlyDeleted, icon: "trash", title: "Recently Deleted")

            Button {
                viewModel.isShowingRecoverableSheet = true
            } label: {
                HStack(spacing: DS.Space.s8) {
                    Image(systemName: "arrow.counterclockwise.circle")
                        .frame(width: 16)
                    Text("Incomplete")
                    Spacer(minLength: 2)
                    let count = viewModel.recoverable.count
                    if count > 0 {
                        Text("\(count)")
                            .font(DS.Typography.captionStrong)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange, in: Capsule())
                    }
                }
                .font(DS.Typography.body)
                .foregroundStyle(Color.orange)
                .padding(.horizontal, 7)
                .frame(minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 3)

            Spacer(minLength: 8)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Storage")
                    Spacer()
                    Text(librarySize(viewModel.recordingGroups.reduce(Int64(0)) { $0 + $1.byteSize }))
                        .monospacedDigit()
                }
                .font(DS.Typography.caption)
                .foregroundStyle(.secondary)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.14))
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: max(4, geo.size.width * storageFraction))
                    }
                }
                .frame(height: 4)

                Text("\(viewModel.recordingSessionCount) recordings")
                    .font(DS.Typography.caption)
                    .foregroundStyle(.secondary)

                Button("Manage Storage…") {
                    viewModel.isShowingStorageSheet = true
                }
                .font(DS.Typography.caption)
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, DS.Space.s8)
            .padding(.bottom, DS.Space.s6)
        }
        .frame(width: 190)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(DS.Space.s8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
        }
    }

    private var storageFraction: Double {
        let used = Double(viewModel.recordingGroups.reduce(Int64(0)) { $0 + $1.byteSize })
        let cap = 10.0 * 1_024 * 1_024 * 1_024
        return min(1, used / cap)
    }

    private func sidebarSection(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(DS.Typography.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, DS.Space.s8)
            .padding(.top, DS.Space.s10)
            .padding(.bottom, 1)
    }

    private func row(
        _ section: LibrarySection,
        icon: String,
        title: LocalizedStringKey
    ) -> some View {
        let selected = viewModel.section == section
        return Button {
            viewModel.selectSection(section)
        } label: {
            HStack(spacing: DS.Space.s8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16)
                Text(title)
                Spacer(minLength: 2)
                Text("\(viewModel.count(for: section))")
                    .font(DS.Typography.caption)
                    .monospacedDigit()
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
            }
            .font(DS.Typography.body)
            .foregroundStyle(selected ? Color.accentColor : .primary)
            .padding(.horizontal, 7)
            .frame(minHeight: 28)
            .background(
                selected ? Color.accentColor.opacity(0.13) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library.sidebar.\(section.rawValue)")
        .padding(.horizontal, 3)
    }
}
