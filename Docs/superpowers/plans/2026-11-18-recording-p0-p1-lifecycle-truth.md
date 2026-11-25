# 录制 P0 · P1 — 生命周期真相与有界结果

> **Status:** `Implemented — targeted Debug build passed; tests not run; not verified`，2026-11-18。P4 已按具体偏差修正迟到音频启动、启动看门狗、屏幕失败/监控代际与退出超时；见本文件末尾「P4 增补」。
> 索引：[`2026-11-18-recording-p0.md`](./2026-11-18-recording-p0.md) · 下一阶段：[`P2`](./2026-11-18-recording-p0-p2-main-thread-and-capture.md)
> 设计依据：spec §5.7、§5.12、§6.3；用户已批准，不再设确认门禁。
>
> **2026-11-18 clarification (approved scope):** allowlist 补入 HUD/菜单栏/退出文案所需文件；`state kind` 在 preparing/saving/quit 全程可用；隐藏 HUD 对音频与屏幕一致；starting 可取消；ready/超时常量为保守有界值而非承诺；不做无消费者的全局材料目录，复用 ledger session root；音频 readiness 以真实源样本为准（合成静音/时钟推进不算）。

**Goal:** 让 `.starting` / `.recording` / `.saving` / 失败/完成都对应真实事实；取消、停止、退出在底层调用不合作时仍返回有界、诚实的 UI 结果；待恢复材料与活动保存解耦且不删除；权限按本次实际音源角色检查；只加隐私安全的阶段 signpost 与 VoiceOver 播报。

**Architecture:** 以 `RecordingSessionController` 为唯一会话事实源，新增 `sessionGeneration` 与幂等 terminal settle；readiness 由 CaptureCore 暴露的真实计数（writer 已接受首帧、真实源样本）驱动；恢复材料复用 ledger session root 并按 session ID 有界登记，只登记、不删除；signpost 只输出 kind/phase 枚举，不输出路径、文件名、设备名、电平或用户文本。

---

## 1. Owned files（精确 allowlist）

**Create**
- `Packages/CaptureCore/Sources/Recording/RecordingSignposts.swift`
- `App/SnapGlass/Sources/Recording/RecordingReadiness.swift`（readiness 错误/超时常量/有界等待辅助；若实现者认为应并入控制器，必须先在本文件“变更记录”说明，不得静默改路径）

**Modify**
- `Packages/CaptureCore/Sources/Recording/RecordingDomain.swift`（`RecordingProgress.capturedSamples`）
- `Packages/CaptureCore/Sources/Recording/RecordingSessionPipeline.swift`（填充 `capturedSamples`）
- `Packages/CaptureCore/Sources/Audio/AudioMixPump.swift`（真实源样本计数，排除合成静音/时钟推进）
- `Packages/CaptureCore/Sources/Audio/AudioRecordingEngine.swift`（填充 `capturedSamples`）
- `Packages/CaptureCore/Sources/Recording/ScreenSegmentCoordinator.swift`（新增“writer 已接受首帧”信号）
- `Packages/CaptureCore/Sources/Recording/ScreenVideoWriterBridge.swift`（`append(video:)` 返回 writer input 是否真正接受，供首帧门禁）
- `App/SnapGlass/Sources/Recording/ScreenRecordingPipelineAdapter.swift`（暴露 readiness 查询）
- `App/SnapGlass/Sources/Recording/RecordingSessionController.swift`
- `App/SnapGlass/Sources/Recording/RecordingSessionController+HUD.swift`
- `App/SnapGlass/Sources/Recording/RecordingQuitFlow.swift`
- `App/SnapGlass/Sources/Recording/RecordingControlPanel.swift`（kind-aware preparing/saving、starting 取消、隐藏 HUD 一致；不动尺寸语义）
- `App/SnapGlass/Sources/MenuBar/CaptureViewModel+Recording.swift`
- `App/SnapGlass/Sources/MenuBar/MenuBarStatusLabel.swift`（kind-aware VoiceOver 值）
- `App/SnapGlass/Sources/MenuBar/MenuBarView.swift`（kind-aware 停止/保存文案）
- `App/SnapGlass/Sources/App.swift`（向菜单栏标签传入当前 kind）
- `App/SnapGlass/Sources/AppLocalization.swift`（仅当需要 kind/phase 文案解析；不新增无关 API）
- `App/SnapGlass/Sources/AppLifecycleDelegate.swift`（退出确认按 kind 给正确文案）
- `App/SnapGlass/Resources/en.lproj/Localizable.strings`
- `App/SnapGlass/Resources/zh-Hans.lproj/Localizable.strings`
- `App/SnapGlass/Resources/ja.lproj/Localizable.strings`
- `App/SnapGlass/Resources/ko.lproj/Localizable.strings`

