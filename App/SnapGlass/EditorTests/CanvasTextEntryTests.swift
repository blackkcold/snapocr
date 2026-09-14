import AnnotationCore
import AppKit
import Testing

@MainActor
struct CanvasTextEntryTests {
  private func image(width: Int = 800, height: Int = 600) throws -> CGImage {
    let context = try #require(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(NSColor.white.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try #require(context.makeImage())
  }

  private func model() throws -> EditorViewModel {
    let model = EditorViewModel()
    model.document = model.interactor.createDocument(from: try image())
    return model
  }

  @Test func draftCommitsOnceAndCanBeUndone() throws {
    let model = try model()
    model.beginTextEntry(at: CGPoint(x: 0.2, y: 0.4))
    model.textDraft = "Hello\n中文"
    #expect(model.document?.nodes.isEmpty == true)
    #expect(model.pendingTextNode != nil)
    model.commitTextEntry()
    #expect(!model.isEnteringText)
    #expect(model.document?.nodes.count == 1)
    #expect(model.document?.nodes.first?.text == "Hello\n中文")
    model.undo()
    #expect(model.document?.nodes.isEmpty == true)
    model.redo()
    #expect(model.document?.nodes.count == 1)
  }

  @Test func cancelAndEmptyEditPreserveExistingText() throws {
    let model = try model()
    model.beginTextEntry(at: CGPoint(x: 0.3, y: 0.3))
    model.textDraft = "original"
    model.commitTextEntry()
    let original = try #require(model.document?.nodes.first)
    model.beginTextEditing(original)
    model.textDraft = "changed"
    model.cancelTextEntry()
    #expect(model.document?.nodes.first?.text == "original")
    model.beginTextEditing(original)
    model.textDraft = " \n "
    model.commitTextEntry()
    #expect(model.document?.nodes.first?.text == "original")
    #expect(!model.isEnteringText)
    model.beginTextEditing(original)
    model.textDraft = "updated\ntext"
    model.commitTextEntry()
    #expect(model.document?.nodes.count == 1)
    #expect(model.document?.nodes.first?.text == "updated\ntext")
    model.undo()
    #expect(model.document?.nodes.first?.text == "original")
  }

  @Test func emptyNewTextCreatesNothingAndToolSwitchCancels() throws {
    let model = try model()
    model.beginTextEntry(at: .zero)
    model.commitTextEntry()
    #expect(model.document?.nodes.isEmpty == true)
    model.beginTextEntry(at: .zero)
    model.textDraft = "unfinished"
    model.activateTool(.arrow)
    #expect(!model.isEnteringText)
    #expect(model.pendingTextNode == nil)
    #expect(model.document?.nodes.isEmpty == true)
  }

  @Test func canvasEditorTracksImageCoordinatesAndResize() throws {
    let canvas = EditableAnnotationCanvasNSView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    canvas.image = try image()
    let node = AnnotationNode(
      tool: .text, color: NSColor.red.cgColor,
      points: [CGPoint(x: 0.2, y: 0.3)], text: "Hello\n中文", fontSize: 24)
    let session = UUID()
    var result = ""
    canvas.updateTextEntry(id: session, node: node, onCommit: { result = $0 }, onCancel: {})
    let editor = try #require(canvas.canvasTextEditor)
    #expect(abs(editor.frame.minX - 160) < 0.01)
    #expect(abs(editor.frame.minY - 180) < 0.01)
    #expect(editor.string == "Hello\n中文")
    let initialSize = editor.frame.size
    canvas.setFrameSize(CGSize(width: 400, height: 300))
    canvas.layoutTextEntry()
    #expect(abs(editor.frame.width - initialSize.width / 2) < 0.01)
    #expect(abs(editor.frame.height - initialSize.height / 2) < 0.01)
    // A representable update must not reset typing or create a new field.
    editor.string = "draft"
    canvas.updateTextEntry(id: session, node: node, onCommit: { _ in }, onCancel: {})
    #expect(canvas.canvasTextEditor === editor)
    #expect(editor.string == "draft")
    editor.onCommit?(editor.string)
    #expect(result == "draft")
    #expect(canvas.canvasTextEditor == nil)
  }

  @Test func activeCanvasEditorAppliesStyleUpdatesWithoutReplacingDraft() throws {
    let canvas = EditableAnnotationCanvasNSView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    canvas.image = try image()
    let session = UUID()
    let node = AnnotationNode(
      tool: .text, color: NSColor.red.cgColor,
      points: [CGPoint(x: 0.2, y: 0.3)], text: "Original", fontSize: 24)
    canvas.updateTextEntry(id: session, node: node, onCommit: { _ in }, onCancel: {})
    let editor = try #require(canvas.canvasTextEditor)
    editor.string = "Live draft"
    editor.setSelectedRange(NSRange(location: 4, length: 0))

    var updated = node
    updated.color = NSColor.blue.cgColor
    updated.fillColor = NSColor.black.withAlphaComponent(0.4).cgColor
    updated.opacity = 0.6
    updated.fontName = "Menlo"
    updated.fontSize = 48
    updated.textAlignment = .trailing
    canvas.updateTextEntry(id: session, node: updated, onCommit: { _ in }, onCancel: {})

    #expect(canvas.canvasTextEditor === editor)
    #expect(editor.string == "Live draft")
    #expect(editor.selectedRange() == NSRange(location: 4, length: 0))
    #expect(editor.sourceNode?.fontSize == 48)
    #expect(editor.font?.pointSize == 48)
    #expect(editor.font?.familyName == NSFont(name: "Menlo", size: 48)?.familyName)
    #expect(editor.alignment == .right)
    #expect(editor.drawsBackground)
    #expect(editor.textColor?.usingColorSpace(.sRGB)?.blueComponent ?? 0 > 0.8)
  }

