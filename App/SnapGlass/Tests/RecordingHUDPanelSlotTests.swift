import Testing

@MainActor
struct RecordingHUDPanelSlotTests {
    /// Stands in for `RecordingControlPanel`: only dismissal matters here.
    private final class Panel {
        private(set) var dismissCount = 0

        func dismiss() {
            dismissCount += 1
        }
    }

    @Test func installingSecondPanelDismissesTheFirstOne() {
        var slot: Panel?
        let preparing = Panel()
        RecordingHUDPanelSlot.install(preparing, into: &slot) { $0.dismiss() }

        #expect(slot === preparing)
        #expect(preparing.dismissCount == 0)

        let countdown = Panel()
        RecordingHUDPanelSlot.install(countdown, into: &slot) { $0.dismiss() }

        #expect(slot === countdown)
        // The replaced panel is dismissed, never left visible without an owner.
        #expect(preparing.dismissCount == 1)
        #expect(countdown.dismissCount == 0)
    }

    @Test func reinstallingLivePanelKeepsItUp() {
        var slot: Panel?
        let panel = Panel()
        RecordingHUDPanelSlot.install(panel, into: &slot) { $0.dismiss() }
        RecordingHUDPanelSlot.install(panel, into: &slot) { $0.dismiss() }

        #expect(slot === panel)
        #expect(panel.dismissCount == 0)
    }

    @Test func clearingSlotDismissesCurrentPanel() {
        var slot: Panel?
        let panel = Panel()
        RecordingHUDPanelSlot.install(panel, into: &slot) { $0.dismiss() }
        RecordingHUDPanelSlot.install(nil, into: &slot) { $0.dismiss() }

        #expect(slot == nil)
        #expect(panel.dismissCount == 1)
    }

    @Test func clearingEmptySlotDoesNothing() {
        var slot: Panel?
        RecordingHUDPanelSlot.install(nil, into: &slot) { $0.dismiss() }

        #expect(slot == nil)
    }
}
