# SnapGlass P6 — 录屏多轨分段接入 阶段实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Status:** `accepted for implementation after P3/P4`；主会话已核对两级轮转、独立视频 coordinator、单 stream/回调与恢复提交契约。本文件仅为实施输入，**不代表产品已实现或 build/test/P0/GUI/TCC/真实采集已通过**。P0-1/2/5/6/8/9 是最终验收，不是开发前置；T17 开工前按 P2/P3/P4 实际接口适配。

**Goal:** 在不重写既有像素采集/首发编码的前提下，把录屏接入一个 SCK stream、T4/T5/T6 音频泵、实际视频帧边界表、P3 检查点/Seal/ledger 与 MP4 多来源音轨，并保证视频后续只直通。

**Architecture:** 视频继续由既有 SCK 像素流首次编码；音频复用同一 stream 的系统 audio output 进入 T4 ring/T6 pump，麦克风走 T5，不建第二个 SCK stream。视频按实际帧表生成**两级**边界：恢复 chunk 约 300s（目标 290s 预备轮转）、可见 segment ≤3540s；每个恢复 chunk 一个视频 MP4（多份压缩 sample），Seal 将同一 segment 的视频 chunks 直通并封装每角色一条 AAC 音轨。旧单 MP4 路径仅开发对照，不做用户静默 fallback。
**Spec:** `Docs/superpowers/specs/2026-11-11-audio-and-segmented-recording-design.md`（修订 2.1）
**母计划:** `Docs/superpowers/plans/2026-11-11-recording-full-delivery.md`
**P3:** `Docs/superpowers/plans/2026-11-11-recording-phase-p3-segmentation-recovery.md`（accepted）
**Workspace:** `.superpowers/sdd/2026-11-11-recording-full-delivery`

## 1. 绑定约束

- **单 stream**：一个视频 session 只有一个 `SCStream`；系统音频复用其 `.audio` output；麦克风只走 T5。`ScreenAudioOutputReuse` 只 `add/removeStreamOutput(.audio)`，**不得** `startCapture`/`stopCapture` 原视频 stream，也不得新建第二个 SCK stream。
- **音频落盘**：视频模式只保存 `system`/`microphone` 的 PCM CAF；不保存 `mixed` 第三份 PCM，不生成外置伴随 `.m4a`。每角色最终只内嵌 MP4 一条 audio input。**callback 不得先构造 owned `[[Float]]`/`AudioPCMBlock` 再写 ring**：`ScreenAudioOutputReuse` 在 SCK 回调中同步借用 CMSampleBuffer（必要时预分配 scratch）直接 ring copy；只有 consumer 构造 owned block。
- **动态系统音频**：初始 `capturesAudio=false` 时切回系统声音必须走 `SCStream.updateConfiguration` 更新 audio flag，不能新建第二 stream/重启 epoch；更新失败保留旧 route，正常关闭来源后不继续无谓 audio 处理。
- **Epoch/同步**：首个有效视频 frame 确立 epoch；此前音频按 host 时标预缓冲，起录时裁去 epoch 前数据、补齐 epoch 后空缺；掉帧不重置 epoch。`RouteEvent` 只改来源，不重开视频 writer/session/epoch。
- **边界**：`ScreenBoundary` 来自实际帧 PTS/DTS/时长表；禁止 `i*3540` 或任何固定音频算式进入视频路径。可见 segment `≤3540s`；恢复 chunk 目标 `300s`、约 290s 预备轮转，实际帧边界与音频 sample 边界同一表。静态无新帧用缓存像素在该边界首次编码同步 frame，但不得解码已压缩视频再编码。**59 分钟段与约 5 分钟恢复 chunk 是两级，不得混为同一 rotation。**
- **恢复语义**：每个 closed video chunk（目标 ≤300s）必须完成文件关闭/校验/fsync、assigned hashes、journal+fsync 后才可计为恢复点；音频 checkpoint 同 P3。视频/音频 closed checkpoint 同一实际边界；真实 300s 未测不得冒充通过。
- **调度**：注入单调 tick/boundary scheduler；即使静态画面没有新 `append(frame)`，也要在 `≤300s` 触发 cached-pixel boundary、关闭旧 chunk 并开新 chunk；不能只靠 append 触发轮转。缓存像素最多 1 帧，旧/新 chunk 必须有可读时间覆盖。
- **资源有界**：T4 每路音频 ring 固定 2s；视频像素缓存最多 1 帧、`queueDepth = 3`；`isReadyForMoreMediaData == false` 时丢弃并计数，不无限 `Task`/不无限追帧。
- **掉帧/来源失效/格式变更**：在已落盘时间轴显式记 gap/原因；格式变化不静默重解释 sample，必要时在真实帧边界关闭当前 chunk 并以兼容格式重启；不能把“没有视频帧即删所有材料”套到纯音频/仍有音频材料的段。
- **GOP**：唯一秒定义 `RecordingConfiguration.maximumKeyFrameIntervalSeconds = 1`；`videoOutputSettings(frameRate:)` 转成 `AVVideoMaxKeyFrameIntervalDurationKey`（秒）或 `Int(round(fps*seconds))` 帧。禁止把 `AVVideoMaxKeyFrameIntervalKey = 1` 当 1 秒（会退化为每帧关键帧）。
- **直通**：Seal/拼接/裁剪视频只读压缩 sample；`AVAssetReaderTrackOutput(outputSettings:nil)` + `AVAssetWriterInput(outputSettings:nil, sourceFormatHint:)`；保留 PTS/DTS/解码顺序/B 帧重排/有效范围，不重编码视频。
- **共存**：T13 的运行时窗口排除、录制中截图/滚动截图、截图架可见性不回退；不重启视频/音频时间轴。录制 UI 与截图架仍排除入镜。
- **旧路径**：`stop`/`retryPublish`/Quit 保存语义与旧录屏兼容；旧单 MP4 仅开发开关，用户运行不得静默回退到无分段/无恢复路径。

