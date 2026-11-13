# 录制 P2 — 音频引擎 阶段计划

> **Status:** `Accepted by main session (P2/T4 boundaries)`；**accepted 不代表已实现**。Task 4 仍未派发/未编译；开发优先，不等 P0 全矩阵。
> 母计划：`Docs/superpowers/plans/2026-11-11-recording-full-delivery.md`
> Spec：`Docs/superpowers/specs/2026-11-11-audio-and-segmented-recording-design.md`（修订 2.1）
> 只读依据：`.superpowers/sdd/2026-11-11-recording-full-delivery/review/p2-buffer-feasibility.md`
> 范围：仅母计划 Task 4–6。P0-1/2/3 是最终验收条件，不阻塞本阶段；真实 SCK/麦克风/旧 OS 验证留最终验收。

**Goal:** 在 CaptureCore 内建立有界、可测试的音频缓冲/混音/来源/路由/漂移泵，使后续 checkpoint/Seal 能在不重写采集层的前提下接入。

**Architecture:** 每 role 一个预分配 SPSC 槽 ring；producer 只同步拷贝并发布完整 owned 槽，consumer 读出 owned `AudioPCMBlock`；macOS 15+ 用 `Synchronization.Atomic`，13/14 用公开 `OSAtomicAdd64Barrier`。系统/麦克风来源把数据写入各自 ring；路由控制器在整数样本位置提交事件；泵按 host-time 消费、渐进重采样、起录后无声补静音。

**Global Constraints**

- 固定最终会话网格 `48000 Hz`；`10ms = 480 frames`；ring 可先按源采样率（44.1/48k）保存，不把 44.1k 冒充 48k。
- 每路 ring 的时间预算 `2s`；`capacityFrames = sampleRate * 2` 精确，不用 256 槽/bitmask 扩大预算。
- 回调只同步 copy + timestamp；禁止 `await`、逐块 `Task`、文件 IO、UI、锁等待；不把 `actor`/`nonisolated` 当无锁证明。
- 不新增 SPM 依赖/C target/`Package.swift` 改动；只用公开 `Synchronization`（15+）与 `OSAtomic`（13/14）。
- 溢出是**有损可观测**：精确 `droppedFrames`/`gapFrames`，绝不覆盖未读槽，不靠 trylock 丢音。
- `AudioPCMBlock` 的 `channels` 拥有存储；借用 `UnsafeBufferPointer` 只在同步作用域，跨 async 只能传 owned block。
- 旧 `RecordingSessionStatus`/视频路径不动；P2 不接 Seal/writer，T6 只依赖 `AudioCheckpointSink` 协议。
- 未测不声称通过；P0/真实设备/旧 OS 缺口在最终验收前保持 `blocked`。

---

## 顺序

`Task 4 → Task 5 → Task 6`。T4 先冻结 ring/atomic/mix/factory；T5 只消费 ring；T6 只消费 T4/T5 与 `AudioCheckpointSink` 协议，不依赖 P3 具体 writer。

---

## Task 4 — ring、atomic cursor、mix policy、buffer factory

