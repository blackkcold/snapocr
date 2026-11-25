import Foundation
import Testing

@Suite("Recording export summary")
struct RecordingExportSummaryTests {
    @Test("Keeps the 1:58:00 selection under the 1:59:30 maximum")
    func selectionBelowMaximum() {
        let summary = RecordingExportSummary(
            selectedDuration: 7_080,
            maximumDuration: 7_170,
            overage: 0,
            videoPassthroughLabel: "Video passthrough",
            audioOperationLabel: "Audio passthrough",
            trackCount: 2,
            missingState: .none
        )

        #expect(summary.selectedDuration == 7_080)
        #expect(summary.maximumDuration == 7_170)
        #expect(summary.overage == 0)
    }

    @Test("Retains an explicit 32 second overage and missing segment identity")
    func overageAndMissingState() {
        let missingID = UUID()
        let summary = RecordingExportSummary(
            selectedDuration: 7_202,
            maximumDuration: 7_170,
            overage: 32,
            videoPassthroughLabel: "Audio only",
            audioOperationLabel: "Audio re-encode",
            trackCount: 1,
            missingState: .missing(segmentID: missingID)
        )

        #expect(summary.selectedDuration == 7_202)
        #expect(summary.overage == 32)
        #expect(summary.missingState == .missing(segmentID: missingID))
        #expect(summary.trackCount == 1)
    }
}
