import AppKit
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation

@preconcurrency import ScreenCaptureKit
import SharedKit

// MARK: - SCKAdapter

/// ScreenCaptureKit 截图适配器。
///
/// 基于 Apple ScreenCaptureKit 框架实现高性能截图，
/// 使用 `SCStream` 单帧捕获模式，适用于 macOS 13+。
///
/// 遵循 `CaptureProtocol` 协议，实现统一的截图接口。
///
/// ## 捕获策略
/// - macOS 13+: 使用 `SCStream` + 帧输出实现单帧捕获（跨版本兼容）
/// - 全局超时保护（5s），防止截图无响应
/// - 双重权限验证（`CGPreflightScreenCaptureAccess` + `SCShareableContent`）
final class SCKAdapter: CaptureProtocol, @unchecked Sendable {
    private let logger: Logger
    /// 单帧捕获超时时间（毫秒）
    private static let captureTimeoutMs: Int = 5_000

    init(logger: Logger = Logger(category: "sck-adapter")) {
        self.logger = logger
    }

    // MARK: - Settings

    private func openScreenCaptureSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else {
            logger.error("Failed to create system preferences URL")
            return
        }
        logger.debug("Opening system preferences: \(url.absoluteString)")
        NSWorkspace.shared.open(url)
    }

    // MARK: - CaptureProtocol

    func capture(mode: CaptureMode, options: CaptureOptions) async throws -> CaptureResult {
        let content = try await SCShareableContent.current

        guard !content.displays.isEmpty else {
            logger.warning("No display available for capture")
            throw CaptureError.displayUnavailable
        }

        let timestamp = Date()

        switch mode {
        case .fullscreen:
            return try await captureFullscreen(content: content, options: options, timestamp: timestamp)

        case .window(let windowID):
            return try await captureWindow(content: content, windowID: windowID, options: options, timestamp: timestamp)

        case .area(let rect):
            return try await captureArea(content: content, rect: rect, options: options, timestamp: timestamp)

        case .scroll:
            throw CaptureError.captureFailed(reason: "Scroll capture must use ScrollCore, not direct SCKAdapter")
        }
    }

    func availableCaptureModes() async -> [CaptureMode] {
        var modes: [CaptureMode] = [.fullscreen]

        do {
            let content = try await SCShareableContent.current

            if !content.displays.isEmpty {
                for display in content.displays {
                    modes.append(.area(display.frame))
                }
            }

            if !content.windows.isEmpty {
                modes.append(.window(nil))
            }

            modes.append(.scroll)
        } catch {
            logger.warning("Failed to query SCShareableContent: \(error.localizedDescription)")
        }

        return modes
    }

    func requestPermission() async -> Bool {
        logger.info("Requesting screen capture permission (SCK)")

        if #available(macOS 15, *) {
            CGRequestScreenCaptureAccess()
        } else {
            openScreenCaptureSettings()
        }

        // 轮询检查，一旦成功立即返回（最多等待 15 秒）
        for i in 0..<15 {
            try? await Task.sleep(for: .seconds(1))
            let granted = await checkPermissionStatus()
            if granted {
                logger.info("SCK: Permission granted after \(i + 1) seconds")
                return true
            }
        }

        logger.warning("SCK: Permission not granted after 15 seconds")
        return false
    }

    func checkPermissionStatus() async -> Bool {
        let preflight = CGPreflightScreenCaptureAccess()
        logger.info("SCK: CGPreflightScreenCaptureAccess() = \(preflight)")

        do {
            let content = try await SCShareableContent.current
            if !content.displays.isEmpty {
                logger.info("SCK: Permission verified via SCShareableContent (displays: \(content.displays.count))")
                return true
            }
            logger.warning("SCK: SCShareableContent returned empty displays")
        } catch {
            logger.warning("SCK: SCShareableContent failed: \(error.localizedDescription)")
        }

        // 重试一次（macOS 15+ ad-hoc 签名下 CGPreflight 可能返回 false，因此不依赖它）
        logger.info("SCK: Retrying permission check...")
        try? await Task.sleep(for: .milliseconds(500))
        do {
            let content = try await SCShareableContent.current
            if !content.displays.isEmpty {
                logger.info("SCK: Permission verified on retry")
                return true
            }
        } catch {
            logger.warning("SCK: Retry failed: \(error.localizedDescription)")
        }

        return false
    }

    /// Captures a scaled still image suitable for a window-picker preview.
    func captureWindowThumbnail(
        windowID: CGWindowID,
        maximumSize: CGSize
    ) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        )
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.windowNotFound
        }
        guard let display = display(containing: window, from: content.displays) else {
            throw CaptureError.displayUnavailable
        }

        let sourceSize = window.frame.size
        guard sourceSize.width > 0, sourceSize.height > 0,
              maximumSize.width > 0, maximumSize.height > 0 else {
            throw CaptureError.captureFailed(reason: "Invalid window thumbnail size")
        }
        let scale = min(
            maximumSize.width / sourceSize.width,
            maximumSize.height / sourceSize.height,
            1
        )

        let filter = SCContentFilter(display: display, including: [window])
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((sourceSize.width * scale).rounded(.up)))
        configuration.height = max(1, Int((sourceSize.height * scale).rounded(.up)))
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 5)
        configuration.queueDepth = 1

        return try await withThrowingTimeout(ms: Self.captureTimeoutMs) {
            try await SingleFrameCapture.capture(
                with: filter,
                configuration: configuration,
                logger: self.logger
            )
        }
    }
}

