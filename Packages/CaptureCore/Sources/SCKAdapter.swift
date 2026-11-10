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

    /// A captured window image plus the metadata the rest of the pipeline needs
    /// to keep shelf placement and pin geometry honest.
    private struct WindowCaptureOutcome {
        let image: CGImage
        let displayInfo: CaptureDisplayInfo
    }

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

    public func checkPermissionStatus() async -> Bool {
        // Share the short-lived success cache with the rest of the capture
        // pipeline instead of enumerating SCShareableContent a second time.
        await PermissionService(logger: logger).checkScreenCapturePermission()
    }

    // swiftlint:disable function_body_length
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
        guard maximumSize.width > 0, maximumSize.height > 0 else {
            throw CaptureError.captureFailed(reason: "Invalid window thumbnail size")
        }

        if #available(macOS 14.0, *) {
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let contentRect = filter.contentRect
            guard contentRect.width > 0, contentRect.height > 0 else {
                throw CaptureError.captureFailed(reason: "Window has no capturable content")
            }

            let nativeScale = max(CGFloat(filter.pointPixelScale), 1)
            let maximumPixelSize = CGSize(
                width: maximumSize.width * min(nativeScale, 2),
                height: maximumSize.height * min(nativeScale, 2)
            )
            let outputSize = Self.thumbnailOutputSize(
                contentPixelSize: CGSize(
                    width: contentRect.width * nativeScale,
                    height: contentRect.height * nativeScale
                ),
                maximumPixelSize: maximumPixelSize
            )

            let configuration = SCStreamConfiguration()
            configuration.width = max(1, Int(outputSize.width))
            configuration.height = max(1, Int(outputSize.height))
            configuration.scalesToFit = false
            configuration.preservesAspectRatio = true
            configuration.captureResolution = .best
            configuration.ignoreShadowsSingleWindow = true
            configuration.shouldBeOpaque = false
            configuration.showsCursor = false
            configuration.capturesAudio = false

            return try await captureStillImage(filter: filter, configuration: configuration)
        }

        let plan = WindowCapturePlan.make(
            windowID: window.windowID,
            windowFrame: window.frame,
            displays: resolvedContent.displays.map(Self.captureDisplay),
            usesDesktopIndependentWindow: false
        )
        guard let plan else { throw CaptureError.displayUnavailable }

        let maximumPixelSize = CGSize(
            width: maximumSize.width * min(max(plan.pointPixelScale, 1), 2),
            height: maximumSize.height * min(max(plan.pointPixelScale, 1), 2)
        )
        let displayByID = Dictionary(
            uniqueKeysWithValues: resolvedContent.displays.map { ($0.displayID, $0) }
        )

        if plan.strategy == .displaySegments {
            let thumbnailPlan = plan.scaledForThumbnail(maxPixelSize: maximumPixelSize)
            var slices: [(segment: WindowCaptureSegment, image: CGImage)] = []
            slices.reserveCapacity(thumbnailPlan.segments.count)
            for segment in thumbnailPlan.segments {
                guard let display = displayByID[segment.displayID] else {
                    throw CaptureError.displayUnavailable
                }
                let image = try await captureWindowSegment(
                    window,
                    display: display,
                    segment: segment
                )
                slices.append((segment, image))
            }
            return try compositeWindowSlices(slices, plan: thumbnailPlan)
        }

        guard let segment = plan.segments.first,
              let display = displayByID[segment.displayID]
        else {
            throw CaptureError.displayUnavailable
        }
        let outputSize = Self.thumbnailOutputSize(
            contentPixelSize: CGSize(
                width: segment.visibleRect.width * segment.pixelScale,
                height: segment.visibleRect.height * segment.pixelScale
            ),
            maximumPixelSize: maximumPixelSize
        )

        let filter = SCContentFilter(display: display, including: [window])
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = segment.sourceRect
        configuration.width = max(1, Int(outputSize.width))
        configuration.height = max(1, Int(outputSize.height))
        configuration.scalesToFit = false
        configuration.showsCursor = false
        configuration.capturesAudio = false

        return try await captureStillImage(filter: filter, configuration: configuration)
    }

    // swiftlint:enable function_body_length

    /// Captures one still frame with the fastest engine available on this OS.
    ///
    /// macOS 14+ uses `SCScreenshotManager`, which produces a still image without
    /// creating, starting and stopping an `SCStream` for every capture. macOS 13
    /// keeps the single-frame `SCStream` path.
    private func captureStillImage(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) async throws -> CGImage {
        try await withThrowingTimeout(
            milliseconds: Self.captureTimeoutMs,
            timeoutError: {
                CaptureError.captureFailed(reason: "Screen capture timed out")
            },
            operation: {
                if #available(macOS 14.0, *) {
                    return try await SCScreenshotManager.captureImage(
                        contentFilter: filter,
                        configuration: configuration
                    )
                }
                return try await SingleFrameCapture.capture(
                    with: filter,
                    configuration: configuration,
                    logger: self.logger
                )
            }
        )
    }

    /// Aspect-fits a thumbnail into a pixel box without ever upscaling.
    ///
    /// ScreenCaptureKit's GPU pipeline performs the actual downscale; keeping the
    /// arithmetic here makes the cap testable and prevents the old `×3` margin
    /// from silently making previews larger than the row that displays them.
    static func thumbnailOutputSize(
        contentPixelSize: CGSize,
        maximumPixelSize: CGSize
    ) -> CGSize {
        guard contentPixelSize.width > 0, contentPixelSize.height > 0,
              maximumPixelSize.width > 0, maximumPixelSize.height > 0
        else { return .zero }

        let scale = min(
            maximumPixelSize.width / contentPixelSize.width,
            maximumPixelSize.height / contentPixelSize.height,
            1
        )
        return CGSize(
            width: max(1, (contentPixelSize.width * scale).rounded()),
            height: max(1, (contentPixelSize.height * scale).rounded())
        )
    }

    static func captureDisplay(_ display: SCDisplay) -> WindowCaptureDisplay {
        let scale = nativeScale(for: display)
        return WindowCaptureDisplay(
            displayID: display.displayID,
            frame: display.frame,
            pixelSize: CGSize(
                width: display.frame.width * scale,
                height: display.frame.height * scale
            )
        )
    }

    /// `SCDisplay.width/height` are points, not backing pixels. Use the
    /// matching `NSScreen` for the real Retina scale and only fall back to 1x.
    static func nativeScale(for display: SCDisplay) -> CGFloat {
        if let screen = NSScreen.screens.first(where: { screen in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? UInt32 else { return false }
            return number == display.displayID
        }) {
            return max(1, screen.backingScaleFactor)
        }
        return 1
    }
}

