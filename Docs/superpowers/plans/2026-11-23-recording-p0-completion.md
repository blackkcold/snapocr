# 录制 P0 收尾 — 五阶段执行计划（UX 优先 / 长期稳定）

> **Status:** `Planned`，2026-11-23。逐阶段实施，每阶段完成并由主代理验收后才进入下一阶段。
> Worktree：`/Users/11169285/.local/share/opencode/worktree/5d0345d699d913b55a21fac44cccbd69a3acb4ec/recording-p0-completion`
> Branch：`fix/recording-p0-completion`（基于 `84e4a6a` + 已迁移的 62 项 P0 未提交改动）
> 基线：`xcodebuild ... SnapGlass build` 通过（arm64 Debug，2026-11-23，见第 8 节）。

## 0. 问题与证据

| 证据 | 事实 | 结论 |
|---|---|---|
| `~/Movies/SnapGlass/Recordings/.SnapGlassSessions/762aadf7-…/segment-00000000/mixed-0001.caf` | 22.02s，48 kHz / 2ch / Int16，96.6% 非零 | 采集链路正常，失败在 App 层状态推进/呈现 |
| 同一会话 `journal.json` | 只有 `register`，无 checkpoint、无 segment | **不是异常**：音频 checkpoint 间隔为 290s，segment 只在封包时产生；22s 会话本就不会有。孤儿文件的真正原因是会话未走完停止流程 |
| 系统日志 10:00:05 | `SnapGlass: hang likely: start` | 主线程被判定卡死 |
| 活动监视器 10:00:07 | SIGKILL | 用户强制退出 |
| App 最后一条日志 09:59:45.820 | 之后无主线程活动 | 卡死发生在启动后约 5 秒 |
| 安装包 `/Applications/SnapGlass.app` | 1.6.0 build 3，二进制 11-18 18:52，晚于源码 18:36 | 不是旧二进制 |
| HUD 路径 | `present`/`update` 同步走 `resize → targetSize → measuredSize → NSHostingController.sizeThatFits`；一次启动序列实测 14 次 `sizeThatFits`，每次重建 rootView；测量离屏且包含 macOS 26 Liquid Glass、spinner、两条 `GeometryReader` 电平条与隐式动画 | 启动路径上唯一新增的主线程同步重活 |
| 冻结帧 | 用户看到的是 `.awaitingFirstAudioSample`；下一帧 `.audioRecording` 第一次带两条电平条测量 | 卡点最可能在首样本提升为 `.recording` 的呈现/测量，而不是 `.starting` 那次 present |
| 截止时间 | 15s 首样本、取消/停止均为 `Task { @MainActor }`；30s 启动看门狗在 `pipeline.start()` 返回时（`:735`）已取消 | 主线程卡死后全部失效，且无任何非 MainActor 兜底 |
| 屏幕会话 | 两个 `chunk-00000000.mp4` 均为 0 字节，`segments: []`；该文件名全仓只有一个生成点，且只有通过 pixel-buffer/PTS 校验的 sync 帧才能到达 | **不是 TCC、也不是 SCK 无帧**：帧已到达，断点在 `AVAssetWriter` 侧（`startWriting` 失败 / `isReadyForMoreMediaData` 持续 false / 进程被杀未收尾） |
| 恢复 | `.SnapGlassSessions` 启动不扫描；`recoverableSessions` 零调用；`recoveryDetails` 只看 checkpoint/intent/closed，**register-only 会话返回 `[]`**，且完全忽略 `screenCheckpoints` | 恢复不只是没接线：现有 API 对今天的 4 个孤儿会话全部返回空，必须新增“从磁盘媒体反推”的目录扫描 |
| 就绪 | `publishProgress` 取 `max(facts.sampleEnd, engineProgress.capturedSamples)`；`facts.sampleEnd` 包含 writer 合成静音与零帧 | 机制上可被纯静音伪造就绪；当前被 290s 间隔与 15s 截止偶然挡住，缩短 checkpoint 会立即暴露 |
| 诊断 | 录制路径无 `Logger`；`RecordingSignposts` 已存在但当天窗口无 signpost 记录 | 事后定位只能靠产物反推 |

**根因判断：** 音频采集正常；主线程在 HUD 呈现/测量路径上阻塞，导致 15s/30s 有界保护与取消都无法执行。修复必须同时做到：呈现不阻塞主线程、生命周期不依赖主线程、失败可恢复、就绪只信真实样本。

## 1. 设计原则

1. **UX 不降级**：HUD 首帧立即出现；尺寸稳定，不随秒数跳动；动效、玻璃材质、无障碍（减少动态/透明度）保留。
2. **主线程只做轻量呈现**：任何测量、等待、超时、停止都不允许在状态变更的同步栈里执行。
3. **失败必须可见且可恢复**：超时要有明确文案与动作；崩溃后重启能看到并恢复会话。
4. **就绪定义唯一**：真实采集样本/真实写入帧，合成静音不算。
5. **可诊断**：关键状态与耗时用隐私安全日志/signpost 记录，出问题不再靠猜。
6. **最小侵入**：不重写 CaptureCore 采集内核；复用现有 actor、状态机和测试。

## 2. 阶段地图

| 阶段 | 主题 | 主要落点 | 验收门槛 |
|---|---|---|---|
| S1 | HUD 呈现与测量移出同步路径 | `RecordingControlPanel.swift`、`RecordingSessionController+HUD.swift`、`RecordingSessionController.swift`、`RecordingHUDPresentation.swift` | 单测绿 + 构建绿 + 手动录音 HUD 正常 |
| T0 | Agent 测试通道（独立实例 / 真实路径 / 无 GUI 点击） | 新增 `App/SnapGlass/Sources/Agent/*`、`scripts/agent-test.sh`、启动短路 | `audio-smoke` 与 `stall-main` 可一键跑通并出报告 |
| S2 | 生命周期迁出 MainActor | 新增 `RecordingSettlementSupervisor.swift`、控制器接入、`RecordingReadiness.swift` 复用 | 单测绿 + `stall-main` 证明主线程阻塞时仍落盘 |
| S4 | 就绪真实性 | `RecordingSessionPipeline.swift`、`AudioRecordingEngine.swift`、相关测试 | 合成静音不得进入 `.recording` |
| S3 | 恢复落地 + checkpoint 间隔 | 新增 `RecordingRecoveryCatalog`（CaptureCore）+ `RecordingRecoveryService`（App）、启动接入、列表展示、checkpoint 常量 | 单测绿 + 重启后恢复今天的 22s 会话 |
| S5 | 录屏 writer 断点 / TCC 独立核查 | `ScreenVideoWriterBridge.swift`、`ScreenSegmentCoordinator.swift`、权限预检与文案 | 真实录屏产出可播放 MP4 |

执行顺序固定 **S1 → S2 → S4 → S3 → S5**。`RecordingSessionController.swift` 串行修改，不并行。

> **顺序调整原因（2026-11-23 复核）：** checkpoint 从 290s 缩短到 5–10s 后，`facts.sampleEnd` 的合成静音会在 15s 首样本截止之内产生 checkpoint，从而把纯静音会话伪造成 `.recording`。因此必须先落 S4（就绪只信真实样本），再缩短 checkpoint。S5 依赖 S2 的 supervisor 执行首帧截止，排在其后。

## 3. S1 — HUD 呈现与测量移出同步路径

**目标：** 状态变更只登记“待呈现”，应用状态时**不做任何测量**；尺寸来自预计算缓存或一次性的静态测量视图；数字字段按最坏宽度，尺寸稳定不抖动；正式内容保留玻璃、电平与动效。

**复核结论（2026-11-23，交叉核查）：**
- 测量全部在主线程同步执行；一次启动序列实测 **14 次** `sizeThatFits`，`present` 单次最多 4 次，且每次都替换 `measurementController.rootView`。
- 测量离屏且渲染完整实时视图；macOS 26 + Xcode 26.6 下走 Liquid Glass 分支；`.audioRecording` 首次测量同时包含两条 `GeometryReader` 电平条、Capsule 玻璃与隐式动画。
- 用户看到“Waiting for the first audio sample”说明 `.starting` 已画出；下一帧 `.audioRecording` 从未画出 → 卡点最可能在首样本提升时的第一次测量/呈现。
- 未发现尺寸反馈闭环；但 `resize` 在 guard 之前无条件 `targetSize`、`present` 内重复 `resize`、每次测量换 rootView，构成显著放大。
- 启动路径其它同步重活均已排除（目录探测/流水线工厂在专用队列，无 security-scoped bookmark，音频路径不涉及 SCShareableContent，权限在 start 前完成）。

