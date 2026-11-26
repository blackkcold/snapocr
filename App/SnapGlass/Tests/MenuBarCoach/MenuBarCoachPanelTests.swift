import AppKit
import SharedKit
import SwiftUI
import Testing

/// The menu-bar coach panel's sizing contract.
///
/// The panel used to grow from 288×96 to 288×888 the moment it was ordered
/// front: `NSHostingView`'s default `sizingOptions` publishes the content's
/// minimum size as `contentMinSize`, and that minimum is computed at a proposed
/// width of zero, where every `.fixedSize(horizontal: false, vertical: true)`
/// text reports one line per character. These tests lock down three things:
/// content cannot resize the window, the tutorial row is not clipped, and the
/// panel stays inside the usable area.
@Suite("Menu bar coach panel")
@MainActor
struct MenuBarCoachPanelTests {
    @Test func contentNeverResizesThePanel() throws {
        let panel = MenuBarCoachPanel(content: .location, layout: .full)
        let hosting = try #require(panel.contentView as? NSHostingView<MenuBarCoachView>)

        #expect(hosting.sizingOptions.isEmpty)
        #expect(panel.contentMinSize == .zero)
        #expect(panel.frame.size == CoachLayout.full.designSize)
    }

    @Test func orderingFrontDoesNotStretchThePanel() {
        // The regression itself: with the default `sizingOptions`, ordering the
        // panel front stretched it from 288×96 to 288×888 — but only on the
        // next run-loop turn. Asserting right after `orderFrontRegardless()`
        // never sees the stretch, and the test passed even with the fix
        // removed. Let the run loop spin once before reading the frame.
        let design = CoachLayout.full.designSize
        let panel = MenuBarCoachPanel(content: .location, layout: .full)
        panel.setFrame(CGRect(origin: CGPoint(x: 40, y: 40), size: design), display: false)
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }

        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        #expect(panel.frame.size == design)
    }

    @Test func tutorialFormIsTallerThanLocationForm() {
        let available = CGSize(width: 1512, height: 957)
        let location = MenuBarCoachPanel.size(
            for: .full,
            content: .location,
            available: available
        )
        let tutorial = MenuBarCoachPanel.size(
            for: .full,
            content: .tutorial(shortcut: "⌘⇧1"),
            available: available
        )

        // The location form is the design height; the tutorial adds a "Try it"
        // row, and a fixed height used to clip it.
        #expect(location.height == CoachLayout.full.designSize.height)
        #expect(tutorial.height > location.height)
        // Hard-coded rather than bounded by `available.height`: 888 also
        // satisfies a bound of 957, so the old assertion missed the stretch.
        #expect(tutorial.height <= 130)
    }

    @Test func sizeNeverExceedsASmallScreen() {
        // 1280×800 with the menu bar removed: the broken panel asked for 888 and
        // hung below the bottom edge.
        let available = CGSize(width: 1280, height: 715)
        let size = MenuBarCoachPanel.size(
            for: .full,
            content: .tutorial(shortcut: "⌘⇧1"),
            available: available
        )
        // Hard-coded: 715 - panelTopInset(8) - panelBottomInset(12) = 695.
        // Recomputing the ceiling from the same constants passes even if one of
        // them is wrong, which is how the original assertion became vacuous.
        #expect(size.width == 288)
        #expect(size.height <= 695)
    }

    @Test func picksTheScreenUnderThePointer() {
        let frames = [
            CGRect(x: 0, y: 0, width: 1440, height: 900),
            CGRect(x: 1440, y: 0, width: 1920, height: 1080),
        ]

        #expect(CoachScreenSelector.index(containing: CGPoint(x: 200, y: 500), in: frames) == 0)
        #expect(CoachScreenSelector.index(containing: CGPoint(x: 2000, y: 500), in: frames) == 1)
        #expect(CoachScreenSelector.index(containing: CGPoint(x: 5000, y: 500), in: frames) == nil)
    }
}
