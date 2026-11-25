import Foundation
import Testing
@testable import LibraryCore

@Suite("Recording retention")
struct RecordingRetentionTests {
    @Test("Old non-favourite complete recordings are eligible")
    func eligibility() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = makeGroup(now: now, daysAgo: 90)
        let recent = makeGroup(now: now, daysAgo: 5)
        let favourite = makeGroup(now: now, daysAgo: 90, favourite: true)
        let offline = makeGroup(now: now, daysAgo: 90, state: .offline)

        let eligible = RecordingRetentionPlanner.eligibleGroups(
            [old, recent, favourite, offline],
            olderThanDays: 30,
            now: now
        )
        #expect(eligible.map(\.sessionID) == [old.sessionID])
    }

    @Test("Zero days disables retention")
    func disabledRetention() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = makeGroup(now: now, daysAgo: 90)
        #expect(
            RecordingRetentionPlanner.eligibleGroups([old], olderThanDays: 0, now: now).isEmpty
        )
    }

    private func makeGroup(
        now: Date,
        daysAgo: Int,
        favourite: Bool = false,
        state: LibraryRecordingState = .complete
    ) -> LibraryRecordingGroup {
        LibraryRecordingGroup(
            sessionID: UUID(),
            kind: .audio,
            layout: .mixed,
            title: "",
            startedAt: now.addingTimeInterval(-Double(daysAgo) * 24 * 60 * 60),
            duration: 60,
            byteSize: 1_024,
            segments: [],
            state: state,
            isFavourite: favourite,
            tags: [],
            note: nil,
            coverURL: nil,
            mediaURL: nil,
            roots: []
        )
    }
}
