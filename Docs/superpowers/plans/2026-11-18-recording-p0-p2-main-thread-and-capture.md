# 录制 P0 · P2 — 主线程 I/O、SCK 复用、HUD 电平与丢帧

> **Status:** `Implemented — targeted Debug build passed; tests not run; not verified`，2026-11-18。未运行测试、未跑 GUI/真机；构建证据见 P4。
> 索引：[`2026-11-18-recording-p0.md`](./2026-11-18-recording-p0.md) · 前置：[`P1`](./2026-11-18-recording-p0-p1-lifecycle-truth.md) · 后续：[`P3`](./2026-11-18-recording-p0-p3-per-kind-settings.md)
> 设计依据：spec §5.8、§5.13、§6.3；用户已批准。实施裁决见 §2.3。

**Goal:** 把目标目录/容量探测与音频管线构造移出 MainActor；复用同一次录制的 `SCShareableContent`，排除窗口变化不再每次全量枚举；HUD 电平更新不触发布局/窗口 resize；把“采集回调 / 帧流 / writer”三层丢帧分别记录且不改变总行为；明确 checkpoint I/O 的可分离边界，保留 journal/durability（≤300 s 恢复窗口）。

**Architecture:** 只改调用位置与缓存/计数，不改录制格式、码率、分段、Seal、导出。I/O 通过有界 `Task.detached` 执行并回主线程更新 UI；引擎仍是单一 SCK stream；checkpoint 的提交语义保持“文件关闭 + 验证 + 账本 fsync 后才 committed”。

---

## 1. Owned files（精确 allowlist）

**Create**
- `App/SnapGlass/Sources/Recording/RecordingDestinationProbe.swift`
- `Packages/CaptureCore/Sources/Recording/ScreenRecordingDropAccounting.swift`

**Modify**
- `App/SnapGlass/Sources/Recording/RecordingSessionController.swift`（`prepareDestination` 异步化；`pipeline.start` await）
- `App/SnapGlass/Sources/MenuBar/CaptureViewModel.swift`（`audioPipelineFactory` 改为后台构造）
- `Packages/CaptureCore/Sources/Recording/RecordingPipelineSpaceGate.swift`（去掉工厂内同步 preflight）
- `Packages/CaptureCore/Sources/ScreenRecordingEngine.swift`（内容快照缓存 + 按需刷新）
- `Packages/CaptureCore/Sources/Recording/ScreenRecordingSessionCoordinator.swift`（三层丢帧计数）
- `App/SnapGlass/Sources/Recording/RecordingControlPanel.swift`（resize 只看布局签名）
- `Packages/CaptureCore/Sources/Recording/RecordingCheckpointWriter.swift`（**仅注释/文档**，不改提交逻辑）

**Do not touch:** 截图架（`ScreenshotShelf*`）、`RecordingPreferencesView.swift`、`SharedKit/PreferenceKeys.swift`、导出窗口、entitlements、TCC、`RecordingHUDMetrics` 的尺寸常量、分段时长。

---

## 2. 接口契约

### 2.1 App 内部

```swift
typealias AudioPipelineFactory = @Sendable (
    AudioRecordingConfiguration,
    RecordingPipelineRoots
) async throws -> RecordingSessionPipeline

struct RecordingDestinationProbe: Sendable {
    static let defaultDeadline: Duration = .seconds(5)

    /// Validates/creates the destination and checks free space on a bounded worker.
    /// Throws `RecordingDestinationError`; timeout is its own distinct case.
    static func prepare(directory: URL, isCustom: Bool, deadline: Duration) async throws

    /// Read-only capacity probe for the in-recording poll (never creates a directory).
    static func capacity(at directory: URL, deadline: Duration) async -> RecordingDestinationCapacity
}

enum RecordingDestinationCapacity: Sendable {
    case available(Int64)
    case unavailable
    case timedOut
}
```

- `RecordingSessionController.startAudio`：`pipeline = try await audioPipelineFactory(configuration, roots)`，`await` 后重新校验 `sessionGeneration` / `lastAudioResult`，不把已取消会话的 pipeline 挂到新状态上。
- `CaptureViewModel` 的闭包在专用串行 setup 队列上调用同步的 `RecordingAudioPipelineFactory.makeSpaceGated`（`Sendable` 值 `recoveryRoot`/`backlog`/`configuration`/`roots`），不使用无界的 `Task.detached`；公共工厂签名保持同步。
- `RecordingDestinationProbe` 内部只传 `URL`/`Bool`，`FileManager.default` 在队列闭包内创建；不得把非 Sendable 的 `FileManager` 跨隔离域捕获。