**Do not touch:** `ScreenRecordingEngine.swift`、`RecordingPreferencesView.swift`、`SharedKit/PreferenceKeys.swift`、entitlements、TCC、截图架、导出窗口。

> P2 只接管 `RecordingControlPanel.swift` 的 resize/几何与电平布局语义；P1 不改 `RecordingHUDMetrics` 常量、不把 kind 变化变成尺寸变化。

---

## 2. 接口契约

### 2.1 新增（CaptureCore / App）

```swift
public enum RecordingPhase: String, Sendable {
    case preparing, starting, recording, saving, finished, failed, cancelled, quitResolved
}

public enum RecordingSignposts {
    /// Emits one privacy-safe signpost event. Never pass paths, file names, device names,
    /// audio levels, or localized/user text.
    public static func emit(_ phase: RecordingPhase, kind: RecordingKind)
}
```

- `RecordingSignposts` 用 `OSSignposter(subsystem: "com.snapglass", category: "recording.phase")`，只发点事件（`emitEvent`），不持有跨阶段 interval state；事件名只允许 `audio.preparing`、`screen.saving` 这类由枚举拼接的静态集合。实现不得把 `UUID`、URL、`localizedDescription` 写入 signpost。
- **不做**独立全局 `RecordingMaterialQuarantine` 目录：恢复材料复用 `RecordingSessionPipeline.ledger.sessionRoot`（屏幕走协调器 journal），控制器只按 `sessionID` 保存有界 URL 列表；只登记、不复制、不移动、不删除，显式恢复动作才释放。理由：现有恢复入口由 ledger 提供，新增无消费者的内存目录会与 ledger 形成双重事实。
- `RecordingReadiness`（App）只有两类内容：保守有界常量、`awaitBounded`/`waitUntil` 辅助。`awaitBounded` 用“工作 Task + 计时 Task + 一次性 continuation”实现，超时返回 `nil` 并取消工作 Task；**禁止** `withTaskGroup` 退出时等待不合作的子任务。actor 查询被锁住时，单次查询本身也受剩余 deadline 限制。
- 常量（暂定、未运行时标定）：首帧观察 5 s、首样本观察 15 s、UI 收敛等待 10 s。它们只决定“继续等待还是给出有界状态”，不是对正常保存耗时的断言；正常保存超过 8 s 不得被判为 stopped/failed。

### 2.2 扩展（CaptureCore）

```swift
public struct RecordingProgress {
    // 既有字段不变…
    /// Real captured source samples observed so far. 0 means "no real sample yet".
    /// Synthetic silence and clock-advanced ticks do not increment this value.
    public let capturedSamples: Int64
}
```

- 新参数给默认值 `0`，保持现有调用点源码兼容。
- `RecordingSessionPipeline.publishProgress()` 取 `max(facts.sampleEnd, engineProgress?.capturedSamples ?? 0)`。
- `AudioMixPump` 统计从 ring/重采样队列实际取出的帧（真实 PCM，含零振幅）；`popFramesLocked` 用合成零填充的 `remaining` 不计入。
- `AudioRecordingEngine.publishProgress()` 的 `capturedSamples` 取该真实计数；`elapsedSeconds` 仍取 `pump.nextSampleIndex`（时钟/合成静音只影响时长，不影响 readiness）。

