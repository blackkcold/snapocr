import CoreGraphics
import Foundation
import Testing

@MainActor
struct ScreenshotShelfDisplayFollowerTests {
    private let mainDisplay = ScreenshotShelfDisplayFollower.Display(
        id: 1,
        frame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
    )
    private let secondDisplay = ScreenshotShelfDisplayFollower.Display(
        id: 2,
        frame: CGRect(x: 1_920, y: 0, width: 1_470, height: 956)
    )
    private let start = Date(timeIntervalSince1970: 1_760_000_000)

    @Test func followsOnlyAfterThePointerChangesDisplaysAndSettles() {
        let state = FollowerState(displays: [mainDisplay, secondDisplay], shelfDisplayID: 1)
        let follower = makeFollower(state: state)
        follower.reset(baselineDisplayID: 1)

        follower.handleTick(now: start)
        #expect(state.followed.isEmpty)

        state.pointer = CGPoint(x: 2_500, y: 500)
        follower.handleTick(now: start.addingTimeInterval(0.25))
        #expect(state.followed.isEmpty, "the pointer must settle first")

        follower.handleTick(now: start.addingTimeInterval(0.50))
        #expect(state.followed == [2])
        #expect(state.shelfDisplayID == 2)

        follower.handleTick(now: start.addingTimeInterval(0.75))
        #expect(state.followed == [2], "the shelf is already on that display")
    }

    @Test func blockedFollowRequiresAFreshDisplayChange() {
        let state = FollowerState(displays: [mainDisplay, secondDisplay], shelfDisplayID: 1)
        let follower = makeFollower(state: state)
        follower.reset(baselineDisplayID: 1)

        state.canFollow = false
        state.pointer = CGPoint(x: 2_500, y: 500)
        follower.handleTick(now: start)
        follower.handleTick(now: start.addingTimeInterval(0.25))
        #expect(state.followed.isEmpty)

        state.canFollow = true
        follower.handleTick(now: start.addingTimeInterval(0.50))
        #expect(state.followed.isEmpty, "a blocked crossing must not fire later by itself")

        // A fresh crossing to the other display is required.
        state.pointer = CGPoint(x: 500, y: 500)
        follower.handleTick(now: start.addingTimeInterval(0.75))
        follower.handleTick(now: start.addingTimeInterval(1.0))
        #expect(state.followed.isEmpty, "the shelf is already on display 1")

        state.pointer = CGPoint(x: 2_500, y: 500)
        follower.handleTick(now: start.addingTimeInterval(1.25))
        follower.handleTick(now: start.addingTimeInterval(1.50))
        #expect(state.followed == [2])
    }

    @Test func respectsTheCooldownBetweenMoves() {
        let state = FollowerState(displays: [mainDisplay, secondDisplay], shelfDisplayID: 1)
        let follower = makeFollower(state: state)
        follower.reset(baselineDisplayID: 1)

        state.pointer = CGPoint(x: 2_500, y: 500)
        follower.handleTick(now: start)
        follower.handleTick(now: start.addingTimeInterval(0.25))
        #expect(state.followed == [2])

        state.pointer = CGPoint(x: 500, y: 500)
        follower.handleTick(now: start.addingTimeInterval(0.50))
        follower.handleTick(now: start.addingTimeInterval(0.75))
        #expect(state.followed == [2], "0.5s after the first move is inside the cooldown")

        follower.handleTick(now: start.addingTimeInterval(0.90))
        #expect(state.followed == [2, 1])
    }

    @Test func resetCancelsAPendingFollow() {
        let state = FollowerState(displays: [mainDisplay, secondDisplay], shelfDisplayID: 1)
        let follower = makeFollower(state: state)
        follower.reset(baselineDisplayID: 1)

        state.pointer = CGPoint(x: 2_500, y: 500)
        follower.handleTick(now: start)
        follower.reset(baselineDisplayID: 2)
        follower.handleTick(now: start.addingTimeInterval(0.25))
        follower.handleTick(now: start.addingTimeInterval(0.50))

        #expect(state.followed.isEmpty)
    }

    @Test func resolvesTheGapBetweenDisplaysToTheNearestOne() {
        let raisedSecondDisplay = ScreenshotShelfDisplayFollower.Display(
            id: 2,
            frame: CGRect(x: 1_920, y: 124, width: 1_470, height: 956)
        )
        let state = FollowerState(
            displays: [mainDisplay, raisedSecondDisplay],
            shelfDisplayID: 1
        )
        let follower = makeFollower(state: state)
        follower.reset(baselineDisplayID: 1)

        // Inside the vertical gap between the two displays, closest to the second one.
        state.pointer = CGPoint(x: 2_000, y: 100)
        follower.handleTick(now: start)
        follower.handleTick(now: start.addingTimeInterval(0.25))

        #expect(state.followed == [2])
    }

    @Test func neverFollowsWithASingleDisplay() {
        let state = FollowerState(displays: [mainDisplay], shelfDisplayID: 1)
        let follower = makeFollower(state: state)
        follower.reset(baselineDisplayID: 1)

        state.pointer = CGPoint(x: 2_500, y: 500)
        follower.handleTick(now: start)
        follower.handleTick(now: start.addingTimeInterval(0.50))

        #expect(state.followed.isEmpty)
    }

    private func makeFollower(state: FollowerState) -> ScreenshotShelfDisplayFollower {
        let follower = ScreenshotShelfDisplayFollower(
            displayProvider: { state.displays },
            pointerLocationProvider: { state.pointer },
            now: { state.now }
        )
        follower.shelfDisplayID = { state.shelfDisplayID }
        follower.canFollow = { state.canFollow }
        follower.onFollow = { displayID in
            state.followed.append(displayID)
            state.shelfDisplayID = displayID
        }
        return follower
    }
}

@MainActor
private final class FollowerState {
    var displays: [ScreenshotShelfDisplayFollower.Display]
    var pointer: CGPoint = CGPoint(x: 100, y: 100)
    var now = Date(timeIntervalSince1970: 1_760_000_000)
    var shelfDisplayID: CGDirectDisplayID?
    var canFollow = true
    var followed: [CGDirectDisplayID] = []

    init(
        displays: [ScreenshotShelfDisplayFollower.Display],
        shelfDisplayID: CGDirectDisplayID?
    ) {
        self.displays = displays
        self.shelfDisplayID = shelfDisplayID
    }
}
