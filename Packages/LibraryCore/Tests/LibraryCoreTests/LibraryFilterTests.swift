import Foundation
import Testing
@testable import LibraryCore

@Suite("LibraryFilter")
struct LibraryFilterTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Favourite and location filters combine")
    func favouriteAndLocation() {
        let filter = LibraryFilter(favouritesOnly: true, location: "/Volumes/Recordings")
        #expect(
            filter.matches(
                date: now,
                duration: 120,
                status: .complete,
                isFavourite: true,
                locationPath: "/Volumes/Recordings",
                now: now
            )
        )
        #expect(
            !filter.matches(
                date: now,
                duration: 120,
                status: .complete,
                isFavourite: false,
                locationPath: "/Volumes/Recordings",
                now: now
            )
        )
        #expect(
            !filter.matches(
                date: now,
                duration: 120,
                status: .complete,
                isFavourite: true,
                locationPath: "/Volumes/Other",
                now: now
            )
        )
    }

    @Test("Duration buckets are inclusive at their boundaries")
    func durationBuckets() {
        let under = LibraryFilter(duration: .underOneMinute)
        #expect(under.matches(date: now, duration: 59.9, status: .complete, isFavourite: false, locationPath: nil, now: now))
        #expect(!under.matches(date: now, duration: 60, status: .complete, isFavourite: false, locationPath: nil, now: now))

        let oneToTen = LibraryFilter(duration: .oneToTenMinutes)
        #expect(oneToTen.matches(date: now, duration: 60, status: .complete, isFavourite: false, locationPath: nil, now: now))
        #expect(oneToTen.matches(date: now, duration: 600, status: .complete, isFavourite: false, locationPath: nil, now: now))
        #expect(!oneToTen.matches(date: now, duration: 601, status: .complete, isFavourite: false, locationPath: nil, now: now))

        let overHour = LibraryFilter(duration: .overOneHour)
        #expect(overHour.matches(date: now, duration: 3_601, status: .complete, isFavourite: false, locationPath: nil, now: now))
        #expect(!overHour.matches(date: now, duration: 3_600, status: .complete, isFavourite: false, locationPath: nil, now: now))
    }

    @Test("Date and status filters reject mismatches")
    func dateAndStatus() {
        let calendar = Calendar(identifier: .gregorian)
        let startOfToday = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? now

        let today = LibraryFilter(dateRange: .today)
        #expect(today.matches(date: startOfToday, duration: 10, status: .complete, isFavourite: false, locationPath: nil, now: now))
        #expect(!today.matches(date: yesterday, duration: 10, status: .complete, isFavourite: false, locationPath: nil, now: now))

        let partial = LibraryFilter(status: .partial)
        #expect(partial.matches(date: now, duration: 10, status: .partial, isFavourite: false, locationPath: nil, now: now))
        #expect(!partial.matches(date: now, duration: 10, status: .complete, isFavourite: false, locationPath: nil, now: now))
    }
}

@Suite("Library metadata maintenance")
struct LibraryMetadataMaintenanceTests {
    @Test("Old tombstones are purged while recent ones survive")
    func purgeTombstones() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryCoreMaintenance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent(RecordingLibraryStore.defaultFileName)
        let store = RecordingLibraryStore(fileURL: url)
        let oldID = UUID()
        let recentID = UUID()
        await store.setDisplayName("Old", for: oldID)
        await store.markDeleted(sessionID: oldID, at: Date(timeIntervalSince1970: 0))
        await store.setDisplayName("Recent", for: recentID)
        await store.markDeleted(sessionID: recentID, at: Date())

        await store.purgeTombstones(
            olderThan: 24 * 60 * 60,
            now: Date(timeIntervalSince1970: 48 * 60 * 60)
        )

        #expect(await store.entry(for: oldID).displayName == nil)
        #expect(await store.entry(for: recentID).displayName == "Recent")
    }
}