**Owned files：**
- `App/SnapGlass/Sources/Recording/RecordingControlPanel.swift`
- `App/SnapGlass/Sources/Recording/RecordingHUDMeasurement.swift`（新增：纯签名/缓存/最坏宽度策略）
- `App/SnapGlass/Sources/Recording/RecordingSessionController.swift`（仅 `makeControlPanel` 预计算与 `updateStatus` 调用点）
- `App/SnapGlass/Sources/Recording/RecordingSessionController+HUD.swift`（去掉重复 present）
- `App/SnapGlass/Tests/RecordingHUDMeasurementTests.swift`（新增）
- `project.yml`（把新文件加入 App 与 `WindowLifecycleStateTests` 源清单）

**实现步骤：**
1. **同步路径零测量**：`present/update` 统一进 `enqueue(state:)`，每回合最多 flush 一次；`apply(state)` 只用缓存尺寸或保守 fallback 立即改 frame，绝不调用 `sizeThatFits`。
2. **按需测量，不在创建时批量测**：面板创建时不测量，用保守 fallback 尺寸立即呈现（`.preparing`/`.starting`/`.saving` 用固定尺寸；`.audioRecording`/`.failure` 用 `bounds.minWidth × 预期高度`）。每次 flush 最多测 **1 个签名**，在 `Task.yield()` 后的下一主循环回合执行；命中率靠签名设计保证。首次出现允许一次 0.12s 尺寸微调，但内容与按钮在 fallback 尺寸下必须已完整可见、可点。
3. **静态测量视图**：`RecordingControlPanelMeasureView` 与正式内容共享文本/间距/控件尺寸，但用纯色背景、固定 16×16 spinner 占位、固定宽度电平条，移除 `glassEffect`、`GeometryReader`、`.animation`。正式视图不变。
4. **未知签名兜底**：缓存未命中时先用 `bounds.minWidth × 预期高度` 呈现，再在下一回合用静态视图测量并按 0.12s 动画微调；同一签名只测一次。
5. **稳定宽度**：签名不含时长/电平；计时、计数、百分比按最坏位数（`99:59:59`、`999`、`100%`）测量，并使用等宽数字，秒数跳动不触发 resize。
6. **幂等与去重**：`apply` 用 `isApplying` 防重入；`present` 只在不可见时 `orderFrontRegardless`；删除 `markAudioPipelineStarted` 与 `handleAudioReadiness` 中重复的 `presentAudioRecordingHUD()`。
7. **有界测量**：静态测量前后取 `ContinuousClock`；超过 50 ms 记录 fault 并保留 fallback 尺寸，不重试。
8. **诊断**：新增 `Logger(subsystem: "com.snapglass", category: "recording.hud")`，只记录状态枚举、签名哈希、耗时毫秒、缓存命中；不记录路径/文件名/电平。
9. **测试**：签名稳定性（时长/电平变化不改变签名）、最坏宽度、缓存命中、未知签名 fallback、语言/展开态产生不同签名。

**非目标：** 不改 HUD 视觉、不改尺寸上限、不改四语言文案、不改录制状态机。

**验收：**
- `RecordingHUDMeasurementTests` 全绿；`WindowLifecycleStateTests` 全绿；App 构建 `** BUILD SUCCEEDED **`。
- 复核 diff：正式视图无视觉改动，仅测量路径与调用顺序变化。
- 真实录音时 HUD 立即出现、10s 内无尺寸跳动；日志可见每次 apply 的缓存命中与耗时。

## 4. S2 — 生命周期迁出 MainActor

**目标：** 首样本 15s、首帧 5s 的截止、就绪判定与停止/落盘不再依赖 MainActor；即使 HUD 卡住，也能在后台完成停止并把结果交回 UI。就绪判定改为单一来源（supervisor），不再由 UI 进度消费者决定。

**复核结论（2026-11-23）：**
- 当前 15s 截止是 `Task { @MainActor }`，在 `markAudioPipelineStarted` 的同步 present **之后**才创建；主线程卡住时任务根本不会创建。
- 30s 启动看门狗在 `pipeline.start()` 返回时（`:735`）已取消，不覆盖首样本阶段。
- 取消/停止全部是 MainActor 同步方法或 `Task { @MainActor }`；`RecordingReadiness.awaitBounded` 虽在非主隔离睡眠，但结果消费方仍需 MainActor，等于无兜底。
- `RecordingSessionPipeline.stop()` 本身幂等（`lastResult` / `stopTask`），可在 supervisor 中安全调用。

**Owned files：**
- 新增 `App/SnapGlass/Sources/Recording/RecordingSettlementSupervisor.swift`
- 新增 `App/SnapGlass/Tests/RecordingSettlementSupervisorTests.swift`
- `App/SnapGlass/Sources/Recording/RecordingSessionController.swift`（arm/settle/disarm 接线）
- `App/SnapGlass/Sources/Recording/RecordingSessionController+HUD.swift`（事件消费，去掉 MainActor 截止）
- `project.yml`（App 与测试目标源清单）

**设计：**
```swift
enum RecordingSettlement: Sendable {
    case audio(AudioRecordingResult)
    case screen(ScreenRecordingOutcome)
    case failed(kind: RecordingKind, message: String)
}

actor RecordingSettlementSupervisor {
    struct Ticket: Sendable, Hashable { let id: UUID; let generation: UUID }
    enum Readiness: Sendable {
        case audioProgress(AsyncStream<RecordingProgress>)
        case poll(@Sendable () async -> Bool)
    }
    enum Event: Sendable {
        case mediaStarted
        case settled(RecordingSettlement, reason: Reason) // .deadline / .requested
    }
    init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) })
    func arm(generation: UUID,
             deadline: Duration,
             readiness: Readiness,
             stop: @escaping @Sendable () async -> RecordingSettlement) -> Ticket
    func settle(ticket: Ticket, reason: Reason) async -> RecordingSettlement
    func disarm(ticket: Ticket)
    nonisolated var events: AsyncStream<Event> { get }
}
```

**实现步骤：**
1. **arm 先于 UI**：`startAudio` 中 `pipeline.start()` 返回后，先 `supervisor.arm(...)`，再 `markAudioPipelineStarted()` 呈现。屏幕同理：先 arm 首帧，再 `updateStatus(.starting)`。
2. **就绪在 supervisor 内判定**：音频消费自己的 progress stream（`capturedSamples > 0`）；屏幕每 100ms `await hasWrittenVideoFrame()`。观察到真实媒体后发 `.mediaStarted` 并取消截止。
3. **截止即落盘**：到期在 actor 内直接 `await stop()`（`pipeline.stop()` / `adapter.stopAndSave()`），完成后发 `.settled(..., reason: .deadline)`；不等待 UI。
4. **停止单一入口**：`stopAudio()`/屏幕停止改为 `await supervisor.settle(...)`；supervisor 内 `settleTask` 保证只执行一次；UI 只消费结果事件并完成状态收尾。
5. **去重**：删除 `startAudioReadinessDeadline` 与 `startScreenReadinessObservation` 的 MainActor 轮询；`handleAudioReadiness` 由 `.mediaStarted` 触发。
6. **过期保护**：Ticket 带 generation；事件消费前校验 `generation == sessionGeneration`；新会话开始时 disarm 旧 ticket。
7. **失败文案**：`.settled(.failed, reason: .deadline)` 与 `.settled(.audio, reason: .deadline)` 都走现有失败面板，文案说明“未收到音频样本/视频帧，已尝试保存可恢复部分”。
8. **测试**：注入即时 sleep；验证到期只 stop 一次、`.mediaStarted` 取消截止、主动 settle 与到期竞争只产生一个终态、过期 ticket 不执行、stop 抛错映射为 `.failed`、不消费事件流也能完成 stop。

**非目标：** 不改采集内核、不改 `RecordingStartOwnership`/`RecordingRequestIdentity` 语义、不改现有失败面板视觉。

**验收：**
- supervisor 单测全绿；`WindowLifecycleStateTests` 全绿；App 构建成功。
- 代码审计确认：15s/5s 截止与 stop 调用链上没有任何 `@MainActor` 依赖。
- 手动：录音 2s 停止 → 列表可见可播放；首样本超时（测试注入 1s）→ 失败面板出现且文件已落盘。

## 5. S3 — 恢复落地（真实可用）+ checkpoint 间隔

> 执行顺序：**S4 之后**。checkpoint 缩短会让合成静音在 15s 截止内产生 checkpoint，必须先由 S4 收紧就绪判定。