// MARK: - Capture Implementations

extension SCKAdapter {
    /// 全屏截图
    private func captureFullscreen(
        content: SCShareableContent,
        options: CaptureOptions,
        timestamp: Date
    ) async throws -> CaptureResult {
        let mainDisplayID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainDisplayID })
                ?? content.displays.first else {
            throw CaptureError.displayUnavailable
        }

        logger.info("Capturing fullscreen on display \(display.displayID)")

        let image = try await captureDisplayImage(display, options: options)
        let displayInfo = displayInfo(for: display)

        return CaptureResult(
            image: image,
            captureMode: .fullscreen,
            timestamp: timestamp,
            displayInfo: displayInfo
        )
    }

    /// 窗口截图
    private func captureWindow(
        content: SCShareableContent,
        windowID: CGWindowID?,
        options: CaptureOptions,
        timestamp: Date
    ) async throws -> CaptureResult {
        guard let targetID = windowID else {
            guard let window = content.windows.first else {
                throw CaptureError.windowNotFound
            }
            return try await captureWindowByID(window.windowID, content: content, options: options, timestamp: timestamp)
        }

        return try await captureWindowByID(targetID, content: content, options: options, timestamp: timestamp)
    }

    /// 按窗口 ID 执行截图
    private func captureWindowByID(
        _ windowID: CGWindowID,
        content: SCShareableContent,
        options: CaptureOptions,
        timestamp: Date
    ) async throws -> CaptureResult {
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.windowNotFound
        }

        logger.info("Capturing window \(windowID)")

        let image = try await captureWindowImage(window, options: options)

        let displayInfo = CaptureDisplayInfo(
            displayID: 0,
            scaleFactor: options.preferredScaleFactor,
            frame: window.frame
        )

        return CaptureResult(
            image: image,
            captureMode: .window(windowID),
            timestamp: timestamp,
            displayInfo: displayInfo
        )
    }

    /// 区域截图
    private func captureArea(
        content: SCShareableContent,
        rect: CGRect?,
        options: CaptureOptions,
        timestamp: Date
    ) async throws -> CaptureResult {
        guard let areaRect = rect else {
            throw CaptureError.invalidRegion
        }

        guard areaRect.width > 0, areaRect.height > 0 else {
            throw CaptureError.invalidRegion
        }

        guard let display = content.displays.first(where: { $0.frame.contains(areaRect) }) else {
            logger.warning("Area spans multiple displays or falls outside available displays: \(areaRect)")
            throw CaptureError.invalidRegion
        }

        logger.info("Capturing area \(areaRect) on display \(display.displayID)")

        let fullImage = try await captureDisplayImage(display, options: options)

        guard let cropRect = Self.pixelCropRect(
            areaRect: areaRect,
            displayFrame: display.frame,
            imageSize: CGSize(width: fullImage.width, height: fullImage.height)
        ) else {
            throw CaptureError.invalidRegion
        }

        guard let croppedImage = fullImage.cropping(to: cropRect) else {
            throw CaptureError.captureFailed(reason: "Failed to crop area from fullscreen capture")
        }

        let displayInfo = displayInfo(for: display)

        return CaptureResult(
            image: croppedImage,
            captureMode: .area(rect),
            timestamp: timestamp,
            displayInfo: displayInfo
        )
    }
}

// MARK: - SCStream Capture Engine

extension SCKAdapter {
    /// 使用 SCStream 捕获显示器的单帧图像
    private func captureDisplayImage(_ display: SCDisplay, options: CaptureOptions) async throws -> CGImage {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let streamConfig = SCStreamConfiguration()
        let scale = Self.outputScale(for: display, options: options)
        streamConfig.width = max(1, Int((display.frame.width * scale).rounded(.up)))
        streamConfig.height = max(1, Int((display.frame.height * scale).rounded(.up)))
        streamConfig.showsCursor = options.includeCursor
        streamConfig.capturesAudio = false

        let image = try await withThrowingTimeout(ms: Self.captureTimeoutMs) {
            try await SingleFrameCapture.capture(with: filter, configuration: streamConfig, logger: self.logger)
        }

        return image
    }

