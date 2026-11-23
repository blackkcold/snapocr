# 录制 P0 修复 — 实施索引（计划先行）

> **Status:** `Implemented — targeted Debug build exit 0; tests not run; not verified`，2026-11-18。P1–P4 已实现；P4 增加 §0 具体偏差修正、静态本地化校验与一次 App+CaptureCore 定向无签名构建。未运行测试、GUI/TCC、真实录制或性能剖析。
> 用户已批准实施，并明确豁免运行时验证与独立评审；本文件不设二次批准门禁，也不构成“已验证”。
> Worktree：`/Users/11169285/.local/share/opencode/worktree/5d0345d699d913b55a21fac44cccbd69a3acb4ec/recording-p0`
> Branch：`fix/recording-p0`（base `84e4a6a`，release/v1.6.0）

**Goal:** 把已批准的 P0 方案 A/B/C 拆成三个可独立派发的实现切片和一个收尾切片；每个切片有明确 owned files、接口、步骤、失败处理与证据口径，供子代理顺序执行、主代理在阶段间合并，不重复评审。

**Architecture:** 产品行为最小变更。A 切片修正“状态与用户看到的事实”，B 切片把主线程 I/O 与重复采集工作收窄，C 切片拆设置页并按 kind 持久化；D 只做定向构建/类型检查。所有新代码沿用现有 `RecordingSessionPipeline` / `ScreenRecordingSessionCoordinator` / `RecordingSessionController` 边界，不新建录制框架。

**Design spec（只引用相关节）:** `Docs/superpowers/specs/2026-11-11-audio-and-segmented-recording-design.md` §5.7、§5.8、§5.10、§5.11、§5.12、§5.13、§6.3、§6.5。
**Project rules:** `Docs/AGENTS.md`（Swift 6、macOS 13、四语言、无 `NSLocalizedString`、协议优先、最小变更）。

---

## 1. 阶段地图（可单独派发）

| 阶段 | 文档 | 主题 | 主要落点 | 依赖 |
|---|---|---|---|---|
| P1 | [`2026-11-18-recording-p0-p1-lifecycle-truth.md`](./2026-11-18-recording-p0-p1-lifecycle-truth.md) | 生命周期真相、取消/退出有界、恢复材料隔离、按角色权限、隐私安全 signpost、VoiceOver | App 控制器 + CaptureCore 进度/协调器信号 | 无 |
| P2 | [`2026-11-18-recording-p0-p2-main-thread-and-capture.md`](./2026-11-18-recording-p0-p2-main-thread-and-capture.md) | 目标卷/容量 I/O 离主线程、SCK 内容与 filter 复用、HUD 电平不触发 resize、真实分层丢帧 | App 控制器/面板 + CaptureCore 引擎/协调器 | P1（同文件串行） |
| P3 | [`2026-11-18-recording-p0-p3-per-kind-settings.md`](./2026-11-18-recording-p0-p3-per-kind-settings.md) | 原生设置页拆分、按 kind 输出目录/AAC 码率、调用时快照、一次性 seed、历史/导出双根 | SharedKit 偏好 + 设置视图 + 导出窗口 | P1、P2（控制器快照） |
| P4 | [`2026-11-18-recording-p0-p4-closeout.md`](./2026-11-18-recording-p0-p4-closeout.md) | 文档/CHANGELOG、四语言、定向构建与可选回归源编译、最终 diff 口径 | 文档 + 构建证据 | P1–P3 |

执行顺序固定为 **P1 → P2 → P3 → P4**。不要并行改 `RecordingSessionController.swift`；P2/P3 对它的改动必须建立在 P1 已合并的工作树上。

**Resumable ledger:** `.context/recording-p0/progress.md`（base commit 已忽略 `.context/`；本计划不修改 `.gitignore`）。

---

## 2. 接口复核（本次只读核对，行号以当前 worktree 为准）

