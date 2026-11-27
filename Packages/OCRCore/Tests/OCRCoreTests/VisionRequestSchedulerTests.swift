import CoreGraphics
import Foundation
import Testing

@testable import OCRCore

/// 验证进程级 Vision 请求池的两件事：并发有上限，单次请求有超时。
///
/// 这些测试都用自己的 scheduler 实例，绝不触碰 ``VisionRequestScheduler/shared``：
/// 一个被超时占死的槽位会留在池里，共享实例会把这种状态带进别的测试。
struct VisionRequestSchedulerTests {
    // MARK: - 超时

    /// 永不返回的请求必须在超时后把控制权交还调用方，并如实记账为「线程仍被占着」。
    @Test func requestThatNeverReturnsIsReportedAsATimeout() async throws {
        let scheduler = VisionRequestScheduler(
            capacity: 2,
            requestTimeout: .milliseconds(80),
            capacityTimeout: .seconds(5)
        )
        let gate = RequestGate()

        let clock = ContinuousClock()
        let started = clock.now
        do {
            _ = try await scheduler.run {
                await gate.beginAndWait()
                return [Self.line("late")]
            }
            Issue.record("expected the request to time out")
        } catch let error as OCRError {
            guard case .visionRequestTimedOut(let timeout) = error else {
                Issue.record("unexpected error: \(error)")
                await gate.open()
                return
            }
            #expect(timeout == .milliseconds(80))
            // 超时不是「没有文字」：结果未知，调用方不能据此跳过这一块。
            #expect(!error.isNoText)
        }
        let elapsed = started.duration(to: clock.now)
        #expect(elapsed >= .milliseconds(60))
        #expect(elapsed < .seconds(3))

        // 超时只是「调用方不等了」，那条线程还在跑，所以槽位仍然占着。
        let snapshot = await scheduler.snapshot
        #expect(snapshot.granted == 1)
        #expect(snapshot.overdue == 1)
        #expect(!snapshot.unresponsive)

        // 让被放弃的请求真的返回：它把槽位还回来，overdue 也清掉。
        // 这条断言就是「槽位随线程、不随超时」的核心：慢过一次不该永久损失容量。
        await gate.open()
        let recovered = await waitFor { await scheduler.snapshot.granted == 0 }
        #expect(recovered)
        let afterReturn = await scheduler.snapshot
        #expect(afterReturn.overdue == 0)
        #expect(!afterReturn.unresponsive)
    }

    /// 超时的槽位在归还之前仍算占用，但剩余容量照常可用。
    ///
    /// Vision 无法中止 `perform`，那条线程确实还在跑，所以不能提前把槽位放回去。
    /// 但线程一旦返回，容量必须回来 —— 否则一次慢请求就会永久削减上限。
    @Test func anOverdueSlotStillHoldsCapacityUntilTheThreadReturns() async throws {
        let scheduler = VisionRequestScheduler(
            capacity: 2,
            requestTimeout: .milliseconds(60),
            capacityTimeout: .seconds(5)
        )
        let stuck = RequestGate()

        do {
            _ = try await scheduler.run {
                await stuck.beginAndWait()
                return []
            }
            Issue.record("expected a timeout")
        } catch is OCRError {
            // 预期
        }

        let afterTimeout = await scheduler.snapshot
        #expect(afterTimeout.granted == 1)
        #expect(afterTimeout.overdue == 1)

        // 还剩一个槽位：常规请求照常完成。
        let lines = try await scheduler.run { [Self.line("ok")] }
        #expect(lines.map(\.text) == ["ok"])

        let settled = await scheduler.snapshot
        #expect(settled.granted == 1)
        #expect(settled.overdue == 1)

        await stuck.open()
        let drained = await waitFor { await scheduler.snapshot.granted == 0 }
        #expect(drained)
        let afterReturn = await scheduler.snapshot
        #expect(afterReturn.overdue == 0)
    }

