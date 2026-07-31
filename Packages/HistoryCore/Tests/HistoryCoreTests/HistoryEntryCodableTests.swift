import Testing
import Foundation
@testable import HistoryCore

/// Tests for HistoryEntry Codable conformance.
///
/// These tests verify serialization round-trips without touching disk storage.
/// They use in-memory JSON encoding/decoding only.
struct HistoryEntryCodableTests {

    @Test func codable_roundTrip() throws {
        let entry = HistoryEntry(
            textContent: "Hello World",
            ocrConfidence: 0.95,
            captureMode: "area",
            sourceType: .screenshot,
            sourceAppName: "Safari",
            sourceWindowTitle: "SnapGlass - Wikipedia",
            imagePath: URL(string: "file:///tmp/test.png"),
            thumbnailPath: URL(string: "file:///tmp/thumb.png")
        )

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(HistoryEntry.self, from: data)

        #expect(decoded.id == entry.id)
        #expect(decoded.timestamp == entry.timestamp)
        #expect(decoded.textContent == entry.textContent)
        #expect(decoded.ocrConfidence == entry.ocrConfidence)
        #expect(decoded.captureMode == entry.captureMode)
        #expect(decoded.sourceType == entry.sourceType)
        #expect(decoded.sourceAppName == entry.sourceAppName)
        #expect(decoded.sourceWindowTitle == entry.sourceWindowTitle)
        #expect(decoded.isFavourite == entry.isFavourite)
        #expect(decoded.tags == entry.tags)
    }

    @Test func initializer_preservesExplicitMetadata() {
        let timestamp = Date(timeIntervalSince1970: 123)
        let entry = HistoryEntry(
            timestamp: timestamp,
            textContent: "text",
            ocrConfidence: 0.8,
            captureMode: "area",
            isFavourite: true,
            tags: ["private"]
        )

        #expect(entry.timestamp == timestamp)
        #expect(entry.isFavourite)
        #expect(entry.tags == ["private"])
    }

    @Test func codable_emptyText() throws {
        let entry = HistoryEntry(
            textContent: "",
            ocrConfidence: 0.0,
            captureMode: "fullscreen"
        )

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(HistoryEntry.self, from: data)

        #expect(decoded.textContent == "")
        #expect(decoded.ocrConfidence == 0.0)
    }

    @Test func codable_favouriteAndTags() throws {
        var entry = HistoryEntry(
            textContent: "test",
            ocrConfidence: 0.8,
            captureMode: "window"
        )
        entry.isFavourite = true
        entry.tags = ["work", "important"]

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(HistoryEntry.self, from: data)

        #expect(decoded.isFavourite)
        #expect(decoded.tags == ["work", "important"])
    }

    @Test func codable_nilPaths() throws {
        let entry = HistoryEntry(
            textContent: "test",
            ocrConfidence: 0.5,
            captureMode: "area"
        )

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(HistoryEntry.self, from: data)

        #expect(decoded.imagePath == nil)
        #expect(decoded.thumbnailPath == nil)
    }

    @Test func codable_clipboardSource() throws {
        let entry = HistoryEntry(
            textContent: "clipboard content",
            ocrConfidence: 0.7,
            captureMode: "area",
            sourceType: .clipboard
        )

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(HistoryEntry.self, from: data)

        #expect(decoded.sourceType == .clipboard)
    }

    @Test func codable_urlSchemeSource() throws {
        let entry = HistoryEntry(
            textContent: "url scheme capture",
            ocrConfidence: 0.6,
            captureMode: "fullscreen",
            sourceType: .urlScheme
        )

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(HistoryEntry.self, from: data)

        #expect(decoded.sourceType == .urlScheme)
    }
}
