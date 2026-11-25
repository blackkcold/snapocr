# 录制 P0 收口加固 — 四阶段计划（P1–P3 已实施，P4 编译已记录）

> **Status:** `Implemented / Compiled — tests and GUI not run`，2026-11-18。P1–P3 已按本计划实施；P4 已对 `SnapGlass` 与 `WindowLifecycleStateTests` 各做一次无签名编译（App `build`、测试 `build-for-testing`），测试未执行、App 未启动、未提交。编译证据与未验证边界见第 9 节。
> 用户已批准该方案，各阶段按“先写后开发”执行；主代理负责验收调度。
>
> **2026-11-18 P3/P4 修订：**
> 1. P3 的 HUD 宽度/高度改为按 SwiftUI 内容测量；准备/启动文案在窄宽下最多三行并实际增高，取消按钮保持完整尺寸；展开错误超过卡片上限时改为有界滚动，操作行保留。
> 2. P4 编译时补齐测试目标的 `RecordingExportRoot.swift` 成员，并把 `RecordingQuitFlowTests` 中会触发 `#expect` 宏“不可变 `$0`”限制的可变调用改为先取值再断言；断言语义未变。
>
> **2026-11-18 修订（P1/P2 交底）：**
> 1. 版本号（`version.txt` / `build.txt` / `project.yml`）只证明版本元数据匹配，不证明已交付二进制来自本工作区源码；报告中的“build 3”只能视为候选源码归属，不能据此升级为交付证明。
> 2. 旧请求的迟到结果不能一律丢弃：不改新 UI，但持有 pipeline/adapter/stream 的迟到结果必须做且只做一次清理，或登记恢复材料。
> 3. 权限与选源可以晚于请求返回：请求身份在入口先定，真正拿到选源后再冻结会话快照；不预填 selection。
> 4. 不为重构而重构：复用现有 `sessionGeneration`、`ContinuousClock`、`RecordingSignposts` 与 `RecordingReadiness`，只把身份判定和启动归属收敛成可测试的纯类型。
> Worktree：`/Users/11169285/.local/share/opencode/worktree/5d0345d699d913b55a21fac44cccbd69a3acb4ec/recording-p0`
> Branch：`fix/recording-p0` · HEAD `84e4a6a`
> 上游索引：[`2026-11-18-recording-p0.md`](./2026-11-18-recording-p0.md)（P1–P4）· 报告：[`2026-11-18-recording-p0-completion.md`](./2026-11-18-recording-p0-completion.md)

## 0. 基线与归属（只读核对，未改动）

| 项 | 实测 | 结论 |
|---|---|---|
| `version.txt` | `1.6.0` | 版本元数据匹配；**不证明**已交付二进制来源 |
| `build.txt` | `3` | 版本元数据匹配；**不证明**已交付二进制来源 |
| `project.yml:18-19` | `MARKETING_VERSION 1.6.0` / `CURRENT_PROJECT_VERSION 3` | 工程配置与报告数字一致；仍只是元数据 |
| HEAD | `84e4a6a`（`chore: 忽略本地证据目录 .context/`） | 本计划基点 |
| `fix/recording-p0` vs `release/v1.6.0` | 同一 commit `84e4a6a` | 分支未分叉 |
| tag `v1.6.0` | `843cf11`，其 `version.txt=1.6.0` / `build.txt=3` | 标签元数据与报告一致，不等于二进制等价 |
| 未提交变更 | 41 个已跟踪文件改动（3896+/704−）+ 18 个未跟踪文件，其中 8 个新 Swift 源文件 | **可核实的源码候选**在本工作树的工作区，不在 tag 快照里 |
| 参考文件存在性 | `RecordingSessionController.swift`(2229 行)、`RecordingControlPanel.swift`(815)、`RecordingHUDLayout.swift`(145)、`RecordingReadiness.swift` 均在位 | 路径与报告一致，无需迁移 |

**归属裁决：** 版本号与工程配置只能证明“报告数字与当前元数据匹配”，不能证明已交付的 build 3 二进制由本工作区编译而来。当前唯一可核实的源码候选是“`84e4a6a` + 当前未提交工作区”。本计划只在该候选上追加，不改写、不丢弃既有未提交改动，不提交、不切分支；也不把任何构建结果称为“与已交付二进制一致”。

