import Foundation
import Testing

@testable import CaptureCore

struct PinnedToolbarVisibilityTests {
    @Test func startsHidden() {
        let state = PinnedToolbarVisibility()
        #expect(state.isVisible == false)
    }

    @Test func enteringRequestsDelayedShow() {
        var state = PinnedToolbarVisibility(showDelay: 0.15, hideDelay: 0.3)
        state.pointerEntered()

        #expect(state.pendingShowDelay == 0.15)
        let didShow = state.applyShow()
        #expect(didShow)
        #expect(state.isVisible)
    }

    @Test func leavingRequestsDelayedHide() {
        var state = PinnedToolbarVisibility(showDelay: 0.15, hideDelay: 0.3)
        state.pointerEntered()
        state.applyShow()
        state.pointerExited()

        #expect(state.pendingHideDelay == 0.3)
        let didHide = state.applyHide()
        #expect(didHide)
        #expect(state.isVisible == false)
    }

    @Test func hideIsCancelledWhenPointerEntersToolbar() {
        var state = PinnedToolbarVisibility()
        state.pointerEntered()
        state.applyShow()
        // 鼠标离开面板（面板 mouseExited）……
        state.pointerExited()
        // ……但随即进入工具条窗口。
        state.pointerEntered()

        #expect(state.pendingHideDelay == nil)
        let didHide = state.applyHide()
        #expect(didHide == false)
        #expect(state.isVisible)
    }

    @Test func showIsImmediateWhenAlreadyVisible() {
        var state = PinnedToolbarVisibility()
        state.pointerEntered()
        state.applyShow()

        #expect(state.pendingShowDelay == 0)
    }

    @Test func hideIsSuppressedWhileInteracting() {
        var state = PinnedToolbarVisibility()
        state.pointerEntered()
        state.applyShow()
        state.interactionBegan()
        state.pointerExited()

        #expect(state.pendingHideDelay == nil)
        let didHide = state.applyHide()
        #expect(didHide == false)
        #expect(state.isVisible)
    }

    @Test func interactionEndRestoresDelayedHide() {
        var state = PinnedToolbarVisibility(hideDelay: 0.3)
        state.pointerEntered()
        state.applyShow()
        state.interactionBegan()
        state.pointerExited()
        state.interactionEnded()

        #expect(state.pendingHideDelay == 0.3)
        let didHide = state.applyHide()
        #expect(didHide)
        #expect(state.isVisible == false)
    }

    @Test func hideDoesNothingWhenAlreadyHidden() {
        var state = PinnedToolbarVisibility()
        #expect(state.pendingHideDelay == nil)
        let didHide = state.applyHide()
        #expect(didHide == false)
        #expect(state.isVisible == false)
    }

    @Test func negativeDelaysAreClampedToZero() {
        let state = PinnedToolbarVisibility(showDelay: -1, hideDelay: -1)
        #expect(state.pendingShowDelay == 0)
    }
}
