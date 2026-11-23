# 录制 P0 · P4 — 收尾、定向编译与证据归档

> **Status:** `Executed — targeted Debug build exit 0; tests not run; not verified`，2026-11-18。§0 为本轮批准增补；定向无签名构建与静态本地化校验完成，未运行测试、GUI/TCC、真实录制或性能剖析。
> 索引：[`2026-11-18-recording-p0.md`](./2026-11-18-recording-p0.md) · 前置：[`P3`](./2026-11-18-recording-p0-p3-per-kind-settings.md)
> 用户已豁免运行时验证与独立评审；本阶段最多到 `Compiled`，不冒充已验证。

**Goal:** 把 P1–P3 的改动收成可交接状态：文档与 CHANGELOG 同步、四语言完整、只做必要的定向构建/类型检查、记录未验证项与最终 diff；不提交、不发布、不跑测试矩阵。

**Architecture:** 不新增产品行为。只允许文档、本地化校验、定向编译和可选“只编译不运行”的回归源。任何编译失败先按 `systematic-debugging` 定位到本 P0 owned files，不扩大到全仓库重构。

---

## 0. 2026-11-18 增补范围（主控静态复核后的具体偏差）

用户已批准在 P4 内直接修正以下具体生命周期回归，不做第二轮独立评审。**先改本节与产品代码，再进入 §2 的构建/证据步骤。**

### D6 音频 start 的迟到成功必须停掉自己的 pipeline

现状（`startAudio`）：`try await task.value` 之后仅 `guard generation == sessionGeneration, lastAudioResult == nil else { return }`；generation 不匹配时直接返回，`pipeline.start` 已成功的麦克风/流继续运行，新会话还可开始。屏幕有 late cleanup，音频没有对应 quarantine。

要求：
1. 在任何 `await`（含 `closeAudioPreview()`）**之前**同步占用本次 start 槽位与 `sessionGeneration`，第二个 start 必须被 `alreadyStarted` 拒绝。
2. 新增 `audioResourceOwner` 资源 owner token，与 UI 终态（`sessionGeneration` / `lastAudioResult`）分离；owner 只在“实际 setup/start/stop 操作已 drain”后释放。
3. UI 先收敛（取消、看门狗、有界 stop 超时）时，保留一个 retiring 操作；迟到的 start 成功必须对自己的 pipeline 执行**恰好一次** `stop()`。
4. retiring 完成后才释放 owner；未释放前 audio/screen 都不得开始新的采集。迟到的 `startAudio` 不得让 ViewModel 写入 mode/startedAt，也不得发第二次成功 toast；控制器已给出有界结果时，调用方静默退出。
5. 迟到 stop 若真的产出了可发布媒体，只登记恢复材料，不写 `saved`、不发成功 toast。

### D7 平台启动看门狗（与媒体 readiness 独立）

现状：`startCapture` 与 `startAudio` 只在 `adapter.start` / `pipeline.start` 返回后，才启动首帧/首样本计时；用户不点 Cancel 时，平台调用不返回会让 UI 永久停在 `.starting`。

要求：
1. 每次 start 在占用 owner 时启动一个 `platformStartDeadline` 看门狗；平台 start 一返回（成功或抛错）立即取消。
2. 看门狗覆盖 factory + 平台 start，但**不**覆盖已获授权的系统权限提示（音频权限与屏幕权限都在进入 start 前解析）。
3. 看门狗到期：给出有界、可本地化的失败结果；不得用结构化 task group 硬 deadline，也不得在 `awaitBounded` 里静默丢弃迟到结果。
4. 屏幕看门狗到期后仍保留 `screenStartPending` 直到迟到 start 的清理真正结束；音频看门狗到期后仍保留 owner 直到 retiring drain。
5. 正常的慢保存不受影响；`RecordingReadiness.awaitBounded` 的超时语义不变。

### D8 屏幕 onFailure 与监控的 generation 守卫；退出超时不得结算活动保存

