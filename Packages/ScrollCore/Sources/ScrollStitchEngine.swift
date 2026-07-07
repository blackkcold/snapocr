import AppKit
import CaptureCore
import CoreGraphics
import Foundation

/// 滚动截图拼接引擎。
///
/// 作为 `ScrollProtocol` 的 `actor` 实现，串行化所有滚动截图操作。
/// 使用独立 actor 避免阻塞主线程（设计文档 §架构设计）。
///
/// ## 核心流程
/// 1. 启动会话 → 校验白名单
/// 2. 逐帧捕获 → 去重 → 重叠检测
/// 3. 流式拼接 → 逐帧处理并释放 → 内存可控
/// 4. 完成/取消 → 清理资源
///
/// ## 白名单策略（设计文档 §R2）
/// 首版仅支持 Safari (`com.apple.Safari`) 和 Chrome (`com.google.Chrome`)。
/// 白名单外应用返回 `ScrollError.applicationNotSupported`。
///
/// ## 内存管理（设计文档 §R18 + §附录 E）
/// - 流式拼接：处理完一帧立即释放对应 CGImage
/// - 内存压力监控：通过 `task_info` 获取驻留内存大小
/// - 压力响应：高压力时暂停新帧采集
///
/// ## 错误处理
/// 拼接失败时返回 `ScrollError.stitchFailed(reason:)`，
/// 上层 UI 应展示"拼接失败，请手动截图"引导。
public actor ScrollStitchActor: ScrollProtocol {

    // MARK: - Dependencies

    /// 底层截图适配器，遵循 `CaptureProtocol`。
    /// 仅在需要自动捕获帧时设置；纯拼接场景可为 `nil`。
    private var captureAdapter: (any CaptureProtocol)?

    /// 帧去重器
    private let deduper: FrameDeduper

    /// 重叠检测器
    private let overlapDetector: OverlapDetector

    /// 当前活跃会话
    private var currentSession: ScrollSession?

    /// 当前会话已捕获的帧（仅在 capturing 期间持有）
    private var capturedFrames: [ScrollFrame] = []

    /// 是否已被取消
    private var isCancelled = false

    // MARK: - Memory Management

    /// 内存压力阈值（字节），参照设计文档 §附录 E
    private static let normalMemoryThreshold: UInt64 = 150 * 1024 * 1024
    private static let moderateMemoryThreshold: UInt64 = 200 * 1024 * 1024
    private static let highMemoryThreshold: UInt64 = 300 * 1024 * 1024
    private static let maxFramesBeforePressureCheck = 5

    /// 当前内存压力级别
    private var memoryPressureLevel: MemoryPressureLevel = .normal

    // MARK: - Initialization

    /// 创建滚动截图引擎（纯拼接模式）。
    ///
    /// 不绑定截图适配器，仅能执行帧拼接和去重操作。
    /// 若需自动捕获帧，调用 ``setCaptureAdapter(_:)`` 注入适配器。
    ///
    /// - Parameters:
    ///   - deduper: 帧去重器，默认使用 `FrameDeduper()`。
    ///   - overlapDetector: 重叠检测器，默认使用 `OverlapDetector()`。
    public init(
        deduper: FrameDeduper = FrameDeduper(),
        overlapDetector: OverlapDetector = OverlapDetector()
    ) {
        self.captureAdapter = nil
        self.deduper = deduper
        self.overlapDetector = overlapDetector
    }

    /// 创建滚动截图引擎（完整模式）。
    ///
    /// 绑定截图适配器，可执行完整的捕获+拼接流程。
    ///
    /// - Parameters:
    ///   - captureAdapter: 遵循 `CaptureProtocol` 的截图适配器。
    ///   - deduper: 帧去重器，默认使用 `FrameDeduper()`。
    ///   - overlapDetector: 重叠检测器，默认使用 `OverlapDetector()`。
    public init(
        captureAdapter: any CaptureProtocol,
        deduper: FrameDeduper = FrameDeduper(),
        overlapDetector: OverlapDetector = OverlapDetector()
    ) {
        self.captureAdapter = captureAdapter
        self.deduper = deduper
        self.overlapDetector = overlapDetector
    }

    /// 注入截图适配器以启用自动帧捕获。
    ///
    /// - Parameter adapter: 遵循 `CaptureProtocol` 的适配器。
    public func setCaptureAdapter(_ adapter: any CaptureProtocol) {
        self.captureAdapter = adapter
    }
}

// MARK: - ScrollProtocol Implementation

extension ScrollStitchActor {

    public func startCapture(windowID: CGWindowID) async throws -> ScrollSession {
        guard ScrollWhitelist.isSupported(windowID.bundleIdentifier ?? "") else {
            throw ScrollError.applicationNotSupported(windowID.bundleIdentifier ?? "unknown")
        }

        cleanup()

        let session = ScrollSession(windowID: windowID)
        self.currentSession = session
        self.capturedFrames = []
        self.isCancelled = false

        return session
    }