| 复核点 | 当前实际实现 | 结论 |
|---|---|---|
| `RecordingSessionController.swift:189` `hasPendingBackgroundFinalization` | 把 `audioStopRequested`、`audioStopTask`、`.finalizing`、`audioRecoveryPending` 合在一个布尔里 | **需拆**：恢复待处理不是活动保存；否则退出/开始新会话被旧材料卡住 |
| `RecordingSessionController.swift:276` `startAudio` | `guard status == .idle, !isAudioSessionActive, !hasPendingBackgroundFinalization`；`pipeline.start` 返回后立即 `markAudioPipelineStarted()` | **需门禁**：start 返回 ≠ 收到真实样本；当前也没有 per-session generation 防止迟到完成 |
| `RecordingSessionController.swift:459` `completeAudioSession` | `guard lastAudioResult == nil` 后写结果；`saved` 由 `failure == nil && segmentCount > 0` 判定 | 可复用为单一 terminal settle 的基础，但需与 quit 路径共用且可重入 |
| `RecordingSessionController.swift:535` `prepareDestination` | `fileExists` / `isWritableFile` / `createDirectory` / `availableBytes` 同步执行于 MainActor | **需移到有界 worker**；低空间阈值 1 GiB / 512 MiB 语义保持不变 |
| `RecordingSessionController.swift:625` 屏幕开始 | `adapter.start` 成功即 `updateStatus(.recording)` | **需门禁**：应以协调器“writer 已写入首帧”为准（`engine.hasAcceptedVideoFrame` 在 segmented 路径只是队列接受） |
| `RecordingSessionController.swift:698` `startMonitoring` | 每 2s 检查丢帧/中断 | 保留；门禁超时后仍由它给可见失败，不伪装 recording |
| `RecordingSessionController.swift:880` `updateStatus` | 按状态更新面板；音频 meter 走 `RecordingHUDPresentation` | meter 变化会进入 `update(state:)` → `resize`，P2 处理 |
| `RecordingPipelineSpaceGate.swift:330` `makeSpaceGated` | `:345` 在工厂内同步 `budget.preflight()`；工厂由 `@MainActor` 闭包调用 | **需移出主线程**；`RecordingSessionPipeline.start` 已有同样的 `spaceGate.preflightStart()`，可保留为唯一启动门禁 |
| `ScreenRecordingEngine.swift:135` `startSegmented` | `:154` 每次启动 `SCShareableContent.current`；`:559` 每次排除窗口变化再枚举一次；`:325` `hasAcceptedVideoFrame` 在 segmented 路径取 `SegmentedRecordingSampleOutput` 的“队列已接受”，不是 writer 已写入 | **可复用 + 需补真实信号**：P1 在协调器加 writer 已写入首帧；P2 做启动快照与按需刷新 |
| `ScreenRecordingSessionCoordinator.swift:250/333/410` | start 建立 journal/stream；`append(video:)` 在 `writer.append` 前可能因无 sync 帧而不写；stop 汇总 `streamDroppedFrames + writer drops`；consume 写入帧并启动音频 | 丢帧只有两级合计，缺 per-stage；P2 加结构化计数，不改质量 |
| `RecordingControlPanel.swift:625` `resize` | `update(state:)` 只要 state 不等就 `resize`；音频态还 `layoutSubtreeIfNeeded()` | **需修**：电平变化不得触发布局/尺寸 |
| `RecordingPreferencesView.swift:52` | 单个 `recording` 页同时含音频、视频、HUD、存储；音频码率用共享 key；目录用共享 key | **需拆页 + 按 kind 持久化**；HUD 外观是唯一有意共享项，需标注 |

**已确认不需要改：** `App/SnapGlass/SnapGlass.entitlements` 注释已写 `com.apple.security.device.audio-input`，且未声明 key；`Info.plist` 已有 `NSMicrophoneUsageDescription`。本计划**不改 entitlements、不改 TCC、不新增权限 key**。

**明确不采纳的审计说法：** 不能声称 `AsyncStream` 的 `.bufferingNewest` + `yield` 永不丢值；`yield` 可以返回 `.dropped`。计划只要求消费者读取“最新值”，不要求无损队列。

---

## 3. 已定裁决（实施者按此执行，不再讨论架构）

- **D1 状态即事实。** 屏幕 readiness = 首个被 writer 写入的视频帧（协调器 `hasWrittenVideoFrame`，不是队列已接受）；音频 readiness = `capturedSamples > 0` 的真实样本，不用电平/响度代替。未满足时保持 `.starting` 或给可见失败，不进入 `.recording`。
- **D2 一个 terminal outcome。** stop、取消、退出、失败收敛到同一幂等 settle；session generation 不匹配的完成一律丢弃。底层 OS 调用不返回时，UI 在有限等待后给出 `failed`（不称已保存），后台保存/材料继续保留。
- **D3 恢复与保存分离。** 待恢复材料独立于活动保存；不删除、不自动清理、不阻塞退出；以 quarantine 登记，显式释放后才允许后续清理。
- **D4 设置按 kind 独立。** 输出目录与 AAC 码率分别持久化；旧共享值只在首次启动 seed 一次，之后不再回读共享 key。屏幕/音频来源 key 原样保留；目录发现、历史、恢复、热键不退化。
- **D5 性能只做必要项。** 只移动同步 I/O、复用 SCK 枚举、隔离 HUD 电平、补真实分层丢帧；不重写 checkpoint/durability、不优化截图架、不改变 59 分钟分段、不降画质。

---

## 4. 证据与状态口径（防止“计划当验收”）

