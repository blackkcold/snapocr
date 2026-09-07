import AnnotationCore
import AppKit
import SharedKit

/// A native multiline field whose bounds use image pixels, not screen points.
/// This preserves type size and horizontal scaling while the canvas resizes.
final class CanvasTextEditor: NSTextView {
  var sourceNode: AnnotationNode?
  var onCommit: ((String) -> Void)?
  var onCancel: (() -> Void)?
  var onLayoutRequested: (() -> Void)?
  var isFinishing = false
  var enterInsertsNewline: () -> Bool = {
    UserDefaults.standard.object(forKey: PreferenceKeys.editorEnterInsertsNewline) as? Bool
      ?? PreferenceDefaults.editorEnterInsertsNewline
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
    if let window {
      NotificationCenter.default.addObserver(
        self, selector: #selector(cancelOnWindowDeactivation),
        name: NSWindow.didResignKeyNotification, object: window)
    }
  }

  @objc private func cancelOnWindowDeactivation(_ notification: Notification) {
    if !isFinishing { onCancel?() }
  }

  override func keyDown(with event: NSEvent) {
    // Let the input method confirm/cancel its candidate before handling shortcuts.
    if hasMarkedText() {
      super.keyDown(with: event)
      return
    }
    if event.keyCode == 53 {
      onCancel?()
      return
    }
    if event.keyCode == 36 || event.keyCode == 76 {
      if TextEntryKeyBehavior.shouldSubmit(
        enterInsertsNewline: enterInsertsNewline(),
        shift: event.modifierFlags.contains(.shift), hasMarkedText: false
      ) {
        onCommit?(string)
      } else {
        insertNewlineIgnoringFieldEditor(self)
      }
      return
    }
    super.keyDown(with: event)
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if event.keyCode == 53 || event.keyCode == 36 || event.keyCode == 76 {
      keyDown(with: event)
      return true
    }
    if event.modifierFlags.contains(.command) {
      switch event.charactersIgnoringModifiers?.lowercased() {
      case "z":
        if event.modifierFlags.contains(.shift) { undoManager?.redo() } else { undoManager?.undo() }
      case "a": selectAll(self)
      case "c": copy(self)
      case "v": pasteAsPlainText(self)
      case "x": cut(self)
      default: return super.performKeyEquivalent(with: event)
      }
      return true
    }
    return super.performKeyEquivalent(with: event)
  }

  override func didChangeText() {
    super.didChangeText()
    onLayoutRequested?()
  }

  override func resignFirstResponder() -> Bool {
    let resigned = super.resignFirstResponder()
    if resigned, !isFinishing {
      // Do not publish SwiftUI state from within an AppKit focus update.
      Task { @MainActor [weak self] in
        guard let self, !self.isFinishing else { return }
        self.onCancel?()
      }
    }
    return resigned
  }
}

extension EditableAnnotationCanvasNSView {
  func updateTextEntry(
    id: UUID, node: AnnotationNode?, onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void
  ) {
    guard let node else {
      endTextEntry()
      return
    }
    if canvasTextEntryID == id { return }
    endTextEntry()
    canvasTextEntryID = id
    let editor = makeTextEditor(for: node)
    editor.onLayoutRequested = { [weak self] in self?.layoutTextEntry() }
    editor.onCommit = { [weak self] text in
      guard let self, self.canvasTextEntryID == id else { return }
      self.endTextEntry()
      onCommit(text)
    }
    editor.onCancel = { [weak self] in
      guard let self, self.canvasTextEntryID == id else { return }
      self.endTextEntry()
      onCancel()
    }
    canvasTextEditor = editor
    addSubview(editor)
    layoutTextEntry()
    Task { @MainActor [weak self, weak editor] in
      guard let self, let editor, self.canvasTextEntryID == id else { return }
      self.window?.makeFirstResponder(editor)
      editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
    }
  }

  private func makeTextEditor(for node: AnnotationNode) -> CanvasTextEditor {
    let editor = CanvasTextEditor(frame: .zero)
    editor.sourceNode = node
    editor.isRichText = false
    editor.importsGraphics = false
    editor.allowsUndo = true
    editor.isVerticallyResizable = false
    editor.isHorizontallyResizable = false
    editor.textContainer?.widthTracksTextView = false
    editor.textContainer?.heightTracksTextView = false
    editor.textContainer?.lineFragmentPadding = 0
    editor.textContainerInset = CGSize(width: 4 / node.textHorizontalScale, height: 4)
    editor.font = NSFont(name: node.fontName, size: node.fontSize) ?? NSFont.systemFont(ofSize: node.fontSize)
    editor.textColor = NSColor(cgColor: node.color ?? NSColor.red.cgColor)?.withAlphaComponent(node.opacity)
    editor.insertionPointColor = .controlAccentColor
    editor.drawsBackground = node.fillColor != nil
    editor.backgroundColor = NSColor(cgColor: node.fillColor ?? NSColor.clear.cgColor) ?? .clear
    editor.alignment =
      switch node.textAlignment {
      case .leading: .left
      case .center: .center
      case .trailing: .right
      }
    editor.string = node.text ?? ""
    editor.setAccessibilityLabel(String(localized: "Edit Text"))
    editor.wantsLayer = true
    editor.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.65).cgColor
    editor.layer?.borderWidth = 1
    return editor
  }

  func endTextEntry() {
    guard let editor = canvasTextEditor else { return }
    editor.isFinishing = true
    if window?.firstResponder === editor { window?.makeFirstResponder(self) }
    editor.removeFromSuperview()
    canvasTextEditor = nil
    canvasTextEntryID = nil
  }

  func layoutTextEntry() {
    guard let editor = canvasTextEditor, var node = editor.sourceNode, let image else { return }
    let display = aspectFitRect(imageSize: CGSize(width: image.width, height: image.height), in: bounds)
    node.text = editor.string.isEmpty ? " " : editor.string
    let measured = TextTool().suggestedSize(for: node)
    let width = min(max(measured.width, CGFloat(image.width) * 0.01), CGFloat(image.width))
    let height = min(max(measured.height, CGFloat(image.height) * 0.01), CGFloat(image.height))
    let origin = node.normalizedRect == .zero ? (node.points.first ?? .zero) : node.normalizedRect.origin
    let originX = min(max(origin.x, 0), 1 - width / CGFloat(image.width))
    let originY = min(max(origin.y, 0), 1 - height / CGFloat(image.height))
    editor.frame = CGRect(
      x: display.minX + originX * display.width, y: display.minY + originY * display.height,
      width: width / CGFloat(image.width) * display.width,
      height: height / CGFloat(image.height) * display.height)
    editor.bounds = CGRect(x: 0, y: 0, width: width / node.textHorizontalScale, height: height)
    editor.textContainer?.containerSize = CGSize(
      width: max((width - 8) / node.textHorizontalScale, 1), height: max(height - 8, 1)
    )
  }
}