**Files**
- Create: `Packages/CaptureCore/Sources/Audio/AudioSourceRingBuffer.swift`
- Create: `Packages/CaptureCore/Sources/Audio/AudioRingAtomicCursor.swift`（internal）
- Create: `Packages/CaptureCore/Sources/Audio/AudioMixPolicy.swift`
- Create: `Packages/CaptureCore/Sources/Audio/AudioSampleBufferFactory.swift`
- Modify: `Packages/CaptureCore/Sources/Audio/AudioSampleClock.swift`（仅 T1 Minor DocC）
- Modify: `Packages/CaptureCore/Sources/Recording/AudioPCMBlock.swift`（仅 range DocC：ring 阶段为源帧序号，T6 后为 48k 会话坐标）
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/AudioSourceRingBufferTests.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/AudioRingAtomicCursorTests.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/AudioMixPolicyTests.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/AudioSampleBufferFactoryTests.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/AudioSampleClockTests.swift`（修改，仅 Minor）

**接口**
```swift
public final class AudioSourceRingBuffer: @unchecked Sendable {
    public init(role: RecordingTrackRole, sampleRate: Int, channelCount: Int,
                hostTicksPerSecond: UInt64, capacitySeconds: Double = 2.0) throws
    public var capacityFrames: Int { get }
    public var slotFrameCount: Int { get }
    public var isClosedAndEmpty: Bool { get }
    public func write(interleaved: UnsafeBufferPointer<Float>, frameCount: Int, hostTime: UInt64) -> RingWriteResult
    public func write(planar: [UnsafeBufferPointer<Float>], frameCount: Int, hostTime: UInt64) -> RingWriteResult
    public func read(maxFrames: Int) -> RingReadResult
    public func finishProducing() -> RingFinalizeResult // producer 已 join 后调用；满则保留 staging，可重试
    public func requestClose()                         // 仅原子关闭标记；不触碰 producer storage
    public func close()                                // 兼容入口 = requestClose
    public var stats: RingStats { get }
}

