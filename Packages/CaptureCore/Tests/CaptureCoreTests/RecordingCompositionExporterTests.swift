import XCTest
@testable import CaptureCore

final class RecordingCompositionExporterTests: XCTestCase {
    func testPublicProgressAndResultPayloadsHaveCallableInitializers() {
        let outputURL = URL(fileURLWithPath: "/recordings/final.m4a")
        let progress = ExportProgress(fraction: 0.5, phase: "audio")
        let result = ExportResult(
            outputURL: outputURL,
            actualDuration: 2,
            videoPassthrough: false,
            audioOperation: .reencodeAudio,
            trackCount: 1
        )

        XCTAssertEqual(progress.fraction, 0.5)
        XCTAssertEqual(progress.phase, "audio")
        XCTAssertEqual(result.outputURL, outputURL)
        XCTAssertEqual(result.trackCount, 1)
    }

    func testCancellationErrorCarriesTaskOwnedStagingURL() {
        let stagingURL = URL(fileURLWithPath: "/recordings/.export-staging")
        let error = ExportError.cancelled(stagingURL: stagingURL)

        XCTAssertEqual(error, .cancelled(stagingURL: stagingURL))
    }
}