| 级别 | 含义 | 本计划允许写 |
|---|---|---|
| `Planned` | 只写了步骤，未改代码 | “计划已写” |
| `Implemented` | 代码已改，静态核对 owned files/接口 | “已实现，未构建” |
| `Compiled` | P4 定向 build/typecheck 有输出 | “定向编译通过；未跑测试” |
| `Validated` | 运行真机/长录/听测等 | **本轮不追求，不得声称** |

P1–P3 子代理交付时只能报 `Implemented`，并列出未运行项。P4 最多到 `Compiled`。任何“通过/已修复/可发布”都必须带限定语。

---

## 5. 全局约束（所有切片继承）

- macOS 13 最低版本；只用现有 API（`OSSignposter` 可用；不用 macOS 14+ 的 `ContentUnavailableView`、`@Observable`、新 `onChange` 双参形式）。
- 不新增 SPM target/依赖；不改 `Package.swift` 既有协议；不手改 `.xcodeproj`；不新增外部二进制。
- 视图内文案用 `LocalizedStringKey` 字面量；视图外用 `AppLocalization.string`；新增/修改文案同步 `en` / `zh-Hans` / `ja` / `ko` 四个 `Localizable.strings`。
- 每个 public API 补 `///`；遵循 `.swift-format` / `.swiftlint.yml`；不使用 force unwrap。
- 不提交、不 stage、不 push、不 merge、不打包、不签名、不安装、不跑 GUI/TCC/长录/性能剖析。
- 不改截图架/截图并发语义；保留 59 分钟产物、录屏与截图共存、现有画质与码率语义。
- 不新增用户可见的“关闭恢复/关闭安全暂存”开关；不把缺失能力做成灰掉的核心控件。

---

## 6. 集成与交接方式

1. 主代理把某个阶段文档 + 本索引路径交给一个实现子代理；子代理只改该阶段 **Owned files**。
2. 子代理完成后写 `.context/recording-p0/progress.md` 对应条目（状态、改动文件、未验证项、需要下游知道的接口变化）。
3. 主代理在阶段边界看 `git diff --stat` 与该阶段的接口清单，不启动独立评审、不重复跑验证；有冲突只做机械合并与接口对齐。
4. P3 完成后由 P4 统一做文档、四语言与定向编译；主代理最终检查 diff/输出。
5. 中途恢复：先读 `.context/recording-p0/progress.md` 的 “Next action”，再读对应阶段文档，不重跑既有基线。

---

## 7. 不在本轮范围

- 重做 P0 验证矩阵、旧 OS/真机/长录/听测/掉电/外置卷证据。
- 修改 `.bufferingNewest` 策略、重写 checkpoint 事务、优化截图架、改导出编码策略。
- 新增权限、entitlements、TCC 重置、签名/安装/发布流程。
- 视觉重设计；只允许现有卡片/紧凑面板体系内的设置页拆分与标注。

---

## 8. 实施证据（2026-11-18）

| 阶段 | 状态 | 证据 |
|---|---|---|
| P1 lifecycle truth | `Implemented — targeted build passed; tests not run; not verified` | P4 §5；`RecordingSessionController`、`RecordingReadiness`、`RecordingQuitFlow` 编译通过 |
| P2 main-thread & capture | `Implemented — targeted build passed; tests not run; not verified` | P4 §5；`RecordingDestinationProbe` 修正 async 锁后编译通过 |
| P3 per-kind settings | `Implemented — targeted build passed; tests not run; not verified` | P4 §5；四语言 key/占位符一致 |
| P4 closeout | `Executed — targeted build exit 0; tests not run; not verified` | `Docs/superpowers/plans/2026-11-18-recording-p0-completion.md` |

关键命令与结果：

- `xcodegen generate` → exit 0。
- `bash scripts/check-localization.sh` → exit 0，`✅ Localization check passed`。
- `xcodebuild -project SnapGlass.xcodeproj -scheme SnapGlass -configuration Debug -destination 'platform=macOS' -derivedDataPath .context/recording-p0/DerivedData -clonedSourcePackagesDirPath .context/recording-p0/SourcePackages -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO SPARKLE_FRAMEWORK_PATH=<cached Sparkle> build` → exit 0，`** BUILD SUCCEEDED **`。
- `git diff --check` → exit 0。

未验证：测试、TCC/GUI、真实首帧/首样本时延、退出挂起、VoiceOver、SCK 排除窗口、分层丢帧真实分布、设置页 UI、旧用户升级路径、实际性能。checkpoint fsync/hash 隔离保持 approved conditional deferred。

偏差记录：

- 为通过 SwiftLint 的 `file_length` error 门槛，`RecordingSessionController.swift` 使用仓库已有先例的文件级禁用；拆分留待后续重构，未抑制 Swift 编译器错误。
- 为修复真实编译错误，`RecordingSessionController` 的 6 个跨文件生命周期成员从 `private` 恢复为模块内可见；行为未变。