### 2.2 CaptureCore

```swift
public struct ScreenRecordingDropAccounting: Sendable, Hashable {
    public let captureCallbackDrops: Int64
    public let frameStreamDrops: Int64
    public let writerDrops: Int64
    public var total: Int64 { /* 饱和加，溢出取 Int64.max */ }
    public static let zero: Self
}

public struct ScreenRecordingOutcome {
    // 既有字段不变
    public let dropAccounting: ScreenRecordingDropAccounting
}
```

- `ScreenRecordingOutcome.init` 增加 `dropAccounting: ScreenRecordingDropAccounting? = nil`；为 `nil` 时用 `droppedFrameCount` 构造兼容值（capture=total，其余 0）。
- `droppedFrameCount` 继续等于 `dropAccounting.total`，旧调用点语义不变。
- `ScreenRecordingSessionCoordinator` 新增 `nonisolated func frameStreamDroppedCount() -> Int64`；帧流 `.dropped`（`yield` 驱逐旧帧）只由采集回调层计一次（通过 `ScreenVideoFrameDisposition.streamDrop`），消费侧只计“已取到但无法 append”的帧；`.terminated` 映射为 `.ignored`，不是反压丢帧。不得为计数创建 Task，避免反压。
- `ScreenRecordingEngine.stopSegmentedCapture()` 返回的仍是 capture callback 层丢帧；协调器组合三层总数。`hasWrittenVideoFrame`（writer 已接受首帧）保持为就绪唯一信号。

### 2.3 P2 实施裁决（先于代码，2026-11-18）

1. **有界执行**：目标目录 `createDirectory`/`attributesOfFileSystem` 与音频工厂构造都放到专用串行队列；同一目标路径的并发探测按 single-flight 合并，阻塞/挂起的卷不会派生更多阻塞 worker。不是 `Task.detached` 泛洪。
2. **超时语义**：新增内部 `RecordingDestinationError.timedOut`，复用现有“Could not check free space…”文案；超时绝不抛 `insufficientCapacity`，不得把慢速但正常的卷报告为已满。录制中的容量轮询超时只跳过该次轮询，不据此结束录制。
3. **探测代数**：`sourcePickerCompleted` 在 `await` 后重新检查 `currentStartAttemptIdentifier` 与 `status`；superseded 结果不得写 `activeSession`、不得进入倒计时、不得弹错误。
4. **工厂**：`RecordingAudioPipelineFactory.makeSpaceGated` 保持同步公共契约并去掉自身 `budget.preflight()`；`RecordingSessionPipeline.start` 的 `spaceGate.preflightStart()` 仍是唯一启动门禁。目录创建随工厂在 setup 队列执行，不拆分 `make`。
5. **丢帧分层**：capture callback = `yield` 返回 `.dropped` 的驱逐帧（引擎计一次）；frame stream = 帧任务已取到但因已停止/处理失败无法 append 的帧；writer = `AVAssetWriterInput` 拒绝的帧。`.terminated` 为正常收尾，不计丢帧；同一帧不得进入两层。阈值、59 分钟分段、画质不变。
6. **SCK 复用**：缓存 `SCShareableContent` 仅在缓存缺失、排除 ID 不在缓存、或 `resolve` 报 `sourceUnavailable` 时刷新；刷新后仍按 revision 丢弃过期结果。窗口来源仍跳过 filter 更新；排除窗口不得静默失效，失败记录 warning 并保留旧 filter。
7. **HUD**：resize 只由布局签名变化触发；签名排除电平与精确时长，只含时长显示位数及结构字段。文字结构变化必须触发一次 resize，不能靠裁切掩盖。
8. **checkpoint**：本阶段只加“已评估、未实施”的注释；不拆分 chunk 写入与 journal/`F_FULLFSYNC`，不改 300 s 窗口、hash 或提交顺序，不声称性能改善。


---

## 3. 实施步骤（顺序执行）

### Step 1 — 目标卷探测离开主线程

