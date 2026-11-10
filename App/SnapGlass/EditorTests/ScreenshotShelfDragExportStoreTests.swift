import Foundation
import Testing

@MainActor
struct ScreenshotShelfDragExportStoreTests {
    private let fixedDate = Date(timeIntervalSince1970: 1_760_000_000)

    @Test func prepareWritesFileAndPublishesArtifact() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let captureID = UUID()
        let data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])

        let artifact = try #require(
            await store.prepare(
                captureID: captureID,
                data: data,
                sourceTypeIdentifier: "public.png"
            )
        )

        #expect(artifact.url.pathExtension == "png")
        #expect(artifact.byteCount == data.count)
        #expect(FileManager.default.contents(atPath: artifact.url.path) == data)
        #expect(store.artifact(for: captureID) == artifact)
        #expect(!artifact.url.lastPathComponent.contains(" "))
        #expect(artifact.url.lastPathComponent.hasPrefix("SnapGlass_"))
    }

    @Test func prepareTwiceReusesTheExistingArtifact() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let captureID = UUID()
        let data = Data(repeating: 0x11, count: 32)

        let first = try #require(
            await store.prepare(captureID: captureID, data: data, sourceTypeIdentifier: "public.png")
        )
        let second = try #require(
            await store.prepare(captureID: captureID, data: data, sourceTypeIdentifier: "public.png")
        )

        #expect(first.url == second.url)
    }

    @Test func capturesInTheSameSecondGetDistinctNames() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let data = Data(repeating: 0x22, count: 16)

        let first = try #require(
            await store.prepare(captureID: UUID(), data: data, sourceTypeIdentifier: "public.png")
        )
        let second = try #require(
            await store.prepare(captureID: UUID(), data: data, sourceTypeIdentifier: "public.png")
        )

        #expect(first.url != second.url)
        #expect(second.url.deletingPathExtension().lastPathComponent.hasSuffix("-2"))
    }

    @Test func jpegSourceKeepsItsExtension() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)

        let artifact = try #require(
            await store.prepare(
                captureID: UUID(),
                data: Data(repeating: 0xFF, count: 8),
                sourceTypeIdentifier: "public.jpeg"
            )
        )

        #expect(artifact.url.pathExtension == "jpg")
    }

    @Test func unknownSourceTypeFallsBackToPNG() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)

        let artifact = try #require(
            await store.prepare(
                captureID: UUID(),
                data: Data(repeating: 0x33, count: 8),
                sourceTypeIdentifier: "not.a.real.type"
            )
        )

        #expect(artifact.url.pathExtension == "png")
    }

    @Test func invalidateDeletesTheFileAndTheIndexEntry() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let captureID = UUID()

        let artifact = try #require(
            await store.prepare(
                captureID: captureID,
                data: Data(repeating: 0x44, count: 8),
                sourceTypeIdentifier: "public.png"
            )
        )
        #expect(FileManager.default.fileExists(atPath: artifact.url.path))

        store.invalidate(captureID: captureID)

        #expect(store.artifact(for: captureID) == nil)
        #expect(!FileManager.default.fileExists(atPath: artifact.url.path))
    }

    @Test func removeAllClearsEveryArtifact() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let firstID = UUID()
        let secondID = UUID()

        let first = try #require(
            await store.prepare(
                captureID: firstID,
                data: Data(repeating: 0x55, count: 8),
                sourceTypeIdentifier: "public.png"
            )
        )
        _ = try #require(
            await store.prepare(
                captureID: secondID,
                data: Data(repeating: 0x66, count: 8),
                sourceTypeIdentifier: "public.png"
            )
        )

        store.removeAll()

        #expect(store.artifact(for: firstID) == nil)
        #expect(store.artifact(for: secondID) == nil)
        #expect(!FileManager.default.fileExists(atPath: first.url.path))
    }

    @Test func sweepStaleDeletesAbandonedSessionDirectories() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        _ = try #require(
            await store.prepare(
                captureID: UUID(),
                data: Data(repeating: 0x77, count: 8),
                sourceTypeIdentifier: "public.png"
            )
        )
        let abandoned = root.appendingPathComponent("session-abandoned", isDirectory: true)
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: fixedDate.addingTimeInterval(-172_800)],
            ofItemAtPath: abandoned.path
        )

        store.sweepStale()

        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
    }

    @Test func sweepStaleDeletesARecentlyAbandonedSession() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        _ = try #require(
            await store.prepare(
                captureID: UUID(),
                data: Data(repeating: 0x99, count: 8),
                sourceTypeIdentifier: "public.png"
            )
        )
        let abandoned = root.appendingPathComponent("session-recent", isDirectory: true)
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: fixedDate.addingTimeInterval(-120)],
            ofItemAtPath: abandoned.path
        )

        store.sweepStale()

        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
    }

    @Test func sweepStaleKeepsTheActiveSession() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let artifact = try #require(
            await store.prepare(
                captureID: UUID(),
                data: Data(repeating: 0x88, count: 8),
                sourceTypeIdentifier: "public.png"
            )
        )

        store.sweepStale()

        #expect(FileManager.default.fileExists(atPath: artifact.url.path))
    }

    private func makeStore(root: URL) -> ScreenshotShelfDragExportStore {
        ScreenshotShelfDragExportStore(
            rootDirectory: root,
            now: { self.fixedDate },
            timeZone: TimeZone(identifier: "Asia/Shanghai") ?? .current
        )
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapGlassDragExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