## 2. Task 17 串行可编译单元（一个 implementer 完成，独立 review）

| 单元 | 交付 | 依赖 |
|---|---|---|
| 17A 配置/GOP | `maximumKeyFrameIntervalSeconds` 唯一秒定义；video settings 只产一个 GOP key；旧配置默认不变 | 无 |
| 17B 写入层抽取/视频 bridge | 从 `ScreenRecordingEngine` 抽出旧 `RecordingWriterPipeline`；新增 `ScreenVideoWriterBridge`（单 video input、首帧 sync、有界队列）；音频输入只在 17C Seal 层，不在 chunk 阶段重复编码 | 17A |
| 17C 分段/音频 bridge/Seal | `VideoSegmentPlanner` 两级实际帧边界；`ScreenSegmentCoordinator`（独立于 P3 `SegmentedWriterCoordinator`，管 video/audio 300s closed checkpoint + 3540s segment）；`ScreenAudioBridge` 同一 stream 系统音频到 T4 ring、T5 mic；`ScreenSegmentSealService` 压缩视频直通 + AAC 音轨封装 | 17B + P3 T7/T8/T9 |
| 17D App controller/兼容 | Core `ScreenRecordingSessionCoordinator` + App `ScreenRecordingPipelineAdapter`/纯 decision mapper；stop/retry/Quit、P13 排除、旧路径回归；`project.yml` 精确测试源与四语言 | 17C + P4 |

- 17A–17D 每单元结束可编译/定向测试；不得拆给多个 implementer；单文件 `<750`、硬上限 `<1200`；`ScreenRecordingEngine.swift` 现 732 行，17B 先抽旧 writer，只移动既有行为。

## 3. 精确 Files

**17A**
- Modify: `Packages/CaptureCore/Sources/RecordingConfiguration.swift`
- Modify: `Packages/CaptureCore/Tests/CaptureCoreTests/RecordingConfigurationTests.swift`

**17B**
- Create: `Packages/CaptureCore/Sources/Recording/ScreenRecordingWriterPipeline.swift`（承载抽出的旧 `RecordingWriterPipeline`/finalization/relay）
- Create: `Packages/CaptureCore/Sources/Recording/ScreenVideoWriterBridge.swift`
- Modify: `Packages/CaptureCore/Sources/ScreenRecordingEngine.swift`（改用抽出类型；单 stream/旧 API 不变）
- Modify: `Packages/CaptureCore/Tests/CaptureCoreTests/RecordingWriterPipelineTests.swift`
- Modify: `Packages/CaptureCore/Tests/CaptureCoreTests/RecordingWriterLifecycleTests.swift`
- Create: `Packages/CaptureCore/Tests/CaptureCoreTests/ScreenVideoWriterBridgeTests.swift`