### 2.3 App 内部

- `RecordingSessionController`：`private var sessionGeneration = UUID()`；`startAudio`、`startRecording` 各生成一次；所有异步完成回调在写状态前比对 generation（音频另比对 `audioSessionID`）。不匹配直接丢弃，不改 status、不写 `lastAudioResult`、不碰新会话资源。
- 单一收敛：`private func settleTerminal(wasSaved:result:outputURL:) -> Bool`；`completeAudioSession` 与 `finishSession` 的 outcome 写入都经过它，`outcomeState.terminalOutcome == nil` 保证只生效一次。
- `pendingRecoverySessionIDs: Set<UUID>` 取代 `audioRecoveryPending: Bool`；`hasPendingBackgroundFinalization` 只看活动 stop/finalizing/start-cleanup，不看恢复集合。
- 屏幕 starting 取消/迟到启动：`startCapture` 捕获 generation；`adapter.start` 返回后 generation 不匹配时，最多执行一个 late cleanup（`stopAndSave`），绝不更新新会话；`screenStartPending` 期间不允许开始下一次屏幕录制，防止重叠采集资源。
- 音频 starting 取消：设置 stop 请求并启动**一次**有界 stop；超时立即给 `failed` 的终端结果，后台 `stopAudio` 继续但迟到完成因 generation 不匹配被丢弃。

### 2.4 HUD / 菜单栏 / 退出（kind 可用）

```swift
enum RecordingControlPanelState: Equatable {
    case starting(kind: RecordingKind, awaitingFirstMedia: Bool)
    case saving(kind: RecordingKind, fileName: String?, isBeforeQuit: Bool)
    // 其余 case 不变
}
```

- `.starting`：kind-aware 文案；`awaitingFirstMedia == true` 时显示“Waiting for the first audio sample…”/“Waiting for the first video frame…”；始终有可访问的 Cancel（`accessibilityLabel("Cancel Recording")`），点击进入与菜单栏相同的取消路径。
- `.saving`：kind-aware“Saving …”、`isBeforeQuit` 时“Saving recording before quitting”；不显示“saved”。
- 隐藏 HUD（`panelHiddenByUser` 或 `RecordingHUDPreferences.isHidden`）对音频与屏幕一致：不创建/不更新/不重新展示面板，只保留菜单栏与 VoiceOver 事实。
- `MenuBarStatusLabel` 接收 `kind: RecordingKind?`，accessibilityValue 使用 preparing/recording/saving 的 kind 文案；`App.swift` 从 `CaptureViewModel` 传入。
- 退出确认由 `CaptureViewModel.activeRecordingKind` 决定标题/正文（音频/屏幕）；`AppLifecycleDelegate` 的 saving 等待文案使用 kind。**不谎报 saved**：超时的 `.failed` 仍不返回 `terminateNow`。


### 2.5 首帧“writer 已接受”信号

```swift
// ScreenVideoWriterBridge
@discardableResult
public func append(video sampleBuffer: CMSampleBuffer) throws -> Bool
// 仅当 AVAssetWriterInput.append(sampleBuffer) 返回 true 时返回 true；
// 未就绪丢帧、首帧非 sync、未打开 writer 均返回 false（不改变既有 throws 语义）。

// ScreenRecordingSessionCoordinator (actor)
public private(set) var hasWrittenVideoFrame: Bool
// 仅在 currentVideoWriter.append(video:) 返回 true 后置 true；start 时重置 false。

// ScreenRecordingPipelineAdapter
let hasWrittenVideoFrame: () async -> Bool
```

- **不得**用 `ScreenRecordingEngine.hasAcceptedVideoFrame` 代替：在 segmented 路径它表示“帧流队列已接受”，不是 writer 已写入。
- 没有 sync 帧、没有打开 writer、或 writer input 未就绪丢弃时，即使队列接受过帧，也不得置 true。
- 该信号只读，不改变 append/丢帧/分段行为。

