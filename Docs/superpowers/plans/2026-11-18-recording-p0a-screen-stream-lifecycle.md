# 录制 P0-A · 录屏流生命周期完整修复（阶段落版）

> **Status:** `Implemented — not compiled this round; tests not run; not verified`，2026-11-18。本文件先于产品改动落版；编译与运行验证由交付代理统一执行，本轮不跑构建、测试、GUI/TCC，不做独立评审。
> Worktree：`/Users/11169285/.local/share/opencode/worktree/5d0345d699d913b55a21fac44cccbd69a3acb4ec/recording-p0`
> Branch：`fix/recording-p0`（base `84e4a6a`）；承接 `2026-11-18-recording-p0.md` 的 P1–P4。
> 设计裁决沿用 P0 索引 §3 的 D1–D5，不重新讨论架构。

**Goal:** 把「按录屏按钮 → 拿到可操作控制 → 停流 → 文件收尾」这条件链补成唯一事实：准备期可见可取消；来源枚举有界而系统授权不误超时；取消后的迟到结果一律丢弃；每次会话独占流；停流确认先于文件收尾；未确认停流禁止新流；停止失败不无限转圈且保留已写文件；首帧失败区分三类；诊断只留阶段/耗时/错误类；Finder/Spotlight 重开可找回控制。

**Architecture:** 不新增录制框架。屏幕路径仍是 `ScreenRecordingEngine → ScreenRecordingSessionCoordinator → ScreenRecordingPipelineAdapter → RecordingSessionController`。P0-A 只做三件事：给「准备期」一个真实 UI 状态与取消；给「停流」一个显式确认结果并把它作为文件收尾与新流准入的前置条件；给「首帧失败」一个可分类的查询面。诊断只扩展已有 `RecordingSignposts` 的数值元数据。

---

## 1. 范围与裁决（本轮固定）

### 1.1 必做（P0-A）

| # | 要求 | 落点 |
|---|---|---|
| R1 | 权限检查/选源即显示准备中 + 取消 | `.preparing(kind:phase:)` 面板状态；`updateStatus(.selectingSource)` 即呈现；取消走既有 `cancelPendingStart()` |
| R2 | 来源枚举有界，系统授权不误超时 | 新增 `ScreenSourceProbe`：preflight 已授权 → 有界枚举；preflight 未授权 → 不设超时、显示「等待系统授权」并可取消 |
| R3 | 取消后的迟到结果丢弃 | 探针/选源/目的地/启动/停止全部按 attempt + generation 守卫；`finishSession` 清空 attempt |
| R4 | 每次会话拥有流 | 引擎 `startSegmented` 在旧流未停时拒绝新流（`.previousStreamNotStopped`）；控制器 `screenStartPending` 只在停流确认后清除 |
| R5 | 取消/启动失败/首帧失败/退出共用清理：先确认停流，再文件收尾 | `ScreenCaptureStopResult(confirmed:)`；协调器未确认时抛 `.streamStopUnconfirmed`，不 `closeSegment`/不 seal |
| R6 | 旧流未确认禁止新流 | 引擎保留 `stream` 引用并标记未确认；同引擎再 start 抛错；控制器保留 `screenStartPending` |
| R7 | 停止失败不无限转圈、可操作恢复、保留已写文件 | 停止 UI 等待受 `uiSettleDeadline` 约束；超时面板转 `.failure`（Finder 定位恢复目录），内部仍 `.saving`，真实结果回来再收敛 |
| R8 | 不混淆「系统流启动 / 首画面 / 写入器接受首帧」 | 首帧门禁超时后按 `writer failure / no capture frame / writer wait timeout` 三类收敛 |
| R9 | 诊断仅阶段、耗时、错误类 | `RecordingSignposts.emit(phase:kind:elapsedMilliseconds:errorClass:)`，只传整数与枚举码 |
| R10 | Finder/Spotlight 重开找回控制并可操作 | `applicationShouldHandleReopen` → 控制器恢复面板（含被用户隐藏的保存面板、失败面板） |

### 1.2 明确不做（可选优化，未获范围确认前不动）

见 §6「可证明的重复工作」中的 OPT-1…OPT-6。全部为性能/调用次数优化，不改行为；本轮只做其中 **DUP-1**，因为它是 R2 的实现副产物（把探针枚举结果交给选择器），不是独立优化。

### 1.3 不做的事（硬边界）

