import AppKit
import Testing

@MainActor
struct ScreenshotShelfManagerTests {
    @Test func windowFrameParsesQuartzBoundsAndRejectsInvalidValues() {
        let bounds: [String: CGFloat] = ["X": 12, "Y": 24, "Width": 320, "Height": 180]

        #expect(ScreenshotShelfScreenResolver.windowFrame(from: bounds) == CGRect(x: 12, y: 24, width: 320, height: 180))
        #expect(ScreenshotShelfScreenResolver.windowFrame(from: ["Width": "not a number"]) == nil)
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

    @Test func captureCompletionStoresMeasuredScaleWithItsSourcePixelWidth() throws {
        let manager = try makeManager()
        let image = try makeImage()
        let captureID = try #require(manager.captureCompleted(image, displayScale: 2))
        let card = try #require(manager.card(for: captureID))

        #expect(card.displayScale == 2)
        #expect(card.scaleSourcePixelWidth == CGFloat(image.width))
    }

    @Test func captureCompletionWithoutMeasuredScaleUsesScaleOneWithoutSourceWidth() throws {
        let manager = try makeManager()
        let image = try makeImage()
        let captureID = try #require(manager.captureCompleted(image))
        let card = try #require(manager.card(for: captureID))

        #expect(card.displayScale == 1)
        #expect(card.scaleSourcePixelWidth == nil)
    }

    @Test func staleCaptureScaleFallsBackToOneWhenImageWidthChanges() {
        #expect(ScreenshotShelfManager.displayScaleForPinning(
            displayScale: 2,
            scaleSourcePixelWidth: 800,
            imagePixelWidth: 800
        ) == 2)
        #expect(ScreenshotShelfManager.displayScaleForPinning(
            displayScale: 2,
            scaleSourcePixelWidth: 800,
            imagePixelWidth: 640
        ) == 1)
        #expect(ScreenshotShelfManager.displayScaleForPinning(
            displayScale: 2,
            scaleSourcePixelWidth: nil,
            imagePixelWidth: 800
        ) == 1)
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

    @Test func shelfFeedbackResolvesForCurrentLocaleAndPreservesVerbatimErrors() throws {
        let manager = try makeManager()
        let image = try makeImage()
        let captureID = try #require(manager.captureCompleted(image))
        let key = "Screenshot copied to clipboard"

        manager.reportFeedback(captureID: captureID, message: .localizedKey(key))

        let localizedCard = try #require(manager.card(for: captureID))
        #expect(localizedCard.feedbackMessage?.resolved(using: { _ in "Copied (English)" }) == "Copied (English)")
        #expect(localizedCard.feedbackMessage?.resolved(using: { _ in "已复制" }) == "已复制")

        let dynamicError = "The image provider returned an unexpected error."
        manager.reportFeedback(captureID: captureID, message: .verbatim(dynamicError), isError: true)

        let errorCard = try #require(manager.card(for: captureID))
        #expect(errorCard.errorMessage?.resolved(using: { _ in "must not replace dynamic text" }) == dynamicError)
        #expect(errorCard.feedbackMessage?.resolved(using: { _ in "must not replace dynamic text" }) == dynamicError)
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