## 1. 现状与缺口（行号以当前工作区为准）

| # | 事项 | 当前实现 | 缺口 |
|---|---|---|---|
| 1 | 不可变请求身份 | `RecordingSessionSnapshot`（`:100-109`）字段全 `let`，但 `activeSession` 在 `:1190` 于多个 `await` 之后才落库；身份由 `sessionGeneration: UUID` + `currentStartAttemptIdentifier` 两套并行 | 请求身份应在权限/选源之前同步确定，选源到手后再冻结快照；两套身份收敛为 `generation` 单轨。迟到结果按“是否当前身份 + 是否仍持资源”分流，而不是一律丢弃 |
| 2 | 已启动等首帧的取消与迟到清理 | `:1399` 轮询 `hasWrittenVideoFrame` 后进入 `:1427 finalizeStartingWithoutFrames`；`:456 cancelStartingSession` 只置 `stopWhenStarted`；`:1483 runScreenCleanup` 有界收尾 | 必须把“start 尚未返回”和“start 已返回、等首帧”分成两条取消路径；已返回待首帧时立即对现存 adapter 发起唯一一次 stop；未确认释放保留占用，确认后同进程可再录 |
| 3 | 可控测试时间源 | `RecordingReadiness` 内部使用 `ContinuousClock`；控制器内 `phaseStartedAt` 硬编码 `ContinuousClock.now`（`:217/1045/1267/1435/1527/2122`） | 阶段时长需要可注入的 `RecordingPhaseClock`，测试不靠 sleep；就绪轮询继续用 `RecordingReadiness` 的真实 clock |
| 4 | 真实阶段与脱敏诊断 | `RecordingPreparationPhase`（`RecordingControlPanel.swift:10-16`）仅 5 个通用态；signpost 已按 numeric class 脱敏（`:1050`）、`announcePhase` 四语言播报（`:1085`） | 缺“权限等待 → 目录检查 → 音频/屏幕启动 → 等首个音频样本/首个写入帧”的独立可见态；需要四个启动阶段并各发一条只带数值 stage 的 signpost |
| 5 | 四语言 HUD | 抽查 `Starting recording`/`Saving recording`/`Cancelled` 四语言齐全 | 需对 HUD 专用键做一次清单式静态核对（含计数/计时/失败/暂停/取消五组），不新造键 |
| 6 | 自适应外窗 | `RecordingHUDMetrics`（`RecordingHUDLayout.swift:26-33`）为固定宽高（176/236/252/344） | 无按本地化文案测宽的自适应；长语言（ja/ko）易挤压 |

## 2. 阶段地图

| 阶段 | 主题 | 主要落点 | 依赖 |
|---|---|---|---|
| P1 | 不可变请求身份 + 可控时间源 | `RecordingSessionController.swift`、`RecordingReadiness.swift`、`RecordingQuitFlow.swift`（新增 `RecordingRequestIdentity` / `RecordingPhaseClock`） | 无 |
| P2 | 首帧取消/迟到清理 + 真实阶段与脱敏诊断 | `RecordingSessionController.swift`、`RecordingSessionController+HUD.swift`、`RecordingControlPanel.swift`、`RecordingQuitFlow.swift`（新增 `RecordingStartOwnership` / `RecordingStartPhase`）、`Packages/CaptureCore/Sources/Recording/RecordingSignposts.swift` | P1 |
| P3 | 四语言 HUD + 自适应外窗 | `Packages/CaptureCore/Sources/RecordingHUDLayout.swift`、`RecordingControlPanel.swift`、四个 `Localizable.strings` | P2 |
| P4 | 一次改后必要编译/类型检查 + 最终静态复核 | 无源码改动（仅证据） | P1–P3 |

执行顺序固定 **P1 → P2 → P3 → P4**；`RecordingSessionController.swift` 串行改，不并行。新增纯类型放在已纳入 `WindowLifecycleStateTests` 测试目标的 `RecordingQuitFlow.swift`，测试放在同目标的 `RecordingQuitFlowTests.swift`，不新增 target/scheme，不改 `.xcodeproj`。

