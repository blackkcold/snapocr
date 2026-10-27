import CoreGraphics
import Foundation
import Testing
@testable import HistoryCore

/// 锁定「同一进程只持有一个 HistoryActor」这一不变量。
///
/// 多实例会让陈旧的内存快照覆盖磁盘上的新 `imageRevision`，用户表现为
/// 「覆盖原记录」后原图无法还原、新记录在已打开的历史窗口里消失。
struct SharedInstanceTests {
    @Test func providerReturnsTheSameInstance() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let provider = HistorySharedProvider { try HistoryActor(baseURL: root) }
        let first = try provider.instance().get()
        let second = try provider.instance().get()

        #expect(first === second)
    }

    @Test func failedInitializationIsNotCached() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let counter = AttemptCounter()

        let provider = HistorySharedProvider {
            guard counter.next() > 1 else { throw HistoryError.fileIOError(path: root.path()) }
            return try HistoryActor(baseURL: root)
        }

        #expect((try? provider.instance().get()) == nil)
        let recovered = try provider.instance().get()
        #expect(recovered === (try provider.instance().get()))
    }

    @Test func resetAllowsReinitialization() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = HistorySharedProvider { try HistoryActor(baseURL: root) }

        let first = try provider.instance().get()
        provider.reset()
        let second = try provider.instance().get()

        #expect(first !== second)
    }

    /// 复现真实路径：A 实例已缓存编辑前的条目，B 实例完成「覆盖原记录」，
    /// 随后 A 实例切换收藏。收藏不能把新的 revision 写回 nil。
    @Test func staleInstanceCannotClobberEditedRevision() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let stale = try HistoryActor(baseURL: root)
        let id = try await stale.saveCapture(
            image: try image(100),
            textContent: "",
            ocrConfidence: 0,
            captureMode: "area"
        )
        _ = try await stale.recent(limit: 10)

        let editor = try HistoryActor(baseURL: root)
        try await editor.replaceImage(id: id, image: try image(200))

        _ = try await stale.setFavourite(id: id, isFavourite: true)

        let reloaded = try HistoryActor(baseURL: root)
        let entry = try #require(try await reloaded.load(id: id))
        #expect(entry.isFavourite)
        #expect(entry.canRestoreOriginal)
        try await reloaded.restoreOriginal(id: id)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
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

/// `@Sendable` 工厂闭包里不能捕获可变局部变量，用一个加锁的盒子计数。
private final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