---

## 3. 实施步骤（顺序执行）

### Step 1 — 进度真实样本字段

1. 在 `RecordingDomain.swift` 给 `RecordingProgress` 增加 `capturedSamples`（默认 0，DocC 注明“真实样本，不是电平”）。
2. 在 `RecordingSessionPipeline.publishProgress()` 与 `AudioRecordingEngine.publishProgress()` 填充；不改变 100 ms 节流与 15 Hz 上限。
3. 静态核对：没有任何 readiness 分支读取 `systemLevel` / `micLevel`。

### Step 2 — signpost

1. 新建 `RecordingSignposts.swift`，实现 §2.1；只在阶段转换处发事件。
2. 控制器调用点：`preparing`（picker/开始前）、`starting`（捕获启动）、`recording`（readiness 通过）、`saving`（stop/finalize）、`finished`/`failed`/`cancelled`/`quitResolved`（terminal settle）。
3. 音频 pipeline 内部不新增 signpost 调用；由控制器统一发，避免双份事实。
4. 禁止把 signpost 接到 `Logger.info` 或任何文件/网络输出。

### Step 3 — 屏幕首帧门禁

1. `ScreenVideoWriterBridge.append(video:)` 改为返回 `Bool`：只有 `AVAssetWriterInput.append` 真正接受才 true；未就绪丢帧/首帧非 sync/未打开 writer 返回 false，throws 语义不变。协调器在三个 append 路径用返回值置 `hasWrittenVideoFrame = true`；`start` 时重置。**不**在 `onVideoFrame` 闭包或队列 `.enqueued` 时置位。
2. Adapter 暴露 `hasWrittenVideoFrame` 查询；`startCapture()` 在 `adapter.start` 成功后**不**直接 `.recording`；保持 `.starting` 并立即启动观察任务（不是 UI 轮询循环）。
3. 观察任务以 100 ms 间隔查询，deadline 5 s（暂定，常量在 `RecordingReadiness`）；每次查询受剩余 deadline 限制，actor 被锁也不会无限等待。
4. 成功且 generation/session 匹配：`outcomeState.markRecordingStarted()`、`updateStatus(.recording)`、`startMonitoring()`、发 `recording` signpost。
5. 超时：取消观察 → `.saving(kind: .screen, isBeforeQuit: false)` → 有界等待 `adapter.stopAndSave()`；无论 save 是否完成都用 `RecordingReadinessError.noVideoFrames` 收敛为 `failed`（若随后真的发布成功，仍如实展示失败原因和 partial，不写 saved）。停止/清理任务最多一个。
6. `stopWhenStarted` 分支保持：门禁通过后再执行待定 stop；门禁超时直接失败收敛。
7. starting 取消：立即使 generation 失效并把 UI 收敛到 `failed`/idle（`noActiveSession` 语义）；`startCapture` 迟到返回时只执行一次 cleanup，不更新新会话；`screenStartPending` 未清空前拒绝下一次屏幕录制。

### Step 4 — 音频首样本门禁

1. `startAudio` 在 `pipeline.start` 返回后只 `markAudioPipelineStarted()` 的“管道已启动”事实；`.recording` 状态由首个 `progress.capturedSamples > 0` 触发。
2. `startAudioProgressMonitoring` 从 `.starting` 就开始订阅 progress；收到 `capturedSamples > 0` 且 generation/sessionID 匹配时：应用 `.started`、记录 `recordingStartedAt`、更新 HUD、发 `recording` signpost。订阅启动后不因单个 progress 值重复触发。
3. 首次样本前显示 `.starting(kind: .audio, awaitingFirstMedia: true)`（“Waiting for the first audio sample…”）；不得把静音/低电平当失败，也不得把 start 返回当 recording。
4. 15 s（暂定常量）仍无真实样本：有界调用 `stopAudio()`；结果按现有 `audioResultWasSaved` 判定；失败呈现失败面板并保留恢复材料。若 stop 在 UI 等待内未返回，给出有界 `failed`，后台继续，迟到完成被 generation 丢弃。
5. 30 s 无有效声音的既有提示保留，仅作为“静音提示”，与 readiness 分离。