## 3. P1 — 请求身份与时间源

**目标：** 一次调用产生一个不可变身份；权限与选源可以晚于请求返回，身份在请求入口先定，真正拿到选源后再冻结会话快照；迟到完成按“是否仍属于当前身份”和“是否仍持有资源”分流；阶段时长可注入。

**Owned files：** `App/SnapGlass/Sources/Recording/RecordingSessionController.swift`、`App/SnapGlass/Sources/Recording/RecordingQuitFlow.swift`（纯类型落点）；继续复用 `RecordingReadiness.swift` 的既有截止时间，不另造一套。

**步骤：**
1. 在 `RecordingQuitFlow.swift` 增加 `RecordingRequestIdentity`：只承载请求级不可变事实 `generation: UUID`（直接复用现有 `sessionGeneration`，不引入第二套 id）与 `kind: RecordingKind`，全部 `let`、`Sendable`。在 `startRecording()` / `beginAudioRequest()` 的第一个 `await` 之前同步构造，并令 `sessionGeneration = identity.generation`。
2. `RecordingSessionSnapshot` 保留来源/配置/目标等字段，但新增 `request: RecordingRequestIdentity`，只在权限通过、用户真正选定来源、目标目录校验通过后一次性构造（冻结）。权限等待和选源面板期间不构造快照，也不预填 selection。
3. 删除 `currentStartAttemptIdentifier` 双轨，改为 `currentRequest: RecordingRequestIdentity?`；所有迟到判定统一为 `identity.isCurrent(generation: sessionGeneration)` 或 `identity.disposition(generation:holdsResource:)`。
4. 迟到分流必须区分两种结果，并落实为 `RecordingLateResultDisposition`：
   - `.apply`：仍属当前身份，允许写状态。
   - `.cleanupOnly`：不属于当前身份但仍持有 pipeline/adapter/stream；只做一次资源清理或登记恢复材料，不改当前 UI、不写新会话状态、不 toast。
   - `.discard`：既不属于当前身份、又不持有资源；不写状态、不 toast、不登记材料。
   音频迟到成功继续走既有 `scheduleAudioRetirement`；屏幕迟到 start 成功走一次性 cleanup；迟到首帧只登记恢复材料，不复活会话。
5. 在 `RecordingQuitFlow.swift` 增加 `RecordingPhaseClock`（默认 `ContinuousClock`，可注入 `now` 闭包）；控制器 `phaseStartedAt` 统一改为 `clock.now`，`phaseElapsedMilliseconds()` 走 `clock.milliseconds(since:)`。就绪/超时轮询仍由 `RecordingReadiness` 的真实 clock 负责，避免把“阶段计时”和“就绪截止时间”混成一套假时钟。
6. 音频请求入口：`beginAudioRequest()` 在麦克风权限提示之前建立身份、进入 `.selectingSource` 并显示权限等待；`startAudio(..., request:)` 只接受仍属当前身份的请求。权限返回后若请求已被取消/替换，抛既有 `supersededStart`，不创建 pipeline、不改 UI。

**完成判据：** 控制器内不再有第二套启动身份；`grep currentStartAttemptIdentifier` 为空；身份不匹配且不持资源的迟到结果不产生状态写入、toast 或材料登记；身份不匹配但持资源的迟到结果恰好清理一次。

**证据口径：** 静态引用截图/行号 + 差异说明；本阶段不构建。

## 4. P2 — 首帧取消与真实阶段

**目标：** “已启动、等首帧”期间的取消是确定的：UI 立即收敛，迟到首帧只进恢复材料，不复活会话；用户看到的阶段与真实资源阶段一致；原 adapter 只停一次，未确认释放保留占用，确认后同进程可再录。

**Owned files：** `RecordingSessionController.swift`、`RecordingSessionController+HUD.swift`、`RecordingControlPanel.swift`、`RecordingQuitFlow.swift`、`Packages/CaptureCore/Sources/Recording/RecordingSignposts.swift`。

