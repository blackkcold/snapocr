import AppKit
import BarcodeCore
import CaptureCore
import HistoryCore
import OCRCore
import SharedKit
import SwiftUI

// MARK: - Capture Processing

extension CaptureViewModel {
    func processCapturedImage(
        _ image: CGImage,
        captureMode: CaptureCore.CaptureMode,
        sourceAppName: String? = nil,
        sourceWindowTitle: String? = nil,
        historyModeOverride: String? = nil,
        destination: CaptureDestination = .configured,
        pinRect: CGRect? = nil
    ) async {
        let modeDescription = historyModeOverride ?? Self.historyModeDescription(for: captureMode)
        let (shouldOpenEditor, shouldCopyImage) = resolveDestination(destination)
        let historyContext = HistorySaveContext(
            modeDescription: modeDescription,
            appName: sourceAppName,
            windowTitle: sourceWindowTitle
        )

        if destination == .pinOnly, let pinRect {
            presentPinnedImage(image, pinRect: pinRect)
        }

        let imageCopySucceeded: Bool
        if shouldCopyImage {
            imageCopySucceeded = await writeImageToClipboard(image)
        } else {
            imageCopySucceeded = true
        }
        presentCopyFeedback(
            imageCopySucceeded: imageCopySucceeded,
            shouldOpenEditor: shouldOpenEditor,
            destination: destination
        )

        if shouldOpenEditor {
            openEditorAndFinish(
                image: image,
                modeDescription: modeDescription,
                destination: destination,
                historyContext: historyContext,
                imageCopySucceeded: imageCopySucceeded
            )
            return
        }

        let ocrResult = await runOCRAndSuggestions(
            on: image,
            shouldOpenEditor: false,
            destination: destination
        )

        // Save before finishing for non-editor destinations: the caller has no
        // window to show while this runs, and pinned captures need the record.
        _ = await saveIfNeeded(
            image: image,
            ocrResult: ocrResult,
            destination: destination,
            imageCopySucceeded: imageCopySucceeded,
            context: historyContext
        )
    }

    /// Links a history record that finished writing after the editor opened.
    private func attachHistoryEntry(_ entryID: UUID, to tabID: UUID) {
        editorWorkspace.attachSourceEntry(entryID, to: tabID)
    }

    /// Opens the editor immediately, then runs OCR/barcode detection and the
    /// history write in the background. The record id is linked afterwards so
    /// "overwrite original" still works.
    private func openEditorAndFinish(
        image: CGImage,
        modeDescription: String,
        destination: CaptureDestination,
        historyContext: HistorySaveContext,
        imageCopySucceeded: Bool
    ) {
        let tabID = openEditor(with: image, captureMode: modeDescription, sourceEntryID: nil)
        Task { [weak self] in
            guard let self else { return }
            let ocrResult = await self.runOCRAndSuggestions(
                on: image,
                shouldOpenEditor: true,
                destination: destination
            )
            let historyEntryID = await self.saveIfNeeded(
                image: image,
                ocrResult: ocrResult,
                destination: destination,
                imageCopySucceeded: imageCopySucceeded,
                context: historyContext
            )
            if let historyEntryID, let tabID {
                self.attachHistoryEntry(historyEntryID, to: tabID)
            }
        }
    }

    /// 按真实缩放倍率创建置顶面板（同步，先于历史写入）。
    private func presentPinnedImage(_ image: CGImage, pinRect: CGRect) {
        let displayScale = PinnedImageGeometry.displayScale(
            imagePixelWidth: CGFloat(image.width),
            pointWidth: pinRect.width
        )
        PinnedWindowManager.shared.pin(
            image: image,
            displayScale: displayScale,
            pinRect: pinRect
        )
    }

    private func saveIfNeeded(
        image: CGImage,
        ocrResult: OCRResult?,
        destination: CaptureDestination,
        imageCopySucceeded: Bool,
        context: HistorySaveContext
    ) async -> UUID? {
        let autoSave = Self.boolPreference(
            forKey: PreferenceKeys.historyAutoSave,
            defaultValue: PreferenceDefaults.historyAutoSave
        )
        let saveFullText = Self.boolPreference(
            forKey: PreferenceKeys.historySaveFullText,
            defaultValue: PreferenceDefaults.historySaveFullText
        )
        let shouldSaveToHistory = switch destination {
        case .configured: autoSave
        case .clipboardOnly: imageCopySucceeded
        case .editorOnly: true
        case .pinOnly: true
        }
        guard shouldSaveToHistory else { return nil }
        return await saveToHistoryAndWait(
            image: image,
            ocrResult: ocrResult,
            saveFullText: saveFullText,
            captureMode: context.modeDescription,
            source: CaptureSourceInfo(
                appName: context.appName,
                windowTitle: context.windowTitle
            ),
            isProtected: destination == .pinOnly
        )
    }

    /// 运行 OCR 并展示条码复制建议，返回 OCR 结果。
    private func runOCRAndSuggestions(
        on image: CGImage,
        shouldOpenEditor: Bool,
        destination: CaptureDestination
    ) async -> OCRResult? {
        guard destination != .pinOnly else { return nil }
        let barcodeResults = shouldOpenEditor ? await detectBarcodesForSuggestion(in: image) : []

        let shouldRunOCR = Self.boolPreference(
            forKey: PreferenceKeys.captureAutoOCR,
            defaultValue: PreferenceDefaults.captureAutoOCR
        )
        let shouldCopyOCRText = destination != .clipboardOnly && Self.boolPreference(
            forKey: PreferenceKeys.captureCopyOCRText,
            defaultValue: PreferenceDefaults.captureCopyOCRText
        )
        let ocrResult = shouldRunOCR
            ? await performOCR(on: image, copyToClipboard: shouldCopyOCRText)
            : nil

        if let payload = BarcodeCopyCandidate.singlePayload(from: barcodeResults) {
            showBarcodeCopySuggestion(payload: payload)
        }
        return ocrResult
    }

    /// 根据目标解析是否打开编辑器与是否复制图片。
    private func resolveDestination(_ destination: CaptureDestination) -> (openEditor: Bool, copyImage: Bool) {
        switch destination {
        case .configured:
            return (
                Self.boolPreference(
                    forKey: PreferenceKeys.captureOpenEditor,
                    defaultValue: PreferenceDefaults.captureOpenEditor
                ),
                Self.boolPreference(
                    forKey: PreferenceKeys.captureCopyToClipboard,
                    defaultValue: PreferenceDefaults.captureCopyToClipboard
                )
            )
        case .clipboardOnly:
            return (false, true)
        case .editorOnly:
            return (true, false)
        case .pinOnly:
            return (false, false)
        }
    }

    /// Presents the copy/editor success or failure toast after a capture.
    private func presentCopyFeedback(
        imageCopySucceeded: Bool,
        shouldOpenEditor: Bool,
        destination: CaptureDestination
    ) {
        guard destination != .pinOnly else { return }
        // Opening the editor is itself the success feedback, so suppress the
        // success toast to avoid it overlapping the editor UI. Failure to copy
        // (when copying was requested) is still surfaced as an error toast.
        if !imageCopySucceeded {
            showToast(
                message: AppLocalization.string("Unable to copy image"),
                type: .error
            )
        } else if !shouldOpenEditor {
            let completionMessage: String
            if destination == .clipboardOnly {
                completionMessage = AppLocalization.string("Screenshot copied to clipboard")
            } else {
                completionMessage = AppLocalization.string("Capture successful")
            }
            showToast(
                message: completionMessage,
                type: .success
            )
        }
    }

}
