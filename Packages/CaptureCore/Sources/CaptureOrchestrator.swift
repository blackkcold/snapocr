import AppKit
import Foundation

@preconcurrency import ScreenCaptureKit
import SharedKit

// MARK: - CaptureOrchestrator

/// 截图捕获编排器。
///
/// 协调 `SCKAdapter`（ScreenCaptureKit 主路径）和
/// `CGCompatAdapter`（CG 兼容降级路径）之间的截图请求分发。
/// 对外提供统一的截图入口，自动选择最优适配器并处理降级逻辑。
///
/// ## 捕获流程
/// 1. 权限检查 — 通过 `PermissionService` 双重验证屏幕录制权限
/// 2. 主路径 — 优先使用 `SCKAdapter` 进行截图
/// 3. 降级路径 — `SCKAdapter` 失败时自动回退到 `CGCompatAdapter`
/// 4. 结果返回 — 统一返回 `CaptureResult`，上层无需关心具体实现
///
/// ## 降级策略
/// | 失败原因 | 降级行为 |
/// |----------|----------|
/// | 权限拒绝 | 不降级，直接抛出 `CaptureError.permissionDenied` |
/// | SCK 不可用（macOS < 15） | 降级到 CG 截图 |
/// | SCStream 超时 | 降级到 CG 截图 |
/// | 窗口未找到 | 不降级，抛出 `CaptureError.windowNotFound` |
/// | 显示器不可用 | 不降级，抛出 `CaptureError.displayUnavailable` |
///
private actor CaptureModeState {
    var value: CaptureMode = .fullscreen

    func set(_ mode: CaptureMode) {
        value = mode
    }
}

public final class CaptureOrchestrator: Sendable {
    private let sckAdapter: SCKAdapter
    private let cgAdapter: CGCompatAdapter
    private let permissionService: PermissionService
    private let logger: Logger
    private let currentMode = CaptureModeState()
    private let currentModeLock = NSLock()

    /// 创建截图编排器实例。
    ///
    /// - Parameter logger: 日志实例，默认使用 `"capture"` 分类。
    public init(logger: Logger = Logger(category: "capture")) {
        self.sckAdapter = SCKAdapter(logger: Logger(category: "sck-adapter"))
        self.cgAdapter = CGCompatAdapter(logger: Logger(category: "cg-compat"))
        self.permissionService = PermissionService(logger: Logger(category: "permission"))
        self.logger = logger
    }