**步骤：**
1. 在 `RecordingQuitFlow.swift` 增加 `RecordingStartOwnership` 纯状态机，作为屏幕启动归属的唯一事实：
   - `stage`: `idle` / `platformStartOutstanding` / `awaitingFirstFrame` / `recording` / `stopping` / `stopUnconfirmed`；
   - `beginStart(generation:)`、`platformStartReturned(generation:)`、`firstFrameAccepted(generation:)`、`requestCancel(generation:)`、`beginInitialStop(generation:)`、`stopConfirmed(generation:)`、`stopUnconfirmed(generation:)`、`beginStopRetry(generation:)`、`startFailed(generation:)`；
   - `blocksNewStart` 直接替代 `screenStartPending` 的语义，`isPlatformStartOutstanding` 替代 `screenPlatformStartPending`。
2. 取消分流（`cancelStartingSession`）：
   - `.stopWhenStartReturns`：start 尚未返回。置 `stopWhenStarted`，UI 有界收敛，迟到 start 成功时对 adapter 执行唯一一次 cleanup；迟到 start 普通失败时只释放本次请求的 gate，不碰新 UI，并清掉旧 release 提示。
   - `.cancelFirstFrameWait`：start 已返回、仍在等首帧。立即取消 `screenReadinessTask`，对现存 adapter 调用一次 `runScreenCleanup`，再收敛 UI；不进入 `.recording`，迟到首帧不再 `updateStatus`/toast。
   - `.alreadyStopping`：已有 stop 在跑，只等待/展示，不再发第二次 stop。
   - 倒计时结束后、目录复查仍悬挂时，状态切到 `.selectingSource` + `.verifyingDestination`（真实、可取消），不保留已结束的倒计时；复查的 `await` 成功/失败在恢复后由 `RecordingDestinationRecheck` 统一按身份交接，过期结果不启动、不报错、不结束新请求。
3. `runScreenCleanup`、`finalizeRecording`、`finalizeStartingWithoutFrames`、`finishScreenRecording`、`retryUnconfirmedScreenStop` 全部走 `beginInitialStop` / `beginStopRetry` / `stopConfirmed` / `stopUnconfirmed`：
   - 初次 stop 每个 adapter 至多一次；
   - stop 未确认时 `stage = .stopUnconfirmed`，gate 保持关闭，`unconfirmedScreenStop` 保留 adapter 与 materialRoot；
   - 重试确认后 `stopConfirmed` 释放 gate，同进程可立即再次 `beginStart`；
   - 普通失败（非 `streamStopUnconfirmed`）也要正确释放 gate，避免遗留 `startUnconfirmed` 假象；
   - 未成为 recording 的 start cleanup 确认后若有已发布片段，登记到既有 `pendingRecoveryIDs` / `recoveryMaterials(for:)`，不改 UI、不 toast。
4. 阶段：在 `RecordingControlPanel.swift` 定义 `RecordingStartPhase` 四态 `startingAudioPipeline` / `awaitingFirstAudioSample` / `startingScreenWriter` / `awaitingFirstVideoFrame`（定义放 `RecordingQuitFlow.swift` 以便测试），`RecordingControlPanelState.starting` 携带该阶段而不是布尔 `awaitingFirstMedia`；映射到既有 `status`，不新增并行状态机。
5. 诊断：`RecordingSignposts` 增加只带数值 `stage` 与毫秒时长的启动阶段事件；控制器在权限等待、目录检查、音频/屏幕启动、首个样本/首个写入帧各发一条，不写来源名、路径、文件名或错误文本。注意：视频只在 writer 接受帧后才算“首个写入”，音频只声明“收到首个样本”，不得把回调到达说成已写入。
6. VoiceOver 播报复用 `announcePhase`；四个新阶段文案复用既有四语言键（`Preparing audio recording` / `Waiting for the first audio sample…` / `Preparing screen recording` / `Waiting for the first video frame…`），本阶段不新增语言键。

**完成判据：** 首帧等待期取消后，`status` 不回到 `.recording`；迟到首帧不产生第二次 `updateStatus`/toast；四个新阶段都能在面板状态里被单独观测；同一 adapter 的初次 stop 不会发出两次；未确认 stop 时新录制被 gate 拒绝，确认后同进程可再开始。

