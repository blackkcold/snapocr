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
        for attempt in 0..<15 {
            try? await Task.sleep(for: .seconds(1))
            let granted = await checkPermissionStatus()
            if granted {
                logger.info("SCK: Permission granted after \(attempt + 1) seconds")
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
    ///
    /// When `content` is provided it is reused, avoiding a second
    /// `SCShareableContent` enumeration per thumbnail.
    func captureWindowThumbnail(
        windowID: CGWindowID,
        maximumSize: CGSize,
        content: SCShareableContent? = nil
    ) async throws -> CGImage {
        let resolvedContent: SCShareableContent
        if let content {
            resolvedContent = content
        } else {
            resolvedContent = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            )
        }

        guard let window = resolvedContent.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.windowNotFound
        }
        guard let display = display(containing: window, from: resolvedContent.displays) else {
            throw CaptureError.displayUnavailable
        }

        let pointSize = window.frame.size
        guard pointSize.width > 0, pointSize.height > 0,
              maximumSize.width > 0, maximumSize.height > 0 else {
            throw CaptureError.captureFailed(reason: "Invalid window thumbnail size")
        }

        let outputSize = thumbnailOutputSize(
            pointSize: pointSize,
            maximumSize: maximumSize,
            display: display
        )

        let filter = SCContentFilter(display: display, including: [window])
        let configuration = SCStreamConfiguration()
        configuration.width = outputSize.width
        configuration.height = outputSize.height
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 5)
        configuration.queueDepth = 1

        return try await withThrowingTimeout(
            milliseconds: Self.captureTimeoutMs,
            timeoutError: {
                CaptureError.captureFailed(reason: "SCStream capture timed out")
            },
            operation: {
                try await SingleFrameCapture.capture(
                    with: filter,
                    configuration: configuration,
                    logger: self.logger
                )
            }
        )
    }

    /// 计算缩略图的物理像素输出尺寸，让 ScreenCaptureKit 的 GPU 管线缩放。
    private func thumbnailOutputSize(
        pointSize: CGSize,
        maximumSize: CGSize,
        display: SCDisplay
    ) -> (width: Int, height: Int) {
        // Compute the output size in *physical* pixels so thumbnails stay sharp on
        // Retina displays, then let ScreenCaptureKit's GPU pipeline scale down the
        // streamed frame (faster and higher quality than a CPU resize).
        let backing = Self.pixelScale(imageWidth: display.width, displayFrame: display.frame)
        let pixelSize = CGSize(
            width: pointSize.width * backing,
            height: pointSize.height * backing
        )
        let scale = min(
            maximumSize.width / pointSize.width,
            maximumSize.height / pointSize.height,
            1
        )

        // Cap the physical output to avoid allocating huge buffers for very large
        // windows (e.g. 4K+). 640pt max is plenty for an ~84pt table row.
        let cappedMaxWidth = max(1, Int((maximumSize.width * backing).rounded(.up)))
        let cappedMaxHeight = max(1, Int((maximumSize.height * backing).rounded(.up)))
        let outputWidth = min(
            max(1, Int((pixelSize.width * scale).rounded(.up))),
            cappedMaxWidth * 3
        )
        let outputHeight = min(
            max(1, Int((pixelSize.height * scale).rounded(.up))),
            cappedMaxHeight * 3
        )
        return (outputWidth, outputHeight)
    }
}

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
            return try await captureWindowByID(
                window.windowID,
                content: content,
                options: options,
                timestamp: timestamp
            )
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

        let image = try await withThrowingTimeout(
            milliseconds: Self.captureTimeoutMs,
            timeoutError: {
                CaptureError.captureFailed(reason: "SCStream capture timed out")
            },
            operation: {
                try await SingleFrameCapture.capture(with: filter, configuration: streamConfig, logger: self.logger)
            }
        )

        return image
    }

    /// 使用 SCStream 捕获窗口的单帧图像。
    ///
    /// `SCContentFilter(display:including:)` streams the entire display region, so the
    /// raw frame is full-screen with the surrounding desktop rendered black. Crop the
    /// output to the window's visible bounds (frame ∩ display) so the result is a clean
    /// high-resolution window image, handling partially-offscreen windows gracefully.
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

        let image = try await withThrowingTimeout(
            milliseconds: Self.captureTimeoutMs,
            timeoutError: {
                CaptureError.captureFailed(reason: "SCStream capture timed out")
            },
            operation: {
                try await SingleFrameCapture.capture(with: filter, configuration: streamConfig, logger: self.logger)
            }
        )

        let visibleBounds = window.frame.intersection(targetDisplay.frame)
        guard !visibleBounds.isEmpty else {
            logger.warning("Window \(window.windowID) has no visible bounds on its display; returning uncropped frame")
            return image
        }

        let windowCrop = Self.pixelCropRect(
            areaRect: visibleBounds,
            displayFrame: targetDisplay.frame,
            imageSize: CGSize(width: image.width, height: image.height)
        )

        guard let windowCrop, let cropped = image.cropping(to: windowCrop) else {
            logger.warning("Window \(window.windowID): crop computation failed, returning uncropped frame")
            return image
        }

        return cropped
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