**17C**
- Create: `Packages/CaptureCore/Sources/Recording/VideoSegmentPlanner.swift`
- Create: `Packages/CaptureCore/Sources/Recording/ScreenSegmentCoordinator.swift`（独立 coordinator，不改 P3 `SegmentedWriterCoordinator` 音频契约）
- Create: `Packages/CaptureCore/Sources/Recording/ScreenAudioBridge.swift`
- Create: `Packages/CaptureCore/Sources/Recording/ScreenSegmentSealService.swift`
- Modify: `Packages/CaptureCore/Sources/Recording/RecordingSessionLedger.swift`（仅加 `commitScreenCheckpoint` 视频 journal 记录；音频行为不变）
- Modify: `Packages/CaptureCore/Sources/Recording/AudioTrackEncoder.swift`（仅加 AAC stream sink/适配；不产临时 m4a）
- Create: `Packages/CaptureCore/Tests/CaptureCoreTests/VideoSegmentPlannerTests.swift`
- Create: `Packages/CaptureCore/Tests/CaptureCoreTests/ScreenSegmentCoordinatorTests.swift`
- Create: `Packages/CaptureCore/Tests/CaptureCoreTests/ScreenAudioBridgeTests.swift`
- Create: `Packages/CaptureCore/Tests/CaptureCoreTests/ScreenSegmentSealServiceTests.swift`
- Create: `Packages/CaptureCore/Tests/CaptureCoreTests/ScreenCheckpointLedgerTests.swift`
- Create: `Packages/CaptureCore/Tests/CaptureCoreTests/AudioAACStreamTests.swift`

**17D**
- Create: `Packages/CaptureCore/Sources/Recording/ScreenRecordingSessionCoordinator.swift`
- Create: `App/SnapGlass/Sources/Recording/ScreenRecordingPipelineAdapter.swift`
- Create: `App/SnapGlass/Sources/Recording/ScreenRecordingPipelineDecision.swift`（纯 decision mapper）
- Modify: `App/SnapGlass/Sources/Recording/RecordingSessionController.swift`
- Modify: `App/SnapGlass/Sources/Recording/RecordingQuitFlow.swift`
- Modify: `project.yml`（`WindowLifecycleStateTests` sources 精确加入 `ScreenRecordingPipelineAdapter.swift`、`ScreenRecordingPipelineDecision.swift`，复用 CaptureCore dependency；随后 `xcodegen generate`）
- Modify: `App/SnapGlass/Resources/en.lproj/Localizable.strings`
- Modify: `App/SnapGlass/Resources/zh-Hans.lproj/Localizable.strings`
- Modify: `App/SnapGlass/Resources/ja.lproj/Localizable.strings`
- Modify: `App/SnapGlass/Resources/ko.lproj/Localizable.strings`
- Create: `App/SnapGlass/Tests/ScreenRecordingPipelineAdapterTests.swift`

> App 主 target 通过 `App/SnapGlass/Sources` 自动纳入新源；`WindowLifecycleStateTests` **不会自动收 App 被测源**，17D 必须在 `project.yml` sources 精确加入 `ScreenRecordingPipelineAdapter.swift`、`ScreenRecordingPipelineDecision.swift`，复用 CaptureCore dependency，随后 `xcodegen generate`；不手改 `.xcodeproj`。四语言 strings 已列入 17D Files。

## 4. 接口与行为

### 17A 配置/GOP

`RecordingConfiguration.maximumKeyFrameIntervalSeconds` 默认 1；`RecordingWriterSettings.videoOutputSettings(...)` 只产一个 GOP key（duration=1s 或 `Int(round(fps*1))` frames，不是 frames=1）。30fps 产生 1s/30 帧；硬件不遵循留给 P0-5 记录，不假称达标。

### 17B 视频 writer bridge

```swift
public struct VideoFrameSample: Sendable, Hashable {
    public let index: Int64
    public let presentationTime: CMTime
    public let decodeTime: CMTime
    public let duration: CMTime
    public let isSync: Bool
}
public final class ScreenVideoWriterBridge {
    public init(destinationURL: URL, configuration: RecordingConfiguration,
                dimensions: CGSize) throws
    public func append(video sampleBuffer: CMSampleBuffer) throws
    public func finish() async throws -> VideoChunkResult
}
```
- 只写视频 chunk；音频从 T7/P3 CAF 在 17C Seal 阶段编码，避免 chunk 阶段重复 AAC/外置 m4a。
- `append(video:)` 只把已采集/首次编码 sample 追加；首帧必须建立 `startSession`/sync；`isReadyForMoreMediaData == false` 时有界丢帧计数，不无限 `Task`。
- `ScreenRecordingWriterPipeline` 抽取旧 writer；`ScreenRecordingEngine` 只保留 stream/lifecycle/transaction 编排，旧 `start/stop/retryPublish` 公开签名不变。