- 不动 Sparkle、菜单栏实现、录音容量/码率、媒体质量、59 分钟分段、checkpoint fsync 策略。
- 不新增/修改 entitlements、Info.plist 权限 key、TCC 行为；不打开系统设置页（沿用既有 `onOpenPermissionGuide`）。
- 不提交、不打包、不签名、不安装；不跑测试/长录/性能剖析；不调用子代理。
- 不删除任何已写媒体或 `.SnapGlassSessions` 目录；不新增自动清理。

---

## 2. 接口契约

### 2.0 裁决 D10（2026-11-18，主控验收补充）

平台 `startCapture` / `stopCapture` / adapter 清理**永不返回**，或返回后仍未确认停流时，`screenStartPending` 即「捕获释放未确认」：

1. 必须有**持续、可重开找回**的静态说明，不得只弹一次 toast 后无声占用；说明里给 Finder 定位与「退出并重新打开 SnapGlass」的明确出口，**不转圈**、**不宣称已停**、**不声称系统一定会释放**。
2. 期间禁止新流；一旦迟到确认到达，立即清除该说明并释放闸门，但**不得触碰新会话**（清闸与清提示在同一同步块内完成）。
3. 「流未确认释放」与「文件尚未封存」分开呈现：前者发生在 `status != .saving`，后者沿用 `.saving` 的「仍在后台保存」文案。
4. 启动尚未成功时的取消，适用同一规则；未确认期间 Retry 不得重入（真实 in-flight 不再发第二次 stop），已写文件一律保留。

### 2.1 停流确认（CaptureCore）

```swift
/// Result of asking the shared SCStream to stop.
public struct ScreenCaptureStopResult: Sendable, Equatable {
    /// Capture-callback drops observed before the stream stopped.
    public let droppedFrames: Int64
    /// `true` only when `SCStream.stopCapture()` returned without throwing.
    public let confirmed: Bool
}

// ScreenRecordingEngine (actor)
public func stopSegmentedCapture() async -> ScreenCaptureStopResult
/// Retries one `stopCapture()` after an unconfirmed stop. Returns the same confirmation rule.
public func confirmSegmentedCaptureStopped() async -> ScreenCaptureStopResult
/// `true` while an unconfirmed stream reference is retained; a new start is refused.
public var hasUnconfirmedStream: Bool { get }
/// Whether the capture callback accepted any video sample (queue level, not writer).
public var hasAcceptedVideoFrame: Bool  // 既有，保留
```

- `startSegmented` 首行守卫：`stream != nil || hasUnconfirmedStream` → 抛 `ScreenRecordingEngineError.previousStreamNotStopped`。
- `stopCapture()` 抛错时：记录失败、**保留** `stream`/`segmentedOutput` 引用、置 `hasUnconfirmedStream = true`、返回 `confirmed: false`；**不**清 `cachedShareableContent`（后续确认/解析还要用）。
- 确认成功时：清引用、清 `hasUnconfirmedStream`、清 cache，与现有行为一致。
- `failSegmentedSession` / `cleanupAfterSegmentedStartFailure` 同样只在确认后释放引用；未确认时保留并置位。

### 2.2 协调器（CaptureCore）

```swift
public enum ScreenRecordingSessionCoordinatorError: Error {
    // 既有…
    /// The stream could not be confirmed stopped; files were deliberately left unfinalized.
    case streamStopUnconfirmed
}

// ScreenRecordingSessionCoordinator (actor)
public func stopAndSave() async throws -> ScreenRecordingOutcome
public func materialRoot() -> URL?   // sessionRoot，用于恢复提示；只读
```

- `stopAndSave()` 顺序固定：`tick` 停 → `engine.stopSegmentedCapture()` → **确认失败则立即 `recordFailure` + 抛 `.streamStopUnconfirmed`**（不 `frameContinuation.finish()`、不 `closeSegment()`、不 `failSegmentedSession()`，保留 `configuration`/`composition`/`lastOutcome==nil`）。
- 确认成功才继续：结束帧流 → 音频 drain → `closeSegment()` → 发布。
- 因为 `configuration` 未清，同一协调器再次 `start` 仍抛 `alreadyStarted`；再次 `stopAndSave` 会重试停流（先确认再收尾）。

### 2.3 Adapter（App）

```swift
func stopAndSave() async throws -> ScreenRecordingOutcome          // 既有
func captureFrameAccepted() async -> Bool                          // 引擎队列接受过帧
func failureDescription() async -> String?                         // 首个采集/写入失败摘要
func materialRoot() async -> URL?                                  // 恢复目录（只读）
```

### 2.4 首帧失败分类（App）

