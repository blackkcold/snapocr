import AppKit
import CaptureCore
import HistoryCore
import LibraryCore
import SwiftUI

// MARK: - List

struct LibraryListView: View {
    @ObservedObject var viewModel: LibraryViewModel
    let captureViewModel: CaptureViewModel
    let gridFocus: FocusState<Bool>.Binding

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(viewModel.daySections) { section in
                    Text(dayTitle(section.date))
                        .font(DS.Typography.captionStrong)
                        .foregroundStyle(.secondary)
                        .padding(.top, DS.Space.s10)
                        .padding(.bottom, DS.Space.s4)

                    ForEach(section.items) { item in
                        LibraryListRow(
                            viewModel: viewModel,
                            item: item,
                            captureViewModel: captureViewModel
                        )
                        if let group = item.recordingGroup,
                            viewModel.expandedGroupIDs.contains(item.id)
                        {
                            ForEach(group.segments) { segment in
                                LibrarySegmentRow(segment: segment)
                            }
                        }
                        Divider()
                            .opacity(0.5)
                            .padding(.leading, 62)
                    }
                }

                if viewModel.canLoadMoreScreenshots {
                    HStack {
                        Spacer()
                        Button {
                            Task { await viewModel.loadMoreScreenshots() }
                        } label: {
                            if viewModel.isLoadingMoreScreenshots {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Load More")
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, DS.Space.s12)
                }
            }
            .padding(.horizontal, DS.Space.s12)
            .padding(.bottom, 84)
        }
        .focusable()
        .focused(gridFocus)
    }
}

private struct LibraryListRow: View {
    @ObservedObject var viewModel: LibraryViewModel
    let item: LibraryCore.LibraryItem
    let captureViewModel: CaptureViewModel