现状：
- `startCapture` 安装的 `onFailure` 闭包直接 `stopAndSave()`，没有 generation/所有权判定，过期回调可停掉新会话。
- `startMonitoring` 在两个 `await` 之后没有重新验证 generation/status。
- `stopAndResolveForQuit` 在 10 s 超时后对仍在保存的会话调用 `completeAudioSession` / `finishSession`，丢弃引用、错误地允许与新采集重叠，并可能让 App 误以为可退出。

要求：
1. `onFailure` 必须用本次 start 的 generation（及当前 adapter 仍为该会话）守卫；不匹配直接丢弃。
2. 监控循环每个 `await` 之后重新检查 generation 与 `.recording`，不匹配即退出。
3. 退出超时**不得** `finishSession` / `completeAudioSession` 一个仍在活动保存的会话。返回 `.failed` + 可操作本地化 toast（“仍在后台收尾，完成后再退出”），保持 `saving` 表示与资源引用；不冻结 App、不声称已保存。下一次退出请求可继续加入同一保存。
4. audio/screen 共享资源门禁：owner 未释放或 `screenStartPending` 未清空前，拒绝新的采集并给出可操作提示。

### D9 `alreadyStarted` 的可操作本地化（recording error 0）

`RecordingPipelineError.alreadyStarted` 目前落到 `error.localizedDescription`，显示为 “CaptureCore.RecordingPipelineError error 0”。要求：
1. `AppLocalization.recordingErrorDescription` 显式处理 `RecordingPipelineError`（至少 `alreadyStarted`），使用可操作文案。
2. 新 key 四语言齐全，占位符一致；不允许对 `alreadyStarted` 走原始 error 兜底。
3. 新增 `RecordingReadinessError` case 同样四语言齐全。

### 允许修改的已触碰文件

除 §1 allowlist 外，本增补只允许改 P1/P2/P3 已触碰的生命周期文件：
- `App/SnapGlass/Sources/Recording/RecordingSessionController.swift`
- `App/SnapGlass/Sources/Recording/RecordingReadiness.swift`
- `App/SnapGlass/Sources/AppLocalization.swift`
- `App/SnapGlass/Sources/MenuBar/CaptureViewModel+Recording.swift`
- 四个 `Localizable.strings`

不新增测试/回归源，除非构建证明必须；即使新增也只编译不运行。

### 明确记录为 deferred / unverified

- checkpoint fsync/hash 隔离：仍为已批准的 conditional deferred，无 profile、无实现。
- TCC/GUI、真实录制、退出挂起、VoiceOver、SCK 排除窗口、分层丢帧真实分布：未验证。
- 性能数字：不声称。

---

## 1. Owned files（精确 allowlist）

**Modify**
- `Docs/superpowers/plans/2026-11-18-recording-p0.md`（状态与证据表）
- `Docs/superpowers/plans/2026-11-18-recording-p0-p1-lifecycle-truth.md`（状态行 + 增补偏差回写）
- `Docs/superpowers/plans/2026-11-18-recording-p0-p2-main-thread-and-capture.md`（状态行）
- `Docs/superpowers/plans/2026-11-18-recording-p0-p3-per-kind-settings.md`（状态行）
- `CHANGELOG.md`（`Unreleased` 条目）
- `.context/recording-p0/progress.md`（收尾状态与证据）
- `App/SnapGlass/Sources/Recording/RecordingSessionController.swift`（§0 D6–D8）
- `App/SnapGlass/Sources/Recording/RecordingReadiness.swift`（§0 D7/D9：启动看门狗常量与错误）
- `App/SnapGlass/Sources/AppLocalization.swift`（§0 D9：`RecordingPipelineError`）
- `App/SnapGlass/Sources/MenuBar/CaptureViewModel+Recording.swift`（§0 D6：迟到 start 不写 mode/time、不重复 toast）
- `App/SnapGlass/Resources/*.lproj/Localizable.strings`（仅补 P1–P4 遗漏的 key；不改语义）

