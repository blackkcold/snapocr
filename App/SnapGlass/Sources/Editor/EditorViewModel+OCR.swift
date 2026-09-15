import AnnotationCore
import AppKit
import BarcodeCore
import HistoryCore
import OCRCore
import SharedKit
import SwiftUI

// MARK: - EditorViewModel OCR / Color Picker / Barcode

extension EditorViewModel {
  public func startOCR() {
    ocrTask?.cancel()
    ocrGeneration &+= 1
    let generation = ocrGeneration
    guard let image = document?.baseImage else {
      isOCRRunning = false
      return
    }
    isOCRRunning = true
    ocrTask = Task { [weak self] in
      guard let self else { return }
      do {
        let options = OCROptions(
          languages: ["zh-Hans", "en-US"],
          minConfidence: 0.1,
          preserveLayout: true
        )
        let result = try await recognizeImage(image, options)
        guard !Task.isCancelled, generation == ocrGeneration else { return }
        ocrLines = result.observations
        showsOCROverlay = true
        isOCRRunning = false
        logger.info("Editor OCR completed with \(result.observations.count) lines")
      } catch is CancellationError {
        guard generation == ocrGeneration else { return }
        isOCRRunning = false
      } catch {
        guard !Task.isCancelled, generation == ocrGeneration else { return }
        ocrLines = []
        isOCRRunning = false
        showToast(message: AppLocalization.string("OCR failed: %@", error.localizedDescription), type: .error)
      }
    }
  }

  func restartOCRForCurrentImage() {
    cancelBarcodeScan()
    ocrLines = []
    startOCR()
  }

  public func copyOCRLine(_ line: OCRLine) {
    copyOCRText(line.text)
  }

  public func copyOCRLines(_ lines: [OCRLine]) {
    copyOCRText(lines.map(\.text).joined(separator: "\n"))
  }

  public func copyOCRSelection(_ text: String) {
    copyOCRText(text)
  }

  public func copyAllOCRText() {
    copyOCRLines(ocrLines)
  }

  public func addOCRLineAsAnnotation(_ line: OCRLine) {
    let rect = line.editorBoundingBox
    let node = AnnotationNode(
      tool: .text,
      color: cgColor,
      lineWidth: strokeWidth,
      opacity: annotationOpacity,
      fillColor: fillEnabled ? NSColor(fillColor).cgColor : nil,
      points: [rect.origin],
      text: line.text,
      fontName: fontName,
      fontSize: max(fontSize, rect.height * CGFloat(document?.baseImage.height ?? 1) * 0.8),
      textAlignment: textAlignment,
      normalizedRect: rect
    )
    addNode(fittedTextNode(node))
    selectedTool = .select
  }

  func fittedTextNode(_ source: AnnotationNode) -> AnnotationNode {
    guard source.tool == .text, let image = document?.baseImage else { return source }
    var node = source
    let origin =
      node.normalizedRect.origin != .zero
      ? node.normalizedRect.origin
      : (node.points.first ?? .zero)
    let imageWidth = CGFloat(max(image.width, 1))
    let maximumWidth = max(imageWidth * (1 - min(max(origin.x, 0), 1)), 1)
    let size = TextTool().suggestedSize(for: node, maximumWidth: maximumWidth)
    let normalizedWidth = size.width / CGFloat(max(image.width, 1))
    let normalizedHeight = size.height / CGFloat(max(image.height, 1))
    let fittedWidth = min(max(normalizedWidth, 0.01), 1)
    let fittedHeight = min(max(normalizedHeight, 0.01), 1)
    node.normalizedRect = CGRect(
      x: min(max(origin.x, 0), 1 - fittedWidth),
      y: min(max(origin.y, 0), 1 - fittedHeight),
      width: fittedWidth,
      height: fittedHeight
    )
    node.points = [node.normalizedRect.origin]
    return node
  }

  func applyingCurrentStyle(to source: AnnotationNode) -> AnnotationNode {
    var node = source
    node.color = cgColor
    node.lineWidth = strokeWidth
    node.opacity = annotationOpacity
    node.fillColor = fillEnabled ? NSColor(fillColor).cgColor : nil
    node.strokeStyle = strokeStyle
    node.cornerRadius = cornerRadius
    node.arrowStyle = arrowStyle
    node.fontName = fontName
    node.fontSize = fontSize
    node.textAlignment = textAlignment
    node.blurMode = blurMode
    node.blurIntensity = blurIntensity
    return node
  }

