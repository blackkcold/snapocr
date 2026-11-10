import CaptureCore
import CoreGraphics
import Foundation
import HistoryCore
import ImageIO

/// Lazy renderer for history entries. History keeps the raw image; the
/// presentation style is decoded only when the user asks for a beautified copy
/// or opens the inspector, so grid scrolling never pays for 6K compositing.
enum HistoryMockupPresenter {
    static func style(from entry: HistoryEntry) -> MockupStyle? {
        guard let json = entry.mockupStyleJSON,
              let data = json.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(MockupStyle.self, from: data)
    }

    static func styleJSON(for style: MockupStyle) -> String? {
        guard let data = try? JSONEncoder().encode(style) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func rawImage(for entry: HistoryEntry, history: HistoryActor) async -> CGImage? {
        guard let data = try? await history.imageData(for: entry.id),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return image
    }

    static func presentedImage(
        for entry: HistoryEntry,
        history: HistoryActor
    ) async -> CGImage? {
        guard let raw = await rawImage(for: entry, history: history) else { return nil }
        guard let style = style(from: entry) else { return raw }
        return await Task.detached(priority: .userInitiated) {
            MockupRenderer.render(raw, style: style)
        }.value ?? raw
    }
}
