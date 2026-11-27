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

        #expect(CoachScreenSelector.index(for: CGPoint(x: 200, y: 500), in: frames) == 0)
        #expect(CoachScreenSelector.index(for: CGPoint(x: 2000, y: 500), in: frames) == 1)
        // A pointer off the desk is not "no answer": the nearest display wins, so the
        // coach follows the pointer instead of jumping to the menu-bar display.
        #expect(CoachScreenSelector.index(for: CGPoint(x: 5000, y: 500), in: frames) == 1)
        #expect(CoachScreenSelector.index(for: CGPoint(x: 0, y: 0), in: []) == nil)
    }

    @Test func picksTheNearestScreenAcrossASeatBetweenDifferentHeights() {
        // Displays of different heights leave a band that belongs to neither frame.
        // The old `CGRect.contains` lookup had no answer there and fell back to
        // `NSScreen.main`, which is how the coach ended up on the wrong display.
        let frames = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 1920, y: 124, width: 1470, height: 956),
        ]

        // 80pt right of the first display, 24pt above the second: the second wins.
        #expect(CoachScreenSelector.index(for: CGPoint(x: 2000, y: 100), in: frames) == 1)
        // 40pt right of the first, 84pt above the second: the first wins.
        #expect(CoachScreenSelector.index(for: CGPoint(x: 1960, y: 40), in: frames) == 0)
    }

    @Test func picksAScreenForTheHalfOpenEdgeThatContainsRejects() {
        // `CGRect.contains` is half-open: `maxX` and `maxY` belong to no frame. With a
        // pointer resting exactly there, the old lookup returned `nil` and the coach
        // jumped to `NSScreen.main` even though the pointer was on a display.
        //
        // These frames are the desk this was reported on: a 1920x1080 display beside a
        // shorter one that hangs 64pt below it. The point below is on the first
        // display, at its right edge and above the second display's top.
        let frames = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 1920, y: -64, width: 1470, height: 956),
        ]

        // `CGRect.contains` says false for both.
        #expect(!frames[0].contains(CGPoint(x: 1920, y: 1000)))
        #expect(!frames[1].contains(CGPoint(x: 1920, y: 1000)))
        // The nearest lookup still resolves it, and to the display it is on.
        #expect(CoachScreenSelector.index(for: CGPoint(x: 1920, y: 1000), in: frames) == 0)
    }

    @Test func picksAScreenWhenDisplaysSitAtNegativeOrigins() {
        // A display to the left of the primary has a negative origin; nothing in the
        // lookup may assume the desk starts at zero.
        let frames = [
            CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
        ]

        #expect(CoachScreenSelector.index(for: CGPoint(x: -500, y: 500), in: frames) == 0)
        #expect(CoachScreenSelector.index(for: CGPoint(x: 500, y: 500), in: frames) == 1)
        #expect(CoachScreenSelector.index(for: CGPoint(x: -2500, y: 540), in: frames) == 0)
    }

    @Test func presentationIndexUsesTheNearerScreenInsteadOfTheMainOne() {
        // The regression this locks: a pointer in the seam belongs to no frame, and the
        // presenter used to fall back to `NSScreen.main` — presenting the coach on the
        // display that owns the menu bar rather than the one the user is on. The old
        // fallback was invisible to tests because it lived in a file no test target
        // compiled; the decision is now here.
        let frames = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 1920, y: 124, width: 1470, height: 956),
        ]

        // Main display is index 0, as it usually is. The seam point is nearer display 1,
        // so the answer must be 1 — the fallback would have produced 0.
        #expect(
            CoachScreenSelector.presentationIndex(
                for: CGPoint(x: 2000, y: 100),
                in: frames,
                mainIndex: 0
            ) == 1)
        // The other side of the seam still resolves to the main display.
        #expect(
            CoachScreenSelector.presentationIndex(
                for: CGPoint(x: 1960, y: 40),
                in: frames,
                mainIndex: 0
            ) == 0)
    }

    @Test func presentationIndexFallsBackToTheMainDisplayWithoutADesk() {
        // No displays: the presenter must not invent an index, so it can still return
        // `nil` and skip presenting rather than present on a screen that is not there.
        #expect(
            CoachScreenSelector.presentationIndex(
                for: .zero,
                in: [],
                mainIndex: nil
            ) == nil)
    }

    @Test func presentationIndexFallsBackToTheFirstScreenWhenMainIsUnknown() {
        // `NSScreen.main` is nil when no window has focus. The presenter still needs a
        // screen, so it uses the first one — same answer the old `main ?? screens.first`
        // produced, now covered.
        let frames = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 1920, y: 0, width: 1920, height: 1080),
        ]

        #expect(
            CoachScreenSelector.presentationIndex(
                for: CGPoint(x: 100, y: 100),
                in: frames,
                mainIndex: nil
            ) == 0)
    }
}