**证据口径：** 静态调用链说明（取消 → 收敛 → 迟到丢弃/清理）；不启动 App、不做 GUI/TCC 复核。

### 4.1 可控回归测试计划（与 P2 同批落地）

测试放在已纳入现有 `WindowLifecycleStateTests` 目标的 `App/SnapGlass/Tests/RecordingQuitFlowTests.swift`，生产逻辑放在同目标已编译的 `App/SnapGlass/Sources/Recording/RecordingQuitFlow.swift`；不新增 target/scheme、不手改 `.xcodeproj`、不复制一份被测逻辑、不使用任意延时。

| # | 用例 | 覆盖竞态 | 断言要点 |
|---|---|---|---|
| 1 | start 未返回时取消，迟到 start 成功 | 竞态 A | 取消返回 `.stopWhenStartReturns`；gate 保持；迟到返回不晋升 UI；`beginInitialStop` 第一次成功、第二次失败；unconfirmed 保留占用；retry 确认后同进程可再次 `beginStart` |
| 2 | start 已返回、等首帧时取消 | 竞态 A | 取消返回 `.cancelFirstFrameWait`；迟到 `firstFrameAccepted` 为 false；cleanup 只发一次；UI 不回到 recording |
| 3 | 已晋升 recording 后取消 | 竞态 A 边界 | `requestCancel` 返回 `.notStarting`，由正常 stop 处理，不误走首帧取消 |
| 4 | 旧 generation 的失败/成功不释放新 gate | 竞态 B | `startFailed(other)` / `platformStartReturned(other)` 返回 false；当前 gate 仍关闭；新 `beginStart` 被拒绝 |
| 5 | stop 未确认 → 重试确认 → 同进程再录 | 竞态 B | `stopUnconfirmed` 后 `blocksNewStart`；`beginStopRetry` 仅在该阶段成功；`stopConfirmed` 后 `beginStart` 成功 |
| 6 | 身份与迟到结果分流 | P1 | 同 generation `.apply`；异 generation + 持资源 `.cleanupOnly`；异 generation + 无资源 `.discard` |
| 7 | 可注入阶段时钟 | P1 | 固定 `now` 闭包下毫秒数确定，不 sleep |
| 8 | 四阶段数值映射唯一 | P2 | 四个 `RecordingStartPhase` 的 `diagnosticCode` 互不相同且稳定 |
| 9 | 目录复查 A/B 成功与失败真实交接 | P2 / 请求归属 | 复查挂起 → A 取消且 B 开始 → 释放 A 的成功/失败；A 的启动、报错、结束计数均为 0，B 仍为 current 且可正常走自己的成功；当前请求 A 的成功/失败正向对照 |
| 10 | 首帧取消的假 adapter stop 计数 | 竞态 A | 真实 `ScreenRecordingPipelineAdapter` 的 stop 闭包只被调用一次；迟到帧不晋升；`stopConfirmed` 后可再次 `beginStart` |

本阶段只写测试源码，**不运行测试/构建**；由主代理在 P4 统一编译验收。

## 5. P3 — 四语言 HUD 与自适应外窗

**目标：** HUD 文案四语言完整；外窗宽度随内容自适应且不抖动。

**Owned files：** `Packages/CaptureCore/Sources/RecordingHUDLayout.swift`、`RecordingControlPanel.swift`、`App/SnapGlass/Resources/{en,ja,ko,zh-Hans}.lproj/Localizable.strings`。

**步骤：**
1. 列出 HUD 实际使用的字符串键（计数、计时、暂停、保存、失败、取消、通知），逐一核对四个 `.strings`；只补缺失，不改既有译文，不引入 `NSLocalizedString`。
2. `RecordingHUDMetrics` 由固定 `CGSize` 改为“文案测宽 + 上下限”：保留现有数值为 `min`/`max` 基准，避免视觉跳变。
3. `RecordingControlPanel.resize` 只在“内容测量宽度变化超过阈值”时调整窗口，电平/计时更新不触发 `layoutSubtreeIfNeeded`。
4. 四角定位与 `screenMargin` 语义不变，窄屏时宽度不超出 visible frame。

**完成判据：** 四语言键集合无缺项（清单式对齐）；同一状态下重复刷新窗口 frame 不变；最长译文不裁切。

