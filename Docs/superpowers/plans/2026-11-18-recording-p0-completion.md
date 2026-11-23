# 录制 P0 — P4 收尾与集成修正报告

> **Status:** `Compiled`，2026-11-18。定向 Debug 无签名构建 exit 0；测试、GUI/TCC、真实录制、性能剖析均未运行，因此**不是** `Validated`。
> Worktree：`/Users/11169285/.local/share/opencode/worktree/5d0345d699d913b55a21fac44cccbd69a3acb4ec/recording-p0`
> Branch：`fix/recording-p0`（base `84e4a6a`）
> 索引：[`2026-11-18-recording-p0.md`](./2026-11-18-recording-p0.md) · P4：[`2026-11-18-recording-p0-p4-closeout.md`](./2026-11-18-recording-p0-p4-closeout.md)

## 1. 本轮实际改动

### 1.1 具体生命周期回归（P4 §0 / P1 §6）

| # | 偏差 | 修正 | 位置 |
|---|---|---|---|
| D6 | `startAudio` 在 `pipeline.start` 成功后 generation 不匹配即返回，麦克风/音频流继续运行 | start 槽位与 `sessionGeneration` 在 `closeAudioPreview()`/任何 `await` 前同步占用；新增 `audioResourceOwner` / `audioStartReservation`；UI 先收敛时保留一个 retiring 操作，迟到成功对自己的 pipeline 恰好一次 `stop()`，drain 后才释放 owner；迟到调用抛 `supersededStart`，不写 mode/startedAt、不重复 toast；retiring 产出的媒体只登记恢复材料 | `RecordingSessionController.swift:416`、`:553`、`:579`、`:591` |
| D7 | 平台 start 不返回时，只有用户点 Cancel 才有界 | 新增 `platformStartDeadline`（30 s，暂定）per-attempt 看门狗，覆盖 preview 收尾/factory/平台 start；音频与屏幕各一个，平台 start 返回即取消；到期只给有界可见失败，资源引用保留到真正 drain；不覆盖已授权系统权限提示 | `RecordingReadiness.swift:18`、`RecordingSessionController.swift:553`、`:1160` |
| D8 | 屏幕 `onFailure` 直接 `stopAndSave()` 无代际；监控 `await` 后不复核；退出超时 `finishSession`/`completeAudioSession` 活动保存 | `onFailure` 加 generation + 当前 adapter 守卫；监控每个 `await` 后复核 generation 与 `.recording`；退出超时只返回 `.failed` + 可操作提示，保留 saving 表示与引用；`hasPendingBackgroundFinalization` 纳入 retiring 操作，audio/screen 共享 `hasLiveCaptureResources` 门禁 | `RecordingSessionController.swift:227`、`:312`、`:1069`、`:1322` |
| D9 | `RecordingPipelineError.alreadyStarted` 落到 “error 0” | `AppLocalization.recordingErrorDescription` 显式映射 `RecordingPipelineError`；四语言补齐 key | `AppLocalization.swift:45` |

### 1.2 编译期真实修正（不改变已批准语义）

1. `RecordingSessionController+HUD.swift` 跨文件访问 private 成员：
   `outcomeState`、`sessionGeneration`、`audioStopRequested`、`audioReadinessTask`、`announcePhase`、`updateStatus`
   恢复为模块内可见。这是编译必需，不是行为变更。
2. `RecordingDestinationProbe.swift` 在 async 上下文调用 `NSLock.lock()/unlock()`：
   改为 `withLock { }`，保留单飞与超时语义。
3. `RecordingReadiness.ReadinessRaceGate<T>` 缺少 `Sendable` 约束：
   改为 `ReadinessRaceGate<T: Sendable>`。
4. `RecordingSessionController.swift` 超过 SwiftLint `file_length` error 上限（1689 > 1200）：
   按仓库已有先例（`AudioMixPump.swift`、`AudioRecordingEngine.swift`、`RecordingCheckpointWriter.swift`）加文件级 `file_length` 禁用；拆分留待后续重构。**未抑制任何 Swift 编译器错误。**

### 1.3 文档与本地化

- `CHANGELOG.md`：新增 `Unreleased` 条目，含如实验证状态。
- `Docs/superpowers/plans/2026-11-18-recording-p0.md`：索引状态与 §8 证据表。
- P1/P2/P3/P4 文档状态行更新；P1 增加 §6「P4 增补」。
- 四语言新增 key（并补齐 P1 遗漏的 `Cancelled`）：
  - `A recording is already starting or in progress.`
  - `The audio recording engine could not start.`
  - `The recording is still finishing in the background. Try quitting again after it finishes.`
  - `The recording start no longer applies.`
  - `The recording took too long to start. It is being stopped in the background.`
  - `The previous recording is still stopping. Try again when it finishes.`
  - `Cancelled`

## 2. 命令与原始结果

### 2.1 工程生成

```bash
xcodegen generate
```

exit 0；生成 `SnapGlass.xcodeproj`（被 `.gitignore` 忽略，未手改工程）。