```swift
enum RecordingReadinessError {
    // 既有…
    /// Frames reached the capture callback but the writer never accepted one.
    case videoWriterWaitTimedOut
    /// The writer reported a failure before accepting a frame.
    case videoWriterFailed
}
```

- 分类只在首帧门禁到期、且尚未进入 `.recording` 时执行一次：
  1. `failureDescription != nil` → `.videoWriterFailed`；
  2. `captureFrameAccepted == false` → `.noVideoFrames`（来源无画面）；
  3. 其余 → `.videoWriterWaitTimedOut`（有帧、写入器未接受）。

### 2.5 准备期状态（App）

```swift
enum RecordingPreparationPhase: Equatable {
    case checkingPermission
    case waitingForAuthorization
    case loadingSources
    case choosingSource
    case verifyingDestination
}

enum RecordingControlPanelState: Equatable {
    // 既有…
    case preparing(kind: RecordingKind, phase: RecordingPreparationPhase)
}
```

- 面板：spinner + 阶段文案 + **始终可用的 Cancel**（`accessibilityLabel("Cancel Recording")`，走 `cancelPendingStart()`）。
- `.preparing` 与 `.starting` 尺寸同为 `RecordingHUDMetrics.recordingSize`；不改 HUD 位置/形状语义。
- 隐藏 HUD 偏好仍按既有规则（`panelHiddenByUser` / `RecordingHUDPreferences.isHidden`）一致处理。

### 2.6 诊断（CaptureCore）

```swift
public enum RecordingDiagnosticErrorClass: Int, Sendable {
    case permission = 1, source = 2, writer = 3, destination = 4, timeout = 5, cancelled = 6, unknown = 7
}

public static func emit(
    _ phase: RecordingPhase,
    kind: RecordingKind,
    elapsedMilliseconds: Int? = nil,
    errorClass: RecordingDiagnosticErrorClass? = nil
)
```

- 事件名仍是固定枚举拼接；元数据只允许整数（`elapsed_ms`、`error_class` 的 rawValue）。**不得**传路径、文件名、设备名、UUID、本地化文案或 `localizedDescription`。

### 2.7 重开恢复（App）

```swift
// SnapGlassApplicationDelegate
func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool

// RecordingSessionController
@discardableResult func restoreControlForReopen() -> Bool
```

- 有活动会话/保存中/失败材料：清 `panelHiddenByUser`（只在内存，不改偏好），重建面板并恢复当前状态；返回 `true`。
- 无会话：返回 `false`，不抢前台。

---

## 3. 实施步骤

1. **CaptureCore 停流确认**：`ScreenCaptureStopResult`、引擎 guard/保留引用/`confirmSegmentedCaptureStopped`、协调器 `.streamStopUnconfirmed` 与顺序固定、`materialRoot()`。
2. **Adapter 查询面**：`captureFrameAccepted` / `failureDescription` / `materialRoot`。
3. **控制器生命周期**：首帧三分类；`finalizeRecording` 有界 UI + 超时恢复面板；`runScreenCleanup` 只有确认后才清 `screenStartPending`；`finishSession` 清 attempt。
4. **准备期 UI**：`.preparing` 面板状态、尺寸与取消；`updateStatus(.selectingSource)` 立即呈现；四语言文案。
5. **来源探针**：`ScreenSourceProbe`（preflight 分流、有界/授权等待、取消即丢结果）；`RecordingSourcePickerPanel.show(content:...)` 复用枚举结果；控制器接入 + 阶段文案。
6. **诊断**：`RecordingSignposts` 数值元数据；控制器只在阶段边界传 elapsed / errorClass。
7. **重开**：delegate `applicationShouldHandleReopen` + 控制器 `restoreControlForReopen`。
8. **静态核对**：`git diff --stat` 与 allowlist；grep 确认无 `localizedDescription` 进 signpost、无删除调用、无新超时覆盖授权。

---

## 4. 失败处理矩阵