**目标：** App 启动时扫描 `.SnapGlassSessions`，把**磁盘上已有媒体但 journal 不完整**的孤儿会话变成列表可见、可播放、可导出的条目；音频 checkpoint 间隔从 290s 缩短到 10s；设置页承诺与实际一致。

**复核结论（2026-11-23，交叉核查）：**
- 启动路径完全没有扫描（`App.swift:165-185` 只做 updater 与权限检查）。
- `recoverableSessions` 零调用，且对 register-only 会话返回 `[]`：`recoveryDetails` 只取 checkpoint/intent/closed 的 segmentIndex，三个集合全空；`screenCheckpoints` 完全未参与。
- `recoveryDetails()` 是 internal、`allEntries` 是 private，App 无法自行扫描。
- `RecordingAudioPipelineFactory.make` 内部 `let sessionID = UUID()`，无法接管已有会话；`resumePublish` 要求 journal 已有 `publishIntent`。
- 今天的 4 个孤儿会话（2 个 22s/4.5MB CAF、2 个 0 字节 MP4）在现有两套 API 里**全部不可见**。
- checkpoint 定时器 290s 在 `RecordingSessionPipeline.swift:1189` 硬编码；无任何测试断言它。`RecordingSegmentPolicy.maximumCheckpointAge = 300` 与录屏 300s 有测试覆盖，**不要改**。
- 设置页 `RecordingPreferencesView.swift:178` 的 `"Always On"` 是硬编码英文，未进本地化。

**Owned files：**
- 新增 `Packages/CaptureCore/Sources/Recording/RecordingRecoveryCatalog.swift`（公开扫描 + 时长探测）
- 新增 `Packages/CaptureCore/Sources/Recording/RecordingRecoveryAdoption.swift`（公开的“收编进索引”实现，或作为 ledger 的公开静态方法）
- 新增 `App/SnapGlass/Sources/Recording/RecordingRecoveryService.swift`
- `App/SnapGlass/Sources/App.swift`（启动扫描接线）
- `App/SnapGlass/Sources/MenuBar/CaptureViewModel+Recording.swift`（转发扫描/恢复/删除）
- `App/SnapGlass/Sources/Recording/RecordingExportViewModel.swift`（可恢复列表数据与动作）
- `App/SnapGlass/Sources/Recording/RecordingExportView.swift`（可恢复分组 UI）
- `App/SnapGlass/Sources/Windows/RecordingPreferencesView.swift` + 四语言 `Localizable.strings`
- `Packages/CaptureCore/Sources/Recording/RecordingSessionPipeline.swift`（仅 checkpoint 间隔常量）
- 测试：`Packages/CaptureCore/Tests/CaptureCoreTests/RecordingRecoveryCatalogTests.swift`、`RecordingRecoveryAdoptionTests.swift`、`App/SnapGlass/Tests/RecordingRecoveryServiceTests.swift`
- `project.yml`（新文件加入 App 与测试目标）

**设计：**

1. **`RecordingRecoveryCatalog`（CaptureCore，纯扫描，不写盘）**
```swift
public struct RecoverableRecording: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable { case audio, screen }
    public enum Condition: Sendable, Hashable { case interrupted, unregistered }
    public let id: UUID            // sessionID
    public let kind: Kind
    public let condition: Condition
    public let createdAt: Date
    public let duration: TimeInterval
    public let materials: [URL]    // 非空、可播放
    public let discardedByteCount: Int64
}

public enum RecordingRecoveryCatalog {
    public static func scan(recordingRoot: URL, fileManager: FileManager = .default) async -> [RecoverableRecording]
}
```
- 枚举 `<root>/.SnapGlassSessions/<UUID>/`；单会话失败不影响其它会话（逐会话 `Result`，不抛整体错误）。
- 素材：`segment-*/` 下非空 `*.caf` / `*.mp4` / `*.mov`；0 字节计入 `discardedByteCount` 但不作为素材。
- kind：优先 journal `register` 的 kind，其次按扩展名；混合存在时以音频优先（音频可播）。
- createdAt：journal 首行时间戳，缺失则目录创建时间。
- duration：音频用 `AudioFile` 估算时长，视频用 `AVURLAsset` 加载时长；取不到为 0，UI 不显示时长而不是显示 0。
- condition：journal 有 checkpoint/intent 但无 published → `.interrupted`；只有 register → `.unregistered`。
- **不调用** `recoverableSessions`（它对孤儿返回空），但保留它给“有 checkpoint 的正常中断”场景；catalog 必须覆盖两者，去重按 sessionID。

2. **收编（adopt）**
- 目标：产出一条与正常完成录制**同构**的 index 记录，引用现有媒体文件（不复制、不转码），使 `publishedSessions`、`isCompleted`、预览、导出全部按现有路径工作。
- 实现前先读 `RecordingSessionRecord` / `PublishedSegment` / `RecordingSessionLedger` 的字段与索引写入路径，复用 `rebuildIndex`/`snapshot` 的写入原语；不新增第二套索引格式。
- 若现有模型无法表达“单段、直接引用 CAF”，最小扩展是给 segment 增加可选 `materialURL`（Codable 向后兼容，旧记录无该字段仍可解码），并在预览/导出侧优先使用它。
- adopt 必须幂等：重复恢复同一 sessionID 不产生重复条目。
- 音频 CAF 必须能被预览与导出：验收时真实播放并导出一个 m4a。

3. **App 侧 `RecordingRecoveryService`（actor）**
- `scan()`：对 `RecordingExportRoots.current(in: .standard)` 的每个根调用 catalog，合并去重。
- `recover(_:)`：adopt → 返回新记录；失败保留原目录并回报可读错误。
- `discard(_:)`：`FileManager.trashItem`（可恢复），不直接 `removeItem`。
- 启动接线：`App.swift` 在 `checkPermissionsOnLaunch()` 之后 `Task { await viewModel.scanRecoverableRecordings() }`；扫描失败只记日志，不弹窗打扰启动。

4. **列表 UX**
- `RecordingExportView` 在正常列表上方增加“可恢复”分组，仅当非空时显示；分组标题带数量。
- 行内容：kind 图标 + “未完成的录音/录屏” + 时长（有则显示）+ 时间；主按钮“保存到列表”（recover），次按钮“删除”（destructive，二次确认）。
- 恢复成功后行移入正常列表并显示一次性成功提示；删除后行消失。
- 空态、加载态、错误态都要有；四语言键齐全，`scripts/check-localization.sh` 通过。
- 0 字节 MP4 会话不显示为可恢复（无内容可救），其目录在 `discard` 时才清理；扫描阶段不自动删任何文件。

5. **checkpoint 间隔**
- `RecordingSessionPipeline.swift:1189`：290 → 10，提取为 `private static let checkpointIntervalSeconds: Int64 = 10`（或等价常量），并加注释说明与 `RecordingSegmentPolicy.maximumCheckpointAge = 300` 的关系（恢复点更密，封包目标不变）。
- 不改 `RecordingSegmentPolicy.maximumCheckpointAge`、`VideoSegmentPlanner` 默认值、`RecordingPipelineSpaceGate`。
- 新增测试：断言常量 ≤ 15；用注入的 checkpoint 触发器验证 22s 会话至少产生 1 个 checkpoint（若 pipeline 无法注入时钟，则退化为常量断言 + 真实录音验收，报告中注明）。

6. **设置页**
- `"Always On"` 改为本地化值（四语言），语义为“启动时自动检查未完成录制”。
- 恢复能力必须真实存在才保留该承诺；本阶段完成后承诺成立。

**非目标：** 不自动恢复（必须用户确认）；不上传、不转码；不改录屏 writer（S5）；不改正常录制路径的 index 格式语义。

**验收：**
- CaptureCore 测试：catalog 对 4 类 fixture（register-only 有 CAF、有 checkpoint、0 字节 MP4、损坏 journal）返回正确结果；adopt 幂等且 `publishedSessions` 可见；discard 走 Trash。
- App 测试：`RecordingRecoveryService` 扫描/恢复/删除的状态流转。
- 真实验收：用今天的 `762aadf7…`（22.02s CAF）验证启动后出现在“可恢复”，点击保存后进入正常列表、可播放、可导出 m4a；`4f699dea…`（0 字节）不显示为可恢复。
- `scripts/check-localization.sh` 通过；App 构建成功；`xcodegen generate` 后工程可编译。
- 证据：扫描输出（sessionID/时长/素材路径）、恢复后 index 片段、导出文件 `afinfo`。

## 6. S4 — 就绪真实性

