import CoreGraphics
import Foundation
import Testing
@testable import HistoryCore

/// 删除 → 撤销 的组合语义：撤销后必须仍能「还原原图」。
///
/// 删除会把原图与编辑版一起移入事务目录并立即清理；只恢复编辑版会让
/// `canRestoreOriginal` 保持为真，但底层文件已不存在。
struct DeleteRestoreTests {
    @Test func undoDeleteRestoresOriginalMedia() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let history = try HistoryActor(baseURL: root)
        let id = try await history.saveCapture(
            image: try image(100),
            textContent: "",
            ocrConfidence: 0,
            captureMode: "area"
        )
        let original = try #require(try await history.imageData(for: id))

        try await history.replaceImage(id: id, image: try image(200))
        let edited = try #require(try await history.imageData(for: id))
        let thumbnail = try await history.thumbnailData(for: id)
        let originalCopy = try #require(try await history.originalImageData(for: id))
        let entry = try #require(try await history.load(id: id))

        try await history.delete(id: id)
        try await history.restore(
            entry,
            imageData: edited,
            thumbnailData: thumbnail,
            originalImageData: originalCopy
        )

        let reloaded = try HistoryActor(baseURL: root)
        #expect(try await reloaded.load(id: id)?.canRestoreOriginal == true)
        #expect(try await reloaded.imageData(for: id) == edited)

        try await reloaded.restoreOriginal(id: id)
        #expect(try await reloaded.imageData(for: id) == original)
        #expect(try await reloaded.load(id: id)?.canRestoreOriginal == false)
    }

    /// 没带原图字节时，撤销后的条目必须如实隐藏「还原原图」入口，
    /// 而不是留一个必然失败的菜单项。
    @Test func undoWithoutOriginalHidesRestoreEntry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let history = try HistoryActor(baseURL: root)
        let id = try await history.saveCapture(
            image: try image(100),
            textContent: "",
            ocrConfidence: 0,
            captureMode: "area"
        )
        try await history.replaceImage(id: id, image: try image(200))

        let edited = try #require(try await history.imageData(for: id))
        let entry = try #require(try await history.load(id: id))
        try await history.delete(id: id)
        try await history.restore(entry, imageData: edited, thumbnailData: nil)

        #expect(try await history.load(id: id)?.canRestoreOriginal == false)
    }

    private func image(_ width: Int) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: 80,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: 80))
        return try #require(context.makeImage())
    }
}