extension SCKAdapter {
    /// Captures one display for the all-display canvas composer.
    func captureDisplay(_ display: SCDisplay, options: CaptureOptions) async throws -> CGImage {
        try await captureDisplayImage(display, options: options)
    }

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

        let outcome = try await captureWindowImage(
            window,
            displays: content.displays,
            options: options
        )

        return CaptureResult(
            image: outcome.image,
            captureMode: .window(windowID),
            timestamp: timestamp,
            displayInfo: outcome.displayInfo
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

        let image = try await captureStillImage(filter: filter, configuration: streamConfig)

        return image
    }

    /// Captures a window without ever mixing display and window coordinate spaces.
    ///
    /// macOS 14+ asks ScreenCaptureKit for the window's own content rect and pixel
    /// scale. macOS 13 uses one `sourceRect` slice per display and composites only
    /// when the window actually spans displays. No path crops the result again.
    private func captureWindowImage(
        _ window: SCWindow,
        displays: [SCDisplay],
        options: CaptureOptions
    ) async throws -> WindowCaptureOutcome {
        let descriptors = displays.map(Self.captureDisplay)

        if #available(macOS 14.0, *) {
            return try await captureDesktopIndependentWindow(
                window,
                displays: displays,
                descriptors: descriptors,
                options: options
            )
        }