| 场景 | 行为 |
|---|---|
| 权限检查中用户取消 | 面板立即消失；探针返回后 attempt/status 不匹配 → 直接丢弃，不弹 toast、不建面板 |
| 系统授权弹窗未响应 | 不超时；面板显示「等待系统授权」+ 取消；`SCShareableContent` 返回后按授权结果继续或引导 |
| 已授权但枚举超时 | 有界失败 + 可重试文案；不进入倒计时、不创建引擎 |
| 选源完成但目的地探测失败 | 既有失败提示；面板回到 idle |
| `adapter.start` 抛错 | 既有失败路径；`screenStartPending` 清；不写 `.recording` |
| 首帧 5 s 未到：无画面 | `.saving` → 停流确认 → 失败面板「未收到画面」；不写 saved |
| 首帧 5 s 未到：写入器失败 | 失败面板带 `failureDescription` 的上层文案；保留恢复目录 |
| 首帧 5 s 未到：有帧但写入器未接受 | 单独文案「写入器未在限定时间内接受首帧」 |
| 停流抛错未确认 | 不收敛文件；失败面板 + Finder 定位会话目录；`screenStartPending` 保持 → 新录屏被拒绝并提示 |
| 停流已确认但保存超 10 s | 面板转恢复提示（不转圈）；内部保持 `.saving`；真实保存完成后按真实结果收敛 |
| 退出时保存中超时 | 沿用 P4：不结算、返回 `.failed`、阻止退出并提示；不谎报 saved |
| Finder/Spotlight 重开 | 恢复面板与可操作控件；隐藏偏好不被改写 |

---

## 5. 证据口径

本轮只到 `Implemented`（代码 + 静态核对）。构建交由交付代理：`xcodebuild … -configuration Debug … CODE_SIGNING_ALLOWED=NO build`，并 `bash scripts/check-localization.sh`。未验证：TCC 弹窗时序、真实首帧/停流、Spotlight 重开激活行为、VoiceOver 听感、真机长录。

### 5.1 实施记录（2026-11-18）

| 要求 | 文件 | 关键符号 |
|---|---|---|
| R1 准备期可见可取消 | `RecordingControlPanel.swift`、`RecordingSessionController.swift` | `RecordingPreparationPhase`、`.preparing(kind:phase:)`、`updatePreparationPhase(_:)`、`updateStatus(.selectingSource)` |
| R2 有界枚举 / 授权不误超时 | `ScreenSourceProbe.swift`（新）、`RecordingReadiness.swift` | `ScreenSourceProbe.load()`、`sourceEnumerationDeadline`、`ScreenSourceProbeBox` |
| R3 丢弃取消后迟到结果 | `RecordingSessionController.swift` | `screenPreparationTask`、`finishSession` 清 `currentStartAttemptIdentifier`、探针后 attempt/status 复检 |
| R4/R5/R6 停流确认先于收尾 | `ScreenRecordingEngine.swift`、`ScreenRecordingSessionCoordinator.swift`、`ScreenSegmentCoordinator.swift` | `ScreenCaptureStopResult`、`stopSegmentedCapture()`、`confirmSegmentedCaptureStopped()`、`hasUnconfirmedStream`、`ScreenRecordingSessionCoordinatorError.streamStopUnconfirmed`、`materialRoot` |
| R7 停止不无限转圈 | `RecordingSessionController.swift`、`RecordingSessionController+HUD.swift` | `screenStopTask`、`finalizeRecording` 有界等待、`presentScreenStopRecovery(materialRoot:reason:canRetry:)`、`retryUnconfirmedScreenStop()`、`retryFailedPublish()` 前置分支 |
| R8 首帧三分类 | `RecordingSessionController.swift`、`ScreenRecordingPipelineAdapter.swift`、`RecordingReadiness.swift` | `classifyScreenStartFailure(adapter:)`、`ScreenStartFailureReason.writerFailed`、`hasAcceptedCaptureFrame()`、`failureDescription()`、`videoWriterWaitTimedOut` |
| R9 诊断口径 | `RecordingSignposts.swift`、`RecordingSessionController.swift` | `RecordingDiagnosticErrorClass`、`emit(_:kind:elapsedMilliseconds:errorClass:)`、`diagnosticClass(for:)` |
| R10 重开找回控制 | `AppLifecycleDelegate.swift`、`CaptureViewModel+Recording.swift`、`RecordingSessionController+HUD.swift` | `applicationShouldHandleReopen`、`restoreRecordingControlOnReopen()`、`restoreControlForReopen()` |
| DUP-1 去重一次枚举 | `RecordingSourcePickerPanel.swift`、`RecordingSessionController.swift` | `RecordingSourcePickerPanel.show(content:onComplete:onFailure:)`（不再自行枚举） |
| D10 释放未确认的可找回出口 | `RecordingSessionController.swift`、`RecordingSessionController+HUD.swift` | `ScreenReleasePhase`、`screenReleasePhase`、`screenReleaseDestination`、`presentScreenReleaseCapsule(...)`、`presentScreenReleaseCapsuleIfNeeded()`、`refreshScreenReleaseCapsule()`、`clearScreenReleaseCapsule()`、`isScreenStopInFlight` |

