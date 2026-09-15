import AppKit
import BarcodeCore
import CaptureCore
import HistoryCore
import OCRCore
import SharedKit
import SwiftUI

// MARK: - CaptureViewModel Capture Operations

extension CaptureViewModel {
    public func captureArea() {
        startAreaCapture()
    }

    private func startAreaCapture() {
        Task {
            guard !isCapturing else { return }
            isCapturing = true
            defer { isCapturing = false }

            let selectionStyle =
                CaptureSelectionStyle(
                    rawValue: Self.stringPreference(
                        forKey: PreferenceKeys.captureSelectionStyle,
                        defaultValue: PreferenceDefaults.captureSelectionStyle
                    )
                ) ?? .rectangle
            let overlayMode = Self.currentCaptureOverlayMode()

            let capturedFrames = await preCaptureAllScreens()

            let selection: AreaSelectionResult? = await withCheckedContinuation { continuation in
                var didResume = false
                Task { @MainActor in
                    AreaSelectionPanel.show(
                        style: selectionStyle,
                        overlayMode: overlayMode,
                        capturedFrames: capturedFrames,
                        onColorPicked: { [weak self] color in
                            self?.copyHexToClipboard(color)
                        },
                        onComplete: { result in
                            guard !didResume else { return }
                            didResume = true
                            continuation.resume(returning: result)
                        }
                    )
                }
            }

            guard let selection else { return }
            let destination: CaptureDestination =
                switch selection.action {
                case .copy: .clipboardOnly
                case .edit: .editorOnly
                }
            await performCapture(
                mode: CaptureCore.CaptureMode.area(selection.screenRect),
                normalizedMaskPath: selection.normalizedPath,
                historyModeOverride: selection.isFreeform ? "freeform" : nil,
                destination: destination,
                managesCaptureState: false
            )
        }
    }

    private static func currentCaptureOverlayMode() -> CaptureOverlayMode {
        CaptureOverlayMode(
            rawValue: stringPreference(
                forKey: PreferenceKeys.captureOverlayMode,
                defaultValue: PreferenceDefaults.captureOverlayMode
            )
        ) ?? .live
    }

