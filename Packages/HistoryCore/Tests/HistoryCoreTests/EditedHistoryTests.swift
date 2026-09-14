import CoreGraphics
import Foundation
import Testing
@testable import HistoryCore

struct EditedHistoryTests {
    @Test func repeatedReplacementCanRestoreOriginalAfterRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = try HistoryActor(baseURL: root)
        let id = try await history.saveCapture(image: image(100), textContent: "old OCR",
            ocrConfidence: 1, captureMode: "area")
        let original = try await history.imageData(for: id)
        _ = try await history.setFavourite(id: id, isFavourite: true)
        try await history.replaceImage(id: id, image: image(200))
        try await history.replaceImage(id: id, image: image(300))
        let reloaded = try HistoryActor(baseURL: root)
        let edited = try #require(try await reloaded.load(id: id))
        #expect(edited.canRestoreOriginal)
        #expect(edited.textContent.isEmpty)
        #expect(edited.isFavourite)
        #expect(await reloaded.count() == 1)
        try await reloaded.restoreOriginal(id: id)
        #expect(try await reloaded.imageData(for: id) == original)
        #expect(try await reloaded.load(id: id)?.canRestoreOriginal == false)
        let restarted = try HistoryActor(baseURL: root)
        #expect(try await restarted.imageData(for: id) == original)
        try await restarted.delete(id: id)
        let files = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("History/v2/images"), includingPropertiesForKeys: nil)
        #expect(files.isEmpty)
    }

    @Test func failedReplacementLeavesOriginalUntouched() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = try HistoryActor(baseURL: root)
        let id = try await history.saveCapture(image: image(100), textContent: "old OCR",
            ocrConfidence: 1, captureMode: "area")
        let original = try await history.imageData(for: id)
        // Prevent the metadata commit after new media files have been written.
        let entryURL = root.appendingPathComponent("History/v2/entries/\(id.uuidString).enc")
        let metadata = try Data(contentsOf: entryURL)
        try FileManager.default.removeItem(at: entryURL)
        try FileManager.default.createDirectory(at: entryURL, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) {
            try await history.replaceImage(id: id, image: image(200))
        }
        #expect(try await history.imageData(for: id) == original)
        try FileManager.default.removeItem(at: entryURL)
        try metadata.write(to: entryURL)
        let reloaded = try HistoryActor(baseURL: root)
        #expect(try await reloaded.imageData(for: id) == original)
        #expect(try await reloaded.load(id: id)?.canRestoreOriginal == false)
    }

    @Test func missingSourceCannotBeOverwritten() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = try HistoryActor(baseURL: root)
        await #expect(throws: (any Error).self) {
            try await history.replaceImage(id: UUID(), image: image(100))
        }
        #expect(await history.count() == 0)
    }

    private func image(_ width: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: 80,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: 80))
        return try #require(context.makeImage())
    }
}
