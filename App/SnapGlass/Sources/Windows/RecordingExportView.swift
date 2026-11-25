import AppKit
import CaptureCore
import SwiftUI

struct RecordingExportView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: RecordingExportViewModel
    @State var trimTarget: RecordingExportTrimTarget?
    /// Session waiting for the delete confirmation.
    @State var discardTarget: UUID?

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
            Text(
                "The recording folder moves to the Trash. You can restore it from the Trash until the Trash is emptied."
            )
        }
        .task {
            // The launch scan already warmed the catalog; this keeps the window
            // correct when it opens later or after a session was discarded.
            await viewModel.scanRecoverableRecordings()
        }
    }

    @ViewBuilder
    var detailPane: some View {
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

    var emptySelectionPane: some View {
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

    func sessionDetails(_ session: RecordingSessionRecord) -> some View {
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

    var emptySessionSegments: some View {
        VStack(spacing: 8) {
            Text("No published segments")
                .font(.headline)
            Text("This completed session has no media available for export.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
    }

    func revealRecordingRoot() {
        NSWorkspace.shared.activateFileViewerSelecting([viewModel.recordingRoot])
    }
}

struct RecordingExportTrimTarget: Identifiable {
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
