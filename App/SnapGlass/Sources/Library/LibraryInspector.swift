import AVFoundation
import AVKit
import AppKit
import CaptureCore
import HistoryCore
import LibraryCore
import SwiftUI

struct LibraryInspector: View {
    @ObservedObject var viewModel: LibraryViewModel
    let item: LibraryCore.LibraryItem
    let captureViewModel: CaptureViewModel

    @State private var titleDraft = ""
    @State private var tagsDraft = ""
    @State private var noteDraft = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.s12) {
                header
                LibraryInspectorPreview(item: item, viewModel: viewModel)
                    .frame(height: 170)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                titleSection
                metadataSection
                if let group = item.recordingGroup {
                    tagAndNoteSection(group)
                    segmentSection(group)
                }
                actionSection
            }
            .padding(DS.Space.s12)
        }
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
        }
        .onAppear {
            titleDraft = item.recordingGroup?.title ?? ""
            tagsDraft = item.recordingGroup?.tags.joined(separator: ", ") ?? ""
            noteDraft = item.recordingGroup?.note ?? ""
        }
        .onChange(of: item.id) { _ in
            titleDraft = item.recordingGroup?.title ?? ""
            tagsDraft = item.recordingGroup?.tags.joined(separator: ", ") ?? ""
            noteDraft = item.recordingGroup?.note ?? ""
        }
    }

    private var header: some View {
        HStack(spacing: DS.Space.s6) {
            Text(typeLabel(item.mediaKind))
                .font(DS.Typography.caption)
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(typeColor(item.mediaKind), in: Capsule())

            if let group = item.recordingGroup, group.isGrouped {
                Text(AppLocalization.string("%@ segments", String(group.segmentCount)))
                    .font(DS.Typography.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task { await viewModel.toggleFavourite(item) }
            } label: {
                Image(systemName: item.isFavourite ? "star.fill" : "star")
                    .foregroundStyle(item.isFavourite ? Color.orange : .secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)

            Button {
                viewModel.isInspectorPresented = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var titleSection: some View {
        switch item {
        case .screenshot(let entry):
            VStack(alignment: .leading, spacing: 3) {
                Text(itemTitle(item))
                    .font(DS.Typography.title)
                    .lineLimit(2)
                Text(entry.timestamp, format: .dateTime.year().month().day().hour().minute())
                    .font(DS.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        case .recording(let group):
            VStack(alignment: .leading, spacing: 5) {
                TextField("Recording name", text: $titleDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(DS.Typography.body)
                    .onSubmit {
                        Task { await viewModel.renameSelectedRecording(to: titleDraft) }
                    }
                HStack {
                    Text(
                        group.kind == .audio
                            ? AppLocalization.string("Audio recording")
                            : AppLocalization.string("Screen recording"))
                    Text("·")
                    Text(group.startedAt, format: .dateTime.year().month().day().hour().minute())
                }
                .font(DS.Typography.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var metadataSection: some View {
        VStack(spacing: 0) {
            metadataRow("Type", typeLabelText(item.mediaKind))
            metadataRow("Date", item.date.formatted(date: .abbreviated, time: .shortened))
            if let duration = item.duration {
                metadataRow("Duration", libraryDuration(duration))
            }
            if let size = item.byteSize, size > 0 {
                metadataRow("Size", librarySize(size))
            }
            if let group = item.recordingGroup {
                metadataRow("Segments", "\(group.segmentCount)")
                metadataRow("Status", statusText(group))
                metadataRow("Location", group.roots.first?.path ?? "—")
                if group.roots.count > 1 {
                    metadataRow(
                        "Copies",
                        AppLocalization.string(
                            "%@ locations",
                            String(group.roots.count)
                        )
                    )
                }
            }
        }
    }

    private func metadataRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s8) {
            Text(label)
                .font(DS.Typography.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value)
                .font(DS.Typography.caption)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.5)
        }
    }

    private func tagAndNoteSection(_ group: LibraryRecordingGroup) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s6) {
            Text("Tags")
                .font(DS.Typography.captionStrong)
                .foregroundStyle(.secondary)

            TextField("Add tags separated by commas", text: $tagsDraft)
                .textFieldStyle(.roundedBorder)

            Text("Note")
                .font(DS.Typography.captionStrong)
                .foregroundStyle(.secondary)
                .padding(.top, DS.Space.s2)

            TextEditor(text: $noteDraft)
                .font(DS.Typography.body)
                .frame(height: 64)
                .padding(4)
                .background(
                    Color(nsColor: .textBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                }

            HStack {
                Spacer()
                Button("Save") {
                    Task {
                        await viewModel.updateTags(for: group, text: tagsDraft)
                        await viewModel.updateNote(for: group, text: noteDraft)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isBusy)
            }
        }
    }

    private func segmentSection(_ group: LibraryRecordingGroup) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Segments")
                .font(DS.Typography.captionStrong)
                .foregroundStyle(.secondary)
                .padding(.top, DS.Space.s2)

            ForEach(group.segments) { segment in
                HStack(spacing: DS.Space.s6) {
                    Text("\(segment.displayIndex)")
                        .font(DS.Typography.caption)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 17, height: 17)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                    Text(libraryDuration(segment.duration))
                        .font(DS.Typography.caption)
                        .monospacedDigit()
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
                                .font(.system(size: 8))
                        }
                        .buttonStyle(.plain)
                        .frame(width: 20, height: 20)
                    }
                }
                .frame(minHeight: 22)
            }
        }
    }

    private var actionSection: some View {
        VStack(spacing: DS.Space.s6) {
            if let group = item.recordingGroup {
                if group.isManualGroup {
                    Button {
                        Task { await viewModel.ungroup(group) }
                    } label: {
                        Label("Ungroup", systemImage: "rectangle.3.group")
                            .frame(maxWidth: .infinity)
                    }
                }

                Button {
                    viewModel.selectedItemID = item.id
                    viewModel.isShowingMergeSheet = true
                } label: {
                    Label("Merge & Export…", systemImage: "square.stack.3d.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(group.segmentCount < 2 || group.state != .complete)
            }

            if item.mediaKind == .screenshot, let entry = item.screenshot {
                Button {
                    Task { await viewModel.openScreenshot(entry, using: captureViewModel) }
                } label: {
                    Label("Open in Editor", systemImage: "pencil.and.outline")
                        .frame(maxWidth: .infinity)
                }
            }

            Button {
                viewModel.selection = [item.id]
                viewModel.isSelecting = true
                viewModel.isShowingExportSheet = true
            } label: {
                Label("Export…", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }

            Button {
                viewModel.revealInFinder(item)
            } label: {
                Label("Show in Finder", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }

            Button(role: .destructive) {
                viewModel.selection = [item.id]
                viewModel.isSelecting = true
                viewModel.requestDeleteSelection()
            } label: {
                Label("Delete…", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, DS.Space.s2)
    }

    private func statusText(_ group: LibraryRecordingGroup) -> String {
        switch group.state {
        case .complete:
            return AppLocalization.string("Complete")
        case .partial(let missing):
            return AppLocalization.string("%@ segment(s) missing", String(missing))
        case .offline:
            return AppLocalization.string("Offline")
        }
    }

    private func typeLabelText(_ kind: LibraryMediaKind) -> String {
        switch kind {
        case .screenshot: return AppLocalization.string("Screenshot")
        case .audio: return AppLocalization.string("Audio")
        case .video: return AppLocalization.string("Video")
        }
    }
}

// MARK: - Preview

private struct LibraryInspectorPreview: View {
    let item: LibraryCore.LibraryItem
    @ObservedObject var viewModel: LibraryViewModel

    @State private var image: NSImage?
    @State private var player: AVPlayer?
    @State private var audioPlayer: AVAudioPlayer?
    @State private var isPlaying = false

    var body: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)

            switch item.mediaKind {
            case .screenshot:
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    placeholder(icon: "photo")
                }
            case .video:
                if let player {
                    VideoPlayer(player: player)
                } else {
                    placeholder(icon: "play.rectangle")
                }
            case .audio:
                audioPreview
            }
        }
        .task(id: item.id) {
            await load()
        }
        .onDisappear {
            player?.pause()
            audioPlayer?.stop()
        }
    }

    private var audioPreview: some View {
        VStack(spacing: DS.Space.s8) {
            HStack(spacing: 3) {
                ForEach(Array((0..<32).enumerated()), id: \.offset) { index, _ in
                    Capsule()
                        .fill(Color.purple.opacity(0.65))
                        .frame(width: 3, height: CGFloat(12 + (index * 7) % 42))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 70)

            Button {
                guard let audioPlayer else { return }
                if audioPlayer.isPlaying {
                    audioPlayer.pause()
                    isPlaying = false
                } else {
                    audioPlayer.play()
                    isPlaying = true
                }
            } label: {
                Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
            }
            .disabled(audioPlayer == nil)
        }
        .padding(DS.Space.s12)
    }

    private func placeholder(icon: String) -> some View {
        VStack(spacing: DS.Space.s6) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
            Text("Preview unavailable")
                .font(DS.Typography.caption)
        }
        .foregroundStyle(.secondary)
    }

    private func load() async {
        switch item {
        case .screenshot(let entry):
            guard let history = HistoryActor.shared,
                let data = try? await history.imageData(for: entry.id)
            else { return }
            image = NSImage(data: data)
        case .recording(let group):
            let url = group.mediaURL
            if group.kind == .screen, let url {
                player = AVPlayer(url: url)
            } else if let url {
                audioPlayer = try? AVAudioPlayer(contentsOf: url)
                audioPlayer?.prepareToPlay()
            }
        }
    }
}
