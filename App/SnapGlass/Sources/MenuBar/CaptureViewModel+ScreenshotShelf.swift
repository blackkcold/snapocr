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
                    message: AppLocalization.string("Opened in editor"),
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
                    message: AppLocalization.string("Screenshot copied to clipboard"),
                    type: .success
                )
            } else {
                reportScreenshotShelfFeedback(
                    captureID: captureID,
                    message: AppLocalization.string("Unable to copy image"),
                    type: .error
                )
            }
        }
    }

    private func pinScreenshotShelfItem(captureID: UUID) {
        Task { [weak self] in
            guard let self,
                  let image = await loadScreenshotShelfImage(captureID: captureID),
                  let screen = screenshotShelfManager.displayScreen else { return }
            let screenFrame = screen.visibleFrame
            let fittedFrame = PinnedImageGeometry.fitToScreen(
                CGRect(origin: .zero, size: CGSize(width: image.width, height: image.height)),
                screenFrame: screenFrame
            )
            let centeredFrame = CGRect(
                x: screenFrame.midX - fittedFrame.width / 2,
                y: screenFrame.midY - fittedFrame.height / 2,
                width: fittedFrame.width,
                height: fittedFrame.height
            )
            PinnedWindowManager.shared.pin(image: image, displayScale: 1, pinRect: centeredFrame)
            reportScreenshotShelfFeedback(
                captureID: captureID,
                message: AppLocalization.string("Screenshot pinned"),
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
                    message: AppLocalization.string("Unable to load screenshot"),
                    type: .error
                )
                return nil
            }
            return image
        } catch {
            reportScreenshotShelfFeedback(
                captureID: captureID,
                message: AppLocalization.string("Unable to load screenshot"),
                type: .error
            )
            return nil
        }
    }

    private func reportScreenshotShelfFeedback(captureID: UUID, message: String, type: ToastType) {
        screenshotShelfManager.reportFeedback(
            captureID: captureID,
            message: message,
            isError: type == .error
        )
        showToast(message: message, type: type)
    }
}