**目标：** 只有真实采集样本才能把音频会话推进到 `.recording`；checkpoint 覆盖范围与 writer 合成的静音不得伪造就绪。

**Owned files：**
- `Packages/CaptureCore/Sources/Recording/RecordingSessionPipeline.swift`
- `Packages/CaptureCore/Sources/Audio/AudioRecordingEngine.swift`（仅在需要明确真实计数来源时）
- `Packages/CaptureCore/Tests/CaptureCoreTests/…`（对应测试）
- `App/SnapGlass/Sources/Recording/RecordingSessionController+HUD.swift`（就绪判定若需同步收紧）

**实现步骤：**
1. `publishProgress` 的 `capturedSamples` 改为只取引擎真实采集帧计数；删除 `max(facts.sampleEnd, …)`。
2. `elapsedSeconds` 保持现状（时钟/合成静音只影响时长，不影响 readiness）。
3. 就绪判定（`.mediaStarted` / `handleAudioReadiness`）只认 `capturedSamples > 0`。
4. 新增回归测试：ledger `sampleEnd > 0` 但引擎真实计数为 0 → 不得就绪；真实追加后 → 就绪；`elapsedSeconds` 仍推进。
5. 屏幕侧核对 `hasWrittenVideoFrame` 是否存在合成来源；若有，同样收紧。

**验收：** 目标测试通过；真实录音仍能正常进入 `.recording` 并保存。

## 7. S5 — 录屏 writer 断点 / TCC 独立核查

**目标：** 0 字节 MP4 的根因收敛到 writer 侧并修掉；权限被拒时立即给出可操作提示；真实录屏产出可播放文件；失败/取消不留 0 字节垃圾。

**复核结论（2026-11-23，交叉核查）：**
- `chunk-00000000.mp4` 全仓只有一个生成点（`ScreenRecordingSessionCoordinator.swift:600`），且只有通过 pixel-buffer/PTS 校验的 **sync 帧**才能到达 `openVideoChunk`。因此 **TCC 被拒或“SCK 没给帧”均被产物本身否证**。
- 断点在 writer 三处：`ScreenVideoWriterBridge.swift:228` `startWriting()` 返回 false；`:242-245` `isReadyForMoreMediaData` 持续 false 导致每个 sync 帧被 drop；或进程在卡死时被杀、writer 未 `finishWriting`/`cancelWriting`，文件停在 0 字节。
- 当前实现**静默 drop sync 帧**，这是最危险的路径：首帧被 drop 后 `hasWrittenVideoFrame` 永远为 false，UI 只能等到 5s 超时。
- 首帧 5s 截止在本工作树是未跟踪的新文件，11/18 的两次会话发生时不一定存在，不能用它反推当时 UI。

**Owned files：**
- `Packages/CaptureCore/Sources/Recording/ScreenVideoWriterBridge.swift`
- `Packages/CaptureCore/Sources/Recording/ScreenSegmentCoordinator.swift`
- `Packages/CaptureCore/Sources/Recording/ScreenRecordingSessionCoordinator.swift`
- `App/SnapGlass/Sources/Recording/ScreenRecordingPipelineAdapter.swift` / `RecordingSessionController.swift`（仅权限预检与失败分类接线）
- 四语言 `Localizable.strings`（仅新增权限/失败文案）
- 测试：writer 分支单测、权限决策测试

**实现步骤：**
1. **sync 帧不得 drop**：`isReadyForMoreMediaData == false` 时，对 sync 帧做有界等待（最多 250ms，分片轮询或 `requestMediaDataWhenReady`），仍不 ready 则抛 `writerNotReady`；非 sync 帧可 drop 但计入计数器。
2. **startWriting 失败立即抛**：返回 false 时读取 `writer.error` 并抛具体错误，同时删除 0 字节文件。
3. **append 失败清理**：`videoInput.append` 抛错 → `cancelWriting()` + 删除当前 chunk 文件，避免留下 0 字节孤儿。
4. **诊断计数器**：`ScreenWriterDiagnostics { startWritingResult, syncDropCount, nonSyncDropCount, appendFailureCount, lastErrorDescription }`，通过 coordinator 暴露给 App 的失败文案；新增 `Logger(subsystem: "com.snapglass", category: "screen.writer")`，只记录计数与错误码，不记录窗口标题/内容。
5. **权限预检**：`startScreen` 前 `CGPreflightScreenCaptureAccess()`；false 时 `CGRequestScreenCaptureAccess()` 一次并直接失败，文案指向“系统设置 → 隐私与安全性 → 屏幕录制”，不再进入“等待首帧”。麦克风同理核对。
6. **首帧截止**：保持 5s，由 S2 supervisor 执行；超时按 D 的三分类给出不同文案（writer 失败 / 未收到帧 / writer 未接受首帧）。
7. **停止收尾**：`finishWriting` 完成后才发布 segment；失败则保留可恢复材料并明确告知，不静默丢。
8. **测试**：writer 分支（not ready 的 sync 帧有界等待、startWriting false、append 抛错后清理）、权限决策映射；真实录屏 10s 验收。
9. **真实验收**：10s 屏幕录制 → 停止 → `chunk-*.mp4` > 0 字节、`afinfo`/`ffprobe` 可读、列表可见可播放；记录 diagnostics 数值。

**非目标：** 不改 SCK 采集配置、不改屏幕 HUD 视觉、不改音频路径。

**验收：**
- writer 单测全绿；App 构建成功。
- 真实录屏产出可播放 MP4，列表可见；0 字节文件不再残留。
- TCC 拒绝场景（可临时用未授权状态或单元测试模拟）文案正确、不进入等待首帧。

## 8. 构建与验证命令

```bash
# 构建（arm64 Debug，复用 SourcePackages）
DERIVED=/private/var/folders/ks/flqyrh0j5wvf2t7v4s7lcnz0b5tfzv/T/opencode/completion-derived
SOURCES=/Users/11169285/.local/share/opencode/worktree/5d0345d699d913b55a21fac44cccbd69a3acb4ec/recording-p0/.context/recording-p0/SourcePackages
SPARKLE="$SOURCES/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
xcodebuild -project SnapGlass.xcodeproj -scheme SnapGlass -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED" -clonedSourcePackagesDirPath "$SOURCES" \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  SPARKLE_FRAMEWORK_PATH="$SPARKLE" build

# App 单测
xcodebuild -project SnapGlass.xcodeproj -scheme WindowLifecycleStateTests \
  -destination 'platform=macOS,arch=arm64' test

# 包测试
scripts/test.sh
```

**基线证据：** `completion-baseline-build.log`，`** BUILD SUCCEEDED **`，`error:` 0。

## 9. 阶段交付记录（实施时填写）

| 阶段 | 状态 | 证据 |
|---|---|---|
| S1 | Pending | — |
| S2 | Done（2026-11-23） | `RecordingSettlementSupervisor` + 8 项单测；`WindowLifecycleStateTests` 129/129 绿（跳过既有崩溃的 `RecordingWindowExclusionRegistryTests`）；T0 五场景全绿，`deadline-during-stall` 报告 `supervisor={settledAtMs:2536, settlementDuringStall:true, reason:"deadline", stopCalls:1}`、`timeline{stallStart:409, supervisorSettled:2536, stallEnd:6410}`、`mainThread.maxStallMs:5960`、产物 38 608 B / 2.25 s（`.build/agent-runs/20261123T125059-55392/report.json`） |
| S3 | Done（2026-11-23） | `RecordingRecoveryCatalog`（纯扫描）+ `RecordingRecoveryAdoption`（原地收编）+ `RecordingRecoveryService`（actor）；索引新增可选 `adopted` journal 行与 `PublishedSegment.materialURL`（旧记录无该键仍解码）；checkpoint `10s`；App 启动扫描 + 录制窗口“可恢复”分组；`recover-orphan` 用今天 22.02s CAF 副本跑通 scan→adopt→列表可见→导出 m4a（`afinfo` 22.020000 s），0 字节 MP4 不出现、连续 recover 两次仍 1 条；`audio-25s` journal 实测 3 个 checkpoint（`.build/agent-runs/20261123T131356-21101`、`20261123T131708-25464`）。详见下文 S3 审计结论 |
| S4 | Done（2026-11-23） | `publishProgress` 只取 `engineProgress?.capturedSamples`，`max(facts.sampleEnd, …)` 全仓 0 处；新增 `RecordingReadinessTruthTests`（ledger `sampleEnd=240000`、引擎计数 0 → `capturedSamples=0` 且 `elapsed≥4.5`；引擎报 4 800 后才 >0）+ 3 项 pump 源计数测试 + supervisor `Checkpoint coverage never starts media`；CaptureCore 650/650、App 130/130；T0 五场景全绿（`audio-smoke` 500 ms / 59 498 B、`audio-10s` 367 ms / 172 842 B、`audio-smoke-default-source` 681 ms / 42 015 B、`stall-main` 542 ms / 108 977 B、`deadline-during-stall` `settledAtMs:2511 / settlementDuringStall:true / stopCalls:1 / becameRecording:false`） |
| S5 | Done（2026-11-23） | writer 三处加固 + 4 个真实断点齐修（writer 静默 drop sync 帧 / `startWriting` 失败不留文件 / append 拒绝删 chunk / **stop 自锁** / **sealer 跨实例 track** / **静态屏时长塌缩**）；**录屏 + 系统音频**另修 3 处：环缓冲 source 的 `commitReconfiguration` 恒 false（每次录屏 `initial route commit failed`）、sealer 多输入交错死锁、音频 flush actor 重入导致范围断裂；音频失败改为非致命（视频继续、提示“系统音频未能录制”）；`screen-10s` 2 029 847 B / 10.43 s；`screen-10s-audio` 2 323 894 B / 9.78 s（**1 video + 1 audio 48 kHz**，`audioTrackPresent=true`、`audioStartFailed=false`）；`screen-10s-audio-degraded` 2 633 183 B / 10.13 s（audio 注入失败仍完整，提示正确）；`screen-permission-denied` 立即失败无残留；CaptureCore 673/673、App 141/141；四语言通过 |