    var body: some View {
        let selected = viewModel.selectedItemID == item.id
        let checked = viewModel.selection.contains(item.id)
        HStack(spacing: DS.Space.s10) {
            if viewModel.isSelecting {
                Button {
                    viewModel.toggleSelection(item.id)
                } label: {
                    Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(checked ? Color.accentColor : .secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
            }

            LibraryThumbnailView(item: item, viewModel: viewModel)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(itemTitle(item))
                        .font(DS.Typography.bodyStrong)
                        .lineLimit(1)
                    if let group = item.recordingGroup, group.isGrouped {
                        Text(AppLocalization.string("%@ segments", String(group.segmentCount)))
                            .font(DS.Typography.caption)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(rowSubtitle(item))
                    .font(DS.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if let group = item.recordingGroup, group.isGrouped {
                Button {
                    viewModel.toggleExpanded(group)
                } label: {
                    Image(
                        systemName: viewModel.expandedGroupIDs.contains(item.id)
                            ? "chevron.down" : "chevron.right"
                    )
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
            }

            if let duration = item.duration {
                Text(libraryDuration(duration))
                    .font(DS.Typography.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Button {
                Task { await viewModel.toggleFavourite(item) }
            } label: {
                Image(systemName: item.isFavourite ? "star.fill" : "star")
                    .foregroundStyle(item.isFavourite ? Color.orange : Color.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(item.isFavourite ? "Remove favourite" : "Add favourite")
        }
        .padding(.horizontal, 7)
        .frame(minHeight: 54)
        .background(
            selected ? Color.accentColor.opacity(0.10) : Color.clear,
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.handleClick(item)
        }
        .onTapGesture(count: 2) {
            openItem()
        }
        .onDrag {
            LibraryDragProvider.provider(for: item, viewModel: viewModel)
        }
        .contextMenu {
            contextMenu
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text(libraryAccessibilityLabel(item)))
        .accessibilityAction(named: Text("Open"), openItem)
        .accessibilityAction(named: Text("Toggle favourite")) {
            Task { await viewModel.toggleFavourite(item) }
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button {
            Task { await viewModel.toggleFavourite(item) }
        } label: {
            Label(
                item.isFavourite ? "Remove favourite" : "Add favourite",
                systemImage: item.isFavourite ? "star.slash" : "star"
            )
        }
        Button {
            openItem()
        } label: {
            Label(item.mediaKind == .screenshot ? "Open in Editor" : "Open", systemImage: "arrow.up.forward.app")
        }
        Button {
            viewModel.revealInFinder(item)
        } label: {
            Label("Show in Finder", systemImage: "folder")
        }
        Divider()
        Button {
            viewModel.selection = [item.id]
            viewModel.isSelecting = true
            viewModel.isShowingExportSheet = true
        } label: {
            Label("Export…", systemImage: "square.and.arrow.up")
        }
        if let group = item.recordingGroup, group.isGrouped, group.state == .complete {
            Button {
                viewModel.selectedItemID = item.id
                viewModel.isShowingMergeSheet = true
            } label: {
                Label("Merge & Export…", systemImage: "square.stack.3d.up")
            }
        }
        Divider()
        Button(role: .destructive) {
            viewModel.selection = [item.id]
            viewModel.isSelecting = true
            viewModel.requestDeleteSelection()
        } label: {
            Label("Delete…", systemImage: "trash")
        }
    }

    private func openItem() {
        switch item {
        case .screenshot(let entry):
            Task {
                await viewModel.openScreenshot(entry, using: captureViewModel)
            }
        case .recording(let group):
            viewModel.openRecording(group)
        }
    }
}

private struct LibrarySegmentRow: View {
    let segment: LibraryRecordingSegment

    var body: some View {
        HStack(spacing: DS.Space.s8) {
            Text("\(segment.displayIndex)")
                .font(DS.Typography.caption)
                .foregroundStyle(Color.accentColor)
                .frame(width: 18, height: 18)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            Text(AppLocalization.string("Segment %@", String(segment.displayIndex)))
                .font(DS.Typography.caption)
                .foregroundStyle(.secondary)
            Text(libraryDuration(segment.duration))
                .font(DS.Typography.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if segment.state == .missing {
                Text("Missing")
                    .font(DS.Typography.caption)
                    .foregroundStyle(.red)
            }
            Spacer()
            if let url = segment.videoURL ?? segment.audioURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Play segment")
            }
        }
        .padding(.leading, 61)
        .padding(.trailing, 9)
        .frame(minHeight: 28)
    }
}

// MARK: - Grid

struct LibraryGridView: View {
    @ObservedObject var viewModel: LibraryViewModel
    let captureViewModel: CaptureViewModel
    let gridFocus: FocusState<Bool>.Binding

    private let columns = [
        GridItem(.adaptive(minimum: 170, maximum: 240), spacing: DS.Space.s12, alignment: .top)
    ]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(viewModel.daySections) { section in
                    Text(dayTitle(section.date))
                        .font(DS.Typography.captionStrong)
                        .foregroundStyle(.secondary)
                        .padding(.top, DS.Space.s10)
                        .padding(.bottom, DS.Space.s6)

                    LazyVGrid(columns: columns, alignment: .leading, spacing: DS.Space.s14) {
                        ForEach(section.items) { item in
                            LibraryGridCard(
                                viewModel: viewModel,
                                item: item,
                                captureViewModel: captureViewModel
                            )
                        }
                    }
                }

                if viewModel.canLoadMoreScreenshots {
                    HStack {
                        Spacer()
                        Button {
                            Task { await viewModel.loadMoreScreenshots() }
                        } label: {
                            if viewModel.isLoadingMoreScreenshots {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Load More")
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, DS.Space.s12)
                }
            }
            .padding(.horizontal, DS.Space.s12)
            .padding(.bottom, 84)
        }
        .focusable()
        .focused(gridFocus)
    }
}

private struct LibraryGridCard: View {
    @ObservedObject var viewModel: LibraryViewModel
    let item: LibraryCore.LibraryItem
    let captureViewModel: CaptureViewModel

    var body: some View {
        let selected = viewModel.selectedItemID == item.id
        VStack(alignment: .leading, spacing: 0) {
            // Badges are overlays on the cover, not ZStack children.
            //
            // As ZStack children they needed `maxHeight: .infinity` to sit at the
            // bottom edge, which made the card's *ideal* height unbounded. A
            // LazyVGrid sizes each row from its items, so that ambiguity let a row
            // collapse to the cover and clip the caption block — the cramped,
            // overlapping grid users saw. Anchoring to the cover keeps the card
            // height exactly 108 + text.
            cover
                .frame(height: 108)
                .frame(maxWidth: .infinity)
                .clipped()
                .overlay(alignment: .topLeading) { badgeRow }
                .overlay(alignment: .bottomTrailing) { durationBadge }
                .overlay(alignment: .bottomLeading) { selectionToggle }

            VStack(alignment: .leading, spacing: 2) {
                Text(itemTitle(item))
                    .font(DS.Typography.bodyStrong)
                    .lineLimit(1)
                Text(cardSubtitle(item))
                    .font(DS.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
        }
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(
                    selected ? Color.accentColor : Color.primary.opacity(0.08),
                    lineWidth: selected ? 2 : 0.5
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onTapGesture {
            viewModel.handleClick(item)
        }
        .onTapGesture(count: 2) {
            openItem()
        }
        .onDrag {
            LibraryDragProvider.provider(for: item, viewModel: viewModel)
        }
        .contextMenu {
            Button {
                Task { await viewModel.toggleFavourite(item) }
            } label: {
                Label(
                    item.isFavourite ? "Remove favourite" : "Add favourite",
                    systemImage: item.isFavourite ? "star.slash" : "star"
                )
            }
            Button {
                openItem()
            } label: {
                Label(item.mediaKind == .screenshot ? "Open in Editor" : "Open", systemImage: "arrow.up.forward.app")
            }
            Button {
                viewModel.revealInFinder(item)
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            Divider()
            Button {
                viewModel.selection = [item.id]
                viewModel.isSelecting = true
                viewModel.isShowingExportSheet = true
            } label: {
                Label("Export…", systemImage: "square.and.arrow.up")
            }
            if let group = item.recordingGroup, group.isGrouped, group.state == .complete {
                Button {
                    viewModel.selectedItemID = item.id
                    viewModel.isShowingMergeSheet = true
                } label: {
                    Label("Merge & Export…", systemImage: "square.stack.3d.up")
                }
            }
            Divider()
            Button(role: .destructive) {
                viewModel.selection = [item.id]
                viewModel.isSelecting = true
                viewModel.requestDeleteSelection()
            } label: {
                Label("Delete…", systemImage: "trash")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text(libraryAccessibilityLabel(item)))
    }

    /// Media-type badge, group count, and the favourite toggle across the top edge.
    private var badgeRow: some View {
        HStack(spacing: 4) {
            Text(typeLabel(item.mediaKind))
                .font(DS.Typography.caption)
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(typeColor(item.mediaKind), in: Capsule())
            if let group = item.recordingGroup, group.isGrouped {
                Text("\(group.segmentCount) segments")
                    .font(DS.Typography.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.48), in: Capsule())
            }
            Spacer(minLength: 0)
            Button {
                Task { await viewModel.toggleFavourite(item) }
            } label: {
                Image(systemName: item.isFavourite ? "star.fill" : "star")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(item.isFavourite ? Color.orange : Color.white)
                    .frame(width: 22, height: 22)
                    .background(.black.opacity(0.32), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(6)
    }

    /// Duration pill in the bottom-trailing corner, when the item has one.
    @ViewBuilder
    private var durationBadge: some View {
        if let duration = item.duration {
            Text(libraryDuration(duration))
                .font(DS.Typography.caption)
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.black.opacity(0.48), in: Capsule())
                .padding(6)
        }
    }

    /// Selection checkbox in the bottom-leading corner, only while selecting.
    @ViewBuilder
    private var selectionToggle: some View {
        if viewModel.isSelecting {
            let checked = viewModel.selection.contains(item.id)
            Button {
                viewModel.toggleSelection(item.id)
            } label: {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(checked ? Color.accentColor : .white)
                    .background(.black.opacity(0.28), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(6)
        }
    }

    @ViewBuilder
    private var cover: some View {
        if item.mediaKind == .audio, let group = item.recordingGroup {
            AudioArtwork(group: group)
        } else {
            LibraryThumbnailView(item: item, viewModel: viewModel)
        }
    }

    private func openItem() {
        switch item {
        case .screenshot(let entry):
            Task { await viewModel.openScreenshot(entry, using: captureViewModel) }
        case .recording(let group):
            viewModel.openRecording(group)
        }
    }
}

// MARK: - Thumbnails and artwork

private struct LibraryThumbnailView: View {
    let item: LibraryCore.LibraryItem
    @ObservedObject var viewModel: LibraryViewModel
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: placeholderColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: placeholderIcon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .task(id: item.id) {
            image = await viewModel.thumbnail(for: item)
        }
    }

    private var placeholderColors: [Color] {
        switch item.mediaKind {
        case .screenshot: [Color(nsColor: .windowBackgroundColor), Color(nsColor: .controlBackgroundColor)]
        case .audio: [Color.purple.opacity(0.75), Color.purple.opacity(0.35)]
        case .video: [Color.blue.opacity(0.8), Color.teal.opacity(0.45)]
        }
    }

    private var placeholderIcon: String {
        switch item.mediaKind {
        case .screenshot: "photo"
        case .audio: "waveform"
        case .video: "play.rectangle"
        }
    }
}

private struct AudioArtwork: View {
    let group: LibraryRecordingGroup
    private let bars: [CGFloat] = [
        0.18, 0.32, 0.24, 0.48, 0.36, 0.62, 0.44, 0.72, 0.38, 0.56, 0.30, 0.66,
        0.42, 0.78, 0.34, 0.52, 0.26, 0.60, 0.40, 0.70, 0.30, 0.46, 0.22, 0.36,
    ]

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(Array(bars.enumerated()), id: \.offset) { _, value in
                    Capsule()
                        .fill(.white.opacity(0.78))
                        .frame(width: 2, height: max(3, geo.size.height * value * 0.7))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                LinearGradient(
                    colors: [Color.purple.opacity(0.85), Color.purple.opacity(0.38)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 4) {
                    Image(systemName: group.layout == .separateTracks ? "rectangle.3.group" : "waveform")
                    Text(group.kind == .audio ? "Audio" : "Video")
                }
                .font(DS.Typography.caption)
                .foregroundStyle(.white.opacity(0.9))
                .padding(6)
            }
        }
    }
}

// MARK: - Helpers

func itemTitle(_ item: LibraryCore.LibraryItem) -> String {
    switch item {
    case .screenshot(let entry):
        return entry.sourceWindowTitle
            ?? entry.sourceAppName
            ?? AppLocalization.string("Screenshot")
    case .recording(let group):
        if !group.title.isEmpty { return group.title }
        return group.kind == .audio
            ? AppLocalization.string("Audio Recording")
            : AppLocalization.string("Screen Recording")
    }
}

func rowSubtitle(_ item: LibraryCore.LibraryItem) -> String {
    switch item {
    case .screenshot(let entry):
        return [
            entry.timestamp.formatted(date: .abbreviated, time: .shortened),
            entry.sourceAppName,
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    case .recording(let group):
        return [
            group.startedAt.formatted(date: .abbreviated, time: .shortened),
            librarySize(group.byteSize),
            group.segmentCount > 1 ? AppLocalization.string("%@ segments", String(group.segmentCount)) : nil,
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }
}

func cardSubtitle(_ item: LibraryCore.LibraryItem) -> String {
    switch item {
    case .screenshot(let entry):
        return entry.sourceAppName ?? entry.captureMode
    case .recording(let group):
        return [
            group.startedAt.formatted(date: .abbreviated, time: .shortened),
            librarySize(group.byteSize),
        ].joined(separator: " · ")
    }
}

func libraryAccessibilityLabel(_ item: LibraryCore.LibraryItem) -> String {
    switch item {
    case .screenshot(let entry):
        return AppLocalization.string(
            "Screenshot, %@, %@",
            itemTitle(item),
            entry.timestamp.formatted(date: .abbreviated, time: .shortened)
        )
    case .recording(let group):
        return AppLocalization.string(
            "%@, %@, %@, %@ segments",
            group.kind == .audio
                ? AppLocalization.string("Audio recording")
                : AppLocalization.string("Video recording"),
            itemTitle(item),
            libraryDuration(group.duration),
            String(group.segmentCount)
        )
    }
}

func typeLabel(_ kind: LibraryMediaKind) -> LocalizedStringKey {
    switch kind {
    case .screenshot: "Screenshot"
    case .audio: "Audio"
    case .video: "Video"
    }
}

func typeColor(_ kind: LibraryMediaKind) -> Color {
    switch kind {
    case .screenshot: Color.gray.opacity(0.85)
    case .audio: Color.purple.opacity(0.9)
    case .video: Color.blue.opacity(0.9)
    }
}

func dayTitle(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return AppLocalization.string("Today") }
    if calendar.isDateInYesterday(date) { return AppLocalization.string("Yesterday") }
    return date.formatted(.dateTime.year().month().day().weekday(.wide))
}

func libraryDuration(_ seconds: TimeInterval) -> String {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = [.hour, .minute, .second]
    formatter.unitsStyle = .positional
    formatter.zeroFormattingBehavior = [.pad]
    formatter.maximumUnitCount = 3
    return formatter.string(from: max(0, seconds.isFinite ? seconds : 0)) ?? "0:00"
}

func librarySize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
}