1. 新建 `RecordingDestinationProbe.prepare`：在专用串行 worker 内复用现有逻辑（custom 目录存在/可写、默认目录创建、`availableBytes`、1 GiB 下限），错误类型与文案保持 `RecordingDestinationError`；相同目录的并发探测合并为 single-flight。
2. 有界：deadline 5 s（暂定）；超时抛 `RecordingDestinationError.timedOut`（复用“Could not check free space…”文案），不新增用户可见错误类型，也不抛 `insufficientCapacity`。
3. `RecordingSessionController.prepareDestination` 被 `RecordingDestinationProbe.prepare` 取代；`sourcePickerCompleted` 在 `await` 后先检查 `currentStartAttemptIdentifier` / status，防止用户已取消仍进入倒计时。
4. 录制中的 512 MiB 轮询同样改为 `RecordingDestinationProbe.capacity`；超时跳过本次轮询，不误报“目录不可用”。
5. 保留低空间行为：开始前仍要求 1 GiB；录制中仍由 `RecordingPipelineSpaceGate` 的 512 MiB / checkpoint / seal headroom 判定；不得因为异步化放宽阈值或吞掉错误。


### Step 2 — 音频管线构造离开主线程

1. `AudioPipelineFactory` 类型改为 `async throws`（见 §2.1），控制器 `startAudio` 使用 `try await`。
2. `CaptureViewModel` 工厂闭包改为在专用串行 setup 队列调用 `makeSpaceGated`；仍返回同一个 `RecordingSessionPipeline` 实例。公共工厂保持同步签名。
3. `RecordingPipelineSpaceGate.makeSpaceGated` 删除工厂内的同步 `budget.preflight()` 与 `spacePreflightDenied` 抛出；保留 `RecordingSessionPipeline.start` 的 `spaceGate.preflightStart()` 作为唯一启动门禁（`start` 在 actor 上执行，天然离开主线程）。

4. 目录创建（`RecordingSessionPipeline.make` 内 `canonicalDirectory(create: true)`）随工厂一起在 worker 执行；不得把 `make` 再拆成两段以避免半初始化。
5. 失败路径：工厂抛错 → `startAudio` 现有 `completeAudioSession(failedAudioResult)`；不得留下半创建的 pipeline 引用。

### Step 3 — SCK 内容与 filter 复用

1. `ScreenRecordingEngine` 增加 actor 内 `private var cachedShareableContent: SCShareableContent?`，在 `startSegmented` 成功枚举后保存；启动失败/会话结束时清空。
2. `applyLatestExcludedWindowFilter` 优先用缓存内容 `resolve`；仅当满足任一条件才 `SCShareableContent.current` 刷新一次：
   - 缓存为 nil；
   - `excludedWindowIDs` 含缓存中不存在的 windowID；
   - `resolve` 抛 `sourceUnavailable`（显示器/窗口消失）。
3. 刷新后必须重新检查 `revision == exclusionRevision`，沿用现有 in-flight 循环合并多次变更；不新增第二 SCK stream、不改 `updateContentFilter` 的调用条件。
4. 窗口来源（`.window`）保持现有“跳过内容 filter 更新”的行为。
5. 失败仍记录 warning 并返回；不得因缓存导致排除窗口静默失效：无法解析时必须刷新或明确失败。

### Step 4 — 三层丢帧真实计数

1. 新建 `ScreenRecordingDropAccounting.swift`：结构体 + `ScreenRecordingDropCounter`（`NSLock`，`@unchecked Sendable`）。
2. `ScreenRecordingEngine` 的采集回调改返回 `ScreenVideoFrameDisposition`：`.enqueued` → `.accepted`；`.dropped` → `.streamDrop`（引擎计一次 capture callback 丢帧）；`.terminated` → `.ignored`（不计丢帧）。`@unknown default` → `.ignored`。
3. `ScreenRecordingSessionCoordinator.start` 的帧流计数只覆盖消费侧：事件已被取出但 `processingFailure`/停止使其无法 append 时递增 `frameStreamDroppedCount()`；不得把 `.dropped` 再计一次。
4. `stopAndSave` 组装：
   - `captureCallbackDrops = streamDroppedFrames`
   - `frameStreamDrops = frameStreamDroppedCount()`
   - `writerDrops = composition.coordinator.droppedVideoFrameCount()`
   - `dropAccounting.total` 饱和求和；`droppedFrameCount` 取 total。
5. `retryPublish` 的 outcome 同样带上计数；不得把同一帧重复计入两层。
6. 不改 writer 的丢帧策略、队列深度、帧率、码率或质量；`hasWrittenVideoFrame` 仍是就绪信号。


