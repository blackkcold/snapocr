import CaptureCore
import Foundation
import Testing

@testable import LibraryCore

@Suite("Manual group projection")
struct LibraryManualGroupProjectorTests {
    @Test("Two sessions project into one manual group")
    func projectsTwoSessions() {
        let first = makeGroup(
            title: "First",
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            duration: 60,
            roots: [URL(fileURLWithPath: "/recordings/a")]
        )
        let second = makeGroup(
            title: "Second",
            startedAt: Date(timeIntervalSince1970: 1_800_000_100),
            duration: 90,
            roots: [URL(fileURLWithPath: "/recordings/b")]
        )
        let manual = RecordingManualGroup(
            title: "Together",
            sessionIDs: [first.sessionID, second.sessionID],
            isFavourite: true
        )

        let projected = LibraryManualGroupProjector.project(
            sessionGroups: [first, second],
            manualGroups: [manual]
        )

        #expect(projected.count == 1)
        #expect(projected[0].isManualGroup)
        #expect(projected[0].manualGroupID == manual.id)
        #expect(projected[0].memberSessionIDs == [first.sessionID, second.sessionID])
        #expect(projected[0].title == "Together")
        #expect(projected[0].duration == 150)
        #expect(projected[0].roots.count == 2)
        #expect(projected[0].isFavourite)
    }

    @Test("Mixed media kinds are not grouped")
    func rejectsMixedKinds() {
        let audio = makeGroup(title: "Audio", kind: .audio)
        let video = makeGroup(title: "Video", kind: .screen)
        let manual = RecordingManualGroup(
            title: "Mixed",
            sessionIDs: [audio.sessionID, video.sessionID]
        )

        let projected = LibraryManualGroupProjector.project(
            sessionGroups: [audio, video],
            manualGroups: [manual]
        )
        #expect(projected.count == 2)
        #expect(projected.allSatisfy { !$0.isManualGroup })
    }

    @Test("A group with fewer than two live members is ignored")
    func rejectsSingleMember() {
        let only = makeGroup(title: "Only")
        let manual = RecordingManualGroup(
            title: "One",
            sessionIDs: [only.sessionID, UUID()]
        )
        let projected = LibraryManualGroupProjector.project(
            sessionGroups: [only],
            manualGroups: [manual]
        )
        #expect(projected.count == 1)
        #expect(!projected[0].isManualGroup)
    }

    private func makeGroup(
        title: String,
        kind: RecordingKind = .audio,
        startedAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
        duration: TimeInterval = 60,
        roots: [URL] = []
    ) -> LibraryRecordingGroup {
        LibraryRecordingGroup(
            sessionID: UUID(),
            kind: kind,
            layout: .mixed,
            title: title,
            startedAt: startedAt,
            duration: duration,
            byteSize: 1_024,
            segments: [],
            state: .complete,
            isFavourite: false,
            tags: [],
            note: nil,
            coverURL: nil,
            mediaURL: nil,
            roots: roots
        )
    }
}