### 2.2 定向构建（一次构建同时编译 CaptureCore 与 App）

```bash
xcodebuild -project SnapGlass.xcodeproj -scheme SnapGlass \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .context/recording-p0/DerivedData \
  -clonedSourcePackagesDirPath "$PWD/.context/recording-p0/SourcePackages" \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO \
  SPARKLE_FRAMEWORK_PATH="$PWD/.context/recording-p0/SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" \
  build
```

最终日志：`.context/recording-p0/build/xcodebuild-20261118-114417-final.log`

```text
EXIT=0
...
** BUILD SUCCEEDED **
```

（`grep -n "error:"` 无输出；产物 `.../Debug/SnapGlass.app/Contents/MacOS/SnapGlass` 存在。）

构建尝试记录（失败均已在最终构建前修正，未绕过）：

| 日志 | exit | 失败原因 | 修正 |
|---|---|---|---|
| `xcodebuild-20261118-114117.log` | 65 | SwiftLint `file_length` error（1689 > 1200） | 文件级 `file_length` 禁用 + 延迟拆分说明 |
| `…-attempt2.log` | 65 | HUD 扩展跨文件访问 private 成员 | 6 个生命周期成员恢复模块内可见 |
| `…-attempt3.log` | 65 | `RecordingDestinationProbe` async 中使用 `NSLock.lock/unlock` | 改为 `withLock` |
| `…-attempt4.log` | 65 | `ReadinessRaceGate<T>` 发送非 Sendable 泛型值 | 加 `T: Sendable` |
| `…-attempt5.log` | 0 | — | 首次成功 |
| `…-final.log` | 0 | — | 最终代码（watchdog 提前 + 尾逗号）再次成功 |

### 2.3 静态本地化

```bash
bash scripts/check-localization.sh
```

exit 0；日志 `.context/recording-p0/build/check-localization-20261118-114426.log`

```text
=== Source-referenced keys present ===
  ✅ all referenced keys exist
=== View code must not bypass the app language ===
  ✅ no view-level String(localized:)

✅ Localization check passed
```

`plutil -lint` 四个 `.lproj` 均 OK。

### 2.4 Diff 卫生

```bash
git diff --check
```

exit 0。`git status` 仅含 P1–P4 allowlist 内的修改与新增计划/源码文件；`.context/` 与 `SnapGlass.xcodeproj` 均被忽略。未 stage、未 commit、未 push。

## 3. 行为口径（本轮实现）

- 屏幕进入 `.recording` 仍以 writer 接受首帧为准；音频仍以 `capturedSamples > 0` 为准。
- 平台启动看门狗与首帧/首样本计时相互独立；看门狗到期不改变媒体 readiness 常量。
- 退出超时不结算活动保存：`status` 保持 `.saving`，引用保留，返回 `.failed` 阻止本次退出；再次退出加入同一保存/retire。
- 音频 owner 未释放或 `screenStartPending` 未清空前，新的 audio/screen start 被拒绝并给出可操作提示。
- 迟到 start 的成功/失败都不再触发第二次成功 toast；retiring 媒体只进入恢复材料登记。
- `alreadyStarted` 等启动错误不再显示原始 “error 0”。

## 4. 未验证项与剩余风险

未运行且未声称：

- 任何测试（`swift test`、`xcodebuild test`）。
- GUI、TCC/权限提示、真实麦克风/系统音频、屏幕首帧、真实录制与长录。
- 退出/取消挂起、看门狗 30 s 到期、迟到 start 的真实时序。
- VoiceOver 播报、SCK 排除窗口、分层丢帧真实分布、设置页 UI、旧用户升级路径。
- 任何性能数字或“更快/更省”结论。

已知风险：

- 看门狗是保守常量（30 s），真实极端慢启动可能被提前判失败；失败后迟到成功会被停掉，媒体不冒充 `saved`。
- 若 `pipeline.stop()`/`adapter` 清理本身永不返回，owner/`screenStartPending` 会保持占用，新采集被拒绝；进程重启前不会自动恢复。这是有意选择：宁可拒绝重叠采集，也不并发旧资源。
- retiring 媒体只在 `pipeline.stop()` 真正产出 segment 时登记恢复材料；若 stop 永久挂起，材料仍在磁盘但未登记。
- SwiftLint `file_length` 禁用掩盖了后续继续增长的风险；拆分仍是 deferred。
- checkpoint fsync/hash 隔离仍为 approved conditional deferred，无 profile、无实现。

## 5. 证据文件

- 计划：`Docs/superpowers/plans/2026-11-18-recording-p0.md`、`…-p1…`、`…-p2…`、`…-p3…`、`…-p4-closeout.md`
- 账本：`.context/recording-p0/progress.md`
- 构建日志：`.context/recording-p0/build/xcodebuild-20261118-114417-final.log`
- 本地化日志：`.context/recording-p0/build/check-localization-20261118-114426.log`
- 构建产物（仅编译，未运行）：`.context/recording-p0/DerivedData/Build/Products/Debug/SnapGlass.app`