    /// 执行截图捕获。
    ///
    /// 自动尝试 SCK 主路径，失败时降级到 CG 兼容路径。
    /// 权限检查在捕获前自动执行，无需调用方额外处理。
    ///
    /// - Parameters:
    ///   - mode: 捕获模式，默认全屏。
    ///   - options: 捕获选项，默认标准配置（含光标、高分辨率、2x 缩放）。
    /// - Returns: 截图结果 `CaptureResult`。
    /// - Throws:
    ///   - `CaptureError.permissionDenied` — 屏幕录制权限被拒绝
    ///   - `CaptureError.displayUnavailable` — 没有可用的显示器
    ///   - `CaptureError.windowNotFound` — 未找到指定窗口
    ///   - `CaptureError.captureFailed(reason:)` — 截图操作失败（主路径和降级均失败）
    ///   - `CaptureError.invalidRegion` — 截图区域无效
    public func capture(
        mode: CaptureMode = .fullscreen,
        options: CaptureOptions = CaptureOptions()
    ) async throws -> CaptureResult {
        await currentMode.set(mode)

        // 主路径 — SCK 截图失败时自动降级到 CG
        let startedAt = Date()
        do {
            logger.info("Attempting capture via SCKAdapter (mode: \(describe(mode)))")
            let result = try await sckAdapter.capture(mode: mode, options: options)
            logger.metric(
                "capture.sck",
                value: Date().timeIntervalSince(startedAt) * 1000,
                unit: "ms"
            )
            return result
        } catch CaptureError.permissionDenied {
            throw CaptureError.permissionDenied
        } catch CaptureError.windowNotFound {
            throw CaptureError.windowNotFound
        } catch CaptureError.displayUnavailable {
            logger.warning("SCK: display unavailable, falling back to CG")
            return try await fallbackCapture(mode: mode, options: options)
        } catch CaptureError.invalidRegion {
            throw CaptureError.invalidRegion
        } catch let error as CaptureError {
            if #available(macOS 15.0, *) {
                throw error
            }
            logger.warning("SCK capture failed: \(error), falling back to CG")
            return try await fallbackCapture(mode: mode, options: options)
        } catch {
            if #available(macOS 15.0, *) {
                throw error
            }
            logger.warning("SCK capture threw unexpected error: \(error.localizedDescription), falling back to CG")
            return try await fallbackCapture(mode: mode, options: options)
        }
    }

    /// Captures a lightweight still preview for a window picker.
    ///
    /// This path intentionally stays on ScreenCaptureKit and does not invoke the legacy
    /// Core Graphics fallback, which would be too expensive when several previews load.
    ///
    /// - Parameter content: Optional pre-fetched `SCShareableContent` to reuse,
    ///   avoiding a fresh enumeration per thumbnail.
    public func captureWindowThumbnail(
        windowID: CGWindowID,
        maximumSize: CGSize,
        content: SCShareableContent? = nil
    ) async throws -> CGImage {
        try await sckAdapter.captureWindowThumbnail(
            windowID: windowID,
            maximumSize: maximumSize,
            content: content
        )
    }

    // swiftlint:disable function_body_length
    /// Captures every available display into one canvas.
    ///
    /// Compact modes place displays edge-to-edge (`gap` defaults to 0) and only
    /// physical mode preserves the system's relative positions. The result is a
    /// normal `.fullscreen` capture so history and the shelf stay unchanged.
    public func captureAllDisplays(
        mode: DisplayCanvasMode,
        gap: CGFloat = 0,
        alignment: DisplayCanvasAlignment = .start,
        options: CaptureOptions = CaptureOptions()
    ) async throws -> CaptureResult {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        )
        guard !content.displays.isEmpty else {
            throw CaptureError.displayUnavailable
        }

        let descriptors = content.displays.map { display in
            let scale = Self.pixelScale(for: display)
            return DisplayCanvasDisplay(
                displayID: display.displayID,
                frame: display.frame,
                pixelSize: CGSize(
                    width: display.frame.width * scale,
                    height: display.frame.height * scale
                )
            )
        }
        guard let plan = DisplayCanvasPlan.make(
            displays: descriptors,
            mode: mode,
            gap: gap,
            alignment: alignment,
            highResolution: options.highResolution
        ) else {
            throw CaptureError.displayUnavailable
        }

        let pixelCount = plan.outputPixelSize.width * plan.outputPixelSize.height
        guard pixelCount <= 80_000_000 else {
            throw CaptureError.captureFailed(
                reason: "All-display canvas is too large (\(Int(pixelCount)) px). "
                    + "Reduce the layout or disable Retina resolution."
            )
        }

        let images = try await withThrowingTaskGroup(
            of: (CGDirectDisplayID, CGImage).self
        ) { group in
            for display in content.displays {
                group.addTask {
                    let image = try await self.sckAdapter.captureDisplay(
                        display,
                        options: options
                    )
                    return (display.displayID, image)
                }
            }
            var result: [CGDirectDisplayID: CGImage] = [:]
            for try await (displayID, image) in group {
                result[displayID] = image
            }
            return result
        }

        guard let composed = DisplayCanvasComposer.compose(
            images: images,
            plan: plan
        ) else {
            throw CaptureError.captureFailed(reason: "Unable to compose all displays")
        }

        let mainDisplay = content.displays.first {
            $0.displayID == CGMainDisplayID()
        } ?? content.displays[0]
        let displayInfo = CaptureDisplayInfo(
            displayID: mainDisplay.displayID,
            scaleFactor: plan.commonScale,
            frame: mainDisplay.frame,
            pointWidth: plan.canvasSize.width
        )
        return CaptureResult(
            image: composed,
            captureMode: .fullscreen,
            timestamp: Date(),
            displayInfo: displayInfo
        )
    }

    /// Captures each display as its own result for the "one per display" mode.
    public func captureEachDisplay(
        options: CaptureOptions = CaptureOptions()
    ) async throws -> [CaptureResult] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        )
        guard !content.displays.isEmpty else {
            throw CaptureError.displayUnavailable
        }

        return try await withThrowingTaskGroup(
            of: (CGDirectDisplayID, CaptureResult).self
        ) { group in
            for display in content.displays {
                group.addTask {
                    let image = try await self.sckAdapter.captureDisplay(
                        display,
                        options: options
                    )
                    let info = CaptureDisplayInfo(
                        displayID: display.displayID,
                        scaleFactor: Self.pixelScale(for: display),
                        frame: display.frame,
                        pointWidth: display.frame.width
                    )
                    let result = CaptureResult(
                        image: image,
                        captureMode: .fullscreen,
                        timestamp: Date(),
                        displayInfo: info
                    )
                    return (display.displayID, result)
                }
            }
            var results: [(CGDirectDisplayID, CaptureResult)] = []
            for try await result in group {
                results.append(result)
            }
            return results
                .sorted { $0.0 < $1.0 }
                .map(\.1)
        }
    }

    private static func pixelScale(for display: SCDisplay) -> CGFloat {
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

    // swiftlint:enable function_body_length

    /// 请求屏幕录制权限。
    ///
    /// macOS 15+ 弹出系统权限弹窗，旧版本跳转系统偏好设置。
    ///
    /// - Returns: 用户是否授权。
    public func requestCapturePermission() async -> Bool {
        logger.info("Requesting capture permission")
        return await permissionService.requestScreenCapturePermission()
    }

    /// 检查当前权限状态。
    ///
    /// - Returns: 权限是否已授予。
    public func checkPermissionStatus() async -> Bool {
        await permissionService.checkScreenCapturePermission()
    }

    /// 获取当前权限状态的完整枚举值。
    ///
    /// 用于驱动 UI 层权限引导卡片的展示逻辑。
    ///
    /// - Returns: 当前 `PermissionState`。
    public func permissionState() async -> PermissionState {
        await permissionService.currentState()
    }

    /// 打开系统屏幕录制权限设置页面。
    ///
    /// 跳转到：系统设置 → 隐私与安全性 → 屏幕录制
    public func openSystemSettings() {
        permissionService.openScreenCaptureSettings()
    }

    /// 返回当前捕获模式。
    public func currentCaptureMode() async -> CaptureMode {
        await currentMode.value
    }
}