### S2 审计结论（2026-11-23）

**15s 首样本截止不在 MainActor 上：**
- `App/SnapGlass/Sources/Recording/RecordingSessionController.swift:799-814`：`pipeline.start()` 返回后先 `await settlementSupervisor.arm(...)`，再 `markAudioPipelineStarted()` 呈现。
- `App/SnapGlass/Sources/Recording/RecordingSettlementSupervisor.swift:189-197`：截止睡眠 `try await self.sleep(deadline)`（默认 `Task.sleep`），到期 `deadlineReached`（`:315`）→ `beginSettlement`（`:322`）。
- 文件内 `@MainActor` 计数：`RecordingSettlementSupervisor.swift` = 0。

**5s 首帧截止不在 MainActor 上：**
- `RecordingSessionController.swift:1661-1682`：`adapter.start()` 返回后先 arm（`deadline: RecordingReadiness.firstVideoFrameDeadline`），再 `updateStatus(.starting)`。
- 就绪探测为 actor 调用：`coordinator.hasWrittenVideoFrame()`（`:1665`），100 ms 间隔在 supervisor 内。

**stop 链不在 MainActor 上：**
- `RecordingSettlementSupervisor.swift:342` 的 `Task.detached` 执行 stop 闭包；音频走 `pipeline.stop()`（`RecordingSessionPipeline` actor，`RecordingSessionController.swift:811`），屏幕走 `coordinator.stopAndSave()`（`ScreenRecordingSessionCoordinator` actor，`:1668`）。
- `@MainActor` 计数：`RecordingSessionPipeline.swift` = 0、`ScreenRecordingSessionCoordinator.swift` = 0、`AudioRecordingEngine.swift` = 0。
- 事件消费 `handleSettlementEvent`（`RecordingSessionController.swift`）在 MainActor 只做呈现；停止与落盘在事件产生前已完成（`deadline-during-stall`：结算 2536 ms，主线程 6410 ms 才恢复，随后 8419 ms 才收到停止请求）。

**与方案草图的差异（均为收紧语义）：**
- `arm(...)` 增加 `kind:`，用于失败映射与事件路由；`settle(...)` 返回 `RecordingSettlement?`，`nil` 表示 ticket 已过期且**没有执行任何 stop**（避免把过期会话误呈现为失败）。
- `Event` 携带 `generation` 与 `kind`，主线程消费前校验 generation。
- 新增 `Diagnostics`（单调时钟 `armedAt/mediaStartedAt/settleStartedAt/settledAt`、`stopCalls`），供 T0 报告证明“结算发生在主线程阻塞期间”，不依赖被测代码自证。

### S4 审计结论（2026-11-23）

**就绪数据流（修改前后）：**
- 修改前：`RecordingSessionPipeline.publishProgress()` 的 `capturedSamples = max(facts.sampleEnd, engineProgress?.capturedSamples ?? 0)`。`facts.sampleEnd` 来自 ledger 已提交 checkpoint 的覆盖末端（`RecordingSessionLedger.progressFacts()`），包含 writer 合成静音，因此纯静音会话也能让 supervisor 看到 `capturedSamples > 0`。
- 修改后：`capturedSamples = engineProgress?.capturedSamples ?? 0`（`RecordingSessionPipeline.swift:1246`）。唯一来源是 `AudioRecordingEngine.publishProgress()` 读取的 `AudioMixPump.capturedSourceFrameCount`（`AudioRecordingEngine.swift:848`、`AudioMixPump.swift:415`），后者只在 `readMoreLocked`/`drainPipelineLocked` 真正从 ring 读到源帧时累加（`AudioMixPump.swift:541`、`:834`），合成静音与纯时钟推进不加。
- `elapsedSeconds` 保持 `max(ledger sampleEnd/48000, engine elapsed, 墙钟)`（`:1232-1236`）；`savedSegments`、`checkpointAgeSeconds`、电平字段不变。时长仍可被 checkpoint 推进，但 readiness 不受影响。

**消费方审计（全仓）：**
- `RecordingSettlementSupervisor.swift:278`：唯一 readiness 判定，`progress.capturedSamples > 0`；未读 `facts.sampleEnd`，无 max。
- `RecordingSessionController+HUD.swift`：`handleAudioReadiness` 仅由 supervisor `.mediaStarted` 触发（`RecordingSessionController.swift:1157-1160`）；HUD 只用 `elapsedSeconds/savedSegments/电平`，不用 `capturedSamples` 决定状态。
- `max(facts.sampleEnd` 全仓 0 处；`facts.sampleEnd` 仅剩 `elapsedSeconds` 一处。
- 屏幕侧：`hasWrittenVideoFrame` 只由 `AVAssetWriterInput.append` 返回 true 置位（`ScreenVideoWriterBridge.swift:246`，`ScreenSegmentCoordinator.swift:234/241/252`），无合成/队列接受来源，无需收紧。

**新增测试：**
- `Packages/CaptureCore/Tests/CaptureCoreTests/RecordingReadinessTruthTests.swift`：`checkpointCoverageNeverBecomesCapturedSamples` — ledger 写入 240 000 帧合成静音（`sampleEnd=240000`）、引擎计数 0 时，progress 必须 `capturedSamples=0` 且 `elapsedSeconds≥4.5`；引擎报 4 800 后 `capturedSamples` 才为 4 800。已反向验证：临时恢复 `max(...)` 时该测试 5 项断言失败。
- `AudioMixPumpTests`：`capturedSourceFramesCountMicrophoneFramesNotClockSilence`、`capturedSourceFramesCountSystemFramesNotClockSilence`、`capturedSourceFramesCountBothRoles`（麦克风、系统、`systemAndMicrophone` 都计数；无源帧的后续 tick 不增加）。
- `App/SnapGlass/Tests/RecordingSettlementSupervisorTests.swift`：`Checkpoint coverage never starts media`（elapsed 5 s、checkpointAge 3 s、savedSegments 1、电平 0.9 但 `capturedSamples=0` → 无 `.mediaStarted`；截止仍以 `.deadline` 结算一次）。

**T0 证据（隔离实例、`--agent-root`、未触碰用户 App/库）：**
| 场景 | readiness | supervisor | 产物 |
|---|---|---|---|
| audio-smoke | `becameRecording:true, firstRealSampleAfterMs:500` | `mediaStarted:true, reason:"requested", settledAtMs:3658, stopCalls:1` | 59 498 B / 3.43 s（`.build/agent-runs/20261123T125852-64768`） |
| audio-10s | `becameRecording:true, firstRealSampleAfterMs:367` | `mediaStarted:true, settledAtMs:10551, stopCalls:1` | 172 842 B / 10.36 s（`20261123T125721-62736`） |
| audio-smoke-default-source | `becameRecording:true, firstRealSampleAfterMs:681` | `mediaStarted:true, settledAtMs:3891, stopCalls:1` | 42 015 B / 3.66 s（`20261123T125807-63683`） |
| stall-main | `becameRecording:true, firstRealSampleAfterMs:542` | `mediaStarted:true, settledAtMs:6714, stopCalls:1`, `mainThread.maxStallMs:5977` | 108 977 B / 6.50 s（`20261123T125818-64012`） |
| deadline-during-stall | `becameRecording:false` | `mediaStarted:false, reason:"deadline", settledAtMs:2511, settlementDuringStall:true, stopCalls:1` | 39 704 B / 2.31 s（`20261123T125833-64374`） |

