import AppKit
import CaptureCore
import SwiftUI

struct RecordingExportView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: RecordingExportViewModel
    @State private var trimTarget: RecordingExportTrimTarget?
    /// Session waiting for the delete confirmation.
    @State private var discardTarget: UUID?

    var body: some View {
        ScrollView {
            PreferencesCardGrid {
                PreferencesCard {
                    PreferencesCardHeader(systemImage: "waveform", title: "Recordings") {
                        Button("Close") {
                            viewModel.cancel()
                            dismiss()
                        }
                        .keyboardShortcut(.escape, modifiers: [])
                        .frame(minWidth: 28, minHeight: 28)
                    }

                    HStack(alignment: .top, spacing: 16) {
                        sessionList
                            .frame(width: 235, alignment: .leading)

                        Divider()

                        detailPane
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 390, alignment: .top)
                }
            }
        }
        .sheet(item: $trimTarget) { target in
            RecordingExportTrimSheet(segment: target.segment, range: target.range) { range in
                viewModel.setTrimRange(range, for: target.segment.id)
            }
        }
        .confirmationDialog(
            Text("Delete incomplete recording?"),
            isPresented: Binding(
                get: { discardTarget != nil },
                set: { if !$0 { discardTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let sessionID = discardTarget {
                Button("Delete", role: .destructive) {
                    discardTarget = nil
                    Task { await viewModel.discardRecording(sessionID) }
                }
            }
            Button("Cancel", role: .cancel) { discardTarget = nil }
        } message: {
            // swiftlint:disable:next line_length
            Text("The recording folder moves to the Trash. You can restore it from the Trash until the Trash is emptied.")
        }
        .task {
            // The launch scan already warmed the catalog; this keeps the window
            // correct when it opens later or after a session was discarded.
            await viewModel.scanRecoverableRecordings()
        }
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sessions")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 4)
                if viewModel.isLoading || viewModel.isScanningRecoverable {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(Text("Loading recordings"))
                }
                Button {
                    Task {
                        await viewModel.loadPublishedSessions()
                        await viewModel.scanRecoverableRecordings()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(minWidth: 28, minHeight: 28)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Refresh recordings"))
            }

            recoverableSection

            if viewModel.publishedSessions.isEmpty && !viewModel.isLoading {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("No Recordings Yet")
                        .font(.headline)
                    Text("Your audio recordings will appear here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Locate recording folder") { revealRecordingRoot() }
                        .frame(minHeight: 28)
                }
                .frame(maxWidth: .infinity, minHeight: 260, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(viewModel.publishedSessions, id: \.id) { record in
                            sessionButton(record)
                        }
                    }
                }
                .frame(maxHeight: 430)
            }
        }
    }

    /// Interrupted sessions that still have media but no index entry.
    @ViewBuilder
    private var recoverableSection: some View {
        if !viewModel.recoverableRecordings.isEmpty || viewModel.isScanningRecoverable {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.counterclockwise.circle")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text(AppLocalization.string("Recoverable (%d)", viewModel.recoverableRecordings.count))
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 4)
                    if viewModel.isScanningRecoverable {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(Text("Checking for unfinished recordings…"))
                    }
                }
                ForEach(viewModel.recoverableRecordings, id: \.id) { recording in
                    recoverableRow(recording)
                }
            }
            .padding(8)
            .background {
                RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08))
            }
            .accessibilityElement(children: .contain)
        }

        if let notice = viewModel.recoveryNotice {
            Label(recoveryNoticeText(notice), systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .accessibilityElement(children: .combine)
                .task {
                    try? await Task.sleep(for: .seconds(5))
                    viewModel.clearRecoveryNotice()
                }
        }
    }

    private func recoverableRow(_ recording: RecoverableRecording) -> some View {
        let isBusy = viewModel.recoveringRecordingID != nil || viewModel.discardingRecordingID != nil
        let isRecovering = viewModel.recoveringRecordingID == recording.id
        let isDiscarding = viewModel.discardingRecordingID == recording.id
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: recording.kind == .audio ? "waveform" : "rectangle.dashed.badge.record")
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(recording.kind == .audio
                        ? LocalizedStringKey("Incomplete audio recording")
                        : LocalizedStringKey("Incomplete screen recording"))
                        .font(.callout.weight(.medium))
                    HStack(spacing: 6) {
                        if recording.duration > 0 {
                            Text(Self.duration(recording.duration))
                                .monospacedDigit()
                        }
                        Text(recording.createdAt, style: .time)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 2)
            }
            HStack(spacing: 8) {
                if isRecovering || isDiscarding {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer(minLength: 2)
                Button("Save to list") {
                    Task { await viewModel.recoverRecording(recording.id) }
                }
                .disabled(isBusy)
                .frame(minHeight: 24)
                .accessibilityLabel(Text("Save to list"))
                Button("Delete") {
                    discardTarget = recording.id
                }
                .disabled(isBusy)
                .frame(minHeight: 24)
                .accessibilityLabel(Text("Move incomplete recording to the Trash"))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .contain)
    }

    private func recoveryNoticeText(_ notice: RecordingRecoveryNotice) -> String {
        switch notice {
        case .recovered:
            AppLocalization.string("Recovered recording added to your list.")
        case .discarded:
            AppLocalization.string("Recording moved to the Trash.")
        }
    }

    private func sessionButton(_ record: RecordingSessionRecord) -> some View {
        let selected = viewModel.selectedSessionID == record.id
        let duration = Self.duration(record.segments
            .filter { $0.state == .published }
            .reduce(0.0) { $0 + Double($1.sampleCount) / 48_000 })
        return Button {
            Task { await viewModel.selectSession(record.id) }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(record.startedAt, style: .date)
                    .font(.body.weight(.medium))
                HStack(spacing: 6) {
                    Text(record.kind == .screen ? "Video" : "Audio")
                    Text("·")
                    Text(duration)
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .padding(.horizontal, 8)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.14))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(AppLocalization.string(
            "Recording session %@, %@",
            record.startedAt.formatted(date: .abbreviated, time: .shortened),
            duration
        )))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var detailPane: some View {
        if viewModel.isLoading || viewModel.isOpeningSession {
            VStack(spacing: 12) {
                ProgressView()
                Text(viewModel.isOpeningSession ? "Opening recording…" : "Loading recordings…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 320)
        } else if let session = viewModel.session {
            sessionDetails(session)
        } else {
            emptySelectionPane
        }
    }

    private var emptySelectionPane: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            if viewModel.publishedSessions.isEmpty {
                Text("No completed recordings")
                    .font(.headline)
                Text("Completed sessions with published segments will appear here.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            } else {
                Text("Choose a recording")
                    .font(.headline)
                Text("Choose a session, then select the segments to export.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 320)
        .accessibilityElement(children: .combine)
    }

    private func sessionDetails(_ session: RecordingSessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.startedAt, style: .date)
                        .font(.headline)
                    Text(session.kind == .screen ? "Video recording" : "Audio recording")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button("Locate recording folder") { revealRecordingRoot() }
                    .frame(minHeight: 28)
            }

            if viewModel.isAssessing {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking selected media…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }

            if session.segments.isEmpty {
                emptySessionSegments
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(session.segments, id: \.id) { segment in
                            segmentRow(segment)
                        }
                    }
                }
                .frame(maxHeight: 230)
            }

            if viewModel.selectedSegmentIDs.isEmpty {
                Text("Select one or more published segments to assess an export.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                outputControls
                assessmentSummary
            }

            if let message = viewModel.message {
                Text(messageText(message))
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Text(messageText(message)))
            }

            if let outputURL = viewModel.succeededOutputURL {
                Label(AppLocalization.string("Exported to %@", outputURL.path), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .textSelection(.enabled)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                }
                .frame(minHeight: 28)
            }

            exportActions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptySessionSegments: some View {
        VStack(spacing: 8) {
            Text("No published segments")
                .font(.headline)
            Text("This completed session has no media available for export.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
    }

    private func segmentRow(_ segment: PublishedSegment) -> some View {
        let isMissing = segment.state == .missing
        let duration = Self.duration(Double(segment.sampleCount) / 48_000)
        return HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { viewModel.selectedSegmentIDs.contains(segment.id) },
                set: { viewModel.setSegmentSelected(segment.id, isSelected: $0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(AppLocalization.string("Segment %d", segment.index + 1))
                    Text(duration)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
            .disabled(isMissing || segment.state != .published)
            .accessibilityHint(
                Text(
                    isMissing
                        ? "This segment is missing and cannot be selected."
                        : "Press Space to select or deselect this segment."
                )
            )

            Spacer(minLength: 2)

            if isMissing {
                Text("Missing")
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("Locate") { revealRecordingRoot() }
                    .frame(minWidth: 28, minHeight: 28)
                    .accessibilityLabel(Text("Locate missing segment in recording folder"))
                    .accessibilityHint(Text("Opens the configured recording folder in Finder."))
            } else if segment.state == .published {
                Button {
                    viewModel.togglePreview(for: segment.id)
                } label: {
                    Image(systemName: viewModel.previewSegmentID == segment.id ? "stop.fill" : "play.fill")
                        .frame(minWidth: 28, minHeight: 28)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text(viewModel.previewSegmentID == segment.id ? "Stop preview" : "Preview segment"))
                .accessibilityHint(Text("Plays this closed recording segment without changing export gain."))

                Button {
                    trimTarget = RecordingExportTrimTarget(
                        segment: segment,
                        range: viewModel.trimRange(for: segment)
                    )
                } label: {
                    Image(systemName: "scissors")
                        .frame(minWidth: 28, minHeight: 28)
                }
                .buttonStyle(.borderless)
                .disabled(segment.sampleCount <= 1)
                .accessibilityLabel(Text("Trim Ends"))
                .accessibilityHint(Text("Adjust the selected start and end samples for this segment."))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(isMissing ? Color.red.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
    }

    private var outputControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Output format", selection: Binding(
                get: { viewModel.outputMode },
                set: { viewModel.setOutputMode($0) }
            )) {
                ForEach(viewModel.availableOutputModes, id: \.self) { mode in
                    outputModeTitle(mode).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 8) {
                Text("Output name")
                    .frame(width: 90, alignment: .leading)
                TextField("Recording name", text: Binding(
                    get: { viewModel.outputStem },
                    set: { viewModel.setOutputStem($0) }
                ))
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 8) {
                Text("Destination")
                    .frame(width: 90, alignment: .leading)
                Text(viewModel.outputDirectory.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Button("Choose Folder…", action: chooseOutputDirectory)
                    .frame(minHeight: 28)
            }

            if !viewModel.selectedSegmentIDs.isEmpty {
                gainControl(
                    title: "Export gain (dB)",
                    value: viewModel.audioGainDB,
                    range: -24...12,
                    valueText: String(format: "%.1f dB", viewModel.audioGainDB),
                    setter: viewModel.setAudioGainDB
                )
            }
            if viewModel.hasPreviewableSegment {
                gainControl(
                    title: "Preview volume",
                    value: viewModel.previewGain,
                    range: 0...1,
                    valueText: "\(Int((viewModel.previewGain * 100).rounded()))%",
                    setter: viewModel.setPreviewGain
                )
            }
        }
    }

    private func gainControl(
        title: LocalizedStringKey,
        value: Double,
        range: ClosedRange<Double>,
        valueText: String,
        setter: @escaping (Double) -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .frame(width: 90, alignment: .leading)
            Slider(value: Binding(get: { value }, set: setter), in: range)
                .accessibilityLabel(Text(title))
            Text(valueText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 55, alignment: .trailing)
        }
    }

    private var assessmentSummary: some View {
        let assessment = viewModel.assess()
        let summary = viewModel.summary
        let overLimit = assessment.overageSeconds > 0
        return VStack(alignment: .leading, spacing: 6) {
            if let summary {
                LabeledContent("Requested", value: Self.duration(summary.selectedDuration))
                LabeledContent("Effective", value: Self.duration(assessment.effectiveDuration))
                LabeledContent("Maximum", value: Self.duration(summary.maximumDuration))
                if summary.overage > 0 {
                    LabeledContent("Over by", value: Self.duration(summary.overage))
                        .foregroundStyle(.red)
                }
                LabeledContent {
                    localizedSummaryLabel(summary.videoPassthroughLabel)
                } label: {
                    Text("Video")
                }
                LabeledContent {
                    localizedSummaryLabel(summary.audioOperationLabel)
                } label: {
                    Text("Audio")
                }
                LabeledContent("Tracks", value: "\(summary.trackCount)")
                if case .missing(let segmentID) = summary.missingState {
                    Text(AppLocalization.string(
                        "A segment is missing (%@). It is disabled; use Locate to open the recording folder.",
                        segmentID.uuidString
                    ))
                    .font(.caption)
                    .foregroundStyle(.red)
                }
            }

            if viewModel.isAssessing {
                Text("Verifying output and selected media…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let reason = assessment.disabledReason {
                Text(disabledReasonText(reason))
                    .font(.callout.weight(overLimit ? .semibold : .regular))
                    .foregroundStyle(overLimit ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(plannedOutput(assessment.outputSpec))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if overLimit {
                RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.10))
            } else {
                RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06))
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var exportActions: some View {
        HStack(spacing: 8) {
            if viewModel.isExporting {
                ProgressView(value: viewModel.exportProgress)
                    .frame(maxWidth: 150)
                    .accessibilityLabel(Text("Export progress"))
                Text("\(Int((viewModel.exportProgress * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("Cancel export") { viewModel.cancel() }
                    .frame(minHeight: 28)
            }
            Spacer(minLength: 4)
            Button("Export") {
                Task {
                    do { _ = try await viewModel.export() } catch { }
                }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canExport)
            .frame(minHeight: 28)
        }
    }

    private func outputModeTitle(_ mode: RecordingExportOutputMode) -> Text {
        switch mode {
        case .mp4Video: Text("MP4 video")
        case .mixedAudio: Text("Mixed audio")
        case .separatedAudio: Text("Audio tracks")
        }
    }

    private func localizedSummaryLabel(_ label: String) -> Text {
        Text(LocalizedStringKey(label))
    }

    private func disabledReasonText(_ reason: ExportDisabledReason) -> String {
        switch reason {
        case .emptySelection:
            AppLocalization.string("Select one or more published segments to export.")
        case .overLimit(let seconds):
            AppLocalization.string("Export exceeds the 1:59:30 limit by %@.", Self.duration(seconds))
        case .incompatibleCodec:
            AppLocalization.string(
                "Selected video segments use incompatible codecs. Export them separately or choose audio-only."
            )
        case .missingSource:
            AppLocalization.string(
                "A selected source is unavailable. Use Locate to inspect the recording folder or deselect that segment."
            )
        case .destinationUnavailable:
            AppLocalization.string("Choose an existing writable destination folder and a valid output name.")
        case .passthroughUnsupported:
            AppLocalization.string("Video passthrough cannot preserve this trim. Adjust the trim or choose audio-only.")
        }
    }

    private func messageText(_ message: RecordingExportViewMessage) -> String {
        switch message {
        case .listingFailed:
            return AppLocalization.string("Could not read completed recordings from the configured recording folder.")
        case .sessionUnavailable:
            return AppLocalization.string(
                "This recording is no longer available. Refresh the session list and try again."
            )
        case .previewUnavailable:
            return AppLocalization.string(
                "This segment is not available for preview. Use Locate to inspect the recording folder."
            )
        case .previewFailed:
            return AppLocalization.string("Audio preview could not be started.")
        case .export(let error):
            return exportErrorText(error)
        case .recoveryScanFailed:
            return AppLocalization.string("Could not check for unfinished recordings.")
        case .recoveryFailed:
            return AppLocalization.string("Could not save this recording. The original folder was kept.")
        case .discardFailed:
            return AppLocalization.string("Could not move this recording to the Trash. The recording was kept.")
        }
    }

    private func exportErrorText(_ error: ExportError) -> String {
        switch error {
        case .emptySelection:
            return AppLocalization.string("Select one or more published segments to export.")
        case .overLimit(let seconds):
            return AppLocalization.string("Export exceeds the 1:59:30 limit by %@.", Self.duration(seconds))
        case .incompatibleCodec:
            return AppLocalization.string(
                "Selected video segments use incompatible codecs. Export them separately or choose audio-only."
            )
        case .missingSource:
            return AppLocalization.string(
                // swiftlint:disable:next line_length
                "A selected source is unavailable. The original recording was kept; use Locate or choose another segment."
            )
        case .destinationUnavailable:
            return AppLocalization.string(
                "The destination is unavailable. The original recording was kept; choose an existing folder."
            )
        case .passthroughUnsupported:
            return AppLocalization.string(
                // swiftlint:disable:next line_length
                "Video passthrough is unavailable for this trim. The original recording was kept; adjust the trim or choose audio-only."
            )
        case .exportInProgress:
            return AppLocalization.string("An export is already in progress.")
        case .cancelled(let stagingURL):
            guard let stagingURL else {
                return AppLocalization.string("Export cancelled. The original recording was kept.")
            }
            return AppLocalization.string(
                "Export cancelled. The original and staging output were kept at %@.",
                stagingURL.path
            )
        case .publishFailed(let stagingURL):
            guard let stagingURL else {
                return AppLocalization.string(
                    "Export failed. The original recording was kept; choose another destination and retry."
                )
            }
            return AppLocalization.string(
                "Export failed. The original and staging output were kept at %@.",
                stagingURL.path
            )
        }
    }

    private func plannedOutput(_ spec: ExportOutputSpec) -> String {
        let name: String
        switch spec.shape {
        case .singleFile(let fileExtension):
            name = "\(spec.destination.stem).\(fileExtension)"
        case .directory:
            name = "\(spec.destination.stem)/"
        }
        return AppLocalization.string(
            "Planned output: %@",
            spec.destination.directory.appendingPathComponent(name).path
        )
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = AppLocalization.string("Choose Folder")
        panel.directoryURL = viewModel.outputDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        viewModel.setOutputDirectory(url)
    }

    private func revealRecordingRoot() {
        NSWorkspace.shared.activateFileViewerSelecting([viewModel.recordingRoot])
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = [.pad]
        formatter.maximumUnitCount = 3
        return formatter.string(from: max(0, seconds.isFinite ? seconds : 0)) ?? "0:00"
    }
}

private struct RecordingExportTrimTarget: Identifiable {
    let segment: PublishedSegment
    let range: SampleRange

    var id: UUID { segment.id }
}

private struct RecordingExportTrimSheet: View {
    @Environment(\.dismiss) private var dismiss
    let segment: PublishedSegment
    let range: SampleRange
    let onSave: (SampleRange) -> Void
    @State private var startSeconds: Double
    @State private var endSeconds: Double

    init(segment: PublishedSegment, range: SampleRange, onSave: @escaping (SampleRange) -> Void) {
        self.segment = segment
        self.range = range
        self.onSave = onSave
        let start = Double(segment.startSample)
        _startSeconds = State(initialValue: max(0, Double(range.startSample) - start) / 48_000)
        _endSeconds = State(
            initialValue: min(
                Double(segment.sampleCount),
                Double(range.startSample + range.sampleCount) - start
            ) / 48_000
        )
    }

    private var duration: Double { Double(max(1, segment.sampleCount)) / 48_000 }
    private var minimumSpan: Double { 1 / 48_000 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Trim segment")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Trim start")
                    Spacer()
                    Text(Self.durationText(startSeconds))
                        .monospacedDigit()
                }
                Slider(value: $startSeconds, in: 0...max(0, min(duration, endSeconds - minimumSpan)))
                    .accessibilityLabel(Text("Trim start"))
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Trim end")
                    Spacer()
                    Text(Self.durationText(endSeconds))
                        .monospacedDigit()
                }
                Slider(value: $endSeconds, in: min(duration, startSeconds + minimumSpan)...duration)
                    .accessibilityLabel(Text("Trim end"))
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .frame(minHeight: 28)
                Button("Apply") {
                    let startSample = segment.startSample + Int64((startSeconds * 48_000).rounded(.down))
                    let endSample = min(
                        segment.startSample + segment.sampleCount,
                        segment.startSample + Int64((endSeconds * 48_000).rounded(.up))
                    )
                    guard endSample > startSample else { return }
                    onSave(SampleRange(startSample: startSample, sampleCount: endSample - startSample))
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 28)
            }
        }
        .padding(20)
        .frame(width: 430)
    }

    private static func durationText(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = [.pad]
        return formatter.string(from: max(0, seconds)) ?? "0:00"
    }
}