  private func copyOCRText(_ text: String) {
    guard !text.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    showToast(message: AppLocalization.string("Copied OCR text"), type: .success)
  }

  /// Handles a single-point color pick from the canvas.
  public func handleColorPicked(_ color: SampledColor) {
    pickerHoverColor = color
    copyColorToClipboard(color)
  }

  /// Handles a region pick, computing the average and dominant colors.
  /// Only the dominant (first) color reaches the clipboard/history so the
  /// history is not flooded by one region pick.
  public func handleRegionColorsPicked(_ colors: [SampledColor]) {
    guard let dominant = colors.first else { return }
    pickerDominantColors = colors
    pickerAverageColor = averageColor(of: colors)
    copyColorToClipboard(dominant)
  }

  private func averageColor(of colors: [SampledColor]) -> SampledColor? {
    guard !colors.isEmpty else { return nil }
    var totalRed = 0
    var totalGreen = 0
    var totalBlue = 0
    for color in colors {
      totalRed += Int(color.red)
      totalGreen += Int(color.green)
      totalBlue += Int(color.blue)
    }
    let count = colors.count
    return SampledColor(
      red: UInt8(totalRed / count),
      green: UInt8(totalGreen / count),
      blue: UInt8(totalBlue / count),
      alpha: 255
    )
  }

  func copyColorToClipboard(_ color: SampledColor) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(color.hexString, forType: .string)
    showToast(
      message: AppLocalization.string("Color %@ copied", color.hexString),
      type: .success
    )
    recordColorHistory(color)
  }

  /// Single recording point for editor-side color picks. Every copy path
  /// (single point, region, inspector swatch) funnels through here, so a
  /// pick is recorded exactly once.
  private func recordColorHistory(_ color: SampledColor) {
    guard colorHistoryEnabled else { return }
    guard let colorHistory = ColorHistoryStore.shared else { return }
    Task {
      try? await colorHistory.save(color, source: .editor)
    }
  }

  private var colorHistoryEnabled: Bool {
    guard UserDefaults.standard.object(forKey: PreferenceKeys.colorHistoryEnabled) != nil else {
      return PreferenceDefaults.colorHistoryEnabled
    }
    return UserDefaults.standard.bool(forKey: PreferenceKeys.colorHistoryEnabled)
  }

  /// Manually scans the current editor image and copies decoded barcode content.
  public func scanBarcodes() {
    barcodeTask?.cancel()
    barcodeGeneration &+= 1
    let generation = barcodeGeneration
    guard let image = document?.baseImage else {
      isBarcodeScanning = false
      return
    }

    isBarcodeScanning = true
    barcodeTask = Task { [weak self] in
      guard let self else { return }
      do {
        let results = try await detectBarcodes(image, [])
        guard !Task.isCancelled, generation == barcodeGeneration else { return }
        isBarcodeScanning = false
        handleBarcodeResults(results)
      } catch is CancellationError {
        guard generation == barcodeGeneration else { return }
        isBarcodeScanning = false
      } catch {
        guard !Task.isCancelled, generation == barcodeGeneration else { return }
        isBarcodeScanning = false
        showToast(
          message: AppLocalization.string("Barcode scan failed: %@", error.localizedDescription),
          type: .error
        )
      }
    }
  }

  /// 将识别到的条码内容复制到剪贴板并提示。
  private func handleBarcodeResults(_ results: [BarcodeResult]) {
    let payloads = results.map(\.payload).filter {
      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    guard !payloads.isEmpty else {
      showToast(
        message: AppLocalization.string("No barcode found"),
        type: .info
      )
      return
    }

    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(payloads.joined(separator: "\n"), forType: .string)
    if payloads.count == 1 {
      showToast(
        message: AppLocalization.string("Barcode copied to clipboard"),
        type: .success
      )
    } else {
      showToast(
        message: AppLocalization.string("%d barcodes copied to clipboard", payloads.count),
        type: .success
      )
    }
    logger.info("Editor barcode scan copied \(payloads.count) result(s)")
  }

  func cancelBarcodeScan() {
    barcodeTask?.cancel()
    barcodeGeneration &+= 1
    isBarcodeScanning = false
  }
}
