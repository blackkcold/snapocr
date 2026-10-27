import AnnotationCore
import AppKit
import Testing

/// 保存面板是非模态的：面板打开期间仍可继续编辑。写盘完成后必须用
/// 「实际写入的那份文档」建立干净基线，否则新改动会被误判为已保存。
@MainActor
struct EditorSaveBaselineTests {
  private func image() throws -> CGImage {
    let context = try #require(
      CGContext(
        data: nil, width: 320, height: 240, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(NSColor.white.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
    return try #require(context.makeImage())
  }

  @Test func editsAfterSnapshotStayDirty() throws {
    let model = EditorViewModel()
    model.document = model.interactor.createDocument(from: try image())
    model.markSaved()

    model.addNode(
      AnnotationNode(
        tool: .rect,
        points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.4, y: 0.4)]
      )
    )
    let written = try #require(model.document)

    // 模拟写盘成功：基线等于写入时的文档。
    model.markSaved(document: written)
    #expect(!model.hasUnsavedChanges)

    // 面板关闭前又画了一笔：仍然必须是脏的。
    model.addNode(
      AnnotationNode(
        tool: .arrow,
        points: [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.6, y: 0.6)]
      )
    )
    #expect(model.hasUnsavedChanges)
  }

  @Test func snapshotBaselineSurvivesAnUndoToIt() throws {
    let model = EditorViewModel()
    model.document = model.interactor.createDocument(from: try image())
    model.markSaved()

    model.addNode(
      AnnotationNode(
        tool: .rect,
        points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.4, y: 0.4)]
      )
    )
    let written = try #require(model.document)
    model.markSaved(document: written)

    model.addNode(
      AnnotationNode(
        tool: .arrow,
        points: [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.6, y: 0.6)]
      )
    )
    #expect(model.hasUnsavedChanges)

    model.undo()
    #expect(!model.hasUnsavedChanges)
  }
}