静态核对（本机只读）：`xcrun swiftc -frontend -parse` 对上述 14 个改动文件全部 exit 0；`bash scripts/check-localization.sh` exit 0（key/占位符四语言一致）。未构建、未测试、未运行。

### 5.2 未在本轮闭合的已知边界

- ad-hoc 签名下 `CGPreflightScreenCaptureAccess()` 可能持续返回 `false`（既有 `PermissionService` 注释已记录）。此时枚举走「授权等待」分支而不设超时：已授权时枚举会立即返回，无提示可等；只有在 ScreenCaptureKit 真正卡住时才会无限等，面板仍可取消。**不**用延长超时掩盖。
- `adapter.start` 永不返回：30 s 看门狗把 UI 收敛为 `.preparing → idle` 后展示**可重开的释放说明**（`.startUnconfirmed`），闸门保持；平台调用若最终返回，迟到成功走唯一 cleanup，迟到失败释放闸门并清除说明。若始终不返回，说明一直保留，出口是 Finder 定位与退出重开；**不声称系统一定释放**。
- 首帧清理/停流永不返回：10 s 后不再转圈，转 `.stopUnconfirmed` 说明；确认到达即清闸并清提示，未确认则提供一次显式 Retry。真实 in-flight 期间 Retry 关闭，避免二次 stop。
- 进程重启前若旧流仍未确认，只有退出重开这一条路；本轮不新增超时兜底。

---

## 6. 可证明的重复工作（与 P0 必做项分离）

> 口径：只列能在源码里指到两次以上同一工作的位置。**本轮只消除 DUP-1**（它是 R2 的实现副产物）。其余列为可选，未获范围确认前不改。下列行号为落版前基线（`fix/recording-p0` 本次改动之前），改动后偏移。

### DUP-1 · 同一次选源动作重复枚举（本轮消除一次）

证据链（一次「录屏」点击）：

1. `RecordingSessionController.startRecording()` → `captureOrchestrator.checkPermissionStatus()`（`RecordingSessionController.swift:1640`）→ `PermissionService.checkScreenCapturePermission()` 内部 `SCShareableContent.current`（`Packages/SharedKit/Sources/Permissions/PermissionService.swift:58`，失败时 `:73` 再枚举一次）。
2. `RecordingSourcePickerPanel.show` → `SCShareableContent.excludingDesktopWindows`（`RecordingSourcePickerPanel.swift:144`）。
3. `ScreenRecordingEngine.startSegmented` → `SCShareableContent.current`（`ScreenRecordingEngine.swift:168`）。

即同一次用户动作至少 3 次同源枚举（授权失败路径 4 次）。

- **消除边界**：探针完成 → 选择器呈现之间。把 (1) 的 `SCShareableContent` 直接交给选择器，删除 (2)。
- **影响**：取消/首帧/旧回调/停流/时序——无。选择器本来就只读该快照；取消仍走 `activeRequestID`；探针失败路径不变。
- **(3) 保留**：引擎必须在真正启动时解析 filter/尺寸（面板刚创建、排除窗口集合可能已变）。把快照跨进程边界传给引擎会引入「选源后显示器/窗口变化」的陈旧几何，直接影响首帧与尺寸校验 → 不是 P0，列为 **OPT-1**。

### 6.1 影响矩阵（取消 / 首帧 / 旧回调 / 停流 / 时序）

| 项 | 影响面 | 结论 |
|---|---|---|
| DUP-1（已消除） | 无 | 选择器改吃探针快照；取消仍由 `activeRequestID` 生效；旧回调仍由 attempt 守卫丢弃；停流与时序不参与 |
| OPT-1 引擎启动复用快照 | 首帧、时序、停流（源解析） | 会让「启动瞬间源已变」与「无画面」不可区分，直接影响 R8 三分类；不做 |
| OPT-2 权限服务 500 ms 重枚举 | 授权/拒绝路径时延、旧回调 | 改的是共享截图链路语义；与录屏取消无关但会改变拒绝时延；不做 |
| OPT-3 音频准备期重复推送 `.starting` | 首样本门禁路径 | `update` 已等值去重，收益≈0；同值状态重写只影响菜单栏重绘；不做 |
| OPT-4 录制中 2 s 全量枚举 | 中断检测时序 | 换成轻量探测会改变窗口移动/分辨率变化的漏检边界；不做 |
| OPT-5 显示参数变化与轮询重复枚举 | 中断检测时序 | 合并为单点复核可减少一次枚举，但会推迟一次检测；不做 |
| OPT-6 首帧轮询 Task 抖动 | 首帧门禁语义 | 去掉 bounded race 会重新引入「actor 锁住即无限等」，违反 P0 裁决；不做 |

