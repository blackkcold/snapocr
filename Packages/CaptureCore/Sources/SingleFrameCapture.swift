import CoreImage
import CoreMedia
import Foundation
import ScreenCaptureKit
import SharedKit

// MARK: - SingleFrameCaptureSession

/// 生命周期安全的单帧捕获会话。
///
/// 强持有 `SCStream`，确保在成功/失败/超时/取消前不被释放。
/// 所有路径通过统一的清理入口，保证恰好执行一次。
private final class SingleFrameCaptureSession: @unchecked Sendable {
    private let stream: SCStream
    private var outputAdaptor: StreamOutputAdaptor?
    private var continuation: CheckedContinuation<CGImage, any Error>?
    private let lock = NSLock()
    private var didFinish = false
    private let logger: Logger

    init(stream: SCStream, logger: Logger) {
        self.stream = stream
        self.logger = logger
    }

    /// 设置 continuation（在 `withCheckedThrowingContinuation` 闭包内调用）
    func setContinuation(_ continuation: CheckedContinuation<CGImage, any Error>) {
        lock.withLock { self.continuation = continuation }
    }

    /// Strongly retain the output adaptor for the lifetime of the capture session.
    func retainOutputAdaptor(_ adaptor: StreamOutputAdaptor) {
        lock.withLock { outputAdaptor = adaptor }
    }

    /// 以错误结束会话：停止流、恢复 continuation（仅首次生效）
    func finish(throwing error: any Error) {
        cleanupAndResume { $0?.resume(throwing: error) }
    }

    /// 以成功结束会话：停止流、恢复 continuation（仅首次生效）
    func finish(returning image: CGImage) {
        cleanupAndResume { $0?.resume(returning: image) }
    }

    private func cleanupAndResume(_ resume: (CheckedContinuation<CGImage, any Error>?) -> Void) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        let cont = continuation
        continuation = nil
        outputAdaptor = nil
        lock.unlock()

        stream.stopCapture { [logger] error in
            if let error {
                logger.warning("SCStream stopCapture error: \(error.localizedDescription)")
            } else {
                logger.debug("SCStream stopped after frame capture")
            }
        }

        resume(cont)
    }
}

// MARK: - SingleFrameCapture

/// SCStream 单帧捕获辅助工具。
///
/// 内部管理 `SCStream` 的生命周期，接收一帧画面后立即停止流。
/// 通过 `CheckedContinuation` 桥接 SCStreamOutput 的回调到 async/await。
enum SingleFrameCapture {
    private static let outputQueue = DispatchQueue(
        label: "com.snapglass.capture.single-frame",
        qos: .userInitiated
    )

    /// 使用给定的 filter 和 configuration 捕获单帧图像
    static func capture(
        with filter: SCContentFilter,
        configuration: SCStreamConfiguration,
        logger: Logger
    ) async throws -> CGImage {
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        let session = SingleFrameCaptureSession(stream: stream, logger: logger)
        let adaptor = StreamOutputAdaptor(session: session, logger: logger)
        session.retainOutputAdaptor(adaptor)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                session.setContinuation(continuation)

                do {
                    try stream.addStreamOutput(adaptor, type: .screen, sampleHandlerQueue: outputQueue)
                    stream.startCapture { [session, logger] error in
                        if let error {
                            logger.error("SCStream startCapture failed", error: error)
                            session.finish(throwing: CaptureError.captureFailed(
                                reason: "SCStream startCapture: \(error.localizedDescription)"
                            ))
                        } else {
                            logger.debug("SCStream started successfully")
                        }
                    }
                } catch {
                    logger.error("SCStream setup failed", error: error)
                    session.finish(throwing: CaptureError.captureFailed(
                        reason: "SCStream setup: \(error.localizedDescription)"
                    ))
                }
            }
        } onCancel: {
            session.finish(throwing: CaptureError.captureFailed(reason: "Capture cancelled"))
        }
    }
}

// MARK: - StreamOutputAdaptor

/// SCStream 输出适配器。
///
/// 接收 `SCStreamOutput` 的帧回调，将 `CMSampleBuffer` 转换为 `CGImage`。
/// 设计为一次性使用——收到第一帧后立即停止流并恢复 continuation。
private final class StreamOutputAdaptor: NSObject, SCStreamOutput, @unchecked Sendable {
    private static let imageContext = CIContext(options: [.workingColorSpace: NSNull()])

    private let session: SingleFrameCaptureSession
    private let logger: Logger
    private let lock = NSLock()
    nonisolated(unsafe) fileprivate var didDeliverResult = false

    fileprivate init(
        session: SingleFrameCaptureSession,
        logger: Logger
    ) {
        self.session = session
        self.logger = logger
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen else { return }

        lock.lock()
        guard !didDeliverResult else {
            lock.unlock()
            return
        }
        didDeliverResult = true
        lock.unlock()

        guard let imageBuffer = sampleBuffer.imageBuffer else {
            logger.error("Received nil imageBuffer from SCStream")
            session.finish(throwing: CaptureError.captureFailed(reason: "SCStream received nil pixel buffer"))
            return
        }

        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        guard let cgImage = Self.imageContext.createCGImage(ciImage, from: ciImage.extent) else {
            logger.error("Failed to convert CIImage to CGImage")
            session.finish(throwing: CaptureError.captureFailed(reason: "Failed to convert SCStream frame to CGImage"))
            return
        }

        logger.info("SCStream captured frame: \(cgImage.width)x\(cgImage.height)")
        session.finish(returning: cgImage)
    }
}