    /// 所有槽位都被超时占死后，新请求立刻失败，而不是排队等一个不可能来的结果。
    ///
    /// 这些线程若之后返回，池子必须自己恢复：拒绝一个健康 App 的新请求，比慢更糟。
    @Test func anExhaustedPoolFailsFastAndRecoversWhenThreadsReturn() async throws {
        let scheduler = VisionRequestScheduler(
            capacity: 1,
            requestTimeout: .milliseconds(50),
            capacityTimeout: .seconds(5)
        )
        let stuck = RequestGate()

        do {
            _ = try await scheduler.run {
                await stuck.beginAndWait()
                return []
            }
            Issue.record("expected a timeout")
        } catch is OCRError {
            // 预期
        }

        let exhausted = await scheduler.snapshot
        #expect(exhausted.unresponsive)

        let clock = ContinuousClock()
        let started = clock.now
        do {
            _ = try await scheduler.run { [Self.line("never")] }
            Issue.record("expected the pool to refuse the request")
        } catch let error as OCRError {
            #expect(error.isEngineUnresponsive)
        }
        // 立即失败：不能等到容量超时。
        #expect(started.duration(to: clock.now) < .seconds(2))

        // 唯一那条线程返回后，池子恢复，不需要用户重启 App。
        await stuck.open()
        let recovered = await waitFor { !(await scheduler.snapshot.unresponsive) }
        #expect(recovered)
        let lines = try await scheduler.run { [Self.line("usable again")] }
        #expect(lines.map(\.text) == ["usable again"])
    }

    // MARK: - 并发上限

    /// 同时在跑的请求不超过容量，超出的排队等待而不是再生一条线程。
    @Test func concurrentRequestsStayWithinCapacity() async throws {
        let scheduler = VisionRequestScheduler(
            capacity: 2,
            requestTimeout: .seconds(10),
            capacityTimeout: .seconds(10)
        )
        let gate = RequestGate()

        var tasks: [Task<[OCRLine], any Error>] = []
        for _ in 0..<5 {
            tasks.append(
                Task {
                    try await scheduler.run {
                        await gate.beginAndWait()
                        return [Self.line("ok")]
                    }
                }
            )
        }

        let reachedCeiling = await waitFor { await scheduler.snapshot.peakGranted == 2 }
        #expect(reachedCeiling)
        try? await Task.sleep(for: .milliseconds(80))

        let held = await scheduler.snapshot
        #expect(held.peakGranted == 2)
        #expect(held.granted == 2)
        #expect(held.overdue == 0)
        let startedOperations = await gate.startedCount
        #expect(startedOperations == 2)

        await gate.open()
        for task in tasks {
            _ = try await task.value
        }

        let drained = await scheduler.snapshot
        #expect(drained.granted == 0)
        #expect(drained.peakGranted == 2)
        let allStarted = await gate.startedCount
        #expect(allStarted == 5)
    }

    // MARK: - 取消

    /// 调用方取消时立刻拿回控制权，但槽位要跟着线程走，不能跟着调用方走。
    @Test func cancellingAnInFlightRequestFreesTheCallerNotTheSlot() async throws {
        let scheduler = VisionRequestScheduler(
            capacity: 1,
            requestTimeout: .seconds(10),
            capacityTimeout: .seconds(10)
        )
        let gate = RequestGate()

        let task = Task {
            try await scheduler.run {
                await gate.beginAndWait()
                return [Self.line("ignored")]
            }
        }
        let running = await waitFor { await scheduler.snapshot.granted == 1 }
        #expect(running)

        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected cancellation")
        } catch is CancellationError {
            // 预期
        }

        let afterCancel = await scheduler.snapshot
        #expect(afterCancel.granted == 1)
        #expect(afterCancel.overdue == 0)

