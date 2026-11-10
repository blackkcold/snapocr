import Testing

@testable import CaptureCore

struct ScreenshotShelfPresentationStateTests {
    @Test func overlappingTemporarySuppressionsRestorePriorShownIntent() {
        var state = ScreenshotShelfPresentationState()
        state.captureCompleted()
        state.beginSuppression(.capture)
        state.beginSuppression(.recording)

        #expect(!state.shouldPresentPanel)

        state.endSuppression(.capture)
        #expect(!state.shouldPresentPanel)

        state.endSuppression(.recording)
        #expect(state.shouldPresentPanel)
    }

    @Test func manualHidePersistsUntilExplicitShowOrAnotherCapture() {
        var state = ScreenshotShelfPresentationState()
        state.captureCompleted()
        state.hide()
        state.beginSuppression(.capture)
        state.endSuppression(.capture)

        #expect(!state.shouldPresentPanel)

        state.show()
        #expect(state.shouldPresentPanel)
        state.hide()
        state.captureCompleted()
        #expect(state.shouldPresentPanel)
    }

    @Test func unlockingDoesNotRestoreShelfUntilAnotherShowIntent() {
        var state = ScreenshotShelfPresentationState()
        state.captureCompleted()
        state.setScreenLocked(true)
        #expect(!state.shouldPresentPanel)

        state.setScreenLocked(false)
        #expect(!state.shouldPresentPanel)

        state.show()
        #expect(state.shouldPresentPanel)
    }

    @Test func fullscreenSuppressionRestoresPriorShownIntent() {
        var state = ScreenshotShelfPresentationState()
        state.captureCompleted()

        state.beginSuppression(.fullScreen)
        #expect(!state.shouldPresentPanel)

        state.endSuppression(.fullScreen)
        #expect(state.shouldPresentPanel)
    }

    @Test func editingSuppressionRestoresPriorShownIntent() {
        var state = ScreenshotShelfPresentationState()
        state.captureCompleted()

        state.beginSuppression(.editing)
        #expect(!state.shouldPresentPanel)

        state.endSuppression(.editing)
        #expect(state.shouldPresentPanel)
    }

    @Test func editingSuppressionDoesNotResurrectManualHide() {
        var state = ScreenshotShelfPresentationState()
        state.captureCompleted()
        state.hide()

        state.beginSuppression(.editing)
        state.endSuppression(.editing)

        #expect(!state.shouldPresentPanel)
    }

    @Test func editingAndCaptureSuppressionsRestoreOnlyWhenBothEnd() {
        var state = ScreenshotShelfPresentationState()
        state.captureCompleted()

        state.beginSuppression(.capture)
        state.beginSuppression(.editing)
        state.endSuppression(.capture)
        #expect(!state.shouldPresentPanel)

        state.endSuppression(.editing)
        #expect(state.shouldPresentPanel)
    }
}