    public func captureNextFrame(session: ScrollSession) async throws -> ScrollFrame {
        guard !isCancelled else {
            throw ScrollError.invalidSession
        }

        guard currentSession?.id == session.id else {
            throw ScrollError.invalidSession
        }

        try checkMemoryPressure()

        guard let adapter = captureAdapter else {
            throw ScrollError.stitchFailed(reason: "截图适配器未注入，无法自动捕获帧")
        }

        let result = try await adapter.capture(
            mode: .window(session.windowID),
            options: CaptureOptions()
        )

        let previousOffset = capturedFrames.last?.predictedScrollOffset ?? 0
        let frame = ScrollFrame(
            image: result.image,
            index: capturedFrames.count,
            timestamp: result.timestamp,
            predictedScrollOffset: previousOffset
        )

        if let lastFrame = capturedFrames.last {
            if deduper.isDuplicate(lastFrame.image, frame.image) {
                return frame
            }
        }

        capturedFrames.append(frame)

        var updatedSession = session
        updatedSession.capturedFrames = capturedFrames.count
        updatedSession.status = .capturing
        self.currentSession = updatedSession

        return frame
    }

    public func stitchFrames(_ frames: [ScrollFrame]) async throws -> CGImage {
        guard !isCancelled else {
            throw ScrollError.invalidSession
        }

        updateMemoryPressure()

        if memoryPressureLevel >= .critical {
            throw ScrollError.memoryPressureHigh
        }

        var session = currentSession
        session?.status = .stitching
        self.currentSession = session

        let framesToStitch = frames.isEmpty ? capturedFrames : frames

        guard framesToStitch.count >= 2 else {
            throw ScrollError.insufficientFrames(count: framesToStitch.count)
        }

        let deduped = deduper.deduplicate(framesToStitch)
        guard deduped.count >= 2 else {
            throw ScrollError.insufficientFrames(count: deduped.count)
        }

        let overlaps = overlapDetector.detectOverlaps(deduped)

        let result = try await streamStitch(frames: deduped, overlaps: overlaps)

        session?.status = .completed
        self.currentSession = session

        return result
    }

    public func cancelCapture(session: ScrollSession) async {
        isCancelled = true

        var updatedSession = session
        updatedSession.status = .cancelled
        self.currentSession = updatedSession

        cleanup()
    }
}

// MARK: - Stitching Algorithm

extension ScrollStitchActor {

    /// 流式拼接多帧图像。
    ///
    /// 逐对处理相邻帧，每次拼接后立即释放已处理帧的 CGImage，
    /// 控制内存占用在设计目标范围内。
    ///
    /// 拼接流程：
    /// 1. 取帧 A（上方）和帧 B（下方）
    /// 2. 用 OverlapDetector 找到最佳拼接偏移量
    /// 3. 创建合成图像：A[0..offset] + B[offset..end]
    /// 4. 释放 A 和 B 的原始 CGImage
    /// 5. 合成图像成为下一轮的帧 A
    /// 6. 重复直到所有帧处理完毕
    private func streamStitch(
        frames: [ScrollFrame],
        overlaps: [CGFloat]
    ) async throws -> CGImage {
        var composite = frames[0].image

        for i in 0..<(frames.count - 1) {
            try Task.checkCancellation()

            if memoryPressureLevel >= .high {
                try await Task.sleep(nanoseconds: 500_000_000)
            }

            let frameB = frames[i + 1]
            let stitchOffset = findStitchOffset(
                frameA: composite,
                frameB: frameB.image,
                overlapRatio: overlaps.indices.contains(i) ? overlaps[i] : 0
            )

            guard let stitched = stitchPair(
                imageA: composite,
                imageB: frameB.image,
                stitchOffset: stitchOffset
            ) else {
                throw ScrollError.stitchFailed(
                    reason: "帧 \(i) 和 \(i + 1) 拼接失败: 无法创建合成画布"
                )
            }

            composite = stitched

            if i % Self.maxFramesBeforePressureCheck == 0 {
                updateMemoryPressure()
                if memoryPressureLevel >= .critical {
                    composite = try await downsampleForPressure(composite)
                }
            }
        }

        return composite
    }

    /// 拼接相邻两帧。
    ///
    /// - Parameters:
    ///   - imageA: 上方帧（或累积的合成图像）。
    ///   - imageB: 下方帧。
    ///   - stitchOffset: imageA 底部应保留的像素高度（拼接点）。
    /// - Returns: 拼接后的合成图像，失败返回 `nil`。
    private func stitchPair(
        imageA: CGImage,
        imageB: CGImage,
        stitchOffset: CGFloat
    ) -> CGImage? {
        let heightA = CGFloat(imageA.height)
        let heightB = CGFloat(imageB.height)
        let width = CGFloat(max(imageA.width, imageB.width))

        let offset = stitchOffset > 0 && stitchOffset < heightA
            ? stitchOffset
            : heightA * 0.85

        let totalHeight = offset + heightB

        let bytesPerComponent = imageA.bitsPerComponent
        let colorSpace = imageA.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = imageA.bitmapInfo

        guard let context = CGContext(
            data: nil,
            width: Int(width),
            height: Int(totalHeight),
            bitsPerComponent: bytesPerComponent,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return nil
        }

        if let croppedA = imageA.cropping(to: CGRect(
            x: 0, y: 0,
            width: min(width, CGFloat(imageA.width)),
            height: offset
        )) {
            context.draw(croppedA, in: CGRect(
                x: 0, y: 0,
                width: CGFloat(croppedA.width),
                height: CGFloat(croppedA.height)
            ))
        }

        let drawHeightB = min(heightB, totalHeight - offset)
        if let croppedB = imageB.cropping(to: CGRect(
            x: 0,
            y: Int(max(0, heightB - drawHeightB)),
            width: min(Int(width), imageB.width),
            height: Int(drawHeightB)
        )) {
            context.draw(croppedB, in: CGRect(
                x: 0,
                y: offset,
                width: CGFloat(croppedB.width),
                height: CGFloat(croppedB.height)
            ))
        }

        return context.makeImage()
    }