### Step 5 — session generation 与单一 terminal outcome

1. `startRecording()` / `startAudio()` 生成 `sessionGeneration`；屏幕迟到 start 与音频迟到 stop 都以 generation 判定；`finishSession` 末尾轮换 generation。
2. 所有 `Task { @MainActor … }` 完成路径（start/stop/readiness/timeout/quit）先 `guard generation == sessionGeneration`；音频另 guard `audioSessionID`。不匹配直接丢弃，不改 status、不写 `lastAudioResult`。
3. 实现 `settleTerminal(wasSaved:result:outputURL:) -> Bool`：仅在 `outcomeState.terminalOutcome == nil` 时写结果/取消 progress/readiness、更新状态并返回 true；`completeAudioSession` 与 `finishSession` 的 outcome 写入都经过它。`stopAndSave`、`stopAudio`、`stopAndResolveForQuit` 不各自发明第二套终态。
4. `RecordingQuitFlow` 只消费 `outcomeState.terminalOutcome`；不得出现 stop 返回 `true` 但 quit 看到 `.failed` 的双重事实。
5. “保存超过 8 s”不是失败条件：只有显式 UI 收敛 deadline 到期才给 `failed`，且文案说明仍在后台保存；成功保存无论多久都写 `saved`。

### Step 6 — 取消/停止/退出有界

1. `cancelPendingStart()` 增加 `.starting`：屏幕按 Step 3.7；音频设置 stop 请求并启动一次有界 stop，UI 立即回到 idle/失败面板，不得无限等待 `pipeline.start`。
2. `RecordingReadiness.awaitBounded(_:operation:)`：工作 Task + 计时 Task + 一次性 continuation；超时返回 `nil` 并取消操作 task；调用方必须给出 `failed` 或“仍在后台保存”的明确文案，不能写“已保存”。不使用结构化 group 等待不合作的子任务。
3. `stopAndResolveForQuit` 等待上限 10 s（暂定）：超时返回 `.failed`，`RecordingQuitFlow` 不谎报 saved；后台保存继续，恢复材料保留。重复 stop/quit 调用加入同一 stop task/outcome waiter，只收敛一次。
4. 任何 `stream.stopCapture` / `pipeline.stop` 抛错都记录为 failure 并保留材料；不因超时删除 partial。
5. 迟到的 start 成功必须尝试 stop/cleanup；同一时刻最多一个 cleanup 任务，且绝不触碰新一代 generation 的状态或资源。

### Step 7 — 恢复材料与活动保存解耦

1. 用 `pendingRecoverySessionIDs` 替代 `audioRecoveryPending`；`hasPendingBackgroundFinalization` 不包含恢复集合。
2. `waitForBackgroundFinalization()`：仅恢复材料时立即返回既有 terminal/`.failed`，不阻塞退出/新会话。
3. 失败完成时登记已知材料：优先 `pipeline.latestPublishedFileURL()`，否则 `pipeline.ledger.sessionRoot`；控制器按 sessionID 保存有界 URL 列表（复用 ledger 路径，不另建全局目录）。不复制、不移动、不删除。
4. 只有用户显式恢复/打开动作才释放登记；本轮不实现自动清理，不修改 ledger 恢复语义。
5. 新会话开始时不得因旧恢复材料被 `guard` 拒绝；旧材料仍可在恢复入口看到。

### Step 8 — 按实际角色检查权限