**证据口径：** 键清单对照表 + 宽度计算说明；不构建、不截图运行。

## 6. P4 — 一次必要编译/类型检查与最终静态复核

**目标：** 只做一次改后必要验证，并给出诚实的静态复核结论。

**步骤：**
1. 改完后只执行一次无签名 Debug 构建 + 类型检查（命令与参数沿用既有计划口径，记录 exit code 与首条错误）。P1/P2 实施子代理不运行基线、构建或测试；由主代理集中执行。
2. 静态复核：身份单轨、取消幂等、阶段映射、四语言键、窗口尺寸变更点各给一条“看哪里”。
3. 报告状态用 `Compiled` / `Not verified`，不得写 `Validated`；测试、GUI/TCC、真实录制、性能剖析均记为未运行。
4. 新增测试若未在本轮执行，明确记为 `Written — not run`，不得由静态阅读推断为通过。

**完成判据：** 构建 exit 0 或如实记录失败；复核清单每项有文件与行号。

## 7. 全局约束

- Swift 6、macOS 13 最低版本；协议优先、最小变更；不使用 `NSLocalizedString`，本地化走 `AppLocalization`。
- 四语言（en/ja/ko/zh-Hans）同步；不新增权限 key、不改 entitlements、不改 TCC。
- 不改 `.context/`、不提交、不切分支、不动旧工作树与 tag。
- 不新增录制框架；沿用 `RecordingSessionPipeline` / `ScreenRecordingSessionCoordinator` / `RecordingSessionController` 边界。

## 8. 不在本轮范围

真实录制/性能剖析、GUI/TCC 手工验收、独立评审、发布与版本号变更、旧工作树迁移、`Docs/RELEASE.md` 验证结论升级。

## 9. P4 编译证据与未验证边界（2026-11-18）

**状态口径：** `Implemented / Compiled — tests and GUI not run`。本轮只证明源码在无签名 Debug 配置下可编译，不证明运行时行为、GUI/TCC、真实录制或测试通过。

### 9.1 P3 窄宽换行与错误滚动收口

| 项 | 落点 | 说明 |
|---|---|---|
| 准备文案换行 | `App/SnapGlass/Sources/Recording/RecordingControlPanel.swift:313-321` | `preparing` 文字改为 `lineLimit(3)` + `fixedSize(horizontal:false, vertical:true)`，高度参与测量 |
| 启动文案换行 | 同文件 `:383-391` | `starting` 同上；取消按钮保持 `.fixedSize()` |
| 多行垂直内边距 | 同文件 `:262-273` | 仅 preparing/starting 增加 6 pt 上下内边距；录制态保持 0，稳定计时胶囊仍为 40 pt |
| 高度上限 | `Packages/CaptureCore/Sources/RecordingHUDLayout.swift:105-112` | `recordingBounds.maxHeight` 40 → 68，只供准备/启动换行使用；录制内容实测仍为 40 |
| 错误超高滚动 | `RecordingControlPanel.swift:706-714`、`:746-752`、`:1014-1051` | 展开错误先测自然高度；超过 `failureBounds.maxHeight`（180）时把文本列限制为 `maxHeight - 64` 并在 `ScrollView` 内滚动，操作行留在滚动区外 |
| 滚动预留 | `RecordingHUDLayout.swift:119-129` | `failureExpandedChromeHeight = 64`（内边距、间距、操作行），保证滚动区外仍有恢复/定位/关闭 |

测高仍是两遍 `NSHostingController.sizeThatFits`：`.ideal` 取理想宽度，`.fixedWidth(w)` 取该宽度下的实际换行高度；只有尺寸变化 ≥ `0.5 pt` 才改 frame。

### 9.2 实际编译命令与退出码

两个目标使用同一组参数，均禁止签名、禁止自动包解析与包更新，并复用 `.context/recording-p0`：

