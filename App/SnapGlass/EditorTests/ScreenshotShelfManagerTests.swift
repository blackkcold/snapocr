import AppKit
import Testing

@MainActor
struct ScreenshotShelfManagerTests {
    @Test func windowFrameParsesQuartzBoundsAndRejectsInvalidValues() {
        let bounds: [String: CGFloat] = ["X": 12, "Y": 24, "Width": 320, "Height": 180]

        #expect(ScreenshotShelfManager.windowFrame(from: bounds) == CGRect(x: 12, y: 24, width: 320, height: 180))
        #expect(ScreenshotShelfManager.windowFrame(from: ["Width": "not a number"]) == nil)
    }

    @Test func captureCompletionIsSynchronousAndHistoryLinkDoesNotReorder() throws {
        let manager = try makeManager()
        let image = try makeImage()

        let firstID = try #require(manager.captureCompleted(image))
        let secondID = try #require(manager.captureCompleted(image))
        let historyID = UUID()
        manager.linkHistory(captureID: firstID, historyID: historyID)

        #expect(manager.orderedCaptureIDs == [secondID, firstID])
        #expect(manager.historyID(for: firstID) == historyID)

        manager.remove(captureID: firstID)
        manager.linkHistory(captureID: firstID, historyID: UUID())

        #expect(manager.orderedCaptureIDs == [secondID])
        #expect(manager.historyID(for: firstID) == nil)
    }

    @Test func captureSuppressionRestoresShownIntentButManualHidePersists() throws {
        let manager = try makeManager()
        let image = try makeImage()
        _ = try #require(manager.captureCompleted(image))
        manager.show()

        manager.beginCaptureSuppression()
        #expect(!manager.shouldPresentPanel)
        manager.endCaptureSuppression()
        #expect(manager.shouldPresentPanel)

        manager.hide()
        manager.beginCaptureSuppression()
        manager.endCaptureSuppression()
        #expect(!manager.shouldPresentPanel)
    }

    @Test func overlappingCaptureSuppressionsWaitForEveryCaptureToFinish() throws {
        let manager = try makeManager()
        let image = try makeImage()
        _ = try #require(manager.captureCompleted(image))
        manager.show()

        manager.beginCaptureSuppression()
        manager.beginCaptureSuppression()
        manager.endCaptureSuppression()

        #expect(!manager.shouldPresentPanel)

        manager.endCaptureSuppression()
        #expect(manager.shouldPresentPanel)
    }

    @Test func cacheFailureKeepsTheCompletedCaptureOnTheShelf() throws {
        let manager = try makeManager()
        let image = try makeImage()
        var reportedFailure: String?
        manager.onCacheFailure = { reportedFailure = $0 }

        let captureID = try #require(manager.captureCompleted(image))

        #expect(manager.orderedCaptureIDs == [captureID])
        #expect(manager.cards.first?.errorMessage != nil)
        #expect(reportedFailure != nil)
    }

    private func makeManager() throws -> ScreenshotShelfManager {
        let suiteName = "ScreenshotShelfManagerTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw ScreenshotShelfManagerTestError.defaultsUnavailable
        }
        defaults.set(true, forKey: "screenshotShelf_enabled")
        defaults.set(3, forKey: "screenshotShelf_count")
        return ScreenshotShelfManager(
            defaults: defaults,
            sessionStore: nil,
            observesSystemEvents: false,
            createsPanel: false
        )
    }

    private func makeImage() throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else {
            throw ScreenshotShelfManagerTestError.imageUnavailable
        }
        return image
    }
}

private enum ScreenshotShelfManagerTestError: Error {
    case defaultsUnavailable
    case imageUnavailable
}