1. 权限按本次角色检查：
   - 仅音频 `.microphone`：只检查麦克风（既有 `AVMicrophoneAuthorizer`），**不探测屏幕共享权限**（音频路径本来就不启用 SCK）。
   - 屏幕 `.system`：走现有屏幕捕获访问检查，不请求麦克风、不创建 tap。
   - 屏幕 `.microphone` / `.systemAndMicrophone`：屏幕视频仍需要现有捕获访问，因此先走既有屏幕访问检查；随后用既有麦克风授权。任一失败都不启动、不降级。
2. 拒绝：toast 明确“屏幕音源含麦克风但权限被拒绝”，并提供权限引导；**不静默降级**为仅系统声音，不继续倒计时。
3. 不含麦克风：不请求麦克风、不创建 tap（沿用现有）。
4. 音频路径保持现有 `startDefaultAudioRecording` 的角色检查；`applyAudioRoute` 保持。
5. 不修改 entitlements/Info.plist/TCC，不打开系统设置页；仅使用既有 `AVMicrophoneAuthorizer` 与 `PermissionService`。

### Step 9 — VoiceOver 与文案

1. 阶段变化时发一次 `NSAccessibility` 播报（`.announcementRequested`），kind-aware：preparing/recording/saving/saved/failed/quit；同一阶段不重复播报。
2. HUD 的 `accessibilityValue` 仍显示时长/段数，但 progress 触发的更新按秒去重，不每个 meter tick 更新。
3. 新增四语言 key（键=英文原文，保持占位符一致）：
   - `Preparing audio recording` / `Preparing screen recording`
   - `Recording audio` / `Recording screen`
   - `Saving audio recording` / `Saving screen recording`
   - `Audio recording saved` / `Screen recording saved`
   - `Saving recording before quitting`
   - `No audio samples were received. The recording was stopped.`
   - `No video frames were received. The recording was stopped.`
   - `Waiting for the first audio sample…`
   - `Waiting for the first video frame…`
   - `Microphone access is needed for the selected screen-audio source. Enable it in System Settings, or choose a source without the microphone.`
   - `An audio recording is in progress.` / `Stop and save the audio recording before quitting?`
4. 视图内用字面量，控制器/AppKit 用 `AppLocalization.string`；同步 `en` / `zh-Hans` / `ja` / `ko`。

### Step 10 — 静态交付核对

- `grep` 确认：readiness 不引用电平；signpost 不含 URL/path/UUID；`audioRecoveryPending` 已不存在；所有 terminal 路径只写一次 outcome；`hasPendingBackgroundFinalization` 不含恢复集合；恢复材料 URL 只来自 pipeline/ledger 且没有删除调用。
- 静态核对：`append(video:)` 的 true 只来自 `AVAssetWriterInput.append`；音频 `capturedSamples` 只来自真实 ring/重采样帧。
- 列出未运行项：真机首帧/首样本时延、退出挂起、VoiceOver 实际听感、TCC 拒绝路径。

---

## 4.1 变更记录（计划澄清）

- 2026-11-18：按已批准裁决补入 `RecordingControlPanel.swift`、`MenuBarStatusLabel.swift`、`MenuBarView.swift`、`App.swift`、`AppLocalization.swift`、`ScreenSegmentCoordinator.swift`、`ScreenVideoWriterBridge.swift`、`AppLifecycleDelegate.swift`；此前 “do not touch” 与 “kind/取消/退出文案” 要求冲突，以本文件为准。
- 2026-11-18：取消 `RecordingMaterialQuarantine` 新文件。恢复材料复用 ledger `sessionRoot` + 控制器按 sessionID 有界登记；理由是无 UI 消费者，避免与 ledger 双重事实。
- 2026-11-18：5/8/10/15 s 明确为保守 UI 边界，不是保存耗时断言；正常长保存不因超过 8 s 被判失败。
- 2026-11-18：`ScreenVideoWriterBridge.append(video:)` 必须返回 `AVAssetWriterInput.append` 的真实接受结果；队列接受不算首帧。
- 2026-11-18：取消/退出超时不使用 `withTaskGroup` 等待不合作子任务；使用一次性 continuation 的 bounded race。
- 2026-11-18：权限检查按 mode：mic-only 不探测屏幕；system 只查屏幕；system+mic 先屏幕引导再麦克风；不静默降级。