### 17C 分段/音频/Seal

```swift
public struct ScreenBoundary: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case chunk, segment }
    public let kind: Kind
    public let segmentIndex: Int; public let chunkIndex: Int
    public let startFrameIndex: Int64; public let endFrameIndex: Int64
    public let startTime: CMTime; public let endTime: CMTime
    public let firstFrameIsSync: Bool
}
public struct ScreenCheckpointCommit: Sendable, Hashable {
    public let segmentIndex: Int; public let chunkIndex: Int
    public let videoURL: URL; public let videoRange: SampleRange
    public let audio: CheckpointCommit?   // video-only nil
    public let contentHashes: [String: String]
}
public struct ScreenAudioCheckpointDTO: Codable, Sendable, Hashable { public let checkpointID: UUID; public let segmentIndex: Int; public let startSample: Int64; public let sampleCount: Int64; public let trackFiles: [String: String]; public let committedAt: Date }
public final class VideoSegmentPlanner {
    public init(maximumSegmentDuration: TimeInterval = 3540,
                checkpointTarget: TimeInterval = 300, frameRate: Int)
    public func append(_ frame: VideoFrameSample) -> ScreenBoundaryDecision
    public func tick(hostTime: UInt64) -> ScreenBoundaryDecision
    public func boundaryTable() -> [ScreenBoundary]
}
public enum ScreenBoundaryDecision: Sendable, Equatable {
    case keepCurrent
    case closeChunk(ScreenBoundary)
    case closeSegment(ScreenBoundary)
    case cachedChunkBoundary(ScreenBoundary)
}
public final class ScreenAudioBridge {
    public init(systemRing: AudioSourceRingBuffer,
                microphoneRing: AudioSourceRingBuffer?, hostTicksPerSecond: UInt64)
    public func appendSystem(sampleBuffer: CMSampleBuffer) throws // callback: direct ring copy
    public func appendSystem(_ block: AudioPCMBlock) throws        // consumer/test only
    public func appendMicrophone(_ block: AudioPCMBlock) throws
}
public final class ScreenAudioOutputReuse: NSObject, SCStreamOutput {
    public func attach(to stream: SCStream) throws // only add .audio
    public func detach(from stream: SCStream)      // only remove .audio
}
public struct ScreenCheckpointRecord: Codable, Sendable, Hashable {
    public let segmentIndex: Int; public let chunkIndex: Int
    public let videoURL: URL; public let videoRange: RecordingSampleRange
    public let audioCheckpoint: ScreenAudioCheckpointDTO?   // video-only nil
    public let coverage: RecordingSegmentCoverage
    public let contentHashes: [String: String]
}
public actor ScreenSegmentCoordinator: AudioCheckpointSink {
    public init(planner: VideoSegmentPlanner,
                videoWriterFactory: @escaping @Sendable (ScreenBoundary) throws -> ScreenVideoWriterBridge,
                audioSinkFactory: @escaping @Sendable (ScreenBoundary) throws -> any SegmentCheckpointSink,
                ledger: RecordingSessionLedger, seal: ScreenSegmentSealService)
    public func append(_ block: AudioPCMBlock) async throws // stable facade -> current sink
    public func commitCheckpoint() async throws -> CheckpointCommit
    public func append(video sampleBuffer: CMSampleBuffer, at hostTime: UInt64) async throws
    public func tick(hostTime: UInt64) async throws
    public func closeCheckpoint() async throws -> ScreenCheckpointCommit
    public func closeSegment() async throws -> SealedSegment
    public func screenCheckpoints(sessionID: UUID) async throws -> [ScreenCheckpointRecord]
    public func commitScreenCheckpoint(_ record: ScreenCheckpointRecord) async throws
}
public actor ScreenSegmentSealService {
    public init(fileManager: FileManager = .default,
                publicationHooks: [any SegmentPublicationHooking] = [])
    public func seal(_ checkpoints: [ScreenCheckpointRecord],
                     audio: RecordingSegmentCheckpointBundle?, segmentID: UUID,
                     context: RecordingSealContext) async throws -> SealedSegment
}
```
- `ScreenSegmentCoordinator` 独立于 P3 `SegmentedWriterCoordinator`：`ScreenBoundary.kind == .chunk` 时关闭当前 video MP4 + 同一实际帧边界的 audio checkpoint，校验/fsync/ledger journal 后产出 `ScreenCheckpointCommit`；`.segment` 时把该 segment 的多个 closed chunks 交 Seal，可见 segment ≤3540s。P3 音频 coordinator 契约不变。
- `ScreenCheckpointRecord`（T17 owner）持久化 videoURL/range/optional audio checkpoint/coverage/hashes；T17 通过 additive `RecordingSessionLedger.commitScreenCheckpoint` 写、`screenCheckpoints(sessionID:)` 读回；恢复 readback 不依赖 `@testable`。`ScreenCheckpointCommit.audio`/Seal audio bundle 对 video-only 为 nil；`SealedSegment.videoURL`/`videoTrackIndex` optional，音频-only nil，不伪造 video/mixed 角色。
- `VideoSegmentPlanner` 只用实际 frame 表 + 注入单调 tick；`ScreenBoundaryDecision { keepCurrent, closeChunk, closeSegment, cachedChunkBoundary }`；静态无新帧由 `tick` 在 ≤300s 触发缓存像素边界，不能只靠 `append(frame)`；close 旧/开新均有可读时间覆盖。
- `ScreenAudioOutputReuse` 只挂/摘 `.audio`，不启动/停止原 stream；callback 直接 CMSampleBuffer 借用/scratch → T4 ring，不构造 owned block；consumer 才构造 `AudioPCMBlock`。system 走 T4 ring/T6 pump，mic 走 T5；`RouteEvent` 不新建 writer/session/epoch。初始 `capturesAudio=false` 切回系统声音用 `SCStream.updateConfiguration` 更新 audio flag，失败保留旧 route。
- `ScreenSegmentSealService` 读每个 closed chunk 的压缩视频 sample（`outputSettings:nil`，sourceFormatHint）；同一 segment 的多 chunk 直通成 ≤3540s MP4；每角色一条 AAC audio input；音轨 map/priming/trim/有效范围写入 manifest/metadata；视频 payload SHA-256 前后一致。Stage 写 T3 transaction；`publicationHooks` 只在 init 注入（生产由 T17 factory 传 T9 hook），`seal` 无重复 hook 参数；验证后 hook journal+fsync 成功才 publish，失败保留 stage。
- `AudioTrackEncoder` 只允许加 `AudioAACStreamSink` 小适配（PCM→AAC `CMSampleBuffer` 供 MP4 input），不得先写临时 m4a 再读回；同一段同一角色一个连续 AAC 上下文；纯音频单轨既有路径回归。
- 掉帧/来源失效/格式变更只在已落盘时间轴标 gap；不能把“没有视频帧即删所有材料”套到纯音频/仍有音频材料的段。零有效视频帧不发布空 MP4，但保留音频/恢复材料并说明原因。