```bash
DERIVED=".context/recording-p0/DerivedData"
SOURCES=".context/recording-p0/SourcePackages"
SPARKLE="$PWD/.context/recording-p0/SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"

xcodebuild -project SnapGlass.xcodeproj -scheme SnapGlass -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  -clonedSourcePackagesDirPath "$SOURCES" \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  SPARKLE_FRAMEWORK_PATH="$SPARKLE" build

xcodebuild -project SnapGlass.xcodeproj -scheme WindowLifecycleStateTests -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  -clonedSourcePackagesDirPath "$SOURCES" \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  SPARKLE_FRAMEWORK_PATH="$SPARKLE" build-for-testing
```

| 目标 | 最终日志 | 退出码 | 成功标记 | `error:` | `warning:` |
|---|---|---|---|---|---|
| SnapGlass `build` | `/private/var/folders/ks/flqyrh0j5wvf2t7v4s7lcnz0b5tfzv/T/opencode/p3-p4-SnapGlass-build-3.log` | 0 | `** BUILD SUCCEEDED **`（第 1485 行） | 0 | 59 |
| WindowLifecycleStateTests `build-for-testing` | `/private/var/folders/ks/flqyrh0j5wvf2t7v4s7lcnz0b5tfzv/T/opencode/p3-p4-WindowLifecycleStateTests-build-for-testing-3.log` | 0 | `** TEST BUILD SUCCEEDED **`（第 224 行） | 0 | 7 |

产物：`.context/recording-p0/DerivedData/Build/Products/Debug/WindowLifecycleStateTests.xctest` 已生成；测试未执行。

### 9.3 过程中的失败与最小修正

1. **App 首次编译失败（exit 65）**：`Embed Sparkle` 脚本报 `Sparkle.framework not found; resolve packages first`。编译本身已走完，失败只在 post-build 嵌入阶段。按任务要求把 `SPARKLE_FRAMEWORK_PATH` 指向 `.context/recording-p0/SourcePackages` 下的绝对路径后重编，App 通过。首次日志：`p3-p4-SnapGlass-build.log`；修复后日志：`p3-p4-SnapGlass-build-2.log`、`-3.log`。
2. **测试目标首次编译失败（exit 65）**：`RecordingExportViewModel.swift` 找不到 `RecordingExportRoot`，原因是 `project.yml` 的 `WindowLifecycleStateTests` 源清单漏了新文件。仅在 `project.yml:192` 增加 `App/SnapGlass/Sources/Recording/RecordingExportRoot.swift`，用 XcodeGen 2.45.4 重新生成工程；`.xcodeproj` 为未跟踪生成物，未覆盖任何已跟踪工程文件。日志：`p3-p4-WindowLifecycleStateTests-build-for-testing.log`。
3. **测试目标第二次编译失败（exit 65）**：`RecordingQuitFlowTests.swift` 中 40 处 `#expect(ownership.mutatingCall(...))` 触发 `#expect` 宏的不可变 `$0` 限制。仅把这些表达式改为“先 `let` 取返回值，再 `#expect`”，断言语义不变；未改生产代码。日志：`p3-p4-WindowLifecycleStateTests-build-for-testing-2.log`。
4. 修复后测试目标通过；日志 `p3-p4-WindowLifecycleStateTests-build-for-testing-3.log`。

### 9.4 未验证边界

- 测试源码为 `Written + compiled — not run`；未执行任何单测、基线、性能或专项检查。
- 未启动 App、未做 GUI/TCC 手工验收、未截图、未真实录制；窄宽换行、增高、错误滚动、VoiceOver 顺序与键盘焦点均未在运行时观察。
- 未独立复核、未发布、未改版本号、未提交。
- `NSHostingController.sizeThatFits` 的实际像素结果、窄屏钳制与“同一状态不抖动”需要在运行时验收；本轮只证明可编译。
- Sparkle 嵌入依赖显式 `SPARKLE_FRAMEWORK_PATH`；显式 `-clonedSourcePackagesDirPath` 下脚本自带的 `CLONED_SOURCE_PACKAGES_DIR_PATH` 回退未生效，属构建环境边界，不是源码结论。
- 方案枚举时执行过一次 `xcodebuild -list`，它触发了本地缓存包的 working copy 创建（日志为 `cached`，未联网下载）；随后两次正式编译均显式复用 `.context/recording-p0/SourcePackages`、`-disableAutomaticPackageResolution` 与 `-skipPackageUpdates`。