    /// 使用 SCStream 捕获窗口的单帧图像
    private func captureWindowImage(_ window: SCWindow, options: CaptureOptions) async throws -> CGImage {
        let display = window.frame.width > 0 ? await currentDisplay(for: window) : nil
        guard let targetDisplay = display else {
            throw CaptureError.displayUnavailable
        }

        let filter = SCContentFilter(display: targetDisplay, including: [window])
        let streamConfig = SCStreamConfiguration()
        let scale = Self.outputScale(for: targetDisplay, options: options)
        streamConfig.width = max(1, Int((window.frame.width * scale).rounded(.up)))
        streamConfig.height = max(1, Int((window.frame.height * scale).rounded(.up)))
        streamConfig.showsCursor = options.includeCursor
        streamConfig.capturesAudio = false

        let image = try await withThrowingTimeout(ms: Self.captureTimeoutMs) {
            try await SingleFrameCapture.capture(with: filter, configuration: streamConfig, logger: self.logger)
        }

        return image
    }

    /// 获取窗口所在的显示器
    private func currentDisplay(for window: SCWindow) async -> SCDisplay? {
        do {
            let content = try await SCShareableContent.current
            let windowCenter = CGPoint(x: window.frame.midX, y: window.frame.midY)
            return content.displays.first { $0.frame.contains(windowCenter) }
                ?? content.displays.first
        } catch {
            return nil
        }
    }

    private func display(containing window: SCWindow, from displays: [SCDisplay]) -> SCDisplay? {
        let windowCenter = CGPoint(x: window.frame.midX, y: window.frame.midY)
        return displays.first { $0.frame.contains(windowCenter) } ?? displays.first
    }
}

// MARK: - Helpers

extension SCKAdapter {
    static func outputScale(for display: SCDisplay, options: CaptureOptions) -> CGFloat {
        guard options.highResolution else { return 1 }
        let nativeScale = pixelScale(imageWidth: display.width, displayFrame: display.frame)
        let backingScale = NSScreen.screens.first { screen in
            guard let screenNumber = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? UInt32 else {
                return false
            }
            return screenNumber == display.displayID
        }?.backingScaleFactor ?? 1
        return max(1, nativeScale, backingScale)
    }

    static func pixelScale(imageWidth: Int, displayFrame: CGRect) -> CGFloat {
        guard imageWidth > 0, displayFrame.width > 0 else { return 1 }
        return CGFloat(imageWidth) / displayFrame.width
    }

    static func pixelCropRect(
        areaRect: CGRect,
        displayFrame: CGRect,
        imageSize: CGSize
    ) -> CGRect? {
        guard displayFrame.contains(areaRect), imageSize.width > 0, imageSize.height > 0 else {
            return nil
        }

        let scaleX = imageSize.width / displayFrame.width
        let scaleY = imageSize.height / displayFrame.height
        let localX = areaRect.minX - displayFrame.minX
        let localY = areaRect.minY - displayFrame.minY
        let cropRect = CGRect(
            x: localX * scaleX,
            y: localY * scaleY,
            width: areaRect.width * scaleX,
            height: areaRect.height * scaleY
        ).integral
        let imageBounds = CGRect(origin: .zero, size: imageSize)
        let clamped = cropRect.intersection(imageBounds)
        return clamped.isEmpty ? nil : clamped
    }

    /// 从 `SCDisplay` 构造 `CaptureDisplayInfo`
    private func displayInfo(for display: SCDisplay) -> CaptureDisplayInfo {
        let scaleFactor: CGFloat = {
            let screens = NSScreen.screens
            for screen in screens {
                if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32,
                   screenNumber == display.displayID {
                    return screen.backingScaleFactor
                }
            }
            return 2.0
        }()

        return CaptureDisplayInfo(
            displayID: display.displayID,
            scaleFactor: scaleFactor,
            frame: display.frame
        )
    }
}

// MARK: - SingleFrameCaptureSession

/// 生命周期安全的单帧捕获会话。
///
/// 强持有 `SCStream`，确保在成功/失败/超时/取消前不被释放。
/// 所有路径通过统一的清理入口，保证恰好执行一次。
fileprivate final class SingleFrameCaptureSession: @unchecked Sendable {
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
    func setContinuation(_ c: CheckedContinuation<CGImage, any Error>) {
        lock.withLock { continuation = c }
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
fileprivate final class StreamOutputAdaptor: NSObject, SCStreamOutput, @unchecked Sendable {
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

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
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

// MARK: - Timeout Helper

/// 为异步操作添加超时保护。
///
/// 在指定毫秒数后如果操作未完成，自动抛出超时错误。
/// 用于保护 SCStream 免于长时间无响应。
private func withThrowingTimeout<T: Sendable>(ms: Int, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            let nanoseconds = UInt64(ms) * 1_000_000
            try await Task.sleep(nanoseconds: nanoseconds)
            throw CaptureError.captureFailed(reason: "SCStream capture timed out after \(ms)ms")
        }

        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
