import LibraryCore
import SwiftUI

// MARK: - Header

struct LibraryHeader: View {
    @ObservedObject var viewModel: LibraryViewModel
    let isWide: Bool
    let openInspector: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.s8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(sectionTitle)
                        .font(DS.Typography.display)
                    Text(countText)
                        .font(DS.Typography.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                searchField

                Menu {
                    Picker("Date", selection: $viewModel.filter.dateRange) {
                        Text("Any time").tag(LibraryDateRange.any)
                        Text("Today").tag(LibraryDateRange.today)
                        Text("Last 7 days").tag(LibraryDateRange.last7Days)
                        Text("Last 30 days").tag(LibraryDateRange.last30Days)
                    }
                    Picker("Duration", selection: $viewModel.filter.duration) {
                        Text("Any duration").tag(LibraryDurationFilter.any)
                        Text("Under 1 min").tag(LibraryDurationFilter.underOneMinute)
                        Text("1–10 min").tag(LibraryDurationFilter.oneToTenMinutes)
                        Text("10–60 min").tag(LibraryDurationFilter.tenToSixtyMinutes)
                        Text("Over 1 hour").tag(LibraryDurationFilter.overOneHour)
                    }
                    Picker("Status", selection: $viewModel.filter.status) {
                        Text("Any status").tag(LibraryStatusFilter.any)
                        Text("Complete").tag(LibraryStatusFilter.complete)
                        Text("Partial").tag(LibraryStatusFilter.partial)
                        Text("Offline").tag(LibraryStatusFilter.offline)
                    }
                    Toggle("Favourites only", isOn: $viewModel.filter.favouritesOnly)
                    Divider()
                    Button("Clear filters") {
                        viewModel.filter = LibraryFilter()
                    }
                } label: {
                    Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Menu {
                    Picker("Sort", selection: $viewModel.sort) {
                        Text("Newest first").tag(LibrarySort.newest)
                        Text("Oldest first").tag(LibrarySort.oldest)
                        Text("Longest first").tag(LibrarySort.longest)
                        Text("Largest first").tag(LibrarySort.largest)
                        Text("Name").tag(LibrarySort.name)
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                if viewModel.section != .colors,
                    viewModel.section != .recoverable,
                    viewModel.section != .recentlyDeleted
                {
                    Picker("View", selection: $viewModel.viewMode) {
                        Image(systemName: "list.bullet").tag(LibraryViewMode.list)
                        Image(systemName: "square.grid.2x2").tag(LibraryViewMode.grid)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 74)

                    Button(viewModel.isSelecting ? "Done" : "Select") {
                        if viewModel.isSelecting {
                            viewModel.cancelSelection()
                        } else {
                            viewModel.beginSelection()
                        }
                    }
                    .accessibilityIdentifier("library.select")
                    .frame(minHeight: 28)
                }

                if isWide {
                    Button(action: openInspector) {
                        Image(systemName: "sidebar.right")
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.borderless)
                    .help("Toggle inspector")
                    .disabled(viewModel.selectedItem == nil)
                }

                if viewModel.isRefreshing {
                    ProgressView().controlSize(.small)
                }

                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }
            .padding(.horizontal, DS.Space.s12)
            .padding(.top, DS.Space.s10)
            .padding(.bottom, DS.Space.s7)

            if viewModel.filter.isActive || !viewModel.searchText.isEmpty {
                activeFilterChips
                    .padding(.horizontal, DS.Space.s12)
                    .padding(.bottom, DS.Space.s7)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search title, date or OCR text", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .font(DS.Typography.body)
                .accessibilityIdentifier("library.search")
                .onChange(of: viewModel.searchText) { _ in
                    viewModel.searchTextChanged()
                }
            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .frame(minWidth: 150, idealWidth: 220, maxWidth: 260)
    }

    private var activeFilterChips: some View {
        HStack(spacing: 5) {
            if viewModel.filter.favouritesOnly {
                chip("Favourites")
            }
            if viewModel.filter.dateRange != .any {
                chip(dateFilterLabel)
            }
            if viewModel.filter.duration != .any {
                chip(durationFilterLabel)
            }
            if viewModel.filter.status != .any {
                chip(statusFilterLabel)
            }
            if !viewModel.searchText.isEmpty {
                chip("\"\(viewModel.searchText)\"")
            }
            Button("Clear") {
                viewModel.filter = LibraryFilter()
                viewModel.searchText = ""
            }
            .font(DS.Typography.caption)
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            Spacer()
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(DS.Typography.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
            .foregroundStyle(Color.accentColor)
    }

    private var sectionTitle: LocalizedStringKey {
        switch viewModel.section {
        case .all: "All"
        case .favourites: "Favourites"
        case .screenshots: "Screenshots"
        case .audio: "Audio"
        case .video: "Video"
        case .colors: "Colors"
        case .recoverable: "Incomplete Recordings"
        case .recentlyDeleted: "Recently Deleted"
        }
    }

    private var countText: String {
        let count = viewModel.filteredItems.count
        let total = viewModel.count(for: viewModel.section)
        if viewModel.section == .colors {
            return AppLocalization.string("%@ colors", String(viewModel.colorEntries.count))
        }
        if viewModel.section == .recoverable {
            return AppLocalization.string("%@ recoverable", String(viewModel.recoverable.count))
        }
        if viewModel.section == .recentlyDeleted {
            return AppLocalization.string("%@ items", String(viewModel.trashEntries.count))
        }
        if count == total {
            return AppLocalization.string("%@ items", String(count))
        }
        return AppLocalization.string("%@ of %@ items", String(count), String(total))
    }

    private var dateFilterLabel: String {
        switch viewModel.filter.dateRange {
        case .any: ""
        case .today: AppLocalization.string("Today")
        case .last7Days: AppLocalization.string("Last 7 days")
        case .last30Days: AppLocalization.string("Last 30 days")
        case .custom: AppLocalization.string("Custom range")
        }
    }

    private var durationFilterLabel: String {
        switch viewModel.filter.duration {
        case .any: ""
        case .underOneMinute: AppLocalization.string("Under 1 min")
        case .oneToTenMinutes: AppLocalization.string("1–10 min")
        case .tenToSixtyMinutes: AppLocalization.string("10–60 min")
        case .overOneHour: AppLocalization.string("Over 1 hour")
        }
    }

    private var statusFilterLabel: String {
        switch viewModel.filter.status {
        case .any: ""
        case .complete: AppLocalization.string("Complete")
        case .partial: AppLocalization.string("Partial")
        case .offline: AppLocalization.string("Offline")
        }
    }
}
