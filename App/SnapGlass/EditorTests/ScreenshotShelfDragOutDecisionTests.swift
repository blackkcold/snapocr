import Testing

@MainActor
struct ScreenshotShelfDragOutDecisionTests {
    @Test func withoutAPreviewTheEventPassesThrough() {
        #expect(
            ScreenshotShelfDragOutDecision.decide(
                previewExists: false,
                isOutside: true,
                artifactExists: true
            ) == .passThrough
        )
    }

    @Test func insideTheShelfTheEventStaysLocal() {
        #expect(
            ScreenshotShelfDragOutDecision.decide(
                previewExists: true,
                isOutside: false,
                artifactExists: true
            ) == .passThrough
        )
    }

    @Test func outsideWithoutAFilePreparesIt() {
        #expect(
            ScreenshotShelfDragOutDecision.decide(
                previewExists: true,
                isOutside: true,
                artifactExists: false
            ) == .prepareFile
        )
    }

    @Test func outsideWithAFileStartsTheSession() {
        #expect(
            ScreenshotShelfDragOutDecision.decide(
                previewExists: true,
                isOutside: true,
                artifactExists: true
            ) == .beginSession
        )
    }
}
