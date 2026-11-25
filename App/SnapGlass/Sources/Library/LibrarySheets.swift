import AppKit
import CaptureCore
import LibraryCore
import SwiftUI

// MARK: - Delete

struct LibraryDeleteSheet: View {
    @ObservedObject var viewModel: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    private var screenshotCount: Int {
        viewModel.selectionItems.filter { $0.mediaKind == .screenshot }.count
    }

    private var recordingCount: Int {
        viewModel.selectionItems.filter { $0.recordingGroup != nil }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s12) {
            Text("Delete selected items?")
                .font(DS.Typography.title)

            if screenshotCount > 0 {
                Label(
                    AppLocalization.string(
                        "%@ screenshot(s) will be permanently deleted. You can undo for 6 seconds.",
                        String(screenshotCount)
                    ),
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.red)
            }

            if recordingCount > 0 {
                Label(
                    AppLocalization.string(
                        "%@ recording(s) will move to the Trash. You can restore them from the Trash.",
                        String(recordingCount)
                    ),
                    systemImage: "trash"
                )
                .foregroundStyle(.secondary)
            }

            Text("This action affects only the selected items. Hidden items are not included.")
                .font(DS.Typography.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Delete", role: .destructive) {
                    Task {
                        await viewModel.performDeleteSelection()
                        dismiss()
                    }
                }
                .disabled(viewModel.isBusy)
            }
        }
        .padding(DS.Space.s20)
        .frame(width: 440)
        .interactiveDismissDisabled(viewModel.isBusy)
    }
}

// MARK: - Export

struct LibraryExportSheet: View {
    @ObservedObject var viewModel: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var destination = LibraryPaths.defaultExportDirectory
    @State private var layout: LibraryExportLayout = .byType
    @State private var includeManifest = true

    private var items: [LibraryCore.LibraryItem] {
        viewModel.selectionItems.isEmpty ? viewModel.filteredItems : viewModel.selectionItems
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s12) {
            Text("Export")
                .font(DS.Typography.title)
            Text(AppLocalization.string("%@ item(s) will be exported.", String(items.count)))
                .font(DS.Typography.body)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: DS.Space.s8) {
                HStack {
                    Text("Destination")
                    Spacer()
                    Text(destination.path)
                        .font(DS.Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose…") { chooseDestination() }
                }

                Picker("Layout", selection: $layout) {
                    Text("By type").tag(LibraryExportLayout.byType)
                    Text("By date").tag(LibraryExportLayout.byDate)
                    Text("Flat").tag(LibraryExportLayout.flat)
                }
                .pickerStyle(.segmented)

                Toggle("Include manifest.csv", isOn: $includeManifest)
            }
            .padding(DS.Space.s10)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )

            Text("Recordings are copied as original files. Merging is a separate action.")
                .font(DS.Typography.caption)
                .foregroundStyle(.secondary)

            if let progress = viewModel.exportProgress {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress)
                    Text(viewModel.exportMessage ?? "Exporting…")
                        .font(DS.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .disabled(viewModel.isBusy)
                Button("Export") {
                    let options = LibraryExportOptions(
                        destination: destination,
                        layout: layout,
                        includeManifest: includeManifest
                    )
                    Task {
                        await viewModel.exportSelection(options: options)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isBusy || items.isEmpty)
            }
        }
        .padding(DS.Space.s20)
        .frame(width: 480)
        .interactiveDismissDisabled(viewModel.isBusy)
        .onAppear {
            if let last = viewModel.lastOutputURLs.first {
                destination = last.deletingLastPathComponent()
            }
        }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = AppLocalization.string("Choose Folder")
        panel.directoryURL = destination
        if panel.runModal() == .OK, let url = panel.url {
            destination = url
        }
    }
}

// MARK: - Merge

struct LibraryMergeSheet: View {
    @ObservedObject var viewModel: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var destination = LibraryPaths.defaultExportDirectory

    private var groups: [LibraryRecordingGroup] {
        viewModel.mergeGroups
    }

    private var totalSegments: Int {
        groups.reduce(0) { $0 + $1.segmentCount }
    }

    private var totalDuration: TimeInterval {
        groups.reduce(0) { $0 + $1.duration }
    }

