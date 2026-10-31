import AppKit
import BarcodeCore
import CaptureCore
import HistoryCore
import OCRCore
import SharedKit
import SwiftUI

// MARK: - CaptureViewModel Capture Operations

private struct PreCapturedDisplays: Sendable {
    let images: [CGDirectDisplayID: CGImage]
    let displayFrames: [CGDirectDisplayID: CGRect]

    var hasEveryDisplay: Bool {
        !displayFrames.isEmpty && displayFrames.keys.allSatisfy { images[$0] != nil }
    }

    static let empty = PreCapturedDisplays(images: [:], displayFrames: [:])
}

private enum CaptureImageSource {
    case live
    case snapshot(CGImage)
}

extension CaptureViewModel {
    public func captureArea() {
        startAreaCapture()
    }

    private func startAreaCapture() {
        Task {
            guard !isCapturing else { return }
            isCapturing = true
            defer { isCapturing = false }

            let (selectionStyle, overlayMode) = Self.areaCapturePreferences()
            let setup = await preCaptureSetup(for: overlayMode)
            if overlayMode == .snapshot, !setup.displays.hasEveryDisplay {
                showStaticSnapshotFailure()
                return
            }
            let selection = await awaitAreaSelection(
                style: selectionStyle,
                overlayMode: overlayMode,
                capturedFrames: setup.displays.images,
                preCaptureTask: setup.task
            )
            setup.task?.cancel()
            guard let selection else { return }
            await performAreaSelection(
                selection,
                overlayMode: overlayMode,
                capturedDisplays: setup.displays
            )
        }
    }

    /// Snapshot mode paints the frozen desktop inside the overlay, so it must
    /// wait for the frames. Live mode presents first and hands them over when
    /// ready; color picking simply has no sample until then.
    private func preCaptureSetup(
        for overlayMode: CaptureOverlayMode
    ) async -> (
        displays: PreCapturedDisplays,
        task: Task<PreCapturedDisplays, Never>?
    ) {
        let captureOptions = Self.currentCaptureOptions()
        if overlayMode == .snapshot {
            return (await preCaptureAllScreens(options: captureOptions), nil)
        }

        let task = Task<PreCapturedDisplays, Never> { [weak self] in
            guard let self else { return .empty }
            return await self.preCaptureAllScreens(options: captureOptions)
        }
        return (.empty, task)
    }

    private func awaitAreaSelection(
        style: CaptureSelectionStyle,
        overlayMode: CaptureOverlayMode,
        capturedFrames: [CGDirectDisplayID: CGImage],
        preCaptureTask: Task<PreCapturedDisplays, Never>?
    ) async -> AreaSelectionResult? {
        await withCheckedContinuation { continuation in
            var didResume = false
            Task { @MainActor in
                AreaSelectionPanel.show(
                    style: style,
                    overlayMode: overlayMode,
                    capturedFrames: capturedFrames,
                    onColorPicked: { [weak self] color in
                        self?.copyHexToClipboard(color)
                    },
                    onRecaptureRegion: { [weak self] quartzRect in
                        guard let self else { return nil }
                        return await self.recaptureRegionForBarcodeScan(quartzRect)
                    },
                    onComplete: { result in
                        guard !didResume else { return }
                        didResume = true
                        continuation.resume(returning: result)
                    }
                )

                if let preCaptureTask {
                    Task { @MainActor in
                        let displays = await preCaptureTask.value
                        AreaSelectionPanel.updateCapturedFrames(displays.images)
                    }
                }
            }
        }
    }

    private func performAreaSelection(
        _ selection: AreaSelectionResult,
        overlayMode: CaptureOverlayMode,
        capturedDisplays: PreCapturedDisplays
    ) async {
        let destination: CaptureDestination =
            switch selection.action {
            case .copy: .clipboardOnly
            case .edit: .editorOnly
            case .pin: .pinOnly
            }

        let imageSource: CaptureImageSource
        if overlayMode == .snapshot {
            guard let displayID = selection.displayID,
                  let snapshot = capturedDisplays.images[displayID],
                  let displayFrame = capturedDisplays.displayFrames[displayID] else {
                showStaticSnapshotFailure()
                return
            }
            do {
                let croppedImage = try StaticSnapshotRegionCropper.crop(
                    from: snapshot,
                    areaRect: selection.screenRect,
                    displayFrame: displayFrame
                )
                imageSource = .snapshot(croppedImage)
            } catch {
                logger.warning("Unable to crop static snapshot for display \(displayID): \(error)")
                showStaticSnapshotFailure()
                return
            }
        } else {
            imageSource = .live
        }

        await performCapture(
            mode: CaptureCore.CaptureMode.area(selection.screenRect),
            imageSource: imageSource,
            normalizedMaskPath: selection.normalizedPath,
            historyModeOverride: selection.isFreeform ? "freeform" : nil,
            destination: destination,
            pinRect: selection.appKitRect,
            managesCaptureState: false
        )
    }

    private func showStaticSnapshotFailure() {
        showToast(
            message: AppLocalization.string(
                "Static snapshot failed. Try again or switch to Live screen in Preferences."
            ),
            type: .error,
            actionLabel: AppLocalization.string("Retry"),
            action: { [weak self] in self?.captureArea() }
        )
    }

