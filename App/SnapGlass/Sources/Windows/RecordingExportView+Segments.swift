import AppKit
import CaptureCore
import SwiftUI

extension RecordingExportView {
    func segmentRow(_ segment: PublishedSegment) -> some View {
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

    var outputControls: some View {
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

    func gainControl(
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

    var assessmentSummary: some View {
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

    var exportActions: some View {
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

    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = AppLocalization.string("Choose Folder")
        panel.directoryURL = viewModel.outputDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        viewModel.setOutputDirectory(url)
    }
}
