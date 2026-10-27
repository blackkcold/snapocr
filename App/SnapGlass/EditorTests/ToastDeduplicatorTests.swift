import Foundation
import Testing

@testable import EditorInteractionTests

/// 同一文案 1 秒内只弹一次；不同文案和超过 1 秒的重复仍要出现。
@MainActor
struct ToastDeduplicatorTests {
    @Test func suppressesSameMessageWithinOneSecond() {
        let deduplicator = ToastDeduplicator()
        #expect(deduplicator.shouldPresent("Saved", now: 100))
        #expect(!deduplicator.shouldPresent("Saved", now: 100.9))
        #expect(deduplicator.shouldPresent("Saved", now: 101.1))
    }

    @Test func allowsDifferentMessagesImmediately() {
        let deduplicator = ToastDeduplicator()
        #expect(deduplicator.shouldPresent("Saved", now: 100))
        #expect(deduplicator.shouldPresent("Copied", now: 100.1))
    }
}