  @Test func editedTextStyleIsDraftedUntilCommitAndCancelRestoresInspector() throws {
    let model = try model()
    model.beginTextEntry(at: CGPoint(x: 0.2, y: 0.3))
    model.textDraft = "Original"
    model.commitTextEntry()
    let original = try #require(model.document?.nodes.first)
    model.beginTextEditing(original)

    model.fontName = "Menlo"
    model.fontSize = 48
    model.textAlignment = .trailing
    model.annotationOpacity = 0.6
    model.fillEnabled = true
    model.fillColor = .black
    model.updateSelectedStyle()

    let draft = try #require(model.pendingTextNode)
    #expect(draft.fontName == "Menlo")
    #expect(draft.fontSize == 48)
    #expect(draft.textAlignment == .trailing)
    #expect(draft.opacity == 0.6)
    #expect(draft.fillColor != nil)
    #expect(model.document?.nodes.first?.fontSize == 24)

    model.cancelTextEntry()
    #expect(model.document?.nodes.first?.fontSize == 24)
    #expect(model.fontSize == 24)

    model.beginTextEditing(original)
    model.textDraft = "Updated"
    model.fontName = "Menlo"
    model.fontSize = 48
    model.textAlignment = .trailing
    model.commitTextEntry()
    #expect(model.document?.nodes.first?.text == "Updated")
    #expect(model.document?.nodes.first?.fontName == "Menlo")
    #expect(model.document?.nodes.first?.fontSize == 48)
    #expect(model.document?.nodes.first?.textAlignment == .trailing)

    model.undo()
    #expect(model.document?.nodes.first?.text == "Original")
    #expect(model.document?.nodes.first?.fontSize == 24)
  }

  @Test func fittedLongTextAccountsForWrappingAtImageWidth() throws {
    let model = EditorViewModel()
    let narrowImage = try image(width: 160, height: 600)
    model.document = model.interactor.createDocument(from: narrowImage)
    model.beginTextEntry(at: .zero)
    model.fontSize = 24
    model.textDraft = Array(repeating: "wrapping", count: 12).joined(separator: " ")
    model.commitTextEntry()

    let node = try #require(model.document?.nodes.first)
    #expect(node.normalizedRect.width <= 1)
    #expect(node.normalizedRect.height > 0.2)
  }

  @Test func smallTextContainerIncludesAllLaidOutGlyphs() throws {
    let canvas = EditableAnnotationCanvasNSView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    canvas.image = try image()
    let node = AnnotationNode(
      tool: .text, color: NSColor.red.cgColor,
      points: [CGPoint(x: 0.2, y: 0.3)], text: "Small 中文", fontSize: 24)
    canvas.updateTextEntry(id: UUID(), node: node, onCommit: { _ in }, onCancel: {})
    let editor = try #require(canvas.canvasTextEditor)
    let container = try #require(editor.textContainer)
    let layoutManager = try #require(editor.layoutManager)
    layoutManager.ensureLayout(for: container)
    let usedHeight = layoutManager.usedRect(for: container).height

    #expect(container.containerSize.height >= ceil(usedHeight) + 1)
    #expect(editor.bounds.height >= ceil(usedHeight) + editor.textContainerInset.height * 2 + 1)
  }

  @Test func nativeReturnModesAndEscape() throws {
    for newline in [false, true] {
      let editor = CanvasTextEditor(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
      editor.enterInsertsNewline = { newline }
      editor.string = "hello"
      editor.setSelectedRange(NSRange(location: 5, length: 0))
      var submitted = false
      var cancelled = false
      editor.onCommit = { _ in submitted = true }
      editor.onCancel = { cancelled = true }
      let newlineEvent = try #require(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero,
          modifierFlags: newline ? [] : [.shift], timestamp: 0, windowNumber: 0, context: nil,
          characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
      editor.keyDown(with: newlineEvent)
      #expect(editor.string == "hello\n")
      #expect(!submitted)
      let submitEvent = try #require(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero,
          modifierFlags: newline ? [.shift] : [], timestamp: 0, windowNumber: 0, context: nil,
          characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
      editor.keyDown(with: submitEvent)
      #expect(submitted)
      let escape = try #require(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero,
          modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
          characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
      editor.keyDown(with: escape)
      #expect(cancelled)
    }
  }

  @Test func clickingCanvasCancelsRatherThanCreatingAnotherText() throws {
    let canvas = EditableAnnotationCanvasNSView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    canvas.image = try image()
    canvas.currentTool = .text
    var cancelled = false
    let node = AnnotationNode(tool: .text, points: [.zero], text: "draft")
    canvas.updateTextEntry(id: UUID(), node: node, onCommit: { _ in }, onCancel: { cancelled = true })
    let click = try #require(
      NSEvent.mouseEvent(
        with: .leftMouseDown, location: CGPoint(x: 500, y: 500),
        modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    canvas.mouseDown(with: click)
    #expect(cancelled)
    #expect(canvas.canvasTextEditor == nil)
  }
}