### 17D App controller/兼容

```swift
public struct ScreenRecordingStartConfiguration: Sendable, Hashable {
    public let source: RecordingSource
    public let video: RecordingConfiguration
    public let audio: AudioRecordingConfiguration
    public let destinationDirectory: URL
    public let excludedWindowIDs: Set<CGWindowID>
    public init(source: RecordingSource, video: RecordingConfiguration,
                audio: AudioRecordingConfiguration, destinationDirectory: URL,
                excludedWindowIDs: Set<CGWindowID>)
}
public struct ScreenSegmentComposition: Sendable {
    public let coordinator: ScreenSegmentCoordinator
    public let audioSink: any AudioCheckpointSink & Sendable   // stable facade, not current segment sink
    public init(coordinator: ScreenSegmentCoordinator, audioSink: any AudioCheckpointSink & Sendable)
}
public actor ScreenRecordingSessionCoordinator {
    public init(engine: ScreenRecordingEngine,
                segmentCompositionFactory: @escaping @Sendable (ScreenRecordingStartConfiguration) throws -> ScreenSegmentComposition,
                audioEngineFactory: @escaping @Sendable (AudioRecordingConfiguration, any AudioCheckpointSink & Sendable, AudioSampleClock) throws -> any AudioRecordingControlling,
                audio: ScreenAudioBridge)
    public func start(_ configuration: ScreenRecordingStartConfiguration,
                      onFailure: @escaping @Sendable (String) -> Void) async throws
    public func stopAndSave() async throws -> ScreenRecordingOutcome
    public func retryPublish() async throws -> URL
}
```
- `start(configuration)` 才用 config 建 `ScreenSegmentComposition`（T7 coordinator + **stable** `audioSink`）和首帧后的 T6 engine；`segmentCompositionFactory` 不依赖 hidden box；`audioEngineFactory` 显式接 `(AudioRecordingConfiguration, any AudioCheckpointSink & Sendable, AudioSampleClock)`。配置/路径未知时不得先建 sink/pipeline；engine 一生只绑定 composition.audioSink（生产为 ScreenSegmentCoordinator actor 的 stable facade），不在每段重建/重置 epoch。
- **audio 抢先/实际边界**：T6 的 `AudioPCMBlock` 可能先于视频实际边界到达。`ScreenSegmentCoordinator` 作为 stable facade 只在当前 T7 sink 追加；若 block 跨已知 `ScreenBoundary`，按该实际 sample boundary 拆块后分别 append；边界尚未由视频确认时最多暂存一个 checkpoint/2s 的 pending audio，超界 fail-closed，不无限缓存、不以猜测 endSample 写错段。实际边界早于 T7 固定 `segmentBoundary`（最终短段）时，只调用 T7 `finishSegmentBundle` 关闭实际较早尾端；不改 T7 音频契约，由 T17 adapter 负责 `audioSinkFactory` 轮转。
- 首个有效视频 frame 后创建 `AudioSampleClock` 并用 factory 建 T6 `AudioRecordingEngine`（实际 init 绑定 T4 ring/T5/T7 sink）；此前音频预缓冲裁/补；`audio` 只负责 SCK 系统 audio 入 ring。
- `ScreenRecordingPipelineDecision` 保留纯 decision mapper（start/stop/retry/quit），App adapter 只做 controller/quit 与 coordinator 的局部适配；P4 实际签名不同时允许在这两个 App 文件内适配，不因可预测变化停等。
- App adapter 把现有 `RecordingSessionController`/`RecordingQuitFlow` 的 stop/retry/Quit 接到新 coordinator；旧录屏 outcome 保持可用；无新用户静默 fallback。
- P13 的运行时窗口排除/截图共存不回退；录制中截图、滚动截图、截图架显示与排除仍走既有 registry；不重启时间轴。
- 四语言只补实际新增文案；无新增则 localization 检查仍必须通过。

