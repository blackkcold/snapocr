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

            // 边采边拼：首帧直接进画布，之后每帧追加完就释放。
            try await scrollEngine.beginIncrementalStitch(
                firstFrame: ScrollFrame(image: result.image, index: 0, timestamp: result.timestamp)
            )

            scrollSession = session
            scrollSourceAppName = selectedWindow.appName
            scrollSourceWindowTitle = selectedWindow.windowTitle
            scrollCapturedFrameCount = 1
            scrollReachedSizeLimit = false
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
        scrollCaptureTask?.cancel()
        let task = Task {
            guard !isCapturing,
                  let session = scrollSession,
                  scrollCapturedFrameCount >= 1 else { return }
            isCapturing = true
            defer { isCapturing = false }

            do {
                let result = try await captureOrchestrator.capture(
                    mode: .window(session.windowID),
                    options: Self.currentCaptureOptions()
                )

                // 取消或已经换成别的会话时，这张迟到的帧不能进画布。
                guard !Task.isCancelled, scrollSession?.id == session.id else { return }

                // 去重与重叠探测都在引擎 actor 里做，主线程不接触 5K 像素。
                switch try await scrollEngine.appendIncrementalFrame(result.image) {
                case .appended(let frameCount):
                    guard !Task.isCancelled, scrollSession?.id == session.id else { return }
                    scrollCapturedFrameCount = frameCount
                    showToast(
                        message: AppLocalization.string("Frame %lld captured", frameCount),
                        type: .success
                    )
                case .duplicate:
                    showToast(
                        message: AppLocalization.string("No visual change detected; scroll and try again"),
                        type: .info
                    )
                case .limitReached:
                    if !scrollReachedSizeLimit {
                        scrollReachedSizeLimit = true
                        showToast(
                            message: AppLocalization.string(
                                "Scrolling capture reached the size limit; finish to keep what has been captured"
                            ),
                            type: .info
                        )
                    }
                case .sizeChanged:
                    if !scrollReachedSizeLimit {
                        scrollReachedSizeLimit = true
                        showToast(
                            message: AppLocalization.string(
                                "The window size changed; finish to keep what has been captured"
                            ),
                            type: .info
                        )
                    }
                }
            } catch CaptureError.permissionDenied {
                openWindow?("permission")
            } catch {
                showToast(
                    message: AppLocalization.string("Scroll frame failed: %@", error.localizedDescription),
                    type: .error
                )
            }
        }
        scrollCaptureTask = task
    }

    /// Finishes the active scrolling capture and sends the long image through the normal capture flow.
    public func finishScrollCapture() {
        Task {
            guard !isCapturing, scrollCapturedFrameCount >= 2, let session = scrollSession else { return }
            isCapturing = true
            defer { isCapturing = false }

            do {
                let result = try await scrollEngine.finishIncrementalStitch()
                // 完成期间被取消/重开：结果属于已经结束的会话，直接丢掉。
                guard scrollSession?.id == session.id else { return }
                let sourceAppName = scrollSourceAppName
                let sourceWindowTitle = scrollSourceWindowTitle
                resetScrollCaptureState()
                await processCapturedImage(
                    result.image,
                    captureMode: .scroll,
                    sourceAppName: sourceAppName,
                    sourceWindowTitle: sourceWindowTitle,
                    destination: .editorOnly
                )
                if result.isTruncated {
                    let limitMessage = AppLocalization.string(
                        "Long screenshot reached the size limit; the captured part was kept"
                    )
                    showToast(message: limitMessage, type: .info)
                }
            } catch {
                // 拼接失败（例如输出画布分配不出来）必须让会话退出，否则用户会卡在
                // 「进行中」但每一帧都报「会话已失效」的死状态，已采集内容也拿不回来。
                resetScrollCaptureState()
                await scrollEngine.cancelCapture(session: session)
                showToast(message: error.localizedDescription, type: .error)
            }
        }
    }

    /// Cancels the active scrolling capture and releases its buffered frames.
    public func cancelScrollCapture() {
        scrollCaptureTask?.cancel()
        scrollCaptureTask = nil
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
