import AppKit
import SharedKit
import SwiftUI

struct RecordingsWindow: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var viewModel: RecordingExportViewModel

    init() {
        let fileManager = FileManager.default
        let recordingRoot = RecordingDestinationPreferences.directory(in: .standard, fileManager: fileManager)
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Movies", isDirectory: true)
                .appendingPathComponent("SnapGlass", isDirectory: true)
                .appendingPathComponent("Recordings", isDirectory: true)
        let indexURL = recordingRoot
            .appendingPathComponent(".SnapGlassSessions", isDirectory: true)
            .appendingPathComponent("recording-index.json")
        _viewModel = StateObject(wrappedValue: RecordingExportViewModel(
            recordingRoot: recordingRoot,
            indexURL: indexURL
        ))
    }

    var body: some View {
        GlassGroup {
            RecordingExportView(viewModel: viewModel)
                .frame(
                    minWidth: PreferencesSpacing.minWindowWidth,
                    idealWidth: PreferencesSpacing.idealWindowWidth,
                    maxWidth: .infinity,
                    minHeight: PreferencesSpacing.minWindowHeight,
                    idealHeight: PreferencesSpacing.idealWindowHeight,
                    maxHeight: .infinity
                )
                .padding(12)
                .background {
                    if reduceTransparency {
                        Color(nsColor: .windowBackgroundColor)
                    } else {
                        Rectangle().fill(.ultraThinMaterial)
                    }
                }
                .containerShape(
                    RoundedRectangle(
                        cornerRadius: PreferencesSpacing.resolvedWindowCornerRadius(
                            forWidth: PreferencesSpacing.idealWindowWidth
                        )
                    )
                )
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: viewModel.selectedSessionID)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: viewModel.selectedSegmentIDs)
                .onAppear {
                    Task { await viewModel.loadPublishedSessions() }
                }
                .onDisappear(perform: viewModel.windowDidClose)
                .onExitCommand {
                    viewModel.cancel()
                    dismiss()
                }
        }
    }

    @Environment(\.dismiss) private var dismiss
}