## 5. 阶段出口
- [ ] 17A–17D 串行编译/定向测试 GREEN；旧 `RecordingWriterLifecycleTests` 不回归；known-fail 按基线披露。
- [ ] 单 stream、单系统音频 output、mic T5、`RouteEvent` 不重开视频/epoch；视频 MP4 每角色一条 audio input，无外置 m4a/mixed 第三份 PCM。
- [ ] 实际帧边界表 ≤3540s、恢复 chunk 目标 300s（约 290s 预轮转）、偏差目标 ≤1 frame；静态边界由 tick 触发首帧 sync；GOP 1s 不是每帧；无 `i*3540` 视频路径。
- [ ] Seal/拼接/裁剪 payload SHA-256 一致、`outputSettings:nil` + sourceFormatHint、PTS/DTS/B 保留；多音轨 map/priming/trim 可读回。
- [ ] 17D stop/retry/Quit、P13 排除/截图共存、旧录屏回归通过；App build/localization/lint 通过。
- [ ] 真实 SCK/TCC/设备/长时/旧 OS/第三方播放器未跑项明确 `not-run`/`blocked`；P0-1/2/5/6/8/9 通过前不声称最终验收。

## 6. 停止条件
- 需要改 spec/母计划/P2/P3 `SegmentedWriterCoordinator` 音频契约、T3/P5 文件、allowlist 外文件 → 停，写 `review/p6-preparation-notes.md` 或任务报告。P3 ledger 仅允许本文件列出的 additive `commitScreenCheckpoint`，不得改音频行为。
- 需要真实 SCK/桌面/TCC/权限/签名/提交 → 停；P0 未跑不构成开发阻塞。
- 出现 0 tests、旧 writer 回归洗绿、视频重编码、单 stream 被破坏、未测真机写成通过 → 停。
