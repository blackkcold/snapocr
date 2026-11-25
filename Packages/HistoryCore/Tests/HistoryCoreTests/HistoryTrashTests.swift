import CoreGraphics
import Foundation
import Testing
@testable import HistoryCore

@Suite("History trash")
struct HistoryTrashTests {
    @Test("Move, list, restore and empty")
    func moveRestoreEmpty() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryTrash-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let history = try HistoryActor(baseURL: root)
        let image = try makeImage(width: 64)
        let id = try await history.saveCapture(
            image: image,
            textContent: "",
            ocrConfidence: 0,
            captureMode: "area"
        )

        try await history.moveToTrash(id: id)
        #expect(try await history.load(id: id) == nil)

        let trash = try await history.trashEntries()
        #expect(trash.count == 1)
        #expect(trash.first?.entry.id == id)

        let restored = try await history.restoreFromTrash(id: id)
        #expect(restored?.id == id)
        #expect(try await history.imageData(for: id) != nil)

        try await history.moveToTrash(id: id)
        try await history.emptyTrash()
        #expect(try await history.trashEntries().isEmpty)
    }

    private func makeImage(width: Int) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: 64,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: 64))
        return try #require(context.makeImage())
    }
}
