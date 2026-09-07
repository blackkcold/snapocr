import AnnotationCore
import AppKit
import Testing

@MainActor
struct CanvasTextRenderingTests {
  @Test func inlineGlyphBoundsMatchCommittedText() throws {
    let context = try #require(
      CGContext(
        data: nil, width: 800, height: 600, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(NSColor.white.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
    let image = try #require(context.makeImage())
    let canvas = EditableAnnotationCanvasNSView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    canvas.image = image
    canvas.showsOCROverlay = false
    let window = NSWindow(contentRect: canvas.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = canvas
    defer {
      canvas.endTextEntry()
      window.close()
    }
    let model = EditorViewModel()
    model.document = model.interactor.createDocument(from: image)
    model.beginTextEntry(at: CGPoint(x: 0.2, y: 0.3))
    model.textDraft = "Hello canvas\n中文标注"
    let node = try #require(model.pendingTextNode)
    canvas.updateTextEntry(id: UUID(), node: node, onCommit: { _ in }, onCancel: {})
    canvas.layoutSubtreeIfNeeded()
    canvas.displayIfNeeded()
    let bitmap = try #require(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
    canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
    let inline = try redBounds(bitmap)
    model.commitTextEntry()
    let document = try #require(model.document)
    let rendered = try Renderer().render(document)
    let committed = try redBounds(NSBitmapImageRep(cgImage: rendered))
    // Compare normalized geometry because cacheDisplay can use a Retina backing scale.
    #expect(abs(inline.minX - committed.minX) < 0.015)
    #expect(abs(inline.minY - committed.minY) < 0.015)
    #expect(abs(inline.width - committed.width) < 0.015)
    #expect(abs(inline.height - committed.height) < 0.015)
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("release")
    let artifact = root.appendingPathComponent("text-preview-\(UUID().uuidString).png")
    try bitmap.representation(using: .png, properties: [:])?.write(to: artifact)
    print("Inline text render evidence: \(artifact.path)")
    let finalArtifact = root.appendingPathComponent("text-committed-\(UUID().uuidString).png")
    try NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:])?.write(to: finalArtifact)
    print("Committed text render evidence: \(finalArtifact.path); inline \(inline), committed \(committed)")
  }

  private func redBounds(_ bitmap: NSBitmapImageRep) throws -> CGRect {
    var rect = CGRect.null
    for row in 0..<bitmap.pixelsHigh {
      for column in 0..<bitmap.pixelsWide {
        guard let color = bitmap.colorAt(x: column, y: row)?.usingColorSpace(.sRGB),
          color.redComponent > 0.6,
          color.redComponent > color.greenComponent * 1.5,
          color.redComponent > color.blueComponent * 1.5
        else { continue }
        rect = rect.union(CGRect(x: column, y: row, width: 1, height: 1))
      }
    }
    #expect(!rect.isNull, "Text must be visible while editing and after commit")
    return CGRect(
      x: rect.minX / CGFloat(bitmap.pixelsWide), y: rect.minY / CGFloat(bitmap.pixelsHigh),
      width: rect.width / CGFloat(bitmap.pixelsWide), height: rect.height / CGFloat(bitmap.pixelsHigh))
  }
}