**Optional Create（只编译，不运行）**
- `Packages/CaptureCore/Tests/CaptureCoreTests/RecordingP0RegressionTests.swift`（纯值测试：`RecordingProgress.capturedSamples` 默认值、`ScreenRecordingDropAccounting.total` 饱和求和、`RecordingDestinationPreferences` seed 语义若可放在 SharedKit 测试则另建）
- `Packages/SharedKit/Tests/SharedKitTests/RecordingPerKindPreferenceTests.swift`（若 SharedKit 已有测试 target；没有则不新建 target）
- `App/SnapGlass/Tests/RecordingPerKindPreferenceTests.swift`（仅当现有 App 测试 target 可直接编译）

**Do not touch:** 已合并的 P1–P3 产品文件之外任何源码；`Package.swift`；`.xcodeproj`；`.gitignore`；entitlements；截图架。

---

## 2. 收尾步骤（顺序执行）

### Step 0 — 先修正 §0 的具体回归

1. 按 D6–D9 改 `RecordingSessionController` / `RecordingReadiness` / `AppLocalization` / `CaptureViewModel+Recording`。
2. 四语言同步新增 key；不删除、不改既有语义。
3. 完成后才进入 Step 1。若某项静态声明被当前代码证伪，在账本记录“声明不成立 + 原因”，不强行制造 diff。

### Step 1 — 本地化完整性

1. 对比 P1/P3 新增 key 在四个 `.lproj` 中是否存在且占位符一致。
2. 运行 `bash scripts/check-localization.sh`（只读校验，不启动 App）。
3. 若脚本报既有历史问题，只修本 P0 新增/修改的 key，不顺手清理无关文案；在交付说明中标注“既有问题未动”。

### Step 2 — 定向编译

1. CaptureCore：`swift build --package-path Packages/CaptureCore`。
2. 若 App 文件有改动：先确认工程已由 XcodeGen 生成（不手改 `.xcodeproj`），再执行最小 App 构建：
   ```bash
   xcodebuild -quiet -project SnapGlass.xcodeproj -scheme SnapGlass \
     -configuration Debug -destination 'platform=macOS' \
     CODE_SIGNING_ALLOWED=NO build
   ```
   不签名、不安装、不运行。
3. 若 P4 新增了回归源，只做“编译测试目标”：
   ```bash
   swift build --build-tests --package-path Packages/CaptureCore
   ```
   **不执行** `swift test`。
4. 编译失败处理：
   - 先定位到具体 P0 文件/接口（P1 generation/readiness、P2 工厂 async、P3 多根/偏好）；
   - 只做最小修复，不改变已批准行为；
   - 若失败来自环境（缺 SDK/Xcode 版本），记录命令、错误摘要与“未编译”，不伪造通过。

### Step 3 — 文档状态

1. 把索引与各阶段 `Status` 从 `Proposed execution` 改为：
   - 编译通过：`Implemented — targeted build passed; tests not run; not verified`
   - 未编译：`Implemented — build not run; not verified`
2. 在索引 §4 证据表追加实际命令、时间、结果摘要；不得写 `Validated`。
3. 明确列出未验证项：真机首帧/首样本时延、取消/退出挂起、VoiceOver、TCC 拒绝、SCK 排除窗口、分层丢帧真实分布、设置页 UI、旧用户升级路径。
4. 不修改 spec 的设计结论；如实现与 spec 有偏差，在进度账本写“偏差 + 理由”，由主代理决定是否回写 spec。

### Step 4 — CHANGELOG

在 `CHANGELOG.md` 的 `Unreleased` 增加一条简洁条目，覆盖：
- 录制状态如实反映首帧/首样本，取消/退出有界，恢复材料与活动保存分离；
- 目标卷探测与音频管线构造离开主线程，SCK 内容复用，HUD 电平不再触发布局；
- 音频/屏幕设置页拆分，输出目录与码率按 kind 独立，旧偏好一次性迁移。

不写“修复所有卡顿/已验证/性能提升 X%”等无证据结论。

### Step 5 — 最终 diff 与交接

