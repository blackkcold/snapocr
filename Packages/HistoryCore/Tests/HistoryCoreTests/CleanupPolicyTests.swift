import Testing
import Foundation
@testable import HistoryCore

struct CleanupPolicyTests {

    private let policy = CleanupPolicy()

    // MARK: - retentionDays

    @Test func retentionDays_image() {
        #expect(policy.retentionDays(for: .image) == 7)
    }

    @Test func retentionDays_text() {
        #expect(policy.retentionDays(for: .text) == 30)
    }

    @Test func retentionDays_thumbnail() {
        #expect(policy.retentionDays(for: .thumbnail) == 90)
    }

    // MARK: - maxCount

    @Test func maxCount_image() {
        #expect(policy.maxCount(for: .image) == 100)
    }

    @Test func maxCount_text() {
        #expect(policy.maxCount(for: .text) == 500)
    }

    @Test func maxCount_thumbnail() {
        #expect(policy.maxCount(for: .thumbnail) == 1000)
    }

    // MARK: - shouldEvict

    @Test func shouldEvict_freshEntry() {
        let entry = HistoryEntry(textContent: "test", ocrConfidence: 0.9, captureMode: "area")
        #expect(!policy.shouldEvict(entry, category: .text))
    }

    @Test func shouldEvict_oldEntry() {
        let entry = HistoryEntry(
            id: UUID(),
            timestamp: Date().addingTimeInterval(-31 * 86_400),
            textContent: "old",
            ocrConfidence: 0.5,
            captureMode: "area",
            sourceType: .screenshot,
            sourceAppName: nil,
            sourceWindowTitle: nil,
            imagePath: nil,
            thumbnailPath: nil
        )
        #expect(policy.shouldEvict(entry, category: .text))
        #expect(!policy.shouldEvict(entry, category: .thumbnail))
    }

    // MARK: - isOverCount

    @Test func isOverCount_underLimit() {
        #expect(!policy.isOverCount(50, category: .text))
    }

    @Test func isOverCount_atLimit() {
        #expect(!policy.isOverCount(500, category: .text))
    }

    @Test func isOverCount_overLimit() {
        #expect(policy.isOverCount(501, category: .text))
    }

    // MARK: - entriesToEvict

    @Test func entriesToEvict_noExpiredEntries() {
        let entries = (0..<10).map { i in
            HistoryEntry(textContent: "entry\(i)", ocrConfidence: 0.9, captureMode: "area")
        }
        let toEvict = policy.entriesToEvict(entries, category: .text)
        #expect(toEvict.isEmpty)
    }

    @Test func entriesToEvict_favouritePreserved() {
        var favEntry = HistoryEntry(textContent: "fav", ocrConfidence: 0.9, captureMode: "area")
        favEntry.isFavourite = true

        let entries = [favEntry]
        let toEvict = policy.entriesToEvict(entries, category: .text)
        #expect(toEvict.isEmpty)
    }

    @Test func entriesToEvict_respectsCategoryRetention() {
        let entry = HistoryEntry(
            timestamp: Date().addingTimeInterval(-8 * 86_400),
            textContent: "layered",
            ocrConfidence: 0.9,
            captureMode: "area"
        )

        #expect(policy.entriesToEvict([entry], category: .image).map(\.id) == [entry.id])
        #expect(policy.entriesToEvict([entry], category: .text).isEmpty)
        #expect(policy.entriesToEvict([entry], category: .thumbnail).isEmpty)
    }

    // MARK: - MemoryPressureLevel

    @Test func memoryPressureLevel_comparable() {
        #expect(MemoryPressureLevel.normal < .medium)
        #expect(MemoryPressureLevel.medium < .high)
        #expect(MemoryPressureLevel.high < .critical)
        #expect(MemoryPressureLevel.normal == .normal)
    }

    // MARK: - cacheLimit

    @Test func cacheLimit_normal() {
        // We can't easily mock resident memory, but we can verify the method
        // returns a value (nil or Int) without crashing.
        let limit = policy.cacheLimit()
        // Just verify it doesn't crash — actual value depends on system memory
        _ = limit
    }
}