所有产物 `afinfo` 均为 `m4af`/AAC；`audio-smoke-default-source` 的首次失败是显示器休眠（`startAudio ... no display available for audio stream`），`caffeinate -d -u` 唤醒后重跑通过，与 S1/T0 已知边界一致。

**已知问题：** `scripts/agent-test.sh` 在 `SNAPGLASS_AGENT_SPM_CACHE` 未设置时，bash 3.2 下 `"${build_args[@]}"` 触发 `unbound variable`（`set -u`）。**S3 已修**为 `"${build_args[@]+"${build_args[@]}"}"`，不设该变量也能一条命令跑通（本次全部 agent 运行均未设置该变量）。

### S3 审计结论（2026-11-23）

**根因复核（与计划一致）：** 启动路径没有扫描；`recoverableSessions` 对 register-only 会话返回空；`recoveryDetails()`/`allEntries` 不对外；`RecordingAudioPipelineFactory.make` 内部生成新 sessionID。今天 4 个孤儿（2 个 22.02/23.28s CAF、2 个 0 字节 MP4）在原 API 下全部不可见。

**索引格式（最小扩展，不新增第二套格式）：**
- `PublishedSegment` 新增 `materialURL: URL?`（`RecordingSessionPipeline.swift`）。Codable 合成器对 Optional 使用 `decodeIfPresent`，`nil` 不编码，因此**旧索引/journal 记录无该键仍原样解码**；测试 `adoptedSegmentDecodesWithoutTheOptionalField` 直接断言编码后无该键、解码为 `nil`。
- journal 新增 payload kind `adopted`，payload 复用 `PublishedSegment`；`LedgerJournalPayload.adopted` 为 Optional，旧的 `register`/`checkpoint`/`published` 行解码后为 `nil`。schemaVersion 保持 1（纯增量字段）。
- `RecordingIndexRecord.currentSchemaVersion` 不变（2）：新增字段不影响读写；索引仍是可重建缓存，journal 仍是权威。

**收编（adopt）语义：**
- `RecordingSessionLedger.adoptPublishedSegment(_:)`：校验媒体全部位于 session root 内且为普通文件，追加 `adopted` 行并 `persistIndex()`；`currentRecord()` 优先使用 `state.adopted[id]`，段状态为 `.published`，因此 `publishedSessions`/`isCompleted`/预览/导出全部走既有路径。
- **不复制、不转码**：`files[role]` 存相对路径，`materialURL` 指向原文件；测试断言原 CAF 仍在且 index 的 `materialURL` 等于它。
- **幂等**：同 index 已有 adopted 段时直接返回原段并只刷新索引缓存；agent 场景连续 `recover` 两次，`publishedAfterRecovery=1`、`idempotent=true`，journal 字节不变。
- **checkpoint 会话**：复用 `state.segmentIDs[index]` 作为 adopted 段 ID，避免与既有 checkpoint 段身份冲突；checkpoint 文件保留在盘上，不被 GC（`collectableCheckpointFiles` 只处理 `state.published`）。
- 预览：`previewURLs(for: .segment)` 对 adopted 段返回原媒体（不经 publish intent）。
- 导出：新增 `ExportAudioSource.recoveredMedia`，planner 用文件自身格式（不可解码即 `missingSource`），exporter 用 `AVAudioFile` 帧数作 range；VM 在 `segment.materialURL != nil` 时选择该 source。原 `.publishedMedia`（需 sealed metadata）路径未改。

**catalog（纯扫描，不写盘）：** `RecordingRecoveryCatalog.scan(recordingRoot:)` 枚举 `.SnapGlassSessions/<UUID>/`，逐会话 `Result`：
- register-only 有媒体 → `.unregistered`；有 checkpoint/intent/closed 但无 published → `.interrupted`；有 `published`/`adopted` → 跳过（不再列出）。
- 0 字节媒体不计入 `materials`（会话若只有 0 字节媒体则整条不返回；`discardedByteCount` 记不可用字节）。
- journal 损坏/未来 schema → 只跳过该会话（测试用 1 好 1 坏断言好会话仍返回、坏会话不崩）。
- 时长用 `AVAudioFile`（音频帧数/采样率）与 `AVURLAsset.load(.duration)`（视频），取不到返回 0（UI 隐藏时长）。
- 测试断言扫描前后 journal 字节不变、媒体文件仍存在。

**App 侧：** `RecordingRecoveryService`（actor）`scan` 对 `RecordingExportRoots.current` 每个根合并去重；`recover` 失败保留原目录并抛可读错误；`discard` 走 `FileManager.trashItem`。启动接线 `App.swift` 在 `checkPermissionsOnLaunch()` 之后 `Task { await viewModel.scanRecoverableRecordingsAtLaunch() }`，失败只记日志。录制窗口顶部“可恢复”分组：仅非空显示、带数量、kind 图标、未完成文案、时长（有则显示）、时间、主按钮“保存到列表”、次按钮“删除”（`confirmationDialog` 二次确认，文案说明移入废纸篓）；空/加载/错误态齐备；恢复成功后移入正常列表并给 5 秒一次性提示；四语言键齐全，`scripts/check-localization.sh` 通过。

**checkpoint：** `RecordingSessionPipeline.checkpointIntervalSeconds = 10`（public，含与 `RecordingSegmentPolicy.maximumCheckpointAge = 300` 的关系注释）。未改 300s 段策略、`VideoSegmentPlanner`、`RecordingPipelineSpaceGate`（测试 `segmentPolicyKeepsItsOwnCheckpointAge` 断言 300）。

**测试与证据：**
| 项 | 命令 | 结果 |
|---|---|---|
| CaptureCore 新增单测 | `swift test --package-path Packages/CaptureCore --filter "RecordingRecovery\|RecordingCheckpointInterval"` | 13/13 绿 |
| CaptureCore 全量（串行） | `swift test --package-path Packages/CaptureCore --no-parallel` | 663/663 绿，33.5 s |
| App 单测 | `xcodebuild … -scheme WindowLifecycleStateTests test -skip-testing:…RecordingWindowExclusionRegistryTests` | 136/136 绿，`** TEST SUCCEEDED **` |
| 构建 | `xcodebuild … -scheme SnapGlass build` | `** BUILD SUCCEEDED **` |
| 本地化 | `bash scripts/check-localization.sh` | 通过 |
| SwiftLint（新增文件） | `swiftlint lint --config .swiftlint.yml <8 个新增文件>` | 0 violations，0 serious |

**`recover-orphan`（22.02 s 副本，seed = 762aadf7 + 2 个 0 字节 MP4）：** `scripts/agent-test.sh scripts/agent-scenarios/recover-orphan.json --agent-seed .build/agent-seeds/s3-orphans-22s --keep` → exit 0，`report.json`：
```json
"recovery": {
  "adopted": 1, "catalogDuration": 22.02, "exportedDuration": 22.02,
  "exportedPath": ".../20261123T131356-21101/recovered-762aadf7-00.m4a",
  "idempotent": true, "publishedAfterRecovery": 1,
  "recoverable": [{ "condition": "unregistered", "durationSec": 22.02,
    "id": "762aadf7-b629-4feb-86ad-e9df4a8d6087", "kind": "audio",
    "materials": [".../762aadf7-…/segment-00000000/mixed-0001.caf"] }],
  "scanned": 1, "zeroByteSessions": 2, "zeroByteVisible": false
}
```
导出 `afinfo`：`m4af`、2 ch / 48000 Hz / AAC、`estimated duration: 22.020000 sec`、1056960 valid frames —— 与 catalog 探测偏差 0.00 s。0 字节会话目录与 journal 未被修改（仍为 1 行 register、0 字节 MP4）。journal 追加的是 `{"kind":"adopted", … "materialURL":"…/mixed-0001.caf", "sampleCount":1056960}`，索引条目含同一 `materialURL`。

**四孤儿全量副本（`s3-orphans-1`）另一次运行：** `scanned=2`（22.02 s 与 23.28 s），`zeroByteSessions=2`、`zeroByteVisible=false`，导出 23.28 s 可播（`.build/agent-runs/20261123T131339-20471`）。

