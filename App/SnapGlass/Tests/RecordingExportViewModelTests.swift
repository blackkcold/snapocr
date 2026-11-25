import CaptureCore
import Foundation
import Testing

@Suite("Recording export view model")
@MainActor
struct RecordingExportViewModelTests {
    @Test("Starts with an empty segment selection and a disabled real assessment")
    func defaultSelectionIsEmpty() {
        let root = URL(fileURLWithPath: "/not-created/recordings", isDirectory: true)
        let index = root.appendingPathComponent(".SnapGlassSessions/recording-index.json")
        let model = RecordingExportViewModel(recordingRoot: root, indexURL: index)

        #expect(model.selectedSegmentIDs.isEmpty)
        #expect(model.assess().disabledReason == .emptySelection)
        #expect(!model.canExport)
    }

    @Test("Validated plan cannot be produced without a selected published segment")
    func emptySelectionCannotMakePlan() {
        let root = URL(fileURLWithPath: "/not-created/recordings", isDirectory: true)
        let index = root.appendingPathComponent(".SnapGlassSessions/recording-index.json")
        let model = RecordingExportViewModel(recordingRoot: root, indexURL: index)

        #expect(throws: ExportError.self) {
            try model.validatedPlan()
        }
    }

    @Test("Preview volume and export gain have independent state")
    func previewAndExportGainAreSeparate() {
        let root = URL(fileURLWithPath: "/not-created/recordings", isDirectory: true)
        let index = root.appendingPathComponent(".SnapGlassSessions/recording-index.json")
        let model = RecordingExportViewModel(recordingRoot: root, indexURL: index)

        model.setAudioGainDB(6)
        model.setPreviewGain(0.25)

        #expect(model.audioGainDB == 6)
        #expect(model.previewGain == 0.25)
    }
}
