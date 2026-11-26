import Foundation
import Testing

@testable import LibraryCore

@Suite("RecordingLibraryStore")
struct RecordingLibraryStoreTests {
    private func makeFileURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(RecordingLibraryStore.defaultFileName)
    }

    @Test("Title, favourite and tags survive a reload")
    func roundTrip() async throws {
        let url = try makeFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let sessionID = UUID()
        let store = RecordingLibraryStore(fileURL: url)
        await store.setDisplayName("产品评审会", for: sessionID)
        await store.setFavourite(true, for: sessionID)
        await store.setTags(["工作", "评审"], for: sessionID)
        await store.saveNow()

        let reloaded = RecordingLibraryStore(fileURL: url)
        let entry = await reloaded.entry(for: sessionID)
        #expect(entry.displayName == "产品评审会")
        #expect(entry.isFavourite)
        #expect(entry.tags == ["工作", "评审"])
    }

    @Test("Unreadable metadata is moved aside instead of crashing")
    func corruptRecovery() async throws {
        let url = try makeFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Data("{not json".utf8).write(to: url)

        let store = RecordingLibraryStore(fileURL: url)
        #expect(await store.snapshot().sessions.isEmpty)

        let siblings = try FileManager.default.contentsOfDirectory(
            at: url.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        #expect(siblings.contains { $0.lastPathComponent.hasPrefix("recording-library.corrupt-") })
    }

    @Test("Backup is used when the primary file is damaged")
    func backupRecovery() async throws {
        let url = try makeFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let sessionID = UUID()
        let store = RecordingLibraryStore(fileURL: url)
        await store.setFavourite(true, for: sessionID)
        await store.saveNow()
        await store.setDisplayName("第二次保存", for: sessionID)
        await store.saveNow()

        try Data("broken".utf8).write(to: url)

        let reloaded = RecordingLibraryStore(fileURL: url)
        let entry = await reloaded.entry(for: sessionID)
        #expect(entry.isFavourite)
    }

    @Test("Tombstone hides a session and revive brings metadata back")
    func tombstoneAndRevive() async throws {
        let url = try makeFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let sessionID = UUID()
        let store = RecordingLibraryStore(fileURL: url)
        await store.setDisplayName("访谈", for: sessionID)
        await store.setFavourite(true, for: sessionID)
        await store.markDeleted(sessionID: sessionID)
        #expect(await store.entry(for: sessionID).deletedAt != nil)

        await store.revive(sessionID: sessionID)
        let entry = await store.entry(for: sessionID)
        #expect(entry.deletedAt == nil)
        #expect(entry.displayName == "访谈")
        #expect(entry.isFavourite)
    }

    @Test("Manual groups assign and clear member sessions")
    func manualGrouping() async throws {
        let url = try makeFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let first = UUID()
        let second = UUID()
        let store = RecordingLibraryStore(fileURL: url)
        let group = await store.createGroup(title: "两段会议", sessionIDs: [first, second])
        let groupID = try #require(group?.id)
        #expect(await store.entry(for: first).groupID == groupID)
        #expect(await store.entry(for: second).groupID == groupID)
        #expect(await store.allGroups().count == 1)

        await store.removeGroup(id: groupID)
        #expect(await store.entry(for: first).groupID == nil)
        #expect(await store.allGroups().isEmpty)
    }
}

@Suite("MergePartPlanner")
struct MergePartPlannerTests {
    @Test("Three 59-minute segments become two files")
    func threeSegments() {
        let parts = MergePartPlanner.parts(
            segmentDurations: [3_540, 3_540, 3_540],
            maximumDuration: 7_170
        )
        #expect(parts.count == 2)
        #expect(parts[0].segmentIndices == [0, 1])
        #expect(parts[0].duration == 7_080)
        #expect(!parts[0].isOverLimit)
        #expect(parts[1].segmentIndices == [2])
        #expect(parts[1].duration == 3_540)
        #expect(!parts[1].isOverLimit)
    }

    @Test("Four segments split evenly at boundaries")
    func fourSegments() {
        let parts = MergePartPlanner.parts(
            segmentDurations: [3_540, 3_540, 3_540, 3_540],
            maximumDuration: 7_170
        )
        #expect(parts.count == 2)
        #expect(parts[0].segmentIndices == [0, 1])
        #expect(parts[1].segmentIndices == [2, 3])
    }

    @Test("A single oversized segment is flagged rather than dropped")
    func oversizedSegment() {
        let parts = MergePartPlanner.parts(
            segmentDurations: [8_000],
            maximumDuration: 7_170
        )
        #expect(parts.count == 1)
        #expect(parts[0].isOverLimit)
    }

    @Test("Empty input produces no output")
    func emptyInput() {
        #expect(MergePartPlanner.parts(segmentDurations: [], maximumDuration: 7_170).isEmpty)
    }
}
