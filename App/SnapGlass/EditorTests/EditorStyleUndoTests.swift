import AnnotationCore
import AppKit
import Testing

@MainActor
struct EditorStyleUndoTests {
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

  @Test func continuousStyleDragRecordsOneUndoStep() throws {
    let model = EditorViewModel()
    model.document = model.interactor.createDocument(from: try image())

    let node = AnnotationNode(
      tool: .rect,
      lineWidth: 2,
      points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.5, y: 0.5)]
    )
    model.addNode(node)

    model.beginStyleEdit()
    #expect(model.isAdjustingStyle)
    for width in stride(from: 5.0, through: 20.0, by: 1.0) {
      model.strokeWidth = width
      model.updateSelectedStyle()
    }
    model.endStyleEdit()
    #expect(!model.isAdjustingStyle)

    #expect(model.document?.nodes.first?.lineWidth == 20)
    model.undo()
    #expect(model.document?.nodes.first?.lineWidth == 2)
  }

  @Test func undoingBackToSavedStateIsClean() throws {
    let model = EditorViewModel()
    model.document = model.interactor.createDocument(from: try image())
    model.markSaved()
    #expect(!model.hasUnsavedChanges)

    model.addNode(
      AnnotationNode(
        tool: .rect,
        points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.5, y: 0.5)]
      )
    )
    #expect(model.hasUnsavedChanges)

    model.undo()
    #expect(!model.hasUnsavedChanges)
  }

  @Test func typedDraftCountsAsUnsavedUntilCancelled() throws {
    let model = EditorViewModel()
    model.document = model.interactor.createDocument(from: try image())
    model.markSaved()

    model.beginTextEntry(at: CGPoint(x: 0.2, y: 0.2))
    model.textDraft = "typing"
    #expect(model.hasUnsavedChanges)

    model.cancelTextEntry()
    #expect(!model.hasUnsavedChanges)
  }

  @Test func unchangedExistingTextDraftIsNotDirty() throws {
    let model = EditorViewModel()
    model.document = model.interactor.createDocument(from: try image())
    model.markSaved()

    model.beginTextEntry(at: CGPoint(x: 0.2, y: 0.2))
    model.textDraft = "note"
    model.commitTextEntry()
    model.markSaved()

    let node = try #require(model.document?.nodes.first)
    model.beginTextEditing(node)
    model.textDraft = "note"
    #expect(!model.hasUnsavedChanges)

    model.textDraft = "note!"
    #expect(model.hasUnsavedChanges)

    model.cancelTextEntry()
    #expect(!model.hasUnsavedChanges)
  }
}
