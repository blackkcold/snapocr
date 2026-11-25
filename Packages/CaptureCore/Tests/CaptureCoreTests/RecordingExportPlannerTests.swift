import XCTest
@testable import CaptureCore

final class RecordingExportPlannerTests: XCTestCase {
    func testDefaultSelectionIsEmptyAndRetainsDestinationInAssessment() {
        let destination = ExportDestination(
            directory: URL(fileURLWithPath: "/recordings", isDirectory: true),
            stem: "session-export"
        )
        let session = RecordingSessionRecord(
            id: UUID(), kind: .audio, layout: .mixed, startedAt: Date(), segments: []
        )
        let selection = ExportSelection(destination: destination)

        let assessment = RecordingExportPlanner.assess(
            session: session, selection: selection, audioSourcesBySegment: [:]
        )

        XCTAssertEqual(assessment.disabledReason, .emptySelection)
        XCTAssertEqual(assessment.outputSpec.destination, destination)
        XCTAssertEqual(assessment.requestedRanges.count, 0)
        XCTAssertEqual(assessment.effectiveRanges.count, 0)
    }

    func testSourceRangeRoundTripsAsSerializablePayload() throws {
        let segmentID = UUID()
        let source = ExportSourceRange(
            segmentID: segmentID,
            segmentIndex: 3,
            role: .microphone,
            requested: ExportSampleRange(startSample: 96_000, sampleCount: 48_000),
            effective: ExportSampleRange(startSample: 48_000, sampleCount: 96_000),
            videoRange: ExportTimeRange(
                startValue: 1_000,
                startTimescale: 1_000,
                durationValue: 2_000,
                durationTimescale: 1_000
            ),
            videoTrackIndex: 0,
            segmentRange: ExportSampleRange(startSample: 0, sampleCount: 240_000),
            sourceFiles: [URL(fileURLWithPath: "/recordings/mic.m4a")]
        )

        let data = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(ExportSourceRange.self, from: data)

        XCTAssertEqual(decoded, source)
        XCTAssertEqual(decoded.segmentID, segmentID)
    }

    func testExportDurationLimitIs7170Seconds() {
        XCTAssertEqual(RecordingExportPlanner.maximumExportDuration, 7_170)
    }
}