### Step 5 — HUD 电平不触发 resize

1. 在 `RecordingControlPanel` 增加布局签名（file-private）：
   - 非音频状态：case 本身；
   - 音频状态：case + `mode` + `expanded` + `savedCount` + `segmentIndex` + `silenceWarning` + 时长数字位数；
   - **排除** `systemLevel` / `micLevel` 与精确时长。
2. `update(state:)`：先比较旧/新布局签名，只有签名变化才 `resize(for:)`；仍更新 `model.state` 以刷新电平/计时。
3. `resize(for:)` 保留现有高度/宽度计算与四角吸附；不得引入新的尺寸常量或改变 macOS 13 布局。
4. 控制器侧 meter 更新频率维持 pipeline 的 100 ms 节流（≤15 Hz）；不得为省事把电平并入 `updateStatus` 触发布局。

### Step 6 — checkpoint I/O 边界澄清（明确 deferred，不改行为）

1. 在 `RecordingCheckpointWriter.swift` 的 `commitCheckpoint` 附近加 DocC/注释：
   - 已评估：append 的 chunk 写入与 checkpoint 的 journal 编码/`F_FULLFSYNC` 可在未来“有证据时”分离为两段；
   - 分离不得改变 committed 语义：文件关闭/验证 + 账本持久化完成前不得报告安全；
   - 恢复点窗口目标仍 ≤300 s；本 P0 **不**实施分离（deferred），不调整 `nextCheckpointSeconds` / `tailReserveSeconds`。
2. 不修改 `RecordingPipelineSpaceGate` 的 300 s 常量；不修改 journal 格式、hash、fsync 顺序。
3. 文档/注释明确：帧流、状态/进度流使用 `.bufferingNewest`，其 `yield` 可能返回 `.dropped`，是“最新值”而非无损；不得以此声称零丢失。
4. 不优化截图架（`ScreenshotShelf*` 不在 allowlist）；不改 `ShowcaseMode`/`sharingType` 语义。

### Step 7 — 静态交付核对

- `grep`：录制启动与监控路径不再直接调用同步 `attributesOfFileSystem` / `createDirectory`（`RecordingStorage.availableBytes` 仅为 P3 设置页保留，P2 不改该页）；`makeSpaceGated` 内无 `preflight()`。
- `grep`：`SCShareableContent.current` 在 `ScreenRecordingEngine` 仅出现于两条启动路径与按需刷新；刷新只由缓存缺失、排除 ID 不全或 `resolve` 失败触发，且刷新后仍校验 revision。
- `grep`：`resize(for:)` 只由布局签名变化触发；`audioMeter` 数据不进入签名。
- 列出未运行项：主线程卡顿实测、SCK 排除窗口真机行为、丢帧各层在真实掉帧下的分布、HUD 视觉回归。

---

## 4. 失败处理

| 场景 | 必须行为 |
|---|---|
| 目标卷探测超时/不可读 | 现有 `RecordingDestinationError`（超时为 `.timedOut`，不复用 `insufficientCapacity`），不启动；不创建媒体半成品 |
| setup 队列工厂抛错 | 现有失败收敛；不保留半创建的 pipeline 引用；UI 不进入 recording |
| `preflightStart` 拒绝 | `RecordingPipelineError.spacePreflightDenied` 原样上抛；低空间文案不变 |
| 缓存内容解析失败 | 刷新一次；仍失败则记录 warning 并保留旧 filter，不中断录制 |
| 排除窗口 ID 不在缓存 | 强制刷新后重建 filter；不得静默漏排除 |
| 帧流计数锁竞争 | 只增计数，不阻塞采集；溢出取 `Int64.max` |
| HUD 签名遗漏导致不 resize | 文字可换行/裁切属可见缺陷；交付说明标出，P4 只做定向编译，不跑 UI |
| checkpoint 注释被误读为已优化 | 文档明确“未实施分离”；不得写性能已改善 |

---

## 5. 验收（本阶段只到 Implemented）

- Owned files 之外无改动；`git diff --stat` 一致。
- 低空间阈值、错误文案、59 分钟分段、码率/画质无变化。
- 三层丢帧总数与旧 `droppedFrameCount` 在“只有一层丢帧”的推理下一致；无重复计数路径。
- `makeSpaceGated` 不再同步 preflight；`pipeline.start` 仍执行 preflight。
- **不运行** App、SCK、真机、长录、测试、profiling、截图架回归。