// MARK: - Fallback Capture

extension CaptureOrchestrator {

    /// 降级截图路径：使用 CGCompatAdapter 实现截图。
    ///
    /// 当 SCKAdapter 不可用或失败时，此方法提供基于 Core Graphics 的降级实现。
    /// 支持全屏、窗口和区域三种模式，但部分高级特性（如光标包含）可能受限。
    private func fallbackCapture(
        mode: CaptureMode,
        options: CaptureOptions
    ) async throws -> CaptureResult {
        // CGWindow/CGDisplay capture is obsoleted on macOS 15. Falling back
        // there silently produced wallpaper or blank frames, which is worse
        // than surfacing the ScreenCaptureKit failure and letting the user retry.
        if #available(macOS 15.0, *) {
            throw CaptureError.captureFailed(
                reason: "Core Graphics capture fallback is unavailable on macOS 15+; retry ScreenCaptureKit"
            )
        }

        logger.info("Falling back to CGCompatAdapter (mode: \(describe(mode)))")

        let timestamp = Date()

        switch mode {
        case .fullscreen:
            return try fallbackFullscreen(options: options, timestamp: timestamp)

        case .window(let windowID):
            return try fallbackWindow(windowID: windowID, options: options, timestamp: timestamp)

        case .area(let rect):
            return try fallbackArea(rect: rect, options: options, timestamp: timestamp)

        case .scroll:
            throw CaptureError.captureFailed(
                reason: "Scroll capture requires ScrollCore, not available in fallback path"
            )
        }
    }

    /// CG 全屏截图
    private func fallbackFullscreen(options: CaptureOptions, timestamp: Date) throws -> CaptureResult {
        let mainDisplayID = CGMainDisplayID()

        guard cgAdapter.isDisplayActive(mainDisplayID) else {
            throw CaptureError.displayUnavailable
        }

        guard let image = cgAdapter.captureDisplay(mainDisplayID, highResolution: options.highResolution) else {
            throw CaptureError.captureFailed(reason: "CG fallback: failed to capture main display")
        }

        let scaleFactor = cgAdapter.backingScaleFactor(for: mainDisplayID)
        let frame = cgAdapter.frame(for: mainDisplayID)

        let displayInfo = CaptureDisplayInfo(
            displayID: mainDisplayID,
            scaleFactor: scaleFactor,
            frame: frame,
            pointWidth: nil
        )

        return CaptureResult(
            image: image,
            captureMode: .fullscreen,
            timestamp: timestamp,
            displayInfo: displayInfo
        )
    }

    /// CG 窗口截图
    private func fallbackWindow(
        windowID: CGWindowID?,
        options: CaptureOptions,
        timestamp: Date
    ) throws -> CaptureResult {
        guard let targetID = windowID else {
            // 未指定窗口 ID，尝试通过 CG 枚举查找第一个非桌面窗口
            let windows = cgAdapter.enumerateWindows()
            guard let firstWindow = windows.first,
                  let winID = firstWindow[kCGWindowNumber as String] as? UInt32 else {
                throw CaptureError.windowNotFound
            }
            return try fallbackWindowResult(
                windowID: winID,
                options: options,
                timestamp: timestamp
            )
        }

        return try fallbackWindowResult(
            windowID: targetID,
            options: options,
            timestamp: timestamp
        )
    }

    /// Builds a window result with the same display metadata shape as the SCK
    /// path. Without it, the shelf falls back to the mouse display and window
    /// styling uses an arbitrary 2x scale on 1x screens.
    private func fallbackWindowResult(
        windowID: CGWindowID,
        options: CaptureOptions,
        timestamp: Date
    ) throws -> CaptureResult {
        guard let image = cgAdapter.captureWindow(windowID, highResolution: options.highResolution) else {
            throw CaptureError.captureFailed(reason: "CG fallback: failed to capture window \(windowID)")
        }

        let windowFrame = cgAdapter.frame(forWindow: windowID)
        let displayInfo: CaptureDisplayInfo? = windowFrame.map { frame in
            let point = CGPoint(x: frame.midX, y: frame.midY)
            let displayID = cgAdapter.displayID(for: point)
            return CaptureDisplayInfo(
                displayID: displayID,
                scaleFactor: cgAdapter.backingScaleFactor(for: displayID),
                frame: cgAdapter.frame(for: displayID),
                pointWidth: frame.width
            )
        }

        return CaptureResult(
            image: image,
            captureMode: .window(windowID),
            timestamp: timestamp,
            displayInfo: displayInfo
        )
    }

    /// CG 区域截图
    private func fallbackArea(rect: CGRect?, options: CaptureOptions, timestamp: Date) throws -> CaptureResult {
        guard let areaRect = rect else {
            throw CaptureError.invalidRegion
        }

        guard areaRect.width > 0, areaRect.height > 0 else {
            throw CaptureError.invalidRegion
        }

        let displayID = cgAdapter.displayID(for: CGPoint(
            x: areaRect.midX,
            y: areaRect.midY
        ))

        guard let image = cgAdapter.captureRect(
            areaRect,
            displayID: displayID,
            highResolution: options.highResolution
        ) else {
            throw CaptureError.captureFailed(reason: "CG fallback: failed to capture rect \(areaRect)")
        }

        let scaleFactor = cgAdapter.backingScaleFactor(for: displayID)
        let frame = cgAdapter.frame(for: displayID)

        let displayInfo = CaptureDisplayInfo(
            displayID: displayID,
            scaleFactor: scaleFactor,
            frame: frame,
            pointWidth: nil
        )

        return CaptureResult(
            image: image,
            captureMode: .area(rect),
            timestamp: timestamp,
            displayInfo: displayInfo
        )
    }
}

// MARK: - Debug

extension CaptureOrchestrator {
    /// 描述捕获模式（用于日志）
    private func describe(_ mode: CaptureMode) -> String {
        switch mode {
        case .fullscreen:
            return "fullscreen"
        case .window(let id):
            return "window(\(id.map(String.init) ?? "nil"))"
        case .area(let rect):
            return "area(\(rect.map(\.debugDescription) ?? "nil"))"
        case .scroll:
            return "scroll"
        }
    }
}