1. 运行 `git status --porcelain` 与 `git diff --stat`，核对是否只在 P1–P4 allowlist 内。
2. 不做 `git add` / `commit` / `push` / `merge`；不创建 PR。
3. 向主代理输出：
   - 改动文件清单（按阶段）；
   - 编译命令与结果（原始摘要，不加工）；
   - 未运行/未验证清单；
   - 仍需主代理裁决的偏差（若有）。
4. 更新 `.context/recording-p0/progress.md`：所有阶段状态、证据路径/命令、Next action = “主代理最终 diff 检查；不跑独立评审”。

---

## 3. 失败处理

| 场景 | 必须行为 |
|---|---|
| 本地化脚本失败于本 P0 key | 补齐四语言后重跑；不删 key 规避 |
| 本地化脚本失败于历史 key | 记录并跳过；不扩大改动 |
| CaptureCore 编译失败 | 最小修复 P0 接口；不重构无关文件 |
| App 构建因签名/环境失败 | 加 `CODE_SIGNING_ALLOWED=NO` 重试一次；仍失败则记录环境原因，状态写“未编译” |
| 回归源编译失败 | 若为可选源且非产品代码，删除该源并在账本说明；不得为让它编译而改产品语义 |
| 发现行为与 spec 冲突 | 不擅自改设计；记录偏差，交主代理 |
| 任何“顺手优化”冲动 | 拒绝；P0 只做已批准项 |

---

## 4. 验收（收尾定义）

- 四个阶段文档状态一致，且没有 `Validated` 字样。
- `.context/recording-p0/progress.md` 可让下一个会话直接恢复：有阶段状态、命令、未验证项、Next action。
- `git diff --stat` 只含 allowlist；无 stage/commit。
- 编译结果如实；没有跑测试、App、GUI、TCC、长录、profiling。
- CHANGELOG 与实现一致，不夸大。

---

## 5. 执行记录（2026-11-18）

| 检查 | 命令/动作 | 结果 |
|---|---|---|
| 工程生成 | `xcodegen generate` | exit 0；`SnapGlass.xcodeproj` 已生成且被 `.gitignore` 忽略 |
| 静态本地化 | `bash scripts/check-localization.sh` | exit 0；重复 key、四语言 key/占位符、源码引用 key、视图绕过检查全部通过 |
| 定向编译 | `xcodebuild … -configuration Debug … -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO SPARKLE_FRAMEWORK_PATH=… build` | exit 0；`** BUILD SUCCEEDED **`；CaptureCore 与 App 在同一次构建中编译 |
| Diff 卫生 | `git diff --check` | exit 0 |
| 测试 | 未运行 | `swift test`/`xcodebuild test` 均未执行 |
| 运行时 | 未运行 | 无 GUI/TCC/真实录制/长录/Profiling |

构建过程中修正的是真实编译错误，不是语义绕过：

1. `RecordingSessionController+HUD.swift` 跨文件访问 private 成员 → 将 6 个生命周期成员恢复为模块内可见（`outcomeState`、`sessionGeneration`、`audioStopRequested`、`audioReadinessTask`、`announcePhase`、`updateStatus`）。
2. `RecordingDestinationProbe.swift` 在 async 上下文使用 `NSLock.lock()/unlock()` → 改为 `withLock {}`。
3. `RecordingReadiness.ReadinessRaceGate<T>` 缺少 `Sendable` 约束 → 加 `T: Sendable`。
4. `RecordingSessionController.swift` 超过 SwiftLint `file_length` error 上限 → 按仓库已有先例加文件级 `file_length` 禁用，拆分留待后续重构；Swift 编译器错误未被抑制。

原始日志：`.context/recording-p0/build/`（`xcodebuild-*-final.log`、`check-localization-*.log`）。

### 未验证 / 明确 deferred

- checkpoint fsync/hash 隔离：approved conditional deferred，无 profile、无实现。
- TCC/权限提示、真实首帧/首样本时延、取消/退出挂起、VoiceOver、SCK 排除窗口、分层丢帧真实分布、设置页 GUI、旧用户升级路径：未验证。
- 性能数字：不声称。
