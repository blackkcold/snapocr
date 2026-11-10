import AppKit
import CaptureCore
import ImageIO
import SharedKit
import UniformTypeIdentifiers

extension CaptureViewModel {
    /// Toggles the recent screenshot shelf when it can be shown.
    public func toggleScreenshotShelf() {
        if screenshotShelfManager.isEditingSuppressed {
            showToast(
                message: AppLocalization.string("Close the editor to show the screenshot shelf"),
                type: .info
            )
            return
        }
        screenshotShelfManager.toggle()
    }

    /// Shows the recent screenshot shelf unless a system suppression is active.
    public func showScreenshotShelf() {
        screenshotShelfManager.show()
    }

    /// Hides the shelf until an explicit show or a later successful capture.
    public func hideScreenshotShelf() {
        screenshotShelfManager.hide()
    }

    /// Removes a capture from the session-only shelf without deleting its history entry.
    ///
    /// - Parameter captureID: Stable identity of the shelf item to remove.
    public func removeScreenshotShelfItem(captureID: UUID) {
        screenshotShelfManager.remove(captureID: captureID)
    }

    /// Clears all session-only shelf entries without changing screenshot history.
    public func clearScreenshotShelf() {
        screenshotShelfManager.clear()
    }

    func configureScreenshotShelf() {
        screenshotShelfManager.onEdit = { [weak self] in
            self?.editScreenshotShelfItem(captureID: $0)
        }
        screenshotShelfManager.onInspectMockup = { [weak self] in
            self?.inspectScreenshotShelfMockup(captureID: $0)
        }
        screenshotShelfManager.onCopy = { [weak self] in
            self?.copyScreenshotShelfItem(captureID: $0)
        }
        screenshotShelfManager.onPin = { [weak self] in
            self?.pinScreenshotShelfItem(captureID: $0)
        }
        screenshotShelfManager.onSave = { [weak self] in
            self?.saveScreenshotShelfItem(captureID: $0)
        }
        screenshotShelfManager.onStateChange = { [weak self] isVisible, hasItems, isEnabled, canToggle in
            self?.isScreenshotShelfVisible = isVisible
            self?.hasScreenshotShelfItems = hasItems
            self?.isScreenshotShelfEnabled = isEnabled
            self?.canToggleScreenshotShelf = canToggle
        }
        screenshotShelfManager.onCacheFailure = { [weak self] message in
            self?.showToast(message: message, type: .error)
        }
        editorWorkspace.onWindowClosed = { [weak self] in
            self?.screenshotShelfManager.endEditingSuppression()
        }
        screenshotShelfManager.publishCurrentState()
    }

    func captureWithoutScreenshotShelf(
        mode: CaptureCore.CaptureMode,
        options: CaptureOptions
    ) async throws -> CaptureResult {
        screenshotShelfManager.beginCaptureSuppression()
        defer { screenshotShelfManager.endCaptureSuppression() }
        return try await captureOrchestrator.capture(mode: mode, options: options)
    }

    private func editScreenshotShelfItem(captureID: UUID) {
        Task { [weak self] in
            guard let self, let image = await loadScreenshotShelfImage(captureID: captureID) else { return }
            let historyID = screenshotShelfManager.historyID(for: captureID)
            let mockupStyle = screenshotShelfManager.card(for: captureID)?.mockupStyle
            if openEditor(
                with: image,
                captureMode: "screenshot-shelf",
                sourceEntryID: historyID,
                mockupStyle: mockupStyle
            ) != nil {
                reportScreenshotShelfFeedback(
                    captureID: captureID,
                    message: .localizedKey("Opened in editor"),
                    type: .success
                )
            }
        }
    }

    private func inspectScreenshotShelfMockup(captureID: UUID) {
        Task { [weak self] in
            guard let self,
                  let image = await loadScreenshotShelfImage(captureID: captureID),
                  let card = screenshotShelfManager.card(for: captureID)
            else { return }

            let presetID = UserDefaults.standard.string(
                forKey: PreferenceKeys.captureMockupPreset
            ) ?? PreferenceDefaults.captureMockupPreset
            let style = card.mockupStyle ?? MockupPolicy.style(for: presetID)
            let historyID = screenshotShelfManager.historyID(for: captureID)

            MockupInspectorPanel.show(
                rawImage: image,
                style: style,
                onStyleChanged: { [weak self] style in
                    self?.screenshotShelfManager.setMockupStyle(style, captureID: captureID)
                },
                onEdit: { [weak self] style in
                    _ = self?.openEditor(
                        with: image,
                        captureMode: "screenshot-shelf",
                        sourceEntryID: historyID,
                        mockupStyle: style
                    )
                }
            )
        }
    }