    /// 使用 OverlapDetector 找到拼接偏移量。
    private func findStitchOffset(
        frameA: CGImage,
        frameB: CGImage,
        overlapRatio: CGFloat
    ) -> CGFloat {
        let heightA = CGFloat(frameA.height)

        let detectedOffset = overlapDetector.findBestMatchOffset(frameA, frameB)
        if detectedOffset > 0 {
            return detectedOffset
        }

        if overlapRatio > 0 {
            return heightA * (1.0 - overlapRatio * 0.5)
        }

        return heightA * 0.85
    }
}

// MARK: - Memory Management

extension ScrollStitchActor {

    /// 检查当前内存压力，压力过高时抛出错误。
    private func checkMemoryPressure() throws {
        updateMemoryPressure()
        if memoryPressureLevel >= .critical {
            throw ScrollError.memoryPressureHigh
        }
    }

    /// 更新内存压力级别。
    ///
    /// 通过 `task_info` 获取当前进程的驻留内存大小，
    /// 与阈值比较后更新压力级别（参照设计文档 §附录 E）。
    private func updateMemoryPressure() {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size
        ) / 4

        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS else { return }

        let residentSize = info.resident_size

        switch residentSize {
        case ..<Self.normalMemoryThreshold:
            memoryPressureLevel = .normal
        case Self.normalMemoryThreshold..<Self.moderateMemoryThreshold:
            memoryPressureLevel = .moderate
        case Self.moderateMemoryThreshold..<Self.highMemoryThreshold:
            memoryPressureLevel = .high
        default:
            memoryPressureLevel = .critical
        }
    }

    /// 获取当前内存压力级别。
    public nonisolated func currentMemoryLevel() -> MemoryPressureLevel {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size
        ) / 4

        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS else { return .normal }

        switch info.resident_size {
        case ..<Self.normalMemoryThreshold:
            return .normal
        case Self.normalMemoryThreshold..<Self.moderateMemoryThreshold:
            return .moderate
        case Self.moderateMemoryThreshold..<Self.highMemoryThreshold:
            return .high
        default:
            return .critical
        }
    }

    /// 内存压力过高时对当前合成图像强制降采样。
    private func downsampleForPressure(_ image: CGImage) async throws -> CGImage {
        let targetWidth = 1024
        let aspectRatio = CGFloat(image.height) / CGFloat(image.width)
        let targetHeight = Int(CGFloat(targetWidth) * aspectRatio)

        let bytesPerComponent = image.bitsPerComponent
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = image.bitmapInfo

        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: bytesPerComponent,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            throw ScrollError.stitchFailed(reason: "内存降采样失败")
        }

        context.interpolationQuality = .medium
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
        )

        guard let downsampled = context.makeImage() else {
            throw ScrollError.stitchFailed(reason: "内存降采样后无法生成图像")
        }

        updateMemoryPressure()
        return downsampled
    }
}

// MARK: - Session Management

extension ScrollStitchActor {

    /// 清理所有会话资源。
    private func cleanup() {
        capturedFrames.removeAll()
    }

    /// 获取会话进度报告。
    public func progressReport() -> ScrollProgress {
        updateMemoryPressure()

        return ScrollProgress(
            capturedFrames: capturedFrames.count,
            estimatedTotalFrames: nil,
            scrollDistance: capturedFrames.reduce(0) { $0 + $1.predictedScrollOffset },
            memoryUsage: currentMemoryUsage(),
            status: currentSession?.status ?? .ready,
            memoryPressure: memoryPressureLevel
        )
    }

    /// 获取当前进程内存使用量。
    private func currentMemoryUsage() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size
        ) / 4

        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS else { return 0 }
        return info.resident_size
    }
}

// MARK: - CGWindowID Extension

extension CGWindowID {
    /// 获取与窗口关联的 bundle identifier。
    ///
    /// 先通过 `CGWindowListCopyWindowInfo` 获取窗口所属进程 PID，
    /// 再通过 `NSRunningApplication` 获取该进程的 bundle identifier。
    fileprivate var bundleIdentifier: String? {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow],
            self
        ) as? [[String: Any]],
              let ownerPID = windowInfo.first?[kCGWindowOwnerPID as String] as? pid_t
        else {
            return nil
        }

        return NSRunningApplication(processIdentifier: ownerPID)?.bundleIdentifier
    }
}
