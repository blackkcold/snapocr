import AppKit
import CaptureCore
import ScrollCore
import SharedKit
import SwiftUI

// MARK: - CaptureViewModel Scroll Capture

extension CaptureViewModel {
    public func startScrollCapture() {
        captureWindow()
    }

    func beginScrollCapture(with selectedWindow: WindowSelectionResult) async {
        var startedSession: ScrollSession?
        do {
            let session = try await scrollEngine.startCapture(windowID: selectedWindow.windowID)
            startedSession = session
            let result = try await captureOrchestrator.capture(
                mode: .window(selectedWindow.windowID),
                options: Self.currentCaptureOptions()
            )

            scrollSession = session
            scrollFrames = [ScrollFrame(image: result.image, index: 0, timestamp: result.timestamp)]
            scrollSourceAppName = selectedWindow.appName
            scrollSourceWindowTitle = selectedWindow.windowTitle
            scrollCapturedFrameCount = 1
            isScrollCaptureActive = true
            showToast(message: AppLocalization.string("Scroll the window, then capture the next frame"), type: .info)
        } catch CaptureError.permissionDenied {
            if let startedSession {
                await scrollEngine.cancelCapture(session: startedSession)
            }
            openWindow?("permission")
        } catch {
            if let startedSession {
                await scrollEngine.cancelCapture(session: startedSession)
            }
            resetScrollCaptureState()
            showToast(message: error.localizedDescription, type: .error)
        }
    }

    /// Captures another frame after the user has manually scrolled the target window.
    public func captureNextScrollFrame() {
        Task {
            guard !isCapturing,
                  let session = scrollSession,
                  let previousFrame = scrollFrames.last else { return }
            isCapturing = true
            defer { isCapturing = false }

            do {
                let result = try await captureOrchestrator.capture(
                    mode: .window(session.windowID),
                    options: Self.currentCaptureOptions()
                )
                let isDuplicate = await Task.detached(priority: .userInitiated) {
                    FrameDeduper().isDuplicate(previousFrame.image, result.image)
                }.value
                guard !isDuplicate else {
                    showToast(
                        message: AppLocalization.string("No visual change detected; scroll and try again"),
                        type: .info
                    )
                    return
                }

                scrollFrames.append(ScrollFrame(
                    image: result.image,
                    index: scrollFrames.count,
                    timestamp: result.timestamp
                ))
                scrollCapturedFrameCount = scrollFrames.count
                showToast(
                    message: AppLocalization.string("Frame %d captured", scrollCapturedFrameCount),
                    type: .success
                )
            } catch CaptureError.permissionDenied {
                openWindow?("permission")
            } catch {
                showToast(
                    message: AppLocalization.string("Scroll frame failed: %@", error.localizedDescription),
                    type: .error
                )
            }
        }
    }

    /// Finishes the active scrolling capture and sends the long image through the normal capture flow.
    public func finishScrollCapture() {
        Task {
            guard !isCapturing, scrollFrames.count >= 2 else { return }
            isCapturing = true
            defer { isCapturing = false }

            do {
                let image = try await scrollEngine.stitchFrames(scrollFrames)
                let sourceAppName = scrollSourceAppName
                let sourceWindowTitle = scrollSourceWindowTitle
                resetScrollCaptureState()
                await processCapturedImage(
                    image,
                    captureMode: .scroll,
                    sourceAppName: sourceAppName,
                    sourceWindowTitle: sourceWindowTitle,
                    destination: .editorOnly
                )
            } catch {
                showToast(message: error.localizedDescription, type: .error)
            }
        }
    }

    /// Cancels the active scrolling capture and releases its buffered frames.
    public func cancelScrollCapture() {
        let session = scrollSession
        resetScrollCaptureState()
        Task {
            if let session {
                await scrollEngine.cancelCapture(session: session)
            }
        }
        showToast(message: AppLocalization.string("Scrolling capture cancelled"), type: .info)
    }
}