    private func copyScreenshotShelfItem(captureID: UUID) {
        Task { [weak self] in
            guard let self,
                  let image = await loadScreenshotShelfPresentedImage(captureID: captureID)
            else { return }
            if await writeImageToClipboard(image) {
                reportScreenshotShelfFeedback(
                    captureID: captureID,
                    message: .localizedKey("Screenshot copied to clipboard"),
                    type: .success
                )
            } else {
                reportScreenshotShelfFeedback(
                    captureID: captureID,
                    message: .localizedKey("Unable to copy image"),
                    type: .error
                )
            }
        }
    }

    private func pinScreenshotShelfItem(captureID: UUID) {
        Task { [weak self] in
            guard let self,
                  let image = await loadScreenshotShelfImage(captureID: captureID),
                  let screen = screenshotShelfManager.displayScreen,
                  let card = screenshotShelfManager.card(for: captureID) else { return }
            let displayScale = ScreenshotShelfManager.displayScaleForPinning(
                displayScale: card.displayScale,
                scaleSourcePixelWidth: card.scaleSourcePixelWidth,
                imagePixelWidth: CGFloat(image.width)
            )
            let centeredFrame = PinnedImageGeometry.shelfPinFrame(
                imageSize: CGSize(width: image.width, height: image.height),
                displayScale: displayScale,
                screenFrame: screen.visibleFrame
            )
            PinnedWindowManager.shared.pin(image: image, displayScale: displayScale, pinRect: centeredFrame)
            reportScreenshotShelfFeedback(
                captureID: captureID,
                message: .localizedKey("Screenshot pinned"),
                type: .success
            )
        }
    }

    private func saveScreenshotShelfItem(captureID: UUID) {
        Task { [weak self] in
            guard let self else { return }
            guard let image = await loadScreenshotShelfPresentedImage(captureID: captureID) else {
                reportScreenshotShelfFeedback(
                    captureID: captureID,
                    message: .localizedKey("Unable to load screenshot"),
                    type: .error
                )
                return
            }

            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = Self.screenshotShelfFileName()
            guard panel.runModal() == .OK, let url = panel.url else { return }

            do {
                try await Task.detached(priority: .userInitiated) {
                    try ImageEncoder.write(image, to: url, format: .png)
                }.value
                reportScreenshotShelfFeedback(
                    captureID: captureID,
                    message: .localizedKey("Screenshot saved"),
                    type: .success
                )
            } catch {
                reportScreenshotShelfFeedback(
                    captureID: captureID,
                    message: .localizedKey("Unable to save image"),
                    type: .error
                )
            }
        }
    }

    private static func screenshotShelfFileName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "SnapGlass_\(formatter.string(from: Date())).png"
    }

    private func loadScreenshotShelfPresentedImage(captureID: UUID) async -> CGImage? {
        do {
            guard let data = try await screenshotShelfManager.presentedData(for: captureID),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                return await loadScreenshotShelfImage(captureID: captureID)
            }
            return image
        } catch {
            return await loadScreenshotShelfImage(captureID: captureID)
        }
    }

    private func loadScreenshotShelfImage(captureID: UUID) async -> CGImage? {
        do {
            guard let data = try await screenshotShelfManager.originalData(for: captureID),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                reportScreenshotShelfFeedback(
                    captureID: captureID,
                    message: .localizedKey("Unable to load screenshot"),
                    type: .error
                )
                return nil
            }
            return image
        } catch {
            reportScreenshotShelfFeedback(
                captureID: captureID,
                message: .localizedKey("Unable to load screenshot"),
                type: .error
            )
            return nil
        }
    }

    private func reportScreenshotShelfFeedback(
        captureID: UUID,
        message: ScreenshotShelfMessage,
        type: ToastType
    ) {
        screenshotShelfManager.reportFeedback(
            captureID: captureID,
            message: message,
            isError: type == .error
        )
        showToast(message: message.resolved(using: { AppLocalization.string($0) }), type: type)
    }
}