        await gate.open()
        let drained = await waitFor { await scheduler.snapshot.granted == 0 }
        #expect(drained)
    }

    /// 排队等槽位时被取消：退出队列，不占住后来者的位置。
    @Test func cancellingAWaitForASlotLeavesTheQueueClean() async throws {
        let scheduler = VisionRequestScheduler(
            capacity: 1,
            requestTimeout: .seconds(10),
            capacityTimeout: .seconds(10)
        )
        let gate = RequestGate()

        let holder = Task {
            try await scheduler.run {
                await gate.beginAndWait()
                return [Self.line("holder")]
            }
        }
        let running = await waitFor { await scheduler.snapshot.granted == 1 }
        #expect(running)

        let waiter = Task {
            try await scheduler.run { [Self.line("waiter")] }
        }
        // 让等待者真的进入队列。
        try? await Task.sleep(for: .milliseconds(50))
        waiter.cancel()
        do {
            _ = try await waiter.value
            Issue.record("expected cancellation")
        } catch is CancellationError {
            // 预期
        }

        await gate.open()
        _ = try await holder.value

        // 队列已清空，槽位归还后新请求可正常完成。
        let lines = try await scheduler.run { [Self.line("next")] }
        #expect(lines.map(\.text) == ["next"])
    }

    /// 等不到槽位时如实报告引擎已卡住，而不是无限等下去。
    @Test func waitingForASlotLongerThanTheBudgetReportsTheEngineStuck() async throws {
        let scheduler = VisionRequestScheduler(
            capacity: 1,
            requestTimeout: .seconds(10),
            capacityTimeout: .milliseconds(60)
        )
        let gate = RequestGate()

        let holder = Task {
            try await scheduler.run {
                await gate.beginAndWait()
                return [Self.line("holder")]
            }
        }
        let running = await waitFor { await scheduler.snapshot.granted == 1 }
        #expect(running)

        do {
            _ = try await scheduler.run { [Self.line("blocked")] }
            Issue.record("expected the slot wait to expire")
        } catch let error as OCRError {
            #expect(error.isEngineUnresponsive)
        }

        await gate.open()
        _ = try await holder.value
    }

    /// 单条超时线程不该让池子自认已瘫痪：容量还有余量就继续接受请求。
    @Test func aSingleOverdueThreadDoesNotShutThePoolDown() async throws {
        let scheduler = VisionRequestScheduler(
            capacity: 3,
            requestTimeout: .milliseconds(50),
            capacityTimeout: .seconds(5)
        )
        let stuck = RequestGate()

        do {
            _ = try await scheduler.run {
                await stuck.beginAndWait()
                return []
            }
            Issue.record("expected a timeout")
        } catch is OCRError {
            // 预期
        }

        let snapshot = await scheduler.snapshot
        #expect(!snapshot.unresponsive)
        #expect(snapshot.granted == 1)
        #expect(snapshot.overdue == 1)
        #expect(snapshot.capacity == 3)

        let lines = try await scheduler.run { [Self.line("still usable")] }
        #expect(lines.map(\.text) == ["still usable"])

        await stuck.open()
        let drained = await waitFor { await scheduler.snapshot.granted == 0 }
        #expect(drained)
    }

    // MARK: - 辅助

    /// 等槽预算必须明显长于单请求上限。
    ///
    /// 每个已授予的请求都受单请求超时约束，所以健康但繁忙的池子最多在一个超时量级
    /// 内就会把名额让出来。预算若更短，正常并发就会报「引擎已无响应，请重新启动」，
    /// 把一个好好的 App 送去重启 —— 这是最难被用户原谅的那类误报。
    @Test func theSlotBudgetOutlastsAHealthyPoolsDrain() {
        #expect(VisionRequestScheduler.defaultCapacityTimeout > VisionRequestScheduler.defaultRequestTimeout)
        // 至少容纳两轮完整请求：一次失败可能是慢，连续两轮全被占死才说明真的卡住。
        let doubled = VisionRequestScheduler.defaultRequestTimeout * 2
        #expect(VisionRequestScheduler.defaultCapacityTimeout >= doubled)
    }

    /// 生产默认容量留出一个空位给单图请求与大画布补跑。
    @Test func theDefaultCapacityLeavesHeadroomOverTheTileLimit() {
        #expect(VisionRequestScheduler.defaultCapacity > OCRPipeline.maxConcurrentTiles)
    }

    private static func line(_ text: String) -> OCRLine {
        OCRLine(text: text, confidence: 0.9, boundingBox: .zero)
    }
}

// MARK: - 测试辅助

/// 让操作停在「已经开始、尚未返回」的状态，模拟阻塞中的 Vision 请求。
private actor RequestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var started = 0

    /// 记一次开始，然后挂住直到 ``open()``。
    func beginAndWait() async {
        started += 1
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// 放行所有被挂住的操作。
    func open() {
        isOpen = true
        let parked = waiters
        waiters.removeAll()
        for continuation in parked {
            continuation.resume()
        }
    }

    /// 已经进入操作体的次数。
    var startedCount: Int { started }
}

