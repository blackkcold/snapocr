import AppKit
import CaptureCore
import ImageIO
import SharedKit

extension CaptureViewModel {
    /// Toggles the recent screenshot shelf when it can be shown.
    public func toggleScreenshotShelf() {
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
        screenshotShelfManager.onCopy = { [weak self] in
            self?.copyScreenshotShelfItem(captureID: $0)
        }
        screenshotShelfManager.onPin = { [weak self] in
            self?.pinScreenshotShelfItem(captureID: $0)
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
            if openEditor(with: image, captureMode: "screenshot-shelf", sourceEntryID: historyID) != nil {
                reportScreenshotShelfFeedback(
                    captureID: captureID,
                    message: .localizedKey("Opened in editor"),
                    type: .success
                )
            }
        }
    }

    private func copyScreenshotShelfItem(captureID: UUID) {
        Task { [weak self] in
            guard let self, let image = await loadScreenshotShelfImage(captureID: captureID) else { return }
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