public struct RingWriteResult: Sendable, Equatable {
    public let acceptedFrames: Int
    public let droppedFrames: Int
    public let reason: RingDropReason?
}
public struct RingReadResult: Sendable {
    public let block: AudioPCMBlock?
    public let gapFrames: Int       // 该块之前的 gap；block nil + closedAndEmpty 时为终端 gap，仅交付一次
    public let isClosedAndEmpty: Bool
    public let reason: RingReadReason?
}
public enum RingDropReason: Sendable, Equatable {
    case overflow, closed, reentrantProducer, reentrantConsumer, invalidFormat, invalidTimestamp
}
public enum RingReadReason: Sendable, Equatable {
    case reentrantConsumer, invalidMaxFrames
}
public struct RingFinalizeResult: Sendable, Equatable {
    public let flushedFrames: Int
    public let retainedStagingFrames: Int
    public let producerStillActive: Bool
}
public struct RingStats: Sendable, Equatable {
    public let acceptedFrames: Int64
    public let droppedFrames: Int64
    public let gapFrames: Int64
    public let stagingFrames: Int
    public let producerMaxDepth: Int
    public let consumerMaxDepth: Int
    public let reentrantRejects: Int
    public let lastDropReason: RingDropReason?
}
public enum AudioRingConfigurationError: Error, Equatable {
    case invalidSampleRate, invalidChannelCount, invalidCapacity, invalidHostTimebase
}
```

- `capacityFrames = floor(Double(sampleRate) * capacitySeconds)`；**不 ceil 槽数扩大容量**；`slotFrameCount = max(1, sampleRate/100)`；`slotCapacity = capacityFrames / slotFrameCount`（floor）。48k 2s=96,000 帧/200 槽；44.1k=88,200/200 槽。`capacitySeconds` 必须 finite、`0.05...2.0`；生产固定 2.0，测试用小容量。
- 单/双声道显式；44.1k 不冒充 48k。`staging` 占用量计入 `capacityFrames`；ring 槽 + staging 总量不得超容量。
- 尾帧：producer 停止并 join 后 `finishProducing()` 把 staging 作为最后短槽发布；若 ring 满则 `retainedStagingFrames > 0`，consumer drain 后由控制上下文重试；不得丢尾帧、不得让 consumer 写 staging。`producerStillActive == true` 时不得触碰 staging。
- `requestClose()` 只设原子关闭标记；producer 回调并发 close 不读取/释放 staging；consumer drain 后 `isClosedAndEmpty` 才为 true；对象在无借用者后析构，`deinit` 不依赖 producer 已停止。
- 溢出 gap 有顺序：drop 只影响其后的帧；gap 由**下一个成功发布槽**携带，不贴给已排队的旧块；关闭时无后续音频则作为终端 gap 交付一次。重复 read 不重复计数。
- 部分读取：`read(maxFrames < slotFrameCount)` 保留 consumer 游标与槽剩余，不丢槽；返回一个连续块，不把不连续区间合成一块。range 在 drop 处跳变，跨 staging/partial 仍连续。
- `AudioPCMBlock.range` 在 ring 输出时是**源采样率帧序号**（含 drop 推进）；T6 重采样后才映射到 48k 会话坐标。T4 只改 `AudioPCMBlock.swift` DocC，不改结构。
- 分割回调时 `slotHostTime = 首帧 hostTime + frameOffset*hostTicksPerSecond/sampleRate`（checked）；首槽精确保留输入 hostTime；测试 24MHz/非 1GHz，不假设 tick=ns。
- Atomic：`AudioAtomicCounter { loadAcquire(); @discardableResult fetchAddRelease(_:) -> Int64; @discardableResult fetchAddAcqRel(_:) -> Int64 }`（均返回旧值）。publish/release 可用 release；depth/ownership gate 必须用 acquire-release RMW（或 CAS 成功 acqrel、失败 acquire/relaxed 的等价证明），不能用 release-only 接管前次 producer/consumer 私有状态。15+ 按 SDK 实际 `Atomic` 返回类型适配，不假设 `fetchAdd` 一定存在；13/14 `OSAtomicAdd64Barrier` 为更强序。有限原子操作、不自旋；`legacyForTesting` 仅 internal。默认与 legacy 都要证明跨次 depth handoff 的 happens-before，不用 TSan 代替证明。
- Mix：`AudioMixPolicy.init(sampleRate:rampDurationSeconds: 0.008)`；`mutating mix(system: AudioPCMBlock?, microphone: AudioPCMBlock?, systemGainDB: Float, microphoneGainDB: Float, masterGainDB: Float) throws -> AudioMixResult { block, clippedSampleCount, nonFiniteSampleCount }`。单声道 mic 合法铺到双声道 system；角色 gain 与总 gain 各有独立 ramp 状态；NaN/Inf 归零并计数，有限超限走 limiter，不硬 clip。
- Factory：`makePCMBuffer` throws；`allocationFailed` 不 force unwrap；`makeSampleBuffer` throws。

**测试**
- 尾帧：1/479/481 帧；满 buffer 尾帧先 `retainedStagingFrames`，drain 后重试回收；被拒帧计 gap，无静默丢失。
- gap 顺序：consumer 慢时先读旧块，drop 后下一块才带 gap；关闭时无后续音频交付终端 gap 一次；重复 read 不重复。
- 部分读：`maxFrames<slot` 不丢槽剩余；range 连续；drop 处跳跃；不合并不连续区间。
- 关闭：close 与 producer 并发只设标志；drain 后 `isClosedAndEmpty`；无 UAF。
- 两线程顺序/容量内零丢失/不覆盖 poison；重入 producer/consumer 被拒绝且 stats 计数。
- 44.1/48k、单/双声道、1/481/1024/4410/8192 帧；24MHz 分割 hostTime；非 1GHz。
- 非法 sampleRate/channel/capacity/NaN/Inf 抛 `AudioRingConfigurationError`，不 trap；小容量严格按 `capacityFrames`。
- 强制 legacy backend 本机 26 测试；depth/ownership gate 跨次 handoff 的 happens-before 在默认/legacy 都验证；TSan 只补充，不能代替证明；重复次数预登记。
- mix：mic 单声道 + system 双声道；角色/总 gain ramp 跨 chunk；NaN 归零；limiter 状态。
- `stats` 分项快照可非同一瞬时一致，但最终 drain 计数守恒；读 stats 不写共享非原子状态。

**T1 Minor DocC**
- `AudioSampleClock.swift` 仅澄清：pre-epoch 不足一采样按截零处理（0，不为负）；sample→host→sample 的逐样本往返只在 `hostTicksPerSecond >= sampleRate` 时成立。
- `AudioSampleClockTests.swift` 只加两个有效域测试；不改算法、不扩展功能。

**退出:** ring/atomic/mix/factory 测试 GREEN；首次编译/链接结论写入报告；若 `Synchronization`/`OSAtomic` 任一不可用，停并交主会话裁定，不在计划中宣布已验证。

---

## Task 5 — 系统/麦克风来源与路由控制器

**Files**
- Create: `Packages/CaptureCore/Sources/Audio/AudioFrameSource.swift`（协议 + generation/event）
- Create: `Packages/CaptureCore/Sources/Audio/AudioSourcePlatform.swift`（SCK/AVAudioEngine 适配协议、设备事件）
- Create: `Packages/CaptureCore/Sources/Audio/SystemAudioSource.swift`
- Create: `Packages/CaptureCore/Sources/Audio/MicrophoneSource.swift`
- Create: `Packages/CaptureCore/Sources/Audio/AudioRouteController.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/SystemAudioSourceTests.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/MicrophoneSourceTests.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/AudioRouteControllerTests.swift`

**接口**
```swift
public struct AudioSourceFormat: Sendable, Hashable { public let sampleRate: Int; public let channelCount: Int }
public struct AudioSourceGeneration: Sendable {
    public let id: UUID
    public let role: RecordingTrackRole
    public let format: AudioSourceFormat
    public let ringBuffer: AudioSourceRingBuffer
}
public enum AudioSourcePreparation: Sendable {
    case prepared(AudioSourceGeneration)
    case unchangedOnFailure(reason: String)
}
public struct AudioDeviceChangeEvent: Sendable {
    public let role: RecordingTrackRole
    public let deviceID: String   // opaque；不得含 serial
    public let format: AudioSourceFormat
}
public protocol AudioFrameSource: AnyObject, Sendable {
    var role: RecordingTrackRole { get }
    func currentGeneration() async -> AudioSourceGeneration
    func start() async throws
    func stop() async
    func prepareReconfiguration(_ event: AudioDeviceChangeEvent) async -> AudioSourcePreparation
    func commitReconfiguration(_ generation: AudioSourceGeneration) async -> Bool
}
public protocol SystemAudioStreaming: AnyObject, Sendable {
    var streamID: UUID { get }
    var isRunning: Bool { get }
    func installAudioOutput(_ handler: @escaping @Sendable (CMSampleBuffer) -> Void) throws
    func removeAudioOutput() async
}
public protocol OwnedSystemAudioStreaming: SystemAudioStreaming {
    func startCapture() async throws
    func stopCapture() async
}
public protocol SystemAudioStreamFactory: Sendable {
    func makeStream() async throws -> any OwnedSystemAudioStreaming // 只创建，不隐式 start
}
public final class SystemAudioSource: AudioFrameSource {
    public init(ringBuffer: AudioSourceRingBuffer, stream: any SystemAudioStreaming) // screen reuse
    public init(ringBuffer: AudioSourceRingBuffer, factory: any SystemAudioStreamFactory) // audio-only owned
}
public final class MicrophoneSource: AudioFrameSource {
    public init(ringBuffer: AudioSourceRingBuffer,
                authorizer: any MicrophoneAuthorizing,
                targetFormat: AVAudioFormat,
                engine: any MicrophoneCaptureEngine,
                deviceMonitor: any AudioDeviceChangeMonitoring)
}
public struct AudioRoutePreparation: Sendable {
    public let preparationID: UUID
    public let result: RoutePreparationResult
    public let generation: AudioSourceGeneration?
}
public final class AudioRouteController {
    public init(authorizer: any MicrophoneAuthorizing, sources: [RecordingTrackRole: any AudioFrameSource])
    public func prepare(_ mode: AudioSourceMode) async -> AudioRoutePreparation
    public func prepareDeviceChange(_ event: AudioDeviceChangeEvent) async -> AudioRoutePreparation
    public func commit(_ event: RouteEvent, preparationID: UUID) async -> RouteCommitResult
    public func currentGeneration(for role: RecordingTrackRole) async -> AudioSourceGeneration?
    public func takeRetiredGenerations() async -> [AudioSourceGeneration]
}
```

- `SystemAudioSource` owned：`start()` = factory.makeStream → installAudioOutput → `startCapture`；任一步失败回滚 remove/stop 只限本次新 stream；`stop()` = remove + stopCapture。screen reuse：只 install/remove，绝不 start/stop 原 video stream；工厂绝不隐式 start。
- `MicrophoneCaptureEngine`：一个 tap、`currentFormat`、install/remove/start/stop；`MicrophoneSource.start()` 只读授权状态，未授权返回失败，**不 requestAccess**。`AudioDeviceChangeMonitoring` 真实注册/注销设备监听，测试注入事件。
- 设备格式变化重建 `AudioSourceGeneration` + 新 ring（closed ring 不复用）；route `commit(event:preparationID:)` 在整数样本交换；`preparationID` 必须匹配当前 expected token，过期 commit `.unchanged`。`takeRetiredGenerations()` 交给 T6 pump 排空；旧健康源不关闭。
- `prepare`/`prepareDeviceChange` 失败保留旧态；superseded prepare 取消；controller 用 actor/serialized ownership，但 reentrancy 由 token/state machine 防，不靠 actor 自动保证。
- callback 不创建 `[[Float]]`/`AudioPCMBlock`：从 CMSampleBuffer/AVAudioPCMBuffer 同步借用，必要预分配 scratch 后直接 `ring.write`；owned block 只在 consumer read 构造。
- `AudioSourcePlatform.swift` 内有可用默认实现：SCK 2×2 low-fps `OwnedSystemAudioStreaming` factory、AVAudioEngine 单 tap engine、CoreAudio 设备监听注册/注销；协议+fake 不是唯一交付。

**测试**
- owned path：fake stream 计数 install→start、stop→remove→stop；install 失败回滚 remove；start 失败回滚 remove+stop；只拥有本次新 stream。
- reuse path：screen fake stream 只 install/remove，start/stop 计数为 0，不新建 stream。
- 两阶段 prepare/commit 用 `preparationID` 匹配；commit 失败旧源不丢；stale/过期 commit `.unchanged`；superseded/取消/并发 commit 串行。
- 44.1→48 设备重配新 generation/ring；closed ring 不复用；mic 拒绝不影响 system；mic 关闭释放 tap；真实设备监听注册/注销计数。
- 配置/事件决策用 fake；SCK/AVAudioEngine 默认真实实现编译但不 start，不触发 TCC；合成 PCM 转换可测。

**退出:** 路由决策/失败路径测试 GREEN；真实设备未验证标 `blocked`。

---

## Task 6 — 漂移泵与音频录制引擎

**Files**
- Create: `Packages/CaptureCore/Sources/Audio/AudioMixPump.swift`
- Create: `Packages/CaptureCore/Sources/Audio/AudioDriftResampler.swift`
- Create: `Packages/CaptureCore/Sources/Audio/AudioRecordingEngine.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/AudioMixPumpTests.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/AudioDriftResamplerTests.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/AudioRecordingEngineTests.swift`

**接口**
```swift
public struct AudioPumpInputs: Sendable {
    public let rings: [RecordingTrackRole: AudioSourceRingBuffer]
    public let activeRoles: Set<RecordingTrackRole>
    public let everEnabledRoles: Set<RecordingTrackRole>
    public let generationIDs: [RecordingTrackRole: UUID]
}
public struct AudioPumpTick: Sendable {
    public let range: SampleRange          // 48k 会话网格；常规 480，路由/边界可短
    public let hostTime: UInt64
    public let blocks: [RecordingTrackRole: AudioPCMBlock] // mixed OR system/mic
    public let gapFramesByRole: [RecordingTrackRole: Int]
    public let isSilence: Bool
}
public final class AudioMixPump {
    public init(clock: AudioSampleClock, policy: AudioMixPolicy,
                layout: AudioOutputLayout, blockFrames: Int = 480)
    public func start()
    public func stop()
    public func updateInputs(_ inputs: AudioPumpInputs) throws
    public func nextTick(for hostTime: UInt64) throws -> AudioPumpTick?
}
public struct ResampleBatch: Sendable {
    public let blocks: [AudioPCMBlock]     // 48k grid, 480 except final
    public let correctionPPM: Double
    public let watermarkSeconds: Double
    public let consumedFrames: Int
    public let gapFrames: Int
}
public final class AudioDriftResampler {
    public init(inputSampleRate: Int, outputSampleRate: Int = 48_000,
                targetWatermarkSeconds: Double, maxCorrectionPPM: Int)
    public func process(_ block: AudioPCMBlock) throws -> ResampleBatch
    public func flush() throws -> ResampleBatch
}
public protocol AudioTickScheduling: Sendable {
    func start(_ handler: @escaping @Sendable () async -> Void) async
    func stop() async
}
public final class AudioRecordingEngine: AudioRecordingControlling {
    public init(sink: any AudioCheckpointSink, clock: AudioSampleClock,
                sources: [RecordingTrackRole: any AudioFrameSource],
                routeController: AudioRouteController,
                pump: AudioMixPump,
                scheduler: any AudioTickScheduling)
    public func start(_ configuration: AudioRecordingConfiguration) async throws
    public func stop() async -> AudioRecordingResult
    public func applyRoute(_ event: RouteEvent) async -> RouteCommitResult
    public func makeProgressStream() -> AsyncStream<RecordingProgress>
}
```

- Pump 每 tick 返回**同一范围的整组** blocks：单轨 `.mixed`；多轨 `.system`/`.microphone` 各自，不能只返回 mixed。某来源本段曾启用但当前缺失 → 原位等长静音；从未启用的 role 不建块。
- `range` 48k 会话网格；常规 480，路由/段边界可短；每 source 先重采样到 48k 再 mix/分轨，不把来源串成先后播放。`gapFramesByRole` 只随该 role 下一块；时钟不停。
- `AudioDriftResampler` 每 source 独立 FIFO/水位/滤波，±100/±300ppm、44.1/48k；ratio 变化有界，不硬丢样本；`flush()` 交尾帧；generation 替换重置 resampler 但不重置 epoch/session range。
- Engine 实际 start/stop T5 sources/controller、T4 ring/policy/factory；source factory、clock、scheduler 注入用于合成测试，不 fake engine。start 前 App 已处理权限，engine 不 requestAccess。
- stop：停 source/join callback → `finishProducing` → drain 尾帧 → sink append/commit → 进度终止 → 幂等结果。多次 start/stop/cancel 由 state/token 防重入；健康源失效另一源继续。
- `applyRoute` 用 T5 preparationID；失败旧路由不变；commit 在 atSample 与 pump tick 边界同步，旧 route 不提前混入新源。
- 进度流有界 buffer；checkpoint cadence 由 P9 组合根驱动，T6 不另建 300s timer；sink 反压有界并诊断，不无限 Task/队列。
- T6 只依赖 `AudioCheckpointSink` 协议，不命名 P3 writer/ledger。

**测试**
- 单/多轨 blocks 同 range；缺源静音；never-enabled 无轨；路由边界短 tick；不合并来源顺序。
- 44.1/48k ±100/±300ppm 水位/残差；flush 尾帧；generation 替换/retired；epoch 不回零。
- Engine start/stop 顺序、幂等、cancel/失败不漏任务；source health 失效；route token/stale；sink 反压；进度终止。
- 真实 engine + real pump/policy/ring + fake source/clock/scheduler；sink 记录 double；不启动真实采集/TCC。

**退出:** pump/resampler/engine 合成测试 GREEN；真实 A/V/设备标 `blocked`。

---

## P2 出口（主会话验收即通过）

- [ ] T4–T6 定向测试 GREEN；Core 包可编译；旧 `RecordingWriterLifecycleTests` 不回归。
- [ ] `AudioPCMBlock` 唯一块类型；无 `AudioPumpBlock`；ring 2s 精确容量、无 bitmask 扩大。
- [ ] atomic 双路径首次编译结论、TSan 是否运行、legacy fallback 结果写入报告。
- [ ] T1 两个 Minor DocC/测试完成，不改算法。
- [ ] 证据按 master §2.1；未测项/旧 OS/真实设备保持 `blocked`，最终验收前补齐。