---

## 4. 失败处理

| 场景 | 必须行为 |
|---|---|
| `adapter.start` 抛错 | 现有失败路径；不写 recording；保留可重试材料 |
| 5 s 无首帧 | `.saving` → 有界 stop → 失败面板；不写 saved；不删除 partial |
| 15 s 无首样本 | 有界 `stopAudio`；按真实结果 saved/failed；材料 quarantine |
| `pipeline.start` 挂起后用户取消 | 有界返回 idle/failed；generation 使迟到 start 无效 |
| `stopAudio`/`stopCapture` 挂起 | 有界返回 `.failed`；后台继续；不阻塞 quit 之外的新会话 |
| 退出时仅恢复材料 | 立即返回既有 terminal，不等待、不删除 |
| 屏幕音源含麦克风但拒绝 | 明确提示 + 权限引导；不降级、不启动 |
| signpost 调用点遗漏 | 不阻塞功能；交付说明标 `Implemented` 而非 validated |

---

## 5. 验收（本阶段只到 Implemented）

- Owned files 之外无改动；`git diff --stat` 与 allowlist 一致。
- `RecordingProgress` 新字段有默认值，既有调用点无需改写。
- 所有 readiness/terminal 分支静态可追踪；无 `saved` 早报。
- 四语言 key 数量与占位符一致（由 P4 跑本地化脚本；P1 只人工核对）。
- **不运行** App、TCC、真机、长录、测试、profiling。

---

## 6. P4 增补（2026-11-18，主控静态复核后）

本轮在 P4 内修正了 P1 生命周期中的四处具体偏差；设计裁决 D1–D5 不变。

1. **迟到音频启动的资源所有权**
   - `startAudio` 在 `closeAudioPreview()`/任何 `await` 前同步占用 `audioResourceOwner` 与 `audioStartReservation`，并轮换 `sessionGeneration`；第二次 start 返回 `alreadyStarted`。
   - generation/UI 已收敛时，迟到成功不再静默返回：`scheduleAudioRetirement` 对该 pipeline 执行恰好一次 `stop()`；owner 只在 stop drain 后释放，期间 audio/screen 都拒绝新采集。
   - 迟到 start 抛 `RecordingReadinessError.supersededStart`；`CaptureViewModel` 不写 mode/startedAt、不重复 toast。retiring 产出的媒体只登记恢复材料，不写 `saved`。
2. **平台启动看门狗**
   - `RecordingReadiness.platformStartDeadline`（30 s，暂定）覆盖 preview 收尾、factory 与平台 start；音频/屏幕各有 per-attempt 看门狗，平台 start 一返回即取消。
   - 看门狗到期只给有界可见失败；屏幕保留 `screenStartPending`、音频保留 owner 直到迟到操作真正 drain。
   - 不覆盖已授权的系统权限提示；`awaitBounded` 的超时语义未改，正常慢保存不受影响。
3. **屏幕失败/监控守卫与退出超时**
   - `onFailure` 用本次 generation + 当前 adapter 存在性守卫；`startMonitoring` 在每个 `await` 后重新校验 generation 与 `.recording`。
   - `stopAndResolveForQuit` 超时不再 `finishSession`/`completeAudioSession` 一个仍在保存的活动会话；返回 `.failed` + 本地化提示，保留 saving 表示与引用。
   - `hasPendingBackgroundFinalization` 纳入 retiring 操作；`waitForBackgroundFinalization` 等待 retire drain。
4. **`alreadyStarted` 本地化**
   - `AppLocalization.recordingErrorDescription` 显式映射 `RecordingPipelineError`；新增四语言 key，`Cancelled` 也补齐。

编译证据与未验证项见 `Docs/superpowers/plans/2026-11-18-recording-p0-completion.md`。