        return try await captureDisplaySegmentedWindow(
            window,
            displays: displays,
            descriptors: descriptors,
            options: options
        )
    }

    @available(macOS 14.0, *)
    private func captureDesktopIndependentWindow(
        _ window: SCWindow,
        displays: [SCDisplay],
        descriptors: [WindowCaptureDisplay],
        options: CaptureOptions
    ) async throws -> WindowCaptureOutcome {
        let plan = WindowCapturePlan.make(
            windowID: window.windowID,
            windowFrame: window.frame,
            displays: descriptors,
            usesDesktopIndependentWindow: true,
            highResolution: options.highResolution
        )
        guard let plan else { throw CaptureError.displayUnavailable }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let contentRect = filter.contentRect
        guard contentRect.width > 0, contentRect.height > 0 else {
            throw CaptureError.captureFailed(reason: "Window has no capturable content")
        }

        let pointScale = options.highResolution
            ? max(CGFloat(filter.pointPixelScale), 1)
            : 1
        let expectedSize = WindowCapturePlan.desktopIndependentOutputSize(
            contentRect: contentRect,
            pointPixelScale: pointScale
        )

        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(expectedSize.width))
        configuration.height = max(1, Int(expectedSize.height))
        configuration.scalesToFit = false
        configuration.preservesAspectRatio = true
        configuration.captureResolution = .best
        configuration.ignoreShadowsSingleWindow = true
        configuration.ignoreGlobalClipSingleWindow = true
        configuration.shouldBeOpaque = false
        configuration.showsCursor = options.includeCursor
        configuration.capturesAudio = false

        let image = try await captureStillImage(filter: filter, configuration: configuration)
        if abs(image.width - Int(expectedSize.width)) > 2
            || abs(image.height - Int(expectedSize.height)) > 2 {
            logger.warning(
                "Window \(window.windowID) produced \(image.width)x\(image.height), "
                    + "expected \(Int(expectedSize.width))x\(Int(expectedSize.height))"
            )
        }

        let displayInfo = CaptureDisplayInfo(
            displayID: plan.displayID ?? 0,
            scaleFactor: pointScale,
            frame: plan.displayFrame ?? window.frame,
            pointWidth: contentRect.width
        )
        return WindowCaptureOutcome(image: image, displayInfo: displayInfo)
    }

    private func captureDisplaySegmentedWindow(
        _ window: SCWindow,
        displays: [SCDisplay],
        descriptors: [WindowCaptureDisplay],
        options: CaptureOptions
    ) async throws -> WindowCaptureOutcome {
        guard let plan = WindowCapturePlan.make(
            windowID: window.windowID,
            windowFrame: window.frame,
            displays: descriptors,
            usesDesktopIndependentWindow: false,
            highResolution: options.highResolution
        ) else {
            throw CaptureError.displayUnavailable
        }

        let displayByID = Dictionary(
            uniqueKeysWithValues: displays.map { ($0.displayID, $0) }
        )

        guard let firstSegment = plan.segments.first else {
            throw CaptureError.captureFailed(reason: "Window has no visible display slice")
        }

        if plan.strategy == .singleDisplaySourceRect {
            guard let display = displayByID[firstSegment.displayID] else {
                throw CaptureError.displayUnavailable
            }
            let image = try await captureWindowSegment(
                window,
                display: display,
                segment: firstSegment
            )
            let displayInfo = CaptureDisplayInfo(
                displayID: firstSegment.displayID,
                scaleFactor: firstSegment.pixelScale,
                frame: firstSegment.displayFrame,
                pointWidth: firstSegment.visibleRect.width
            )
            return WindowCaptureOutcome(image: image, displayInfo: displayInfo)
        }

        var slices: [(segment: WindowCaptureSegment, image: CGImage)] = []
        slices.reserveCapacity(plan.segments.count)
        for segment in plan.segments {
            guard let display = displayByID[segment.displayID] else {
                throw CaptureError.displayUnavailable
            }
            do {
                let image = try await captureWindowSegment(
                    window,
                    display: display,
                    segment: segment
                )
                slices.append((segment, image))
            } catch {
                throw CaptureError.captureFailed(
                    reason: "Display \(segment.displayID) slice failed: \(error.localizedDescription)"
                )
            }
        }

        let image = try compositeWindowSlices(slices, plan: plan)
        let displayInfo = CaptureDisplayInfo(
            displayID: plan.displayID ?? firstSegment.displayID,
            scaleFactor: plan.pointPixelScale,
            frame: plan.displayFrame ?? firstSegment.displayFrame,
            pointWidth: plan.contentRect.width
        )
        logger.info(
            "Stitched window \(window.windowID) from \(slices.count) display slices "
                + "at \(image.width)x\(image.height)"
        )
        return WindowCaptureOutcome(image: image, displayInfo: displayInfo)
    }

    private func captureWindowSegment(
        _ window: SCWindow,
        display: SCDisplay,
        segment: WindowCaptureSegment
    ) async throws -> CGImage {
        let filter = SCContentFilter(display: display, including: [window])
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = segment.sourceRect
        configuration.width = max(1, Int(segment.capturePixelSize.width))
        configuration.height = max(1, Int(segment.capturePixelSize.height))
        configuration.scalesToFit = false
        configuration.showsCursor = false
        configuration.capturesAudio = false
        return try await captureStillImage(filter: filter, configuration: configuration)
    }

    private func compositeWindowSlices(
        _ slices: [(segment: WindowCaptureSegment, image: CGImage)],
        plan: WindowCapturePlan
    ) throws -> CGImage {
        let width = max(1, Int(plan.outputPixelSize.width))
        let height = max(1, Int(plan.outputPixelSize.height))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            throw CaptureError.captureFailed(reason: "Unable to create window stitch canvas")
        }

        context.interpolationQuality = .high
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        for slice in slices {
            let segment = slice.segment
            let destination = CGRect(
                x: segment.outputOrigin.x,
                y: CGFloat(height) - segment.outputOrigin.y - segment.outputPixelSize.height,
                width: segment.outputPixelSize.width,
                height: segment.outputPixelSize.height
            )
            context.draw(slice.image, in: destination)
        }

        guard let image = context.makeImage() else {
            throw CaptureError.captureFailed(reason: "Unable to render stitched window")
        }
        return image
    }
}
