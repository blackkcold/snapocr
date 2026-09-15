import AppKit
import HistoryCore
import OCRCore
import SharedKit
import SwiftUI

// MARK: - CaptureViewModel History Persistence

extension CaptureViewModel {
  /// 将截图与 OCR 结果保存到历史记录。
  private func saveToHistory(
    image: CGImage,
    ocrResult: OCRResult?,
    saveFullText: Bool,
    captureMode: String,
    source: CaptureSourceInfo
  ) {
    let textToStore = saveFullText ? (ocrResult?.text ?? "") : ""
    let confidence = ocrResult?.confidence ?? 0
    scheduleHistorySave(
      image: image,
      textContent: textToStore,
      confidence: confidence,
      captureMode: captureMode,
      source: source
    )
  }

  /// Synchronous history save that returns the new entry id so the editor can
  /// bind its reversible-overwrite action to this capture.
  func saveToHistoryAndWait(
    image: CGImage,
    ocrResult: OCRResult?,
    saveFullText: Bool,
    captureMode: String,
    source: CaptureSourceInfo
  ) async -> UUID? {
    let textToStore = saveFullText ? (ocrResult?.text ?? "") : ""
    let confidence = ocrResult?.confidence ?? 0
    guard let history = HistoryActor.shared else {
      logger.error("HistoryActor unavailable, save skipped")
      showToast(message: AppLocalization.string("History unavailable; capture not saved"), type: .error)
      return nil
    }
    do {
      return try await history.saveCapture(
        image: image,
        textContent: textToStore,
        ocrConfidence: confidence,
        captureMode: captureMode,
        sourceType: .screenshot,
        sourceAppName: source.appName,
        sourceWindowTitle: source.windowTitle
      )
    } catch {
      logger.error("History save failed: \(error.localizedDescription)")
      showToast(message: AppLocalization.string("History save failed"), type: .error)
      return nil
    }
  }

  private func scheduleHistorySave(
    image: CGImage,
    textContent: String,
    confidence: Float,
    captureMode: String,
    source: CaptureSourceInfo
  ) {
    Task.detached(priority: .utility) { [weak self] in
      let logger = Logger(category: "capture")
      guard let history = HistoryActor.shared else {
        logger.error("HistoryActor unavailable, save skipped")
        await MainActor.run {
          self?.showToast(
            message: AppLocalization.string("History unavailable; capture not saved"),
            type: .error
          )
        }
        return
      }
      do {
        try await history.saveCapture(
          image: image,
          textContent: textContent,
          ocrConfidence: confidence,
          captureMode: captureMode,
          sourceType: .screenshot,
          sourceAppName: source.appName,
          sourceWindowTitle: source.windowTitle
        )
      } catch {
        logger.error("History save failed: \(error.localizedDescription)")
        await MainActor.run {
          self?.showToast(message: AppLocalization.string("History save failed"), type: .error)
        }
      }
    }
  }
}