/// 轮询直到条件成立或超时。
///
/// 不用固定 sleep：这些断言关心的是「状态有没有到达」，而余量很薄的固定等待
/// 在满载机器上会误报。
private func waitFor(
    timeout: Duration = .seconds(10),
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

// MARK: - 空结果判据

/// 「没有文字」必须由错误结构表达，不能靠文案。
struct OCRErrorSemanticsTests {
    /// 只有结构化的空结果算「没有文字」。
    @Test func onlyTheStructuredEmptyResultCountsAsNoText() {
        #expect(OCRError.noTextFound.isNoText)
        #expect(!OCRError.visionRequestTimedOut(timeout: .seconds(30)).isNoText)
        #expect(!OCRError.engineUnresponsive.isNoText)
        #expect(!OCRError.engineUnavailable(.vision).isNoText)
        #expect(!OCRError.languageNotSupported("xx").isNoText)
        #expect(!OCRError.imageTooLarge(width: 99_999, height: 99_999).isNoText)
    }

    /// 关键回归：沿用旧中文文案的 `recognitionFailed` 不再被当成空白。
    ///
    /// 旧判据在失败文案里找「未识别到任何有效文本」，于是任何复用这句话的真实
    /// 失败（超时、引擎崩溃）都会被分块路径静默跳过，用户只看到少了几行字。
    @Test func aRecognitionFailureCarryingTheOldPhraseIsNotNoText() {
        let legacy = OCRError.recognitionFailed(reason: "未识别到任何有效文本（所有候选置信度均低于 0.1）")
        #expect(!legacy.isNoText)
    }

    /// 只有引擎彻底耗尽才算「无响应」，普通失败不该触发快速放弃。
    @Test func onlyTheExhaustedEngineCountsAsUnresponsive() {
        #expect(OCRError.engineUnresponsive.isEngineUnresponsive)
        #expect(!OCRError.visionRequestTimedOut(timeout: .seconds(30)).isEngineUnresponsive)
        #expect(!OCRError.noTextFound.isEngineUnresponsive)
        #expect(!OCRError.recognitionFailed(reason: "Vision 框架识别失败").isEngineUnresponsive)
    }
}

// MARK: - 引擎接线

/// 验证引擎把超时当失败上报，而不是当成空白。
struct VisionEngineGuardTests {
    /// 注入的识别器永不返回时，`recognize` 必须在超时后抛错。
    @Test func aHungRequestSurfacesAsATimeoutFromRecognize() async throws {
        let scheduler = VisionRequestScheduler(
            capacity: 2,
            requestTimeout: .milliseconds(80),
            capacityTimeout: .seconds(5)
        )
        let gate = VisionRequestSchedulerTestsGate()
        let engine = VisionOCREngine(scheduler: scheduler) { _, _, _, _ in
            await gate.beginAndWait()
            return [OCRLine(text: "late", confidence: 0.9, boundingBox: .zero)]
        }

        do {
            _ = try await engine.recognize(
                image: try makeGuardImage(width: 300, height: 200),
                languages: ["zh-Hans", "en-US"],
                options: OCROptions()
            )
            Issue.record("expected the request to time out")
        } catch let error as OCRError {
            guard case .visionRequestTimedOut = error else {
                Issue.record("unexpected error: \(error)")
                await gate.open()
                return
            }
            #expect(!error.isNoText)
        }

        await gate.open()
    }

    /// 空结果走结构化错误，供分块路径当成空白。
    @Test func anEmptyResultThrowsTheStructuredNoTextError() async throws {
        let scheduler = VisionRequestScheduler(
            capacity: 2,
            requestTimeout: .seconds(10),
            capacityTimeout: .seconds(10)
        )
        let engine = VisionOCREngine(scheduler: scheduler) { _, _, _, _ in [] }

        do {
            _ = try await engine.recognize(
                image: try makeGuardImage(width: 300, height: 200),
                languages: ["zh-Hans"],
                options: OCROptions()
            )
            Issue.record("expected the empty result to throw")
        } catch let error as OCRError {
            #expect(error.isNoText)
        }
    }

    private func makeGuardImage(width: Int, height: Int) throws -> CGImage {
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            throw OCRError.recognitionFailed(reason: "Unable to create test context")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw OCRError.recognitionFailed(reason: "Unable to create test image")
        }
        return image
    }
}

/// ``RequestGate`` 的同名能力，供本文件另一个 suite 使用（private actor 不能跨文件共享）。
private actor VisionRequestSchedulerTestsGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func beginAndWait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let parked = waiters
        waiters.removeAll()
        for continuation in parked {
            continuation.resume()
        }
    }
}
