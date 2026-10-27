import AppKit
import CaptureCore
import CoreGraphics
import Foundation

/// 增量拼接的进行中状态。
///
/// 画布一次性按 `heightLimit` 预分配：几何增长看起来更省，但 `CGContext`
/// 无法原地扩容，扩容要先 `makeImage()` 再重绘，瞬时是「旧图 + 旧画布 + 新画布」
/// 三份，比一次性预留更糟。
private struct LiveStitchState {
    var context: CGContext
    var width: Int
    var limit: Int
    var lastTop: Int
    var frames: Int
    var dropped: Int
    var lastImage: CGImage
}

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

    /// 长图输出预算（高度 + 像素双上限）
    private let budget: StitchBudget

    /// 诊断：本次拼接的画布分配次数与字节数，用于测试「一次性预分配」不变量。
    private(set) var stitchCanvasAllocationCount = 0
    private(set) var stitchCanvasAllocatedBytes = 0
    /// 诊断：重叠探测的实际调用次数，用于测试「每对相邻帧只探测一次」。
    private(set) var overlapProbeCount = 0

    /// 增量拼接的进行中状态（采一帧拼一帧，原始帧随即释放）。
    private var liveStitch: LiveStitchState?

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
    ///   - budget: 长图输出预算，默认使用 ``StitchBudget/default``。
    public init(
        deduper: FrameDeduper = FrameDeduper(),
        overlapDetector: OverlapDetector = OverlapDetector(),
        budget: StitchBudget = .default
    ) {
        self.captureAdapter = nil
        self.deduper = deduper
        self.overlapDetector = overlapDetector
        self.budget = budget
    }

    /// 创建滚动截图引擎（完整模式）。
    ///
    /// 绑定截图适配器，可执行完整的捕获+拼接流程。
    ///
    /// - Parameters:
    ///   - captureAdapter: 遵循 `CaptureProtocol` 的截图适配器。
    ///   - deduper: 帧去重器，默认使用 `FrameDeduper()`。
    ///   - overlapDetector: 重叠检测器，默认使用 `OverlapDetector()`。
    ///   - budget: 输出预算，默认使用 ``StitchBudget/default``。
    public init(
        captureAdapter: any CaptureProtocol,
        deduper: FrameDeduper = FrameDeduper(),
        overlapDetector: OverlapDetector = OverlapDetector(),
        budget: StitchBudget = .default
    ) {
        self.captureAdapter = captureAdapter
        self.deduper = deduper
        self.overlapDetector = overlapDetector
        self.budget = budget
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
        guard ScrollAllowlist.isSupported(windowID.bundleIdentifier ?? "") else {
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

        if let lastFrame = capturedFrames.last,
           deduper.isDuplicate(lastFrame.image, result.image) {
            throw ScrollError.duplicateFrameDetected(index: capturedFrames.count)
        }

        let predictedOffset = capturedFrames.last.map {
            overlapDetector.findBestMatchOffset($0.image, result.image)
        } ?? 0
        let frame = ScrollFrame(
            image: result.image,
            index: capturedFrames.count,
            timestamp: result.timestamp,
            predictedScrollOffset: predictedOffset
        )

        capturedFrames.append(frame)

        var updatedSession = session
        updatedSession.capturedFrames = capturedFrames.count
        updatedSession.status = .capturing
        self.currentSession = updatedSession

        return frame
    }

    /// 兼容入口：只返回图像。输出可能被预算截断且不报告丢弃帧数。
    /// 需要截断信息时用 ``stitchFramesDetailed(_:)``。
    public func stitchFrames(_ frames: [ScrollFrame]) async throws -> CGImage {
        try await stitchFramesDetailed(frames).image
    }

    /// 将多个帧拼接为完整长图，并返回预算截断信息。
    ///
    /// 与 ``stitchFrames(_:)`` 相同，但会报告因 ``StitchBudget`` 被截断的帧数。
    /// 达到上限时保留已经拼好的部分，不抛错。
    public func stitchFramesDetailed(_ frames: [ScrollFrame]) async throws -> StitchResult {
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

        let result = try await stitchOnce(frames: deduped)

        session = currentSession
        session?.status = .completed
        self.currentSession = session

        // 拼接完成后不再需要原始帧，立刻让出内存。
        cleanup()

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

    /// 一次性拼接多帧图像。
    ///
    /// B5 重构后的实现，在「各帧同宽同高、重叠探测成功」时与原逐对拼接逐像素一致
    /// （探测失败或中途换过窗口尺寸时按上一帧高度收敛，比旧实现更保守），并且：
    /// 1. 每对相邻帧只做 **一次** 重叠探测（原实现每对探测两次，且第二次在
    ///    不断变高的合成图上做）；
    /// 2. 先算出每帧的纵向位置和最终高度，**一次性分配**唯一画布，
    ///    不再每步新建 `(offset + heightB)` 的画布并重绘整张旧图；
    /// 3. 高度同时受 `maxHeight` 与 `maxPixels` 约束，宽图自动降低高度上限；
    /// 4. 超出预算时保留已拼部分并返回 `droppedFrameCount`，由 UI 提示。
    private func stitchOnce(frames: [ScrollFrame]) async throws -> StitchResult {
        let width = frames.reduce(0) { max($0, $1.image.width) }
        guard width > 0 else {
            throw ScrollError.stitchFailed(reason: "帧尺寸无效")
        }

        // 1) 计划：只用原始相邻帧探测一次，得到每帧相对上一帧的增长量。
        var growth: [Int] = [0]
        growth.reserveCapacity(frames.count)
        for index in 1..<frames.count {
            try Task.checkCancellation()
            growth.append(overlapGrowth(previous: frames[index - 1], next: frames[index]))
        }

        // 2) 累加位置，按像素预算截断。
        let heightLimit = budget.heightLimit(forWidth: width)
        var positions: [Int] = []
        positions.reserveCapacity(frames.count)
        var cursor = 0
        var outputHeight = 0
        var clippedLastFrame = false

        for (index, frame) in frames.enumerated() {
            if index > 0 {
                cursor += max(0, growth[index])
            }
            guard cursor < heightLimit else { break }
            positions.append(cursor)
            let bottom = cursor + frame.image.height
            outputHeight = min(heightLimit, bottom)
            clippedLastFrame = bottom > heightLimit
            if clippedLastFrame { break }
        }

        guard !positions.isEmpty, outputHeight > 0 else {
            throw ScrollError.stitchFailed(reason: "帧内容为空，无法拼接")
        }

        // 3) 一次性分配唯一画布。
        //
        // 压力闸门放在分配之前：一旦画布已经分配，再在绘制循环里 sleep 并不会
        // 释放任何内存，只会让「完成拼接」这一步变慢。
        updateMemoryPressure()
        if memoryPressureLevel >= .critical {
            throw ScrollError.memoryPressureHigh
        }

        guard let context = CGContext(
            data: nil,
            width: width,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ScrollError.stitchFailed(reason: "无法创建合成画布")
        }
        stitchCanvasAllocationCount += 1
        stitchCanvasAllocatedBytes += width * outputHeight * 4

        // 4) 逐帧绘制到固定画布：后绘制的帧覆盖重叠带，与旧实现的裁剪拼接等价。
        for (index, y) in positions.enumerated() {
            try Task.checkCancellation()

            let image = frames[index].image
            context.draw(image, in: CGRect(
                x: 0,
                y: outputHeight - y - image.height,
                width: image.width,
                height: image.height
            ))
        }

        guard let image = context.makeImage() else {
            throw ScrollError.stitchFailed(reason: "无法生成拼接结果")
        }

        let dropped = frames.count - positions.count
        return StitchResult(
            image: image,
            stitchedFrameCount: positions.count,
            droppedFrameCount: clippedLastFrame ? max(1, dropped) : dropped
        )
    }

    /// 计算下一帧相对上一帧顶部的纵向增长量（像素）。
    ///
    /// 顺序与旧实现一致：先用重叠探测，失败则退回采帧时记录的滚动偏移，
    /// 最后按 85% 高度保守估算。探测失败时沿用旧实现的 `detectOverlaps`
    /// 比例公式，保证输出不变。
    private func overlapGrowth(previous: ScrollFrame, next: ScrollFrame) -> Int {
        let previousHeight = CGFloat(previous.image.height)
        guard previousHeight > 0, next.image.height > 0 else { return 0 }

        overlapProbeCount += 1
        let detected = overlapDetector.findBestMatchOffset(previous.image, next.image)
        if detected > 0 && detected < previousHeight {
            return Int(detected.rounded())
        }

        let estimated: CGFloat
        if previous.predictedScrollOffset > 0 && previous.predictedScrollOffset < previousHeight {
            estimated = previous.predictedScrollOffset
        } else {
            estimated = previousHeight * 0.85
        }

        let overlapRatio = min(max((previousHeight - estimated) / previousHeight, 0), 1)
        return Int((previousHeight - CGFloat(next.image.height) * overlapRatio).rounded())
    }
}

// MARK: - Incremental Stitching

extension ScrollStitchActor {

    /// 开始增量拼接：画布一次性预分配到像素预算允许的最大高度。
    ///
    /// 采帧端每拿到一帧就 `append`，原始帧随即释放，因此稳态内存是
    /// 「画布 + 1 帧」，而不是「全部帧 + 画布」。
    public func beginIncrementalStitch(firstFrame: ScrollFrame) throws {
        guard !isCancelled else {
            throw ScrollError.invalidSession
        }

        updateMemoryPressure()
        if memoryPressureLevel >= .critical {
            throw ScrollError.memoryPressureHigh
        }

        let width = firstFrame.image.width
        let height = firstFrame.image.height
        guard width > 0, height > 0 else {
            throw ScrollError.stitchFailed(reason: "帧尺寸无效")
        }

        let limit = budget.heightLimit(forWidth: width)
        // 首帧比整个预算还高时显式失败，而不是悄悄裁掉下半截。
        guard height <= limit else {
            throw ScrollError.stitchFailed(reason: "首帧高度超出输出预算")
        }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: limit,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ScrollError.stitchFailed(reason: "无法创建合成画布")
        }

        context.draw(firstFrame.image, in: CGRect(
            x: 0,
            y: limit - height,
            width: width,
            height: height
        ))

        liveStitch = LiveStitchState(
            context: context,
            width: width,
            limit: limit,
            lastTop: 0,
            frames: 1,
            dropped: 0,
            lastImage: firstFrame.image
        )
        stitchCanvasAllocationCount += 1
        stitchCanvasAllocatedBytes += width * limit * 4

        var session = currentSession
        session?.status = .capturing
        self.currentSession = session
    }

    /// 追加一帧到正在进行的增量拼接。
    ///
    /// - Note: 预算边界与批式拼接略有不同：增量路径在写入前判断整帧是否放得下，
    ///   放不下时返回 `.limitReached`，不会只画半帧；`stitchOnce` 则会画入能放下的
    ///   部分。因此在「刚好差一点」的阈值上，两者的输出可能相差一个残条高度。
    ///   需要与批式逐像素一致时，请走 `stitchFramesDetailed(_:)`。
    ///
    /// - Parameter image: 新捕获的帧。
    @discardableResult
    public func appendIncrementalFrame(_ image: CGImage) throws -> IncrementalAppendResult {
        guard var live = liveStitch else {
            throw ScrollError.invalidSession
        }
        guard !isCancelled else {
            throw ScrollError.invalidSession
        }
        guard image.width > 0, image.height > 0 else {
            throw ScrollError.stitchFailed(reason: "帧尺寸无效")
        }

        if deduper.isDuplicate(live.lastImage, image) {
            return .duplicate
        }

        // 宽不一致（1x ↔ 2x 显示器、窗口被拉宽）时继续拼会横向错位，直接停。
        guard image.width == live.width else {
            live.dropped += 1
            liveStitch = live
            return .sizeChanged
        }

        let growth = overlapGrowth(
            previous: ScrollFrame(image: live.lastImage, index: 0),
            next: ScrollFrame(image: image, index: 0)
        )
        let top = live.lastTop + max(0, growth)
        guard top + image.height <= live.limit else {
            live.dropped += 1
            liveStitch = live
            return .limitReached
        }

        // 按原始尺寸绘制，超出画布的部分由 CGContext 裁掉；用 min() 会缩放变形。
        live.context.draw(image, in: CGRect(
            x: 0,
            y: live.limit - top - image.height,
            width: image.width,
            height: image.height
        ))

        live.lastTop = top
        live.frames += 1
        live.lastImage = image
        liveStitch = live
        return .appended(frameCount: live.frames)
    }

    /// 完成增量拼接并返回结果。
    public func finishIncrementalStitch() throws -> StitchResult {
        guard let live = liveStitch else {
            throw ScrollError.invalidSession
        }
        liveStitch = nil

        let height = min(live.limit, live.lastTop + live.lastImage.height)
        guard height > 0, let full = live.context.makeImage() else {
            throw ScrollError.stitchFailed(reason: "无法生成拼接结果")
        }

        // 内容明显短于预算时把结果复制到精确高度：`cropping` 会共享整块
        // 预分配缓冲，否则一张 8 000 行的长图会一直背着 32 000 行的内存。
        // 阈值取 1/4 而不是 1/2：1/2 附近复制会同时压住「预算画布 + 接近半个预算的副本」。
        updateMemoryPressure()
        if memoryPressureLevel >= .critical {
            throw ScrollError.memoryPressureHigh
        }
        let image: CGImage
        if height * 4 < live.limit {
            guard let exactContext = CGContext(
                data: nil,
                width: live.width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                throw ScrollError.stitchFailed(reason: "无法创建输出画布")
            }
            guard let cropped = full.cropping(to: CGRect(x: 0, y: 0, width: live.width, height: height)) else {
                throw ScrollError.stitchFailed(reason: "无法裁剪拼接结果")
            }
            exactContext.draw(cropped, in: CGRect(x: 0, y: 0, width: live.width, height: height))
            guard let exact = exactContext.makeImage() else {
                throw ScrollError.stitchFailed(reason: "无法生成输出图像")
            }
            image = exact
        } else {
            guard let cropped = full.cropping(to: CGRect(x: 0, y: 0, width: live.width, height: height)) else {
                throw ScrollError.stitchFailed(reason: "无法裁剪拼接结果")
            }
            image = cropped
        }

        var session = currentSession
        session?.status = .completed
        self.currentSession = session

        return StitchResult(
            image: image,
            stitchedFrameCount: live.frames,
            droppedFrameCount: live.dropped
        )
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

}

// MARK: - Session Management

extension ScrollStitchActor {

    /// 清理所有会话资源。
    private func cleanup() {
        capturedFrames.removeAll()
        liveStitch = nil
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