### OPT-1 · 引擎启动时的第二次枚举（未做）

`ScreenRecordingEngine.swift:168` 的枚举是 start 时的新鲜度保证；如果改为复用选择器快照，需要同时处理：显示器分辨率变化、窗口移动、排除窗口集合更新。**风险直接落在首帧与写入器初始化**，且 R8 的三分类会失去「启动时源已变」和「无画面」的区分能力。不在本轮范围。

### OPT-2 · `PermissionService.checkScreenCapturePermission()` 失败后 500 ms 再枚举（未做）

`PermissionService.swift:58` 与 `:73`：同一次权限判定内两次 `SCShareableContent.current`，中间只 `sleep(500ms)`。可证明重复，但删除会改变「拒绝/边缘」路径的延迟与误判率，且该函数被截图链路共用（`CaptureOrchestrator.swift:296`、`SCKAdapter.swift:126`），属于共享语义变更 → 需单独范围确认。

### OPT-3 · 音频准备期按 progress tick 重复推送同一个 `.starting`（未做）

`RecordingSessionController+HUD.swift:77-79` 在 `audioStateMachine.state == .starting` 时每个 progress（≤10 Hz）都构造 `.starting(kind:.audio, awaitingFirstMedia:true)`，并在 `:98` 对不可见面板再次 `present`。`RecordingControlPanel.update(state:)` 已按 `model.state != state` 去重（`RecordingControlPanel.swift:673`），所以**没有视觉重复**，只是每 tick 一次等值比较 + 一次 `present` 分支判断。真实收益接近零，改动会碰首样本门禁路径 → 不做。

同时记录一处**同值状态重写**：`startAudio` 已在 `:456` 设 `.starting`，`markAudioPipelineStarted()` 在 `:762` 再设一次 `.starting`；`@Published recordingStatus` 每次赋值都会发通知（菜单栏重绘）。消除点明确（`markAudioPipelineStarted` 内跳过已 `.starting`），但属可选清理，未做。

### OPT-4 · 录制中每 2 s 的全量枚举（未做）

`startMonitoring()` → `recordingInterruptionReason()` 每 2 s 调 `SCShareableContent.current`（`RecordingSessionController.swift:1362`）。这是当前唯一的「源变化」探测器，同时承担断显/分辨率/窗口变化的判定。可选优化是用 `CGGetActiveDisplayList` 之类的轻量检查先过滤，仅在变化时枚举；但这会改变中断检测的时序与漏检边界（尤其窗口移动），不是 P0。

### OPT-5 · 显示参数变化时与 2 s 轮询重复枚举（未做）

`NSApplication.didChangeScreenParametersNotification` → `handleInterruptionIfSourceChanged()` 枚举一次（`:1492`），轮询循环也可能在同一 2 s 窗口内再枚举一次。可在通知里只置一个「需要复核」标记，交给唯一的监控循环枚举。属于检测路径合并，非 P0。

### OPT-6 · 首帧轮询每次新建 Task + 计时 Task（未做）

`RecordingReadiness.waitUntil` 每 100 ms 通过 `awaitBounded` 起一个工作 Task 与一个计时 Task（5 s 上限内 ≤50 对）。收益是可证明的分配抖动，但去掉 bounded race 会让「actor 被锁 → 无限等」重新出现（P0 明令禁止）→ 保留现状。

### 已核对**不存在**的重复（避免误改）

- 首帧门禁通过后没有回到准备期：`startScreenReadinessObservation` 成功后一次性置 `.recording`、`markRecordingStarted()`、启动监控（`RecordingSessionController.swift:1200-1211`），没有第二处再写 `.starting`。
- 写入器首帧信号没有双写：只有 `ScreenSegmentCoordinator.append(video:)` 的三个 append 分支在 `AVAssetWriterInput.append` 返回 `true` 时置位（`ScreenSegmentCoordinator.swift:228/235/246`）；队列接受不会置位。
- 停流不是「两次 stop」：`stopAndSave` 有 `isStopping` 与 `lastOutcome` 双守卫；本轮新增的确认失败路径仍保持单次停止尝试，重试必须由显式动作触发。