    /// Pre-captures each screen's full frame before the overlay appears so the
    /// frames contain no overlay windows, no cursor, and a stable sample source
    /// for hover/click color picking. The area rect must use Quartz global
    /// bounds (CGDisplayBounds) so it matches both the sampling path above
    /// (which converts AppKit points via quartzScreenFrame: CGDisplayBounds)
    /// and the selection path below (selection.screenRect is already a Quartz
    /// rect). AppKit screen.frame coordinates can diverge from Quartz bounds
    /// on secondary displays arranged above/left of the main screen. Sampling
    /// and snapshot previews share these full-resolution frames.
    private func preCaptureAllScreens() async -> [CGDirectDisplayID: CGImage] {
        var capturedFrames: [CGDirectDisplayID: CGImage] = [:]
        let captureOptions = CaptureOptions(
            includeCursor: false,
            highResolution: true
        )
        for screen in NSScreen.screens {
            guard
                let displayID = screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                ] as? CGDirectDisplayID
            else { continue }
            do {
                let result = try await captureOrchestrator.capture(
                    mode: CaptureCore.CaptureMode.area(CGDisplayBounds(displayID)),
                    options: captureOptions
                )
                capturedFrames[displayID] = result.image
            } catch {
                logger.warning(
                    "Pre-capture failed for display \(displayID): \(error.localizedDescription)"
                )
            }
        }
        return capturedFrames
    }

    private func copyHexToClipboard(_ color: SampledColor) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(color.hexString, forType: .string)
        showToast(
            message: AppLocalization.string("Color %@ copied", color.hexString),
            type: .success
        )
        recordColorHistory(color, source: .area)
    }

    private func recordColorHistory(_ color: SampledColor, source: ColorHistoryEntry.Source) {
        guard colorHistoryEnabled else { return }
        guard let colorHistory = ColorHistoryStore.shared else { return }
        Task {
            try? await colorHistory.save(color, source: source)
        }
    }

    private var colorHistoryEnabled: Bool {
        guard UserDefaults.standard.object(forKey: PreferenceKeys.colorHistoryEnabled) != nil else {
            return PreferenceDefaults.colorHistoryEnabled
        }
        return UserDefaults.standard.bool(forKey: PreferenceKeys.colorHistoryEnabled)
    }

    /// Triggers a window capture.
    public func captureWindow() {
        startWindowCapture(destination: .configured)
    }

    /// Captures a selected window directly to the clipboard without opening the editor.
    public func captureWindowToClipboard() {
        startWindowCapture(destination: .clipboardOnly)
    }

    private func startWindowCapture(destination: CaptureDestination) {
        Task {
            guard !isCapturing, !isScrollCaptureActive else { return }
            isCapturing = true
            defer { isCapturing = false }

            guard await captureOrchestrator.checkPermissionStatus() else {
                openWindow?("permission")
                return
            }

            guard let selectedWindow = await selectWindow() else { return }

            switch selectedWindow.action {
            case .still:
                await performCapture(
                    mode: CaptureCore.CaptureMode.window(selectedWindow.windowID),
                    sourceAppName: selectedWindow.appName,
                    sourceWindowTitle: selectedWindow.windowTitle,
                    destination: destination,
                    managesCaptureState: false
                )
            case .edit:
                // Double-clicking a window preview opens it directly in the editor.
                await performCapture(
                    mode: CaptureCore.CaptureMode.window(selectedWindow.windowID),
                    sourceAppName: selectedWindow.appName,
                    sourceWindowTitle: selectedWindow.windowTitle,
                    destination: .editorOnly,
                    managesCaptureState: false
                )
            case .scrolling:
                await beginScrollCapture(with: selectedWindow)
            }
        }
    }

    /// Triggers a fullscreen capture.
    public func captureFullscreen() {
        Task {
            await performCapture(mode: CaptureCore.CaptureMode.fullscreen, destination: .configured)
        }
    }

    /// Captures the fullscreen image directly to the clipboard without opening the editor.
    public func captureFullscreenToClipboard() {
        Task {
            await performCapture(mode: CaptureCore.CaptureMode.fullscreen, destination: .clipboardOnly)
        }
    }

    /// Performs OCR on the image currently in the clipboard.
    public func ocrFromClipboard() {
        Task {
            guard let image = NSPasteboard.general.readObjects(
                forClasses: [NSImage.self],
                options: nil
            )?.first as? NSImage,
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                showToast(message: AppLocalization.string("No image found in clipboard"), type: .error)
                return
            }

            _ = await performOCR(on: cgImage, copyToClipboard: true)
        }
    }

    /// Opens a fresh annotation editor session for an image.
    public func openEditor(
        with image: CGImage,
        captureMode: String? = nil,
        sourceEntryID: UUID? = nil
    ) {
        editorImage = image
        editorContext = EditorCaptureContext.capture(
            image: image,
            captureMode: captureMode,
            sourceEntryID: sourceEntryID
        )
        editorSessionID = UUID()
        openWindow?("editor")
    }

    /// Performs a capture with the specified mode.
    ///
    /// - Parameter mode: The capture mode to use.
    private func performCapture(
        mode: CaptureCore.CaptureMode,
        sourceAppName: String? = nil,
        sourceWindowTitle: String? = nil,
        normalizedMaskPath: [CGPoint]? = nil,
        historyModeOverride: String? = nil,
        destination: CaptureDestination = .configured,
        managesCaptureState: Bool = true
    ) async {
        if managesCaptureState {
            guard !isCapturing else { return }
            isCapturing = true
        }
        defer {
            if managesCaptureState {
                isCapturing = false
            }
        }

        do {
            let result = try await captureOrchestrator.capture(
                mode: mode,
                options: Self.currentCaptureOptions()
            )
            let image = if let normalizedMaskPath {
                try SelectionMaskProcessor.apply(to: result.image, normalizedPath: normalizedMaskPath)
            } else {
                result.image
            }
            await processCapturedImage(
                image,
                captureMode: result.captureMode,
                sourceAppName: sourceAppName,
                sourceWindowTitle: sourceWindowTitle,
                historyModeOverride: historyModeOverride,
                destination: destination
            )
        } catch CaptureError.permissionDenied {
            openWindow?("permission")
        } catch {
            showToast(message: AppLocalization.string("Capture failed: %@", error.localizedDescription), type: .error)
        }
    }

    func processCapturedImage(
        _ image: CGImage,
        captureMode: CaptureCore.CaptureMode,
        sourceAppName: String? = nil,
        sourceWindowTitle: String? = nil,
        historyModeOverride: String? = nil,
        destination: CaptureDestination = .configured
    ) async {
        let modeDescription = historyModeOverride ?? Self.historyModeDescription(for: captureMode)
        let (shouldOpenEditor, shouldCopyImage) = resolveDestination(destination)

        let imageCopySucceeded = !shouldCopyImage || writeImageToClipboard(image)
        presentCopyFeedback(
            imageCopySucceeded: imageCopySucceeded,
            shouldOpenEditor: shouldOpenEditor,
            destination: destination
        )

        let ocrResult = await runOCRAndSuggestions(
            on: image,
            shouldOpenEditor: shouldOpenEditor,
            destination: destination
        )

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
        }
        // Save before opening the editor so the editor knows which record the
        // image belongs to and can offer a reversible overwrite.
        var historyEntryID: UUID?
        if shouldSaveToHistory {
            historyEntryID = await saveToHistoryAndWait(
                image: image,
                ocrResult: ocrResult,
                saveFullText: saveFullText,
                captureMode: modeDescription,
                source: CaptureSourceInfo(
                    appName: sourceAppName,
                    windowTitle: sourceWindowTitle
                )
            )
        }

        if shouldOpenEditor {
            openEditor(
                with: image,
                captureMode: modeDescription,
                sourceEntryID: historyEntryID
            )
        }
    }

    /// 运行 OCR 并展示条码复制建议，返回 OCR 结果。
    private func runOCRAndSuggestions(
        on image: CGImage,
        shouldOpenEditor: Bool,
        destination: CaptureDestination
    ) async -> OCRResult? {
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
        }
    }

    /// Presents the copy/editor success or failure toast after a capture.
    private func presentCopyFeedback(
        imageCopySucceeded: Bool,
        shouldOpenEditor: Bool,
        destination: CaptureDestination
    ) {
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

    private func selectWindow() async -> WindowSelectionResult? {
        await withCheckedContinuation { continuation in
            var didResume = false
            let resumeOnce: (WindowSelectionResult?) -> Void = { result in
                guard !didResume else { return }
                didResume = true
                continuation.resume(returning: result)
            }

            Task { @MainActor in
                WindowSelectionPanel.show { result in
                    resumeOnce(result)
                }
            }

            // Safety net: if the panel never completes (e.g. a stale/leaked
            // instance), force-resume so `isCapturing` is always released.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(8))
                resumeOnce(nil)
            }
        }
    }

    func resetScrollCaptureState() {
        scrollSession = nil
        scrollFrames.removeAll()
        scrollSourceAppName = nil
        scrollSourceWindowTitle = nil
        scrollCapturedFrameCount = 0
        isScrollCaptureActive = false
    }
}
