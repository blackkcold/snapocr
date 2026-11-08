import Foundation
import Testing

@testable import CaptureCore

struct ScreenshotShelfStateTests {
    @Test func insertsNewestFirstAndEvictsOldestEntryAtLimit() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let fourth = UUID()
        var state = ScreenshotShelfState(limit: 3)

        #expect(state.insert(captureID: first, completionSequence: 1).isEmpty)
        #expect(state.insert(captureID: second, completionSequence: 2).isEmpty)
        #expect(state.insert(captureID: third, completionSequence: 3).isEmpty)
        let evicted = state.insert(captureID: fourth, completionSequence: 4)

        #expect(evicted == [first])
        #expect(state.entries.map(\.captureID) == [fourth, third, second])
        #expect(state.entries.map(\.completionSequence) == [4, 3, 2])
    }

    @Test func linkingHistoryDoesNotChangeCaptureIdentityOrOrder() {
        let first = UUID()
        let second = UUID()
        let historyID = UUID()
        var state = ScreenshotShelfState(limit: 3)
        _ = state.insert(captureID: first, completionSequence: 1)
        _ = state.insert(captureID: second, completionSequence: 2)

        state.linkHistory(captureID: first, historyID: historyID)

        #expect(state.entries.map(\.captureID) == [second, first])
        #expect(state.entries.first(where: { $0.captureID == first })?.historyID == historyID)
    }

    @Test func loweringLimitEvictsOldestAndIncreasingLimitDoesNotRestoreEntries() {
        let ids = (1...4).map { _ in UUID() }
        var state = ScreenshotShelfState(limit: 4)
        for (offset, id) in ids.enumerated() {
            _ = state.insert(captureID: id, completionSequence: UInt64(offset + 1))
        }

        let evicted = state.setLimit(2)

        #expect(Set(evicted) == Set([ids[0], ids[1]]))
        #expect(state.entries.map(\.captureID) == [ids[3], ids[2]])

        #expect(state.setLimit(6).isEmpty)
        #expect(state.entries.map(\.captureID) == [ids[3], ids[2]])
    }

    @Test func configuredLimitClampsToOneThroughSix() {
        let first = UUID()
        let second = UUID()
        var minimumState = ScreenshotShelfState(limit: 0)
        _ = minimumState.insert(captureID: first, completionSequence: 1)
        #expect(minimumState.insert(captureID: second, completionSequence: 2) == [first])

        let ids = (1...7).map { _ in UUID() }
        var maximumState = ScreenshotShelfState(limit: 12)
        for (offset, id) in ids.enumerated() {
            _ = maximumState.insert(captureID: id, completionSequence: UInt64(offset + 1))
        }
        #expect(maximumState.entries.count == 6)
        #expect(maximumState.entries.map(\.captureID) == Array(ids.dropFirst().reversed()))
    }

    @Test func removeAndClearReturnOnlyAssetsThatLeaveTheShelf() {
        let first = UUID()
        let second = UUID()
        var state = ScreenshotShelfState(limit: 3)
        _ = state.insert(captureID: first, completionSequence: 1)
        _ = state.insert(captureID: second, completionSequence: 2)

        state.remove(captureID: first)

        #expect(state.entries.map(\.captureID) == [second])
        #expect(state.clear() == [second])
        #expect(state.entries.isEmpty)
        #expect(state.clear().isEmpty)
    }

    @Test func historyReconciliationRemovesOnlyMissingLinkedEntries() {
        let removedCaptureID = UUID()
        let keptCaptureID = UUID()
        let unsavedCaptureID = UUID()
        let removedHistoryID = UUID()
        let keptHistoryID = UUID()
        var state = ScreenshotShelfState(limit: 3)
        _ = state.insert(captureID: removedCaptureID, completionSequence: 1)
        _ = state.insert(captureID: keptCaptureID, completionSequence: 2)
        _ = state.insert(captureID: unsavedCaptureID, completionSequence: 3)
        state.linkHistory(captureID: removedCaptureID, historyID: removedHistoryID)
        state.linkHistory(captureID: keptCaptureID, historyID: keptHistoryID)

        let removed = state.reconcileHistory(existingHistoryIDs: [keptHistoryID])

        #expect(removed == [removedCaptureID])
        #expect(state.entries.map(\.captureID) == [unsavedCaptureID, keptCaptureID])
        #expect(state.entries.last?.historyID == keptHistoryID)
    }
}