**T0 回归（全部 `Microphone`/默认音源，独立实例、`--agent-root`、用户库 `unchanged`）：**
| 场景 | 结果 |
|---|---|
| `audio-smoke` | exit 0 |
| `audio-10s` | exit 0 |
| `audio-smoke-default-source` | 首次失败为显示器休眠（`no display available for audio stream`，harness 显式失败）；`caffeinate -d -u` 唤醒后 exit 0 |
| `stall-main` | 首次 `maxStallMs=93`（探针在 `probe.stop()` 前未落地 6 s 采样的既有测量竞态，timeline 仍显示 `stallStart 473 → stallEnd 6475`）；重跑 exit 0，`maxStallMs=5969`、`probeSamples=12`、产物 6.51 s |
| `deadline-during-stall` | exit 0 |
| `audio-25s` | exit 0，`journal.checkpointCount=3`、`checkpointIntervalSeconds=10`，产物 25.54 s |

**已知问题 / 未完成项：**
- **S4 单测在全量并行下 flake**：`RecordingReadinessTruthTests.checkpointCoverageNeverBecomesCapturedSamples` 在默认并行全量（66 suites）下确定性失败（`sawRealCount`，约 12.2 s 超时），而：单独运行通过（1.8 s）、`--no-parallel` 全量通过（663/663）、把 checkpoint 常量临时改回 290 后全量**仍同样失败**（对照组），并行子集（该 suite + 本次新增 suite）14/14 通过。结论：**与 S3 改动无关的既有并行时序敏感测试**，未改其断言（按约束不修改 S4 文件）。建议 S4 所有者把该测试的 `waitFor` 上界从 10 s 放宽或在串行套件中运行。
- 屏幕孤儿收编路径已实现（视频作为 `videoURL` + `files["mixed"]`），但今天没有非零 MP4 可验收，S5 前不承诺屏幕导出可用。
- 一个 segment 有多个 checkpoint 分块时，收编只引用最长的一个 CAF（其余分块保留在盘上，不删除），属部分恢复，已在代码注释与本节写明。
- UI 仅做了构建与数据路径测试（VM/服务单测 + agent 导出），**未做真实点击验收**（菜单栏 App、录制窗口“可恢复”分组的按钮、二次确认、一次性提示）——留给最终人工验收。
- 用户真实库未被写入：每次 agent 运行前后 `user-before/user-after` 哈希一致（`User library: unchanged`），未对用户孤儿执行 recover，未改用户索引。


### S5 审计结论（2026-11-23）

**修复前基线（`screen-10s` 首跑，修复前代码 + 仅诊断计数器）：**
- 两次运行均 `chunk-00000000.mp4` 为 **0 字节**，journal 只有 `register`，`segments: []`；`screen={writerStart:true, syncDropCount:0, nonSyncDropCount:0, published:false}`（`.build/agent-runs/20261123T142442-99903`、`20261123T142634-1804`）。
- **不是三处 writer 假设中的任何一处**：`startWriting` 成功、append 成功（`hasWrittenVideoFrame=true`，UI 1.0 s 进入 recording），sync 帧没有丢。真正断点在停止收尾：`sample` 显示主线程外的 stop 栈永久卡在
  `stopSegmentedCapture → sampleQueue.sync → SegmentedRecordingSampleOutput.snapshot → failureMessage → snapshot → _pthread_mutex_lock_wait`（`s5-hang-sample.txt`），即 **NSLock 同线程重入自锁**；进程随后被 harness 结束，`finishWriting` 从未运行，文件停在 0 字节。
- 修掉自锁后又暴露两个断点（均用真实产物否证）：sealer 用「另一份 AVURLAsset 实例的 track」给 reader，`reader.canAdd(output)==false` → `videoTrackUnavailable`，永远无法发布；以及 SCK 静态画面只在开始给 1–8 帧，10 s 录制的视频时长塌缩到 0.1–0.7 s。

**落地位置：**
| 断点 | 修复 |
|---|---|
| stop 自锁 | `ScreenRecordingEngine.swift:887-897`：`snapshot` 直接读 `recordedFailureMessage`，不再经 `failureMessage` 重入 |
| sealer track/asset 跨实例 | `ScreenSegmentSealService.swift:185-206`：`videoTrack(for:)` 返回 `(asset, track, format)`，reader 用同一个 `asset` |
| 静态屏时长塌缩 | `ScreenSegmentCoordinator.swift:279-372`：保留最后一帧，每秒 tick 用 `CMSampleBufferCreateCopyWithNewTiming` 写入同画面新时间戳（`freezeFrameInterval=0.5 s`） |
| sync 帧静默 drop | `ScreenVideoWriterBridge.swift:309-421`：`awaitInputReady` 分片轮询 ≤250 ms，仍不 ready 抛 `writerNotReady` 并删 chunk；非 sync 帧丢弃计 `nonSyncDropCount` |
| `startWriting` 失败 | `ScreenVideoWriterBridge.swift:357-375`：读 `writer.error`、`cancelWriting()`、删 0 字节文件、抛 `writerFailed` |
| append 拒绝 | `ScreenVideoWriterBridge.swift:424-446`：`cancelWriting()` + 删除当前 chunk，计 `appendFailureCount` |
| 0 字节残留 | `ScreenVideoWriterBridge.swift:483-494` + `finish()`：所有失败/无帧路径删空文件；测试 `finishWithoutAcceptedFramesLeavesNoFile` |
| 诊断 | `ScreenWriterDiagnostics{startWritingResult,syncDropCount,nonSyncDropCount,appendFailureCount,lastErrorDescription}`（`ScreenVideoWriterBridge.swift:79`）→ `ScreenSegmentCoordinator.writerDiagnostics()`（`:188`）→ `ScreenRecordingSessionCoordinator.writerDiagnostics()`（`:419`）/`writerFailureDescription()`（`:406`）→ `ScreenRecordingPipelineAdapter` → `RecordingSessionController.screenWriterDiagnostics()`（`:2248`，停止后保留最后一帧计数）。`Logger(subsystem:"com.snapglass", category:"screen.writer")` 只记计数与错误码 |
| 首帧失败分类 | `RecordingSettlementSupervisor.Readiness.poll` 改为三态 `PollOutcome{waiting,ready,failed(String)}`（`:86`），失败即结算并保留 `diagnostics.readinessFailure`（`:332`）；`RecordingSessionController.classifyScreenStartFailure`（`:1870`）按「writer 启动失败 → 无帧 → writer 未接受首帧」区分 |
| 权限预检 | 新增 `ScreenCapturePermissionGate`（`preflight` + 一次 `request`，拒绝即失败）；`beginScreenCapture`（`:1618`）在任何 writer/journal/deadline 之前判定，拒绝时 `didAwaitFirstVideoFrame` 保持 false |

**三分类文案（四语言键）：**
- writer 启动失败 / engine 报错：既有 `"The video writer failed before the recording started: %@"`。
- 未收到帧：既有 `"No video frames were received. The recording was stopped."`。
- writer 未接受首帧：新增 `"The video writer was not ready to accept video frames: %@"` + 兜底 `"The media writer was not ready to accept a video sample."`。
- 权限被拒：新增 `"Screen recording access is off. Enable SnapGlass in System Settings → Privacy & Security → Screen Recording, then try again."`（`ScreenCapturePermissionCopy.deniedKey`，四语言同步，`scripts/check-localization.sh` 通过）。

**修复后真实验收：**
- `screen-10s`（`scripts/agent-test.sh scripts/agent-scenarios/screen-10s.json --timeout 240 --keep`，exit 0）：`screen={writerStart:true, syncDropCount:0, nonSyncDropCount:0, appendFailureCount:0, lastError:null, published:true, becameWaitingForFrame:true, chunkCount:1, zeroByteChunkCount:0, chunkBytes:2029847, artifactDuration:9.9}`；发布 `Recording-5364190a…-00.mp4` 2 029 855 B / 9.90 s；chunk 2 029 847 B / 10.433 s；AVFoundation 复核 `videoTracks=1, samples=57, readerStatus=completed, 1920×1080`（`ffprobe` 未安装，`afinfo` 只支持音频，故用 AVFoundation 探针；`afinfo` 对纯视频 MP4 返回 `AudioFileOpenURL failed`，符合预期）。
- `screen-permission-denied`（exit 0）：`startReturned 736 ms`，无 `screen.recording`，`becameWaitingForFrame=false`、`chunkCount=0`、根目录无任何文件；`failureMessage` 为“屏幕录制权限已关闭。请在“系统设置 → 隐私与安全性 → 屏幕录制”中启用 SnapGlass，然后重试。”
- 单测：`swift test --package-path Packages/CaptureCore` 670/670；`WindowLifecycleStateTests` 141/141（跳过 HEAD 即崩溃的 `RecordingWindowExclusionRegistryTests`）；新增 writer 分支 6 例、sealer 真实 chunk 1 例、权限决策 3 例、supervisor 失败原因 2 例。