    private var totalParts: Int {
        groups.reduce(0) { partial, group in
            partial + MergePartPlanner.parts(
                segmentDurations: group.segments.map(\.duration),
                maximumDuration: RecordingExportPlanner.maximumExportDuration
            ).count
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s12) {
            if !groups.isEmpty {
                Text("Merge & Export")
                    .font(DS.Typography.title)
                Text(
                    AppLocalization.string(
                        "%@ recordings · %@ segments · %@ · source files will be kept.",
                        String(groups.count),
                        String(totalSegments),
                        libraryDuration(totalDuration)
                    )
                )
                .font(DS.Typography.body)
                .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 5) {
                    ForEach(groups) { group in
                        HStack(spacing: DS.Space.s8) {
                            Image(systemName: group.kind == .audio ? "waveform" : "rectangle.dashed.badge.record")
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            Text(group.title.isEmpty ? defaultTitle(group) : group.title)
                                .font(DS.Typography.bodyStrong)
                                .lineLimit(1)
                            Spacer()
                            Text(
                                AppLocalization.string(
                                    "%@ segments · %@",
                                    String(group.segmentCount),
                                    libraryDuration(group.duration)
                                )
                            )
                            .font(DS.Typography.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        }
                    }
                }
                .padding(DS.Space.s10)
                .background(
                    Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )

                if totalParts > groups.count {
                    Label(
                        AppLocalization.string(
                            "This merge exceeds 1:59:30 and will create %@ files, split at segment boundaries.",
                            String(totalParts)
                        ),
                        systemImage: "info.circle"
                    )
                    .font(DS.Typography.caption)
                    .foregroundStyle(.orange)
                }

                if groups.contains(where: { $0.state != .complete }) {
                    Label("Some segments are missing or offline. Merge is unavailable.", systemImage: "exclamationmark.triangle")
                        .font(DS.Typography.caption)
                        .foregroundStyle(.red)
                }

                HStack {
                    Text("Name")
                    TextField("Merged recording", text: $title)
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Text("Destination")
                    Spacer()
                    Text(destination.path)
                        .font(DS.Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose…") { chooseDestination() }
                }

                if let progress = viewModel.mergeProgress {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: progress)
                        Text(viewModel.mergeMessage ?? "Merging…")
                            .font(DS.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Choose one recording to merge.")
                    .font(DS.Typography.body)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .disabled(viewModel.isBusy)
                Button("Merge") {
                    Task {
                        await viewModel.mergeSelected(
                            destination: destination,
                            outputTitle: title
                        )
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isBusy || !viewModel.canMergeSelection)
            }
        }
        .padding(DS.Space.s20)
        .frame(width: 500)
        .interactiveDismissDisabled(viewModel.isBusy)
        .onAppear {
            guard let first = groups.first else { return }
            title = groups.count == 1
                ? (first.title.isEmpty ? defaultTitle(first) : first.title)
                : AppLocalization.string("Merged Recordings")
            destination = LibraryPaths.defaultExportDirectory
        }
    }

    private func defaultTitle(_ group: LibraryRecordingGroup) -> String {
        let kind = group.kind == .audio
            ? AppLocalization.string("Audio Recording")
            : AppLocalization.string("Screen Recording")
        return "\(kind) \(group.startedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = AppLocalization.string("Choose Folder")
        panel.directoryURL = destination
        if panel.runModal() == .OK, let url = panel.url {
            destination = url
        }
    }
}

// MARK: - Recoverable

struct LibraryRecoverableSheet: View {
    @ObservedObject var viewModel: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s12) {
            HStack {
                Text("Incomplete Recordings")
                    .font(DS.Typography.title)
                Spacer()
                Button("Done") { dismiss() }
            }

            if viewModel.recoverable.isEmpty {
                Text("Nothing to recover.")
                    .font(DS.Typography.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    VStack(spacing: DS.Space.s8) {
                        ForEach(viewModel.recoverable) { recording in
                            HStack(spacing: DS.Space.s10) {
                                Image(systemName: recording.kind == .audio
                                      ? "waveform" : "rectangle.dashed.badge.record")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(recording.kind == .audio
                                         ? "Incomplete audio recording"
                                         : "Incomplete screen recording")
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
                }
            }
        }
        .padding(DS.Space.s20)
        .frame(width: 520)
        .frame(minHeight: 260)
    }
}