    /// 区域截图的样式与遮罩模式偏好。
    private static func areaCapturePreferences() -> (CaptureSelectionStyle, CaptureOverlayMode) {
        let style =
            CaptureSelectionStyle(
                rawValue: stringPreference(
                    forKey: PreferenceKeys.captureSelectionStyle,
                    defaultValue: PreferenceDefaults.captureSelectionStyle
                )
            ) ?? .rectangle
        return (style, currentCaptureOverlayMode())
    }

    private static func currentCaptureOverlayMode() -> CaptureOverlayMode {
        CaptureOverlayMode(
            rawValue: stringPreference(
                forKey: PreferenceKeys.captureOverlayMode,
                defaultValue: PreferenceDefaults.captureOverlayMode
            )
        ) ?? .live
    }

    /// Pre-captures each screen's full frame before the overlay appears using the
    /// ordinary capture options, keeping a stable preview and sample source
    /// for hover/click color picking. The area rect must use Quartz global
    /// bounds (CGDisplayBounds) so it matches both the sampling path above
    /// (which converts AppKit points via quartzScreenFrame: CGDisplayBounds)
    /// and the selection path below (selection.screenRect is already a Quartz
    /// rect). AppKit screen.frame coordinates can diverge from Quartz bounds
    /// on secondary displays arranged above/left of the main screen. Sampling
    /// and snapshot previews share these frames at the requested resolution.
    private func preCaptureAllScreens(options captureOptions: CaptureOptions) async -> PreCapturedDisplays {
        let displays: [(id: CGDirectDisplayID, bounds: CGRect)] = NSScreen.screens.compactMap { screen in
            guard
                let displayID = screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                ] as? CGDirectDisplayID
            else { return nil }
            return (displayID, CGDisplayBounds(displayID))
        }
        guard !displays.isEmpty else { return .empty }
        let displayFrames = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0.bounds) })

        let orchestrator = captureOrchestrator
        return await withTaskGroup(
            of: (id: CGDirectDisplayID, image: CGImage?, failure: String?).self,
            returning: PreCapturedDisplays.self
        ) { group in
            for display in displays {
                group.addTask {
                    do {
                        let result = try await orchestrator.capture(
                            mode: CaptureCore.CaptureMode.area(display.bounds),
                            options: captureOptions
                        )
                        return (display.id, result.image, nil)
                    } catch {
                        return (display.id, nil, error.localizedDescription)
                    }
                }
            }

            var capturedFrames: [CGDirectDisplayID: CGImage] = [:]
            for await result in group {
                if let image = result.image {
                    capturedFrames[result.id] = image
                } else if let failure = result.failure {
                    logger.warning(
                        "Pre-capture failed for display \(result.id): \(failure)"
                    )
                }
            }
            return PreCapturedDisplays(images: capturedFrames, displayFrames: displayFrames)
        }
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
    @discardableResult
    public func openEditor(
        with image: CGImage,
        captureMode: String? = nil,
        sourceEntryID: UUID? = nil
    ) -> UUID? {
        let context = EditorCaptureContext.capture(
            image: image,
            captureMode: captureMode,
            sourceEntryID: sourceEntryID
        )
        guard let tab = editorWorkspace.open(image: image, context: context) else {
            showToast(
                message: AppLocalization.string("Close a tab before opening another screenshot"),
                type: .error
            )
            return nil
        }
        openWindow?("editor")
        return tab.id
    }

    /// Performs a capture with the specified mode.
    ///
    /// - Parameter mode: The capture mode to use.
    private func performCapture(
        mode: CaptureCore.CaptureMode,
        imageSource: CaptureImageSource = .live,
        sourceAppName: String? = nil,
        sourceWindowTitle: String? = nil,
        normalizedMaskPath: [CGPoint]? = nil,
        historyModeOverride: String? = nil,
        destination: CaptureDestination = .configured,
        pinRect: CGRect? = nil,
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
            let captureMode: CaptureCore.CaptureMode
            let capturedImage: CGImage
            switch imageSource {
            case .live:
                let result = try await captureOrchestrator.capture(
                    mode: mode,
                    options: Self.currentCaptureOptions()
                )
                captureMode = result.captureMode
                capturedImage = result.image
            case .snapshot(let image):
                captureMode = mode
                capturedImage = image
            }
            let image = if let normalizedMaskPath {
                try SelectionMaskProcessor.apply(to: capturedImage, normalizedPath: normalizedMaskPath)
            } else {
                capturedImage
            }
            await processCapturedImage(
                image,
                captureMode: captureMode,
                sourceAppName: sourceAppName,
                sourceWindowTitle: sourceWindowTitle,
                historyModeOverride: historyModeOverride,
                destination: destination,
                pinRect: pinRect
            )
        } catch CaptureError.permissionDenied {
            openWindow?("permission")
        } catch {
            showToast(message: AppLocalization.string("Capture failed: %@", error.localizedDescription), type: .error)
        }
    }

    func resetScrollCaptureState() {
        scrollSession = nil
        scrollSourceAppName = nil
        scrollSourceWindowTitle = nil
        scrollCapturedFrameCount = 0
        scrollReachedSizeLimit = false
        isScrollCaptureActive = false
    }
}