**已知风险 / 未完成项：**
- 静态画面用「重复最后一帧」保时长（≈1 帧/秒），是 SCK 变化驱动采集的最小代价方案；若后续要恒定帧率，应改采集配置（S5 非目标）。
- 首帧 5 s 截止仍由 S2 supervisor 执行，S5 只新增「失败原因传递」，未改其超时/停止语义。
- 录屏中途 SCK 偶发无效帧（`ScreenSegmentCoordinatorError.invalidFrame`）仍按既有语义判为致命，会提前结束该次录制（4 次 10 s 录屏中观察到 1 次）。属既有语义，S5 未改；如需改为丢帧降级应单独立项。
- `screen-10s-audio` 的音频轨为真实 system audio（48 kHz），但未做“是否有声音”的主观听感验收，只验证了轨道存在与可播。
- 构建与 agent 通道通过；HUD/失败面板/权限引导的真实点击未验证。
- 全量回归时 `audio-smoke` 的 `hudFirstVisible < 300 ms` 在系统负载 19–30 下多次测到 473–732 ms（同一构建下 `stall-main`/screen 场景 223–238 ms）；该阈值未放宽，需在空闲机器上复测。
- 基线复现暴露过 agent 隔离缺口：screen 场景的 `destinationDirectory` 原先取用户偏好，曾把 1 个 0 字节会话写进 `~/Movies/SnapGlass`。已修复（agent 把 screen 目标目录设为 `--agent-root`），泄漏的会话目录与索引条目经用户批准后移出/删除，用户库文件数恢复 11。

### S5 补充：录屏 + 系统音频（2026-11-23）

**现象：** `screen-10s` 副本仅把 `audioMode` 改为 `system`（run `20261123T151324-62287`）→ `screen.published=true` 但只有 **80 803 B / 0.0667 s（2 帧）**；日志 `screen.session audio start failed: AudioRecordingEngineError.startFailed("initial route commit failed")`，随后 `recordFailure` 使 `processingFailure != nil`，`consume` 与 `advanceBoundaryTick` 全部提前返回，视频与 freeze-frame 一起停摆。

**三个真实缺陷（全部在屏幕侧，未改音频引擎行为）：**
| 缺陷 | 根因 | 修复 |
|---|---|---|
| 路由 commit 恒失败 | `ScreenRingAudioFrameSource.commitReconfiguration` 无条件 `return false`（`ScreenRecordingSessionCoordinator.swift:839`）；音频独占路径的 `SystemAudioSource` 返回 `commitLocked` 的真实结果。`AudioRouteController.commitLocked` 因此返回 `unchanged("source rejected generation commit")` → engine 映射成 `initial route commit failed` | 现返回 `generation.id == self.generation.id && !stopped`；`prepareReconfiguration`/`commitReconfiguration` 记录结果到 `screen.audio` 日志（`matches=`/`running=`） |
| sealer 多输入交错死锁 | `ScreenSegmentSealService` 先追加完全部视频再追加音频；AVAssetWriter 在加入音频输入后，视频输入在第 4 个样本后 `isReadyForMoreMediaData` 恒 false（独立探针复现），`appendVideo` 的 1 ms 循环永不退出 | 先从首帧视频样本解析 `mediaOrigin` 并 `startSession`，再用 `Task` **并发**喂视频与音频（`appendAudioTracks`），任一侧失败都取消另一侧 |
| 音频 flush actor 重入 | `ScreenSegmentCoordinator.flushAudio` 在 `await sink.append` 处被 actor 重入，两个 flush 重复写同一 pending 块并跳过另一块 → `RecordingCheckpointError.nonContiguousRange(expectedStart: 51840, actualStart: 53280)` | 新增单槽 flush 闸门（`acquireAudioFlush`/`releaseAudioFlush`）+ 只消费进入时观察到的 pending 前缀，append 期间新入队的块保持 pending |

**非致命音频策略：**
- 新增 `audioFailureReason`，`consume` 的音频启动失败只调用 `recordAudioFailure`（不设 `processingFailure`、不触发 `onFailure`、不停止采集），视频、freeze-frame、边界 tick 全部继续；每次会话只尝试一次音频。
- `ScreenRecordingOutcome.audioFailure` + `ScreenWriterDiagnostics.audioFailureReason` 暴露到 `screenWriterDiagnostics()` 与 agent report；发布不受影响（`isSaved` 仍为 true）。
- 保存时文案改为新增键 `"The system audio could not be recorded. The video was saved: %@"`（四语言）；正常路径仍显示 `Recording saved: %@`。
- `session.audioMode` 改为场景显式值（screen 场景此前永远写 `system`）。

**验收（均为真实 10 s 录屏）：**
- `screen-10s-audio`（`audioMode=system`，run `20261123T154454-10900`）：exit 0，`Recording-c68d0362…-00.mp4` **2 323 894 B / 9.783 s**；AVFoundation 探针 `videoTracks=1 audioTracks=1`（audio 48 kHz，video 1920×1080）；`screen={writerStart:true, syncDropCount:0, nonSyncDropCount:0, appendFailureCount:0, audioStartFailed:false, audioTrackPresent:true, published:true, zeroByteChunkCount:0}`；`session.audioMode="system"`。
- `screen-10s-audio-degraded`（注入音频工厂失败，run `20261123T153412-61702` / `20261123T153432-62097`）：两次 exit 0，**10.125 s / 10.033 s**、2.6/3.3 MB、`audioTrackPresent=false`、`audioStartFailed=true`、`failureMessage="系统音频未能录制，视频已保存：…"`、`published=true`、无 0 字节。
- `screen-10s`（video-only，run `20261123T153506-62640`）：exit 0，9.53 s，`session.audioMode="none"`。
- 单测新增：ring source commit 接受自身/拒绝外来/停止后拒绝 3 断言、`audioFailure` 不影响 `isSaved`、sealer 同时封包真实 audio+video（1+1 轨）。

## 10. 未验证边界

- HUD 卡死的具体栈帧仍需在复现时用 `sample SnapGlass 5` 确认；本计划按“呈现/测量不阻塞 + 生命周期不依赖主线程”双保险修复，不依赖单一栈帧结论。
- 录屏 TCC 状态与 SCK 首帧行为需在真机验收，代码审查不能替代。
- 恢复后的可播放性需真实文件验证，不以单元测试代替。

### S5 最终复核（lead 独立验收，2026-11-23 16:02）

- 独立 AVFoundation 探针（非 agent 报告）：`screen-10s-audio` 最终产物 `duration=10.8333`、`videoTracks=1`、`audioTracks=1`（video 1920×1080，audio 48 kHz）。
- 最终构建（executable 15:49:56，DR 与已安装 App 逐字一致）统一回归 10 场景全部 exit 0：

| 场景 | 结果 |
|---|---|
| screen-10s | 10.108 s / 3.41 MB，published，0 字节 0 |
| screen-10s-audio | 9.650 s / 2.54 MB，**1 video + 1 audio**，audioStartFailed=false |
| screen-10s-audio-degraded | 9.258 s / 2.34 MB，audioStartFailed=true、视频完整、提示正确 |
| screen-permission-denied | 立即失败，root 0 文件，未进入等待首帧 |
| audio-smoke | 3.41 s，HUD 首现 55 ms |
| audio-10s | 10.49 s，HUD 首现 70 ms |
| audio-smoke-default-source | 3.63 s，HUD 首现 63 ms |
| stall-main | 6.46 s，maxStallMs=6007 |
| deadline-during-stall | settlementDuringStall=true，stopCalls=1 |
| recover-orphan（种子 `.build/agent-seeds/s3-orphans-22s`） | adopted=1，catalog=exported=22.02 s，幂等，0 字节隐藏 |

- 种子与用户真实孤儿 CAF `shasum` 一致（`629db7b0…`）。
- 2026-11-23 16:01 之后无新增 0 字节 MP4；用户库 11 文件 / 4 会话 / 索引 4 条 / index mtime 14:23 未变 / defaults 哈希 `3ad10b2a…` 未变 / pid 52603 存活。
- 全量：CaptureCore 673/673（15:46:29）、App 141/141（15:46:42）、`BUILD SUCCEEDED`（15:46:59）；无源码晚于测试日志；localization 通过。
