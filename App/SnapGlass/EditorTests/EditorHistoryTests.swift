import AnnotationCore
import AppKit
import HistoryCore
import Testing

@testable import EditorInteractionTests

final class HistoryRequestRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var entries: [(mode: EditorHistorySaveMode, source: UUID?)] = []

  func append(_ mode: EditorHistorySaveMode, _ source: UUID?) {
    lock.lock()
    entries.append((mode, source))
    lock.unlock()
  }

  var all: [(mode: EditorHistorySaveMode, source: UUID?)] {
    lock.lock()
    defer { lock.unlock() }
    return entries
  }
}

@MainActor
struct EditorHistoryTests {
  private func image(width: Int = 400, height: Int = 300) throws -> CGImage {
    let context = try #require(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(NSColor.white.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try #require(context.makeImage())
  }

  @Test func saveToHistoryReportsModeAndSource() async throws {
    let sourceID = UUID()
    let requests = HistoryRequestRecorder()
    let model = EditorViewModel(
      image: try image(),
      context: EditorCaptureContext(
        captureMode: "area", supportsVerticalTrim: false,
        startsInVerticalTrim: false, sourceEntryID: sourceID
      ),
      historySaver: { image, mode, source in
        #expect(image.width == 400)
        requests.append(mode, source)
      }
    )
    await model.saveToHistory(mode: .overwriteOriginal)
    let first = requests.all
    #expect(first.count == 1)
    #expect(first[0].mode == .overwriteOriginal)
    #expect(first[0].source == sourceID)

    await model.saveToHistory(mode: .newRecord)
    let all = requests.all
    #expect(all.count == 2)
    #expect(all[1].mode == .newRecord)
    #expect(all[1].source == sourceID)
  }

  @Test func overwriteWithoutSourceIsRejected() async throws {
    let requests = HistoryRequestRecorder()
    let model = EditorViewModel(
      image: try image(),
      historySaver: { _, mode, source in requests.append(mode, source) }
    )
    await model.saveToHistory(mode: .overwriteOriginal)
    #expect(requests.all.isEmpty)
    #expect(model.toastMessage?.type == .error)
  }

  @Test func failedSaveSurfacesErrorToast() async throws {
    let model = EditorViewModel(
      image: try image(),
      historySaver: { _, _, _ in throw HistoryError.entryNotFound(id: UUID()) }
    )
    await model.saveToHistory(mode: .newRecord)
    #expect(model.toastMessage?.type == .error)
  }
}
