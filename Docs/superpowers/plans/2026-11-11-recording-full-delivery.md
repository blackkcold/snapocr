# SnapGlass 录制全量交付 — 主实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Status:** `用户已批准执行（2026-11-11）；开发优先；P0 全矩阵移至最终验收`。R1 F01–F12 已复核，R2-1–R2-6 已收敛。本文件只写计划、接口、测试与证据，**未实现任何产品功能，未运行 P0，未修改源码/配置/权限/签名**。P1 阶段文档与 Task 1 brief 已落版，可交执行 worker；敏感操作仍需单独确认。

**Goal:** 在保留 macOS 13 基线、Swift 6 并发约束和既有录屏行为的前提下，交付纯音频录制、59 分钟分段、崩溃恢复、来源多轨、录屏内嵌来源音轨、应用内拼接导出，以及录制期间截图共存。

**Architecture:** 在 `Packages/CaptureCore` 内新增纯决策层（时间网格、分段边界、路由、空间预算、导出计划）与有界采集/封装层；App target 只做窗口、菜单、HUD、权限引导和本地化。音频统一进入 48 kHz 整数样本泵，视频继续使用既有像素采集与首次编码，后续封装/拼接/裁剪只直通压缩样本；音源切换是同一 session 的 `RouteEvent`，不重开会话、不重启视频。

**Tech Stack:** Swift 6、StrictConcurrency、Swift Testing、AVFoundation、ScreenCaptureKit、AVAudioEngine/CoreAudio、SwiftUI/AppKit；仅依赖本地 `SharedKit`，不新增 SPM 依赖，不改最低系统版本。

**Spec:** `Docs/superpowers/specs/2026-11-11-audio-and-segmented-recording-design.md`（修订 2.1，2026-11-11；开发优先/最终验收时序）
**证据表:** `.context/recording-full-delivery/requirements-map.md`
**P0 方案:** `Docs/superpowers/plans/2026-11-11-recording-p0-validation.md`（v1.1，最终验收）

---

## Global Constraints

以下约束对每个任务隐式生效，单任务不得放宽：

- 正常自动产物每段 `≤3540s`；纯音频 `2h = 59 + 59 + 2` 三段；不生成隐藏超长总文件。
- 主动导出上限 `7170s`（1:59:30）；裁剪吸附后按 `effectiveRanges` 再校验，UI 与执行前双重校验。
- 恢复提交窗口目标 `≤300s`；`maximumCheckpointAge` 不可关闭；约 290s 启动轮转，余量由 P0 校准。
- 固定 `48000 Hz`；`10ms = 480 frames`；所有时间轴用整数样本，不以浮点秒累计。
- **`i * sampleRate * 3540` 只允许用于纯音频边界**。公共 `SegmentedWriterCoordinator` 必须接收实际 `[SegmentBoundary]`；视频边界按真实帧/GOP 生成，禁止偷用固定算式。
- 每个角色只产出一个 `.m4a` / 一个音频输入；**只有视频 MP4 可以有多条音频输入**。纯音频多轨是同目录多个单轨文件，不额外混音副本。
- 视频首次编码只发生在录制时；封装、拼接、裁剪不得再次编码视频。音频混音、增益、裁剪、补静音可只重编码音频，UI 必须分别标注“视频直通 / 音频直通或处理”。
- 音源/设备切换是 `RouteEvent`：session ID、段号、视频流不重启；缺失区间原位补静音。
- 旧 `RecordingSessionStatus` 的穷举 `switch` **暂冻结**；新生命周期用独立类型。迁移与 App 改动必须在同一任务内保持编译。
- `actor` + `nonisolated` 不证明无锁。采集回调只做拷贝/时标记录，禁止 `await`、逐块 `Task`、文件 IO、UI；队列必须是预分配 SPSC 所有权。不新增 Atomics 依赖，不把 native trylock 包装成“无损/无锁已证明”。
- 新增纯音频路径**不得复用**现有“零视频帧即丢弃”的录屏决策；零有效音频不发布空文件，但保留有恢复价值的材料并说明原因。
- 四语言 `en` / `zh-Hans` / `ja` / `ko` 必须与每个 UI 任务同任务补齐，不拖到收尾；视图内用 `LocalizedStringKey`，视图外用 `AppLocalization.string(_:)`。
- 主 App target 通过 `App/SnapGlass/Sources` 目录自动纳入新源；纯 App 测试 target（如 `WindowLifecycleStateTests`）逐个列 App 来源，`App/SnapGlass/Tests` 目录自动收测试文件。测试 target 需要的 App 源与本地 package 依赖仍须在 `project.yml` 登记；允许 `xcodegen generate`，禁止手改 `.xcodeproj`。
- 不新增 SPM 依赖，不改 `Package.swift` 既有协议定义；不引入 FFmpeg/外部二进制；不改最低系统版本。
- 任何任务结束时只记录**差异快照 + 测试日志 + 证据**，不提交、不 push、不建 PR。
- 已知基线：CaptureCore 284 tests，283 pass，1 既有随机失败 `legacyDirectoriesWaitForTheLegacyGrace`。不得修断言、删用例或用重跑变绿洗掉记录。
- **授权与层级（F01/F02/R2-6）：** 用户已确认执行；**每个 Task 的 `Files:` 精确路径**就是该 Task 的授权范围；`Packages/CaptureCore/**` 不构成任意修改授权。清单外路径、危险操作或 spec 变更才停。`CaptureCore` 不得依赖 App 类型；授权、窗口、HUD 展示等 App 类型只在 App target 测试。
- **并发与时钟（F03）：** `AudioSampleClock` 必须带 `epochHostTime` 与 `hostTicksPerSecond`；测试前 epoch 负样本、非 1 GHz 时基、8 小时整数精度/溢出。起录后无声/缺源按 host-time 产等长静音，时钟不停。
- **视频 GOP（F07）：** 只用 `maximumKeyFrameIntervalSeconds`（默认 1 秒）或等价 `AVVideoMaxKeyFrameIntervalDurationKey`；不得把“1”误设为每帧关键帧，不得出现两份定义。
- **回归口径（F08）：** 以“实际总数 + 新增测试全过 + 无新增失败”验收；既有 known-fail 无论本次是否复现都记录，不强制它失败，不用重跑洗绿，也不把 known-fail 当全量绿色。
- **证据（F09）：** 每个任务按 §2.1 记录开始/结束路径与 SHA-256、tracked diff、未跟踪新文件全文 `--no-index` diff；不提交，review 包放本 plan 的 workspace。

### 基线

| 项 | 值 |
|---|---|
| 工作树 | linked worktree `snapglass-shelf-position-ux`，`release/v1.5.0` @ `f2dadc0d18c358481b63e7dd20a04455623a11d4` |
| 系统 / 架构 | macOS 26.4.1 / Build 25E253 / arm64 |
| Swift | Apple Swift 6.3.3 |
| 既有失败 | `ScreenshotShelfSessionDirectoryTests.swift:78` `legacyDirectoriesWaitForTheLegacyGrace`，随机 UUID 首段为纯数字时误判 PID |
| 原始证据 | `.context/recording-full-delivery/baseline.md`（主会话已核验日志 hash 与失败原文） |

### 主会话已裁定

1. 视频边界不得使用纯音频固定算式；协调器接收实际边界表。
2. 旧 `RecordingSessionStatus` 冻结；新状态独立，迁移与 App 同任务。
3. 每角色一个 m4a / 单 audio input；只有视频 MP4 多 audio input。
4. 回调无锁等待、无逐块 Task、无文件 IO；不以 `actor`/trylock 声称已证明。
5. P0 合成测试无需 TCC；真实 SCK/麦克风不能在无 usage description 的 `swift test` 中采集。
6. 其他 OS、麦克风、设备、真实采集不能被当前 26.4.1 覆盖；缺口必须标 `blocked`，不得静默降级或标 `pass`。

---

## Review Focus

1. **视频边界误用音频公式**：合理预期是 59 分钟按真实帧边界切、接缝不重复不丢失；任何 `i*3540` 进入视频路径都必须被测试抓住。
2. **多轨退化成混音或重复输入**：合理预期是每角色恰好一个 m4a、视频 MP4 每角色一条音轨；不能为兼容播放偷偷加 mixed 轨。
3. **录制中截图仍被拦截或截图架整架消失**：合理预期是普通/滚动截图都可用，截图架默认可见、仅设置开启时隐藏，控制 UI 不入镜。
4. **退出/后台保存竞态**：合理预期是 Quit 等真实结果，后台 Seal 不丢、不误报“已保存”，旧状态穷举不被新 case 打破。
5. **回调阻塞被 `actor` 掩盖**：合理预期是采集回调 p99 与队列所有权可测；不能把 `nonisolated` 或 trylock 当无锁证明。

---

## 1. 阶段门禁文档（先落版，再实现）

每个阶段开始前，必须先写对应阶段文档并由主会话验收；**阶段文档批准即开工，不再等待 P0 全矩阵**。P0 项是最终验收条件；未测/`blocked` 不得声称验收通过。

| 阶段 | 必须先落版的文档 | 最终验收 P0 依据 | 阶段出口门禁 |
|---|---|---|---|
| P1 权限与骨架 | `Docs/superpowers/plans/2026-11-11-recording-phase-p1-permissions-skeleton.md` | P0-12 | 权限/迁移/事务测试通过；App 可编译 |
| P2 音频引擎 | `Docs/superpowers/plans/2026-11-11-recording-phase-p2-audio-engine.md` | P0-1, P0-2, P0-3 | 漂移/路由/背压测试通过；无回调阻塞证据缺口 |
| P3 分段与恢复 | `Docs/superpowers/plans/2026-11-11-recording-phase-p3-segmentation-recovery.md` | P0-4, P0-5, P0-7, P0-10, P0-11 | 崩溃矩阵、AAC trim、目录原子、空间预算通过 |
| P4 音频 UX | `Docs/superpowers/plans/2026-11-11-recording-phase-p4-audio-ux.md` | P0-8, P0-9, P0-12 | 正常/失败/恢复全链路可操作；四语言通过 |
| P5 导出 | `Docs/superpowers/plans/2026-11-11-recording-phase-p5-export.md` | P0-4, P0-10, P0-11 | 7170s 双重校验、无源覆盖、视频直通通过 |
| P6 录屏接入 | `Docs/superpowers/plans/2026-11-11-recording-phase-p6-screen-integration.md` | P0-1, P0-2, P0-5, P0-6, P0-8, P0-9 | 多音轨 MP4、视频轮转、截图回归通过 |
| P7 收尾 | `Docs/superpowers/plans/2026-11-11-recording-phase-p7-closeout.md` | 全部 P0 | 验收矩阵、四语言、PRIVACY/CHANGELOG、性能记录齐全 |

> 阶段文档必须复用本计划的 Global Constraints 和接口名；新增公共辅助类型在阶段文档中登记，由主会话验收，**不需逐项重新向用户确认**。只有 spec/UX 需求或安全范围变化才升级用户。
>
> **P0-8/9/12 是产品复跑，不再建 probe**；产品行为在 Task 13/Task 14/Task 2 与 Task 18 验证。未复跑不得宣称最终验收完成；开发可继续。

---

## 2. 文件地图

### CaptureCore（新目录，SwiftPM 递归包含，无需改 `Package.swift`）

| 路径 | 责任 |
|---|---|
| `Packages/CaptureCore/Sources/Recording/RecordingDomain.swift` | 录制类型、角色、样本区间、生命周期、配置/结果 |
| `Packages/CaptureCore/Sources/Recording/RecordingInterfaces.swift` | 授权/checkpoint/控制协议 |
| `Packages/CaptureCore/Sources/Recording/AudioPCMBlock.swift` | 拥有 `[[Float]]` 的 PCM block |
| `Packages/CaptureCore/Sources/Recording/RecordingSegmentPolicy.swift` | 3540s/300s 纯音频边界与检查点决策 |
| `Packages/CaptureCore/Sources/Recording/RecordingCheckpointWriter.swift` | PCM CAF 检查点写入/关闭/提交 |
| `Packages/CaptureCore/Sources/Recording/SegmentedWriterCoordinator.swift` | 单写者、实际边界表、writer 交接 |
| `Packages/CaptureCore/Sources/Recording/AudioTrackEncoder.swift` | 每角色一次连续 AAC 编码 |
| `Packages/CaptureCore/Sources/Recording/RecordingSealService.swift` | 段封装、校验、目录/文件发布 |
| `Packages/CaptureCore/Sources/Recording/RecordingSessionLedger.swift` | 恢复账本、幂等提交、索引重建 |
| `Packages/CaptureCore/Sources/Recording/RecordingSpaceBudget.swift` | 峰值空间、预检、backlog、优先级 |
| `Packages/CaptureCore/Sources/Recording/RecordingExportPlanner.swift` | 选段/裁剪/7170s/缺失区间 |
| `Packages/CaptureCore/Sources/Recording/RecordingCompositionExporter.swift` | 视频直通裁剪、音频处理、取消 |
| `Packages/CaptureCore/Sources/Audio/AudioSampleClock.swift` | host-time ⇄ 整数样本 ⇄ CMTime |
| `Packages/CaptureCore/Sources/Audio/AudioSourceRingBuffer.swift` | 每路 2s 预分配 SPSC |
| `Packages/CaptureCore/Sources/Audio/AudioRingAtomicCursor.swift` | internal 原子 cursor；15+ Synchronization / 13–14 OSAtomic |
| `Packages/CaptureCore/Sources/Audio/AudioMixPolicy.swift` | 求和/增益/限幅/静音 |
| `Packages/CaptureCore/Sources/Audio/AudioSampleBufferFactory.swift` | PCM ⇄ CMSampleBuffer 缓冲池 |
| `Packages/CaptureCore/Sources/Audio/SystemAudioSource.swift` | SCK 纯音频/复用录屏 stream |
| `Packages/CaptureCore/Sources/Audio/MicrophoneSource.swift` | 单 tap、格式归一化、设备重配 |
| `Packages/CaptureCore/Sources/Audio/AudioRouteController.swift` | 预备/提交 RouteEvent |
| `Packages/CaptureCore/Sources/Audio/AudioMixPump.swift` | 按 host-time 消费、渐进重采样 |
| `Packages/CaptureCore/Sources/Audio/AudioRecordingEngine.swift` | 音频会话编排，不依赖视频零帧决策 |

### App（现有路径）

> `{en,zh-Hans,ja,ko}` 表示四个实际 locale 路径（`en.lproj`、`zh-Hans.lproj`、`ja.lproj`、`ko.lproj`），逐一创建/修改；不是 shell 通配执行。

| 路径 | 用途 |
|---|---|
| `App/SnapGlass/Sources/MenuBar/MenuBarView.swift` | 录制菜单、5 处 disabled、快捷键空态 |
| `App/SnapGlass/Sources/MenuBar/MenuBarStatusLabel.swift` | 图标三态、菜单栏时长 |
| `App/SnapGlass/Sources/MenuBar/CaptureViewModel+Recording.swift` | 录制入口/停止/退出 outcome |
| `App/SnapGlass/Sources/MenuBar/CaptureViewModel+Capture.swift` | 5 处截图拦截 |
| `App/SnapGlass/Sources/MenuBar/CaptureViewModel+Scroll.swift` | 2 处滚动截图拦截 |
| `App/SnapGlass/Sources/Recording/RecordingSessionController.swift` | 生命周期/锁屏观察者/保存 |
| `App/SnapGlass/Sources/Recording/RecordingSessionController+HUD.swift` | HUD 数据与窗口排除采集 |
| `App/SnapGlass/Sources/Recording/RecordingQuitFlow.swift` | 退出确认与后台保存 |
| `App/SnapGlass/Sources/Recording/RecordingControlPanel.swift` | HUD 视图，复用 glassSurface/DS |
| `App/SnapGlass/Sources/Recording/RecordingCaptureFramePanel.swift` | 捕获框窗口排除 |
| `App/SnapGlass/Sources/Recording/RecordingWindowExclusionRegistry.swift` | 运行时窗口排除登记（新增） |
| `App/SnapGlass/Sources/ScreenshotShelf/ScreenshotShelfManager.swift` | `setRecordingActive` 拆分可见/隐藏 |
| `App/SnapGlass/Sources/Windows/RecordingPreferencesView.swift` | 设置三卡片，复用 `PreferencesCard` |
| `App/SnapGlass/Sources/Windows/PreferencesLayout.swift` | 圆角 14/布局 |
| `App/SnapGlass/Sources/App.swift` | `Window(id: "recordings")` 注册 |
| `App/SnapGlass/Sources/AppWindowPresenter.swift` | `AppWindowRegistrationView`/presenter 复用 |
| `Packages/SharedKit/Sources/HotKeys/HotKeyManager.swift` | 快速录音热键，默认 `nil` |
| `Packages/SharedKit/Sources/PreferenceKeys.swift` | 新偏好键集中登记 |
| `Packages/CaptureCore/Sources/RecordingHUDLayout.swift` | HUD 尺寸纯类型 |
| `App/SnapGlass/Sources/Info.plist` | `NSMicrophoneUsageDescription` |
| `App/SnapGlass/Resources/{en,zh-Hans,ja,ko}.lproj/InfoPlist.strings` | 四语言权限说明（新增） |
| `App/SnapGlass/Resources/{en,zh-Hans,ja,ko}.lproj/Localizable.strings` | 当前各 678 键；每 UI 任务同步补 |
| `App/SnapGlass/SnapGlass.entitlements` | 只修注释，不加 key |

---

## 2.1 证据协议（本任务精确 Files allowlist，F09/R2-1）

计划 bootstrap 工件（待批准后创建，不属产品）：`scripts/plan-evidence-snapshot.sh`。每个 Task 的 allowlist 必须来自该任务 `Files:` 列表，写入 `.context/recording-full-delivery/evidence/Txx.files`（仓库相对路径，一行一个）；**不得**把整个目录或 `git ls-files --others` 当 allowlist。每次运行使用唯一 `run-<UTC>-<pid>` 目录。

```bash
set -euo pipefail
ROOT=$(git rev-parse --show-toplevel)
TASK=Txx
ALLOW="$ROOT/.context/recording-full-delivery/evidence/$TASK.files"
RUN="$ROOT/.context/recording-full-delivery/evidence/$TASK/run-$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -m 700 -p "$RUN/start" "$RUN/end"

snapshot() { # $1 = start|end
  local side=$1 tree="$RUN/$1/tree" manifest="$RUN/$1/manifest.sha256"
  mkdir -p "$tree"; : > "$manifest"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    case "$rel" in /*|*..*|.context/recording-full-delivery/evidence/*|.git/*|*/.build/*|*/DerivedData/*)
      echo "invalid/excluded path: $rel" >&2; exit 2;; esac
    if [ ! -e "$ROOT/$rel" ]; then printf '%s\n' "$rel" >> "$RUN/$side/deleted.txt"; continue; fi
    [ -f "$ROOT/$rel" ] || [ -L "$ROOT/$rel" ] || { echo "not a file: $rel" >&2; exit 2; }
    real=$(perl -MCwd=abs_path -e 'print abs_path($ARGV[0]) // ""' "$ROOT/$rel")
    case "$real" in "$ROOT"/*) ;; *) echo "escaping symlink: $rel" >&2; exit 2;; esac
    mkdir -p "$tree/$(dirname "$rel")"
    cp -Pp "$ROOT/$rel" "$tree/$rel"
    printf '%s  %s\n' "$(shasum -a 256 "$ROOT/$rel" | cut -d' ' -f1)" "$rel" >> "$manifest"
  done < "$ALLOW"
  LC_ALL=C sort -o "$manifest" "$manifest"
}

snapshot start
# ...执行本任务...
snapshot end
git -C "$ROOT" diff --binary --pathspec-from-file="$ALLOW" > "$RUN/end/tracked.diff"
set +e
git -C "$ROOT" diff --no-index --binary "$RUN/start/tree" "$RUN/end/tree" > "$RUN/end/tree.diff"
rc=$?
set -e
[ "$rc" -le 1 ] || { echo "tree diff error: $rc" >&2; exit "$rc"; }
( cd "$RUN/start/tree" && find . -type f | LC_ALL=C sort ) > "$RUN/start/files.txt"
( cd "$RUN/end/tree" && find . -type f | LC_ALL=C sort ) > "$RUN/end/files.txt"
comm -23 "$RUN/start/files.txt" "$RUN/end/files.txt" > "$RUN/end/deleted-from-start.txt"
comm -13 "$RUN/start/files.txt" "$RUN/end/files.txt" > "$RUN/end/added-since-start.txt"
```

- `git diff --no-index` 的 `1` 表示有差异、`0` 表示无差异、`>1` 才是错误；脚本必须区分，不能用 `|| true` 吞错。
- `start/tree` 与 `end/tree` 都保存**内容副本**（含既有未跟踪文件），因此可区分“前序未提交新文件被本任务修改”；`manifest.sha256` 是内容校验，不是替代物。
- 排除证据目录、`.git`、`.build`、`DerivedData`；`perl abs_path` 拒绝逃逸 symlink；不跟随到仓库外。
- review 包放 `.superpowers/sdd/2026-11-11-recording-full-delivery/review/Txx/run-.../`；最终完整 review 放 `review/final/`。测试/构建日志独立保存；报告写明“未提交”。
- 下文各任务的“记录 `Txx`”均指本节协议，不得退化为单一 `git diff` 或 `new-$(basename).diff`。

## 2.2 公共接口表（唯一来源，R2-2）

| 符号 | Owner | 规范形状 | 消费方 |
|---|---|---|---|
| `AudioSampleClock` | T1 | `init(epochHostTime:hostTicksPerSecond:sampleRate:)`；`sampleIndex -> Int64?`；`hostTime -> UInt64?`；`time -> CMTime` | T4/T6 |
| `AudioPCMBlock` | T1 | `role/range/sampleRate/channelCount/frameCount/hostTime/channels:[[Float]]/isSilence`；拥有存储 | T4/T6/T7/T8/T17 |
| `AudioRecordingConfiguration` | T1 | `kind/mode/layout/sampleRate/channelCountByRole/bitRate` | T6/T14 |
| `AudioRecordingControlling` | T1 | `start(_:) async throws`；`stop() async -> AudioRecordingResult`；`applyRoute(_:) async -> RouteCommitResult`；`makeProgressStream()` | T11/T14 |
| `RouteEvent` / `RoutePreparationResult` / `RouteCommitResult` | T1 | `atSample/mode/deviceID`；`.prepared/.unchangedOnFailure(reason:)`；`.committed(atSample:)/.unchanged(reason:)` | T5/T6/T14 |
| `MicrophoneAuthorizing` | T1 | `currentState()`；`requestAccess() async` | T2/T5 |
| `AudioCheckpointSink` | T1 | `append(_ AudioPCMBlock) async throws`；`commitCheckpoint() async throws -> CheckpointCommit` | T6/T7/T9 |
| `CheckpointCommit` / `SegmentCheckpointSet` | T1 | 单时间范围全活动轨 / 一段的 checkpoint 集合 | T7/T8/T9 |
| `SegmentCheckpointSink` / `RecordingSegmentPlan` | T7 | `finishSegmentBundle()`；`commitAvailableCheckpoints()`；`closeSegmentBundle(isFinal:)`；`AudioSegmentPlan` 增量 3540s，不预生成无限表 | T8/T9 |
| `RecordingCheckpointRecord` / `RecordingSampleRange` / `RecordingTrackCoverage` / `RecordingSegmentCoverage` / `RecordingSegmentCheckpointBundle` | T7 | sidecar schema 1；每 role 固定格式、missingRanges、writer silence；不要求 T1 Codable | T8/T9 |
| `SealedSegment` | T8 | 段 ID、索引、每角色文件、`manifestURL?`（单文件 nil/嵌入元数据，多轨目录必有）、有效区间、视频边界、轨映射 | T9 |
| `SegmentPublicationCandidate` / `SegmentPublicationHooking` | T8 | reservedFinalURL/staging/segmentID/contentHashes/coverage；`beforePublish` 在 T3 rename 前，失败保留 stage 不发布 | T9 |
| `RecordingPublishIntent` | T9 | segmentID/reservedFinalURL/staging/contentHashes/coverage；journal+fsync 先于 rename | T9 recovery |
| `PublishedSegment` | T9 | 段 ID、索引、文件、起点/样本数、轨映射、missingRanges: [RecordingSampleRange]、state | T15/T16 |
| `PreviewLease` | T9 | 段 ID、媒体 URL、到期时间；未释放不得 GC | T16 |
| `RecordingSessionPipeline` | T9 | 唯一 engine→CAF→Seal→ledger 组合根；batch journal 所有 commit；可选 `spaceGate` | T14/T15 |
| `RecordingSpaceGating` | T9/T10 | preflightStart/checkpointCommitted/admitSeal/statusStream；T10 实现并真实接线 | T10 |
| `ExportPlan` | T15 | 请求/有效区间、clips、trackMap、音频操作、视频直通、估算时长/峰值 | T16 |
| `ScreenRecordingEngine.updateExcludedWindowIDs` | T13 | `async` 更新排除集合；不重启视频/音频 | T13 registry |

> 任何任务不得重新定义表中类型；字段或 case 变化必须先改本表并由主会话验收。

## 3. 任务

### Phase P1 — 权限与骨架

> 阶段文档：`Docs/superpowers/plans/2026-11-11-recording-phase-p1-permissions-skeleton.md`。门禁：P0-12 `pass` + 文档批准。

### Task 1: 录制域、分段策略与样本时钟

**Files:**
- Create: `Packages/CaptureCore/Sources/Recording/RecordingDomain.swift`
- Create: `Packages/CaptureCore/Sources/Recording/RecordingInterfaces.swift`
- Create: `Packages/CaptureCore/Sources/Recording/AudioPCMBlock.swift`
- Create: `Packages/CaptureCore/Sources/Recording/RecordingSegmentPolicy.swift`
- Create: `Packages/CaptureCore/Sources/Audio/AudioSampleClock.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/RecordingSegmentPolicyTests.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/AudioSampleClockTests.swift`

**Interfaces:**
- Consumes: Foundation、CoreMedia `CMTime`、AVFoundation `AVAudioPCMBuffer`。
- Produces: `RecordingKind`、`AudioSourceMode`、`AudioOutputLayout`、`RecordingTrackRole`、`SampleRange`、`SegmentBoundary`、`RecordingLifecycle`；`AudioPCMBlock { role: RecordingTrackRole, range: SampleRange, sampleRate: Int, channelCount: Int, frameCount: Int, hostTime: UInt64, channels: [[Float]], isSilence: Bool }`（拥有存储，跨 async 传递）；`AudioRecordingConfiguration { kind, mode, layout, sampleRate, channelCountByRole: [RecordingTrackRole: Int], bitRate }`；`CheckpointCommit { checkpointID: UUID, segmentIndex: Int, range: SampleRange, trackURLs: [RecordingTrackRole: URL], committedAt: Date }`；`SegmentCheckpointSet { segmentIndex: Int, checkpoints: [CheckpointCommit] }`；`MicrophoneAuthorizationState`、`MicrophoneAuthorizing`、`AudioCheckpointSink`；`RouteEvent { atSample: Int64, mode: AudioSourceMode, deviceID: String? }`、`RoutePreparationResult { prepared | unchangedOnFailure(reason: String) }`、`RouteCommitResult { committed(atSample: Int64) | unchanged(reason: String) }`、`RecordingProgress { sessionID, elapsedSeconds, savedSegments, checkpointAgeSeconds, droppedSamples }`、`AudioRecordingResult { sessionID, kind, layout, segmentCount, droppedRanges, checkpointAge, failure: String? }`；`AudioRecordingControlling { start(_ configuration: AudioRecordingConfiguration) async throws; stop() async -> AudioRecordingResult; applyRoute(_ event: RouteEvent) async -> RouteCommitResult; makeProgressStream() -> AsyncStream<RecordingProgress> }`；`RecordingSegmentPolicy.audioBoundaries(totalSamples:)`、`.maximumCheckpointAge`；`AudioSampleClock(epochHostTime:hostTicksPerSecond:sampleRate:)`、`.sampleIndex(forHostTime:) -> Int64?`（溢出返回 nil，负值合法）、`.hostTime(forSample:) -> UInt64?`（sample < 0 或溢出返回 nil）、`.time(forSample:) -> CMTime`。

**Steps:**
- [ ] 写失败测试：`audioBoundariesAre59ThenRemainder()` 断言 `120*60*48_000` 切成 `[169_920_000, 169_920_000, 5_760_000]`；`tenMillisecondsIs480Frames()` 在 `epochHostTime = 5_000_000`、`hostTicksPerSecond = 1_000_000_000` 下对 `15_000_000` ticks 返回 `480`；`preEpochSamplesAreNegative()` 对 epoch 前 10ms 返回 `-480`；`nonGigahertzTimebase()` 在 `hostTicksPerSecond = 24_000_000` 下对 `240_000` ticks 返回 `480`；`largeEpochNegativeDelta()` 在 epoch 接近 `Int64.max` 时仍返回负样本；`overflowReturnsNil()` 对大 hostTime/大 sample 返回 nil；`hostTimeForNegativeSampleReturnsNil()`。
- [ ] 运行 `swift test --package-path Packages/CaptureCore --filter RecordingSegmentPolicyTests` 与 `--filter AudioSampleClockTests`，预期 FAIL（类型不存在）。
- [ ] 实现纯类型；`RecordingSegmentPolicy` 只提供纯音频边界，不提供视频固定算式；`RecordingLifecycle` 独立于旧 `RecordingSessionStatus`；`AudioSampleClock` 用商/余数 `q = delta / ticksPerSecond`、`r = delta % ticksPerSecond`，再对 `q * sampleRate`、`r * sampleRate`、加法做 `multipliedReportingOverflow`/`addingReportingOverflow` 检查，禁止 `deltaTicks * 48_000`；`hostTime(forSample:)` 对 `sample < 0` 返回 nil，对溢出返回 nil。
- [ ] 运行 `swift test --package-path Packages/CaptureCore --filter RecordingSegmentPolicyTests` 与 `--filter AudioSampleClockTests`，预期 PASS。
- [ ] 按 §2.1 记录 `T01`（含 tracked diff 与全部新增文件全文），保存测试日志到 `logs/T01.log`。

**Covers:** G4, I1, I2, I10。

### Task 2: 麦克风权限、偏好迁移与 plist

**Files:**
- Create: `Packages/CaptureCore/Sources/Recording/RecordingAudioPreferenceMigration.swift`
- Create: `Packages/CaptureCore/Sources/Recording/AVMicrophoneAuthorizer.swift`（Core 原生 `AVCaptureDevice` 适配）
- Create: `App/SnapGlass/Sources/Recording/MicrophonePermission.swift`（只做引导/文案，不注入 Core）
- Modify: `App/SnapGlass/Sources/Recording/RecordingPermissionDecision.swift`
- Modify: `Packages/SharedKit/Sources/PreferenceKeys.swift`
- Modify: `App/SnapGlass/Sources/Info.plist`
- Create: `App/SnapGlass/Resources/en.lproj/InfoPlist.strings`（`zh-Hans`/`ja`/`ko` 同任务）
- Modify: `App/SnapGlass/Resources/{en,zh-Hans,ja,ko}.lproj/Localizable.strings`（权限引导文案，四语言同任务）
- Modify: `App/SnapGlass/SnapGlass.entitlements`（仅注释 `device.microphone` → `device.audio-input`，不加 key）
- Modify: `project.yml`（主 App target 目录自动纳入 `MicrophonePermission.swift`；在 `WindowLifecycleStateTests` sources 增加该文件，并在其 dependencies 增加本地 `CaptureCore` package；`App/SnapGlass/Tests` 自动收新测试，不重复单文件登记；随后 `xcodegen generate`）
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/RecordingAudioPreferenceMigrationTests.swift`
- Test: `App/SnapGlass/Tests/RecordingPermissionDecisionTests.swift`（修改）
- Test: `App/SnapGlass/Tests/MicrophonePermissionTests.swift`（新增）

**Interfaces:**
- Consumes: `AudioSourceMode`、`MicrophoneAuthorizationState`、`MicrophoneAuthorizing`（Task 1）、`AVCaptureDevice.authorizationStatus(for: .audio)`。
- Produces: `RecordingAudioPreferenceMigration.resolve(audioMode:screenMode:legacySystemAudio:) -> Resolution { audioMode, screenMode, persistAudioMode, persistScreenMode }`（纯音频默认 `.systemAndMicrophone`；旧 bool **只迁移 screen**：`true → .system`、`false → .none`；已存在新键不覆盖；幂等）；`mode(fromPreferenceValue:)` / `preferenceValue(for:)`；`AVMicrophoneAuthorizer: MicrophoneAuthorizing`（`currentState()`、`requestAccess() async`；请求只能由显式用户动作触发）；App `MicrophonePermission` 只做状态→引导映射，**Core 不依赖 App 类型**；新键 `recordingAudioMode`、`recordingScreenAudioMode`、`recordingOutputLayout`、`recordingHideShelfWhileRecording`、`recordingMenuBarDuration`、`recordingAudioShortcut`、`recordingShortcutHintShown`（前两者独立默认，旧 bool 不改纯音频）。

**Steps:**
- [ ] 写失败测试：纯音频 nil + 旧 `false` 仍为 `.systemAndMicrophone`；screen nil + 旧 `true/.system`、`false/.none`；已有新键不被覆盖；重复 resolve 不写；旧用户升级不触发麦克风请求；拒绝后 `RecordingPermissionDecision` 仍给系统声音降级；fake `MicrophoneAuthorizing` 验证 Core 不依赖 App。
- [ ] 运行 `swift test --package-path Packages/CaptureCore --filter RecordingAudioPreferenceMigrationTests`，预期 FAIL。
- [ ] 实现双类型迁移与 Core 授权适配；`Info.plist` 增加 `NSMicrophoneUsageDescription`；四语言 `InfoPlist.strings` 与 `Localizable.strings` 同任务补齐；entitlements 只改注释；App 引导只消费 Core 状态。
- [ ] 运行 Core 测试、`xcodebuild ... WindowLifecycleStateTests test`、`bash scripts/check-localization.sh`、App build（DerivedData `$TMPDIR/snapglass-dd`），预期 PASS。
- [ ] 按 §2.1 记录 `T02`；不触发 TCC，不启动 App。

**Covers:** G1, G3, I5, P0-12。

### Task 3: 输出事务扩展（段号/扩展名/多轨目录）

**Files:**
- Modify: `Packages/CaptureCore/Sources/RecordingOutputTransaction.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/RecordingOutputTransactionTests.swift`（修改）

**Interfaces:**
- Consumes: 既有 `AtomicRecordingOutputPublisher`/`RecordingOutputTransaction` 的 hard-link/exclusive-rename 行为；旧 init 与旧 MP4 命名/测试**不改**。
- Produces: `RecordingOutputRequest { destinationDirectory: URL, stem: String, segmentIndex: Int, shape: Shape }`；`Shape { singleFile(fileExtension: String), directory }`；`RecordingOutputRequest.init(...) throws` 校验；`RecordingOutputTransaction.init(request:now:timeZone:fileManager:) throws`；`partialURL`（单文件隐藏 partial / 目录隐藏 staging）、`finalURL`、`isDirectoryOutput`；`publish() throws -> URL` 按 shape 分派（单文件走旧 publisher；目录只走同卷 exclusive rename，不走 hardlink）。**视频逻辑多轨仍是一个 MP4 = `.singleFile("mp4")`，不得复用 `AudioOutputLayout`。**
- 命名：`stem` 是含日期的完整基名，**不含**段号/扩展名；段号从 `-00` 起，碰撞 `-00_2`；单文件 `stem-00.m4a`，目录 `stem-00/`。
- 错误：新增 `RecordingOutputRequestError { emptyStem, invalidStem, negativeSegmentIndex, invalidFileExtension }`；路径分隔符/`..`/NUL/空/前导点拒绝；扩展名仅 `[A-Za-z0-9]+`。旧 `RecordingOutputTransactionError` 不改。

**Steps:**
- [ ] 写失败测试：`-00`/`-01`、`_2`、旧 `.mp4` 命名；负段号/空 stem/`../x`/`.m4a` 拒绝；目录 staging 隐藏且同父目录，`publish` 后 final 为无扩展目录，既有 final 不被覆盖，失败保留 staging；目录路径不调用 hardlink。
- [ ] 运行 `swift test --package-path Packages/CaptureCore --filter RecordingOutputTransactionTests`，预期 FAIL。
- [ ] 在 `RecordingOutputTransaction.swift` 内新增 request/validation/directory publisher；旧 init、旧 publish、旧 partial 语义保持；新 public API 加 DocC；不新增接口文件、不重构旧逻辑。
- [ ] 重跑该过滤器 + 既有 `RecordingWriterLifecycleTests`，预期 PASS；再跑 `swift test --package-path Packages/CaptureCore` 一次，记录实际总数与已知 `legacyDirectoriesWaitForTheLegacyGrace`。
- [ ] 按 §2.1 记录 `T03`；报告 `reports/task-03-report.md`，review `review/task-03/`；不触碰真实用户文件。

**Covers:** G2, I4, I10。

### Phase P2 — 音频引擎

> 阶段文档：`Docs/superpowers/plans/2026-11-11-recording-phase-p2-audio-engine.md`。门禁：阶段文档经主会话验收即开工；P0-1/2/3 是最终验收条件，不阻塞开发。

### Task 4: 来源环形缓冲、混音策略与缓冲工厂

**Files:**
- Create: `Packages/CaptureCore/Sources/Audio/AudioSourceRingBuffer.swift`
- Create: `Packages/CaptureCore/Sources/Audio/AudioRingAtomicCursor.swift`（internal atomic 适配）
- Create: `Packages/CaptureCore/Sources/Audio/AudioMixPolicy.swift`
- Create: `Packages/CaptureCore/Sources/Audio/AudioSampleBufferFactory.swift`
- Modify: `Packages/CaptureCore/Sources/Audio/AudioSampleClock.swift`（仅 T1 Minor DocC）
- Modify: `Packages/CaptureCore/Sources/Recording/AudioPCMBlock.swift`（仅 range DocC：ring 阶段为源帧序号，T6 后为 48k 会话坐标）
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/AudioSourceRingBufferTests.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/AudioRingAtomicCursorTests.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/AudioMixPolicyTests.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/AudioSampleBufferFactoryTests.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/AudioSampleClockTests.swift`（修改，仅 Minor）

**Interfaces:**
- Ring：`AudioSourceRingBuffer.init(role:sampleRate:channelCount:hostTicksPerSecond:capacitySeconds: 2.0) throws`；`capacityFrames = floor(sampleRate*capacitySeconds)`，`slotCapacity = capacityFrames/slotFrameCount`（不 ceil）；`finishProducing() -> RingFinalizeResult`（producer joined 后发布尾帧；满则保留 staging，drain 后重试）、`requestClose()`（仅原子关闭标记）、`close()` 兼容入口 = requestClose；`read(maxFrames:)` 保留槽剩余/游标，`gapFrames` 只归下一成功槽，终端 gap 只交付一次；`RingReadResult { block, gapFrames, isClosedAndEmpty, reason }`、`RingReadReason { reentrantConsumer, invalidMaxFrames }`、`RingFinalizeResult { flushedFrames, retainedStagingFrames, producerStillActive }`、`RingStats { acceptedFrames, droppedFrames, gapFrames, stagingFrames, producerMaxDepth, consumerMaxDepth, reentrantRejects, lastDropReason }`、`AudioRingConfigurationError { invalidSampleRate, invalidChannelCount, invalidCapacity, invalidHostTimebase }`。
- Atomic：`AudioAtomicCounter { loadAcquire(); addRelease(_:) -> Int64 }`（fetch-add 旧值）；15+ `Synchronization.Atomic`，13/14 `OSAtomicAdd64Barrier`；depth gate 有限 fetch-add/leave，不自旋；`legacyForTesting` 仅 internal。
- Mix：`mix(system:microphone:systemGainDB:microphoneGainDB:masterGainDB:) throws -> AudioMixResult { block, clippedSampleCount, nonFiniteSampleCount }`；mic 单声道合法铺到 stereo system；角色/总 gain 独立 ramp；NaN/Inf 归零计数，有限超限走 limiter。
- 时标：ring 的 `AudioPCMBlock.range` 是源采样率帧序号（含 drop 推进），T6 后才是 48k 会话坐标；分割 hostTime 用 `hostTicksPerSecond` 注入，首槽保留输入 hostTime。
- Factory：`makePCMBuffer` throws；不 force unwrap；`makeSampleBuffer` throws。

**Steps:**
- [ ] 写失败测试：1/479/481 尾帧、满 buffer 尾帧保留后重试、gap 顺序/终端 gap、`maxFrames<slot` 部分读、1/481/1024/4410/8192、44.1/48k、单双声道、24MHz hostTime、非法参数不 trap、overflow 不覆盖、close 并发、强制 legacy backend。
- [ ] 运行 `swift test --package-path Packages/CaptureCore --filter AudioSourceRingBufferTests`，预期 FAIL。
- [ ] 实现 ring/atomic/mix/factory；producer 只发布完整槽；尾帧由 `finishProducing` 发布；close 不触碰 staging；drop 后 gap 归下一槽/终端；读 stats 不写共享非原子状态。
- [ ] 跑 ring/atomic/mix/factory/clock 测试；TSan 可用定向跑，否则 `not-run`；重复次数预登记。
- [ ] T1 Minor DocC/测试只澄清有效域，不改算法。
- [ ] 按 §2.1 记录 `T04`；报告 `reports/task-04-report.md`，review `review/task-04/`。

**Covers:** G1, G5, I1, I6, I11。

### Task 5: 系统/麦克风来源与路由控制器

**Files:**
- Create: `Packages/CaptureCore/Sources/Audio/AudioFrameSource.swift`（协议 + generation/event 类型）
- Create: `Packages/CaptureCore/Sources/Audio/AudioSourcePlatform.swift`（SCK/AVAudioEngine 适配协议、设备事件）
- Create: `Packages/CaptureCore/Sources/Audio/SystemAudioSource.swift`
- Create: `Packages/CaptureCore/Sources/Audio/MicrophoneSource.swift`
- Create: `Packages/CaptureCore/Sources/Audio/AudioRouteController.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/SystemAudioSourceTests.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/MicrophoneSourceTests.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/AudioRouteControllerTests.swift`

**Interfaces:**
- `AudioFrameSource { role; currentGeneration() async -> AudioSourceGeneration; start() async throws; stop() async; prepareReconfiguration(_ event:) async -> AudioSourcePreparation; commitReconfiguration(_ generation:) async -> Bool }`。
- `AudioSourceFormat { sampleRate, channelCount }`；`AudioSourceGeneration { id, role, format, ringBuffer }`；`AudioSourcePreparation { prepared(generation) | unchangedOnFailure(reason) }`；`AudioDeviceChangeEvent { role, deviceID, format }`。
- `SystemAudioStreaming { streamID, isRunning, installAudioOutput, removeAudioOutput }`；`OwnedSystemAudioStreaming: SystemAudioStreaming { startCapture() async throws; stopCapture() async }`；`SystemAudioStreamFactory.makeStream() async throws -> any OwnedSystemAudioStreaming`（只创建，不隐式 start）。
- `SystemAudioSource.init(ringBuffer:stream:)`（screen reuse：只 install/remove，不 start/stop 原 video stream）与 `init(ringBuffer:factory:)`（audio-only owned：start = makeStream→install→startCapture，失败回滚本次新 stream；stop = remove→stopCapture）。
- `MicrophoneCaptureEngine` + `AudioDeviceChangeMonitoring`；`MicrophoneSource.init(ringBuffer:authorizer:targetFormat:engine:deviceMonitor:)`；一个 AVAudioEngine tap；`start()` 仅在已授权时成功，**不调用 requestAccess**。
- `AudioSourcePlatform.swift` 必须包含可用默认实现：SCK 2×2 low-fps `capturesAudio`/`excludesCurrentProcessAudio` factory、AVAudioEngine 单 tap engine、CoreAudio 设备监听注册/注销；协议+fake 不是唯一交付。
- `AudioRouteController.init(authorizer:sources:)`、`prepare(_ mode:) async -> AudioRoutePreparation { preparationID, result, generation? }`、`prepareDeviceChange(_ event:) async -> AudioRoutePreparation`、`commit(_ event:preparationID:) async -> RouteCommitResult`、`currentGeneration(for:) async`、`takeRetiredGenerations() async`。prepare 先备新源/新 generation/新 ring；commit 在整数样本交换且 token 必须匹配；失败保留旧态；rollback 只 stop 本轮新源；旧健康源不关闭；closed ring 不复用。

**Steps:**
- [ ] 写失败测试：owned start/stop 顺序与 install/start 失败回滚；reuse 不 start/stop 原 stream；两阶段 prepare/commit 用 preparationID，stale/过期 commit `.unchanged`；commit 失败旧源不丢；superseded prepare 取消；并发 async commit 串行；rollback 只停新源；设备格式 44.1→48 新 generation/ring；mic 拒绝不影响 system；mic 关闭释放 tap；closed ring 不复用。
- [ ] 运行 `swift test --package-path Packages/CaptureCore --filter AudioRouteControllerTests`、`SystemAudioSourceTests`、`MicrophoneSourceTests`，预期 FAIL。
- [ ] 实现来源/路由与默认平台适配；SCK 纯音频 standalone 一个 stream；screen 复用一个 video stream（T17 提供 adapter）；mic 一个 tap、callback 同步借用/预分配 scratch 后直接 ring copy，不创建 owned `[[Float]]`；owned block 只在 consumer read 构造。
- [ ] 重跑三条过滤器，预期 PASS；fake stream/engine/authorizer/device 事件，不启动真实采集/TCC；真实采集未验证标 `blocked`。
- [ ] 按 §2.1 记录 `T05`；报告 `reports/task-05-report.md`，review `review/task-05/`。

**Covers:** G1, G3, G9, I5, I6, I9。

### Task 6: 混音泵与音频录制引擎

**Files:**
- Create: `Packages/CaptureCore/Sources/Audio/AudioMixPump.swift`
- Create: `Packages/CaptureCore/Sources/Audio/AudioDriftResampler.swift`
- Create: `Packages/CaptureCore/Sources/Audio/AudioRecordingEngine.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/AudioMixPumpTests.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/AudioDriftResamplerTests.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/AudioRecordingEngineTests.swift`

**Interfaces:**
- Consumes: `AudioSourceRingBuffer`、`AudioMixPolicy`、`AudioSampleClock`、`AudioPCMBlock`、`AudioCheckpointSink`（Task 1 定义；Task 7 实现，T6 不依赖具体 writer）、`AudioRecordingConfiguration`。
- Produces: `AudioDriftResampler.init(inputSampleRate: Int, outputSampleRate: Int = 48_000, targetWatermarkSeconds: Double, maxCorrectionPPM: Int)`、`process(_ block: AudioPCMBlock) -> ResampleResult { block: AudioPCMBlock, correctionPPM: Double, watermarkSeconds: Double }`（输入/输出均 owned，不跨 async 借指针）；`AudioMixPump.nextBlock(for hostTime: UInt64) -> AudioPCMBlock?`（仅未起录返回 nil；起录后无声/缺源返回 480 帧等长静音，时钟不停）；`AudioRecordingEngine.init(sink: any AudioCheckpointSink, clock: AudioSampleClock)`、`start(_ configuration: AudioRecordingConfiguration) async throws`、`stop() async -> AudioRecordingResult`、`applyRoute(_ event: RouteEvent) async -> RouteCommitResult`、`makeProgressStream() -> AsyncStream<RecordingProgress>`（与 T1 `AudioRecordingControlling` 完全一致）。

**Steps:**
- [ ] 写失败测试：未起录空缓冲返回 nil；起录后无声返回 480 帧静音且 `range` 连续；480 帧块 `PTS = startSample / 48_000`；单轨只请求 mixed、多轨不请求 mixed；44.1→48k 注入 `±100/±300 ppm` 后时间轴残差 ≤480 样本且无周期性硬丢；`AudioSampleClock` 返回 nil（溢出/非法）时进入故障停止，不 force unwrap；背压超预算返回 `.droppedRanges` 而非静默成功。
- [ ] 运行 `swift test --package-path Packages/CaptureCore --filter AudioMixPumpTests`，预期 FAIL。
- [ ] 实现泵/重采样/引擎；算法参数绑定 P0-3 冻结结果，P0 未定时用注入 ppm 的确定性测试，不以“实现漂移”充数；不依赖视频零帧决策；回调路径无 `await`/Task/文件 IO；零有效时长不发布空文件。
- [ ] 重跑 `AudioMixPumpTests`、`AudioDriftResamplerTests`、`AudioRecordingEngineTests`，预期 PASS。
- [ ] 按 §2.1 记录 `T06`；漂移真机结论留给 P0-3。

**Covers:** G1, G4, G5, I1, I6。

### Phase P3 — 分段与恢复

> 阶段文档：`Docs/superpowers/plans/2026-11-11-recording-phase-p3-segmentation-recovery.md`。最终验收 P0-4/5/7/10/11；阶段文档经主会话验收即开工，P0 不阻塞开发。

### Task 7: 检查点写入与分段协调器（实际边界表）

**Files:**
- Create: `Packages/CaptureCore/Sources/Recording/RecordingCheckpointWriter.swift`
- Create: `Packages/CaptureCore/Sources/Recording/SegmentedWriterCoordinator.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/RecordingCheckpointWriterTests.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/SegmentedWriterCoordinatorTests.swift`

**Interfaces:**
- Consumes: `AudioPCMBlock`、`AudioCheckpointSink`、`CheckpointCommit`、`SegmentCheckpointSet`、`SegmentBoundary`、`RecordingSegmentPolicy`（Task 1 定义）。
- Produces: `RecordingCheckpointWriter.init(directory:sessionRoot:segment:sampleRate:roles:durability:now:) throws`，实现 `AudioCheckpointSink`/`SegmentCheckpointSink`：`append`、`commitCheckpoint`、`finishSegment`、`finishSegmentBundle`、`statistics`；`RecordingTrackCoverage`/`RecordingSegmentCoverage`/`RecordingSegmentCheckpointBundle`/`RecordingCheckpointWriterStats`；`SegmentedWriterCoordinator.init(plan:sinkFactory:)`（保留 `init(boundaries:sinkFactory:)`）、`append(at:)`、`commitCheckpoint()`（只提交最旧 open sink 的当前 chunk，T1 兼容）、`commitAvailableCheckpoints() -> [CheckpointCommit]`（按段序排空所有 open sink，T9 必须逐条 journal）、`closeSegment(at:isFinal:)`、`closeSegmentBundle(at:isFinal:)`。协调器只读实际 plan/边界表；**无** `i*3540` 视频分支；跨边界可多 sink open，不因单 role 跨界自动 finalize。

**Steps:**
- [ ] 写失败测试：音频/自定义视频边界按表切分；跨界精确拆分；`< boundary` 旧、`>=` 新；旧 sink 在显式 close 前保持 open，晚到 role 前缀仍入旧段；`commitCheckpoint` 不排空 younger sink；`commitAvailableCheckpoints` 返回全部新 commit 且不重复；`closeSegmentBundle` 每 role/chunk 恰好一次；最终短段 `isFinal`；coverage 在 role 停止后有显式 missing range；`committed == input + writerSynthesizedSilence`。
- [ ] 运行 `swift test --package-path Packages/CaptureCore --filter SegmentedWriterCoordinatorTests`，预期 FAIL。
- [ ] 实现检查点关闭/验证/提交、support types/durability 默认实现（同 writer 文件）、多 sink 单提交/批量排空；单写者所有权；writer 交接不在采集回调；不出现 55–60 分钟跨边界 chunk。
- [ ] 重跑 `SegmentedWriterCoordinatorTests` 与 `RecordingCheckpointWriterTests`，预期 PASS。
- [ ] 记录 `T07.diff` + 日志；kill 级验证留给 P0-7。

**Covers:** G4, G5, I2, I3, I11。

### Task 8: 每角色 AAC 编码与 Seal

**Files:**
- Create: `Packages/CaptureCore/Sources/Recording/AudioTrackEncoder.swift`
- Create: `Packages/CaptureCore/Sources/Recording/RecordingSealService.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/AudioTrackEncoderTests.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/RecordingSealServiceTests.swift`

**Interfaces:**
- Consumes: `RecordingSegmentCheckpointBundle`、`RecordingSegmentCoverage`、`RecordingSampleRange`、`CheckpointCommit`、`RecordingOutputTransaction`、`RecordingOutputRequest`（T3 实现 DONE 327 tests、review 待定；按实际输出适配，不修改）。
- Produces: `AudioTrackEncoder.init(role:sampleRate:channelCount:bitRate:outputURL:)`、`beginSegment(_:) throws`、`append(_:) async throws`、`finish() async throws -> AudioSealResult`（同一段同一角色只开一个连续 AAC 上下文）；`AudioSealResult { role, url, effectiveRange, priming, remainder, insertedSilence }`；`SegmentPortableRecord`（T8 owner；单文件嵌入 metadata，多轨目录 `manifest.json` 必有）；`RecordingSealContext`；`RecordingSealService.seal(_ bundle: RecordingSegmentCheckpointBundle, videoChunks: [URL], segmentID: UUID, context: RecordingSealContext, publicationHooks: [any SegmentPublicationHooking]) async throws -> SealedSegment`；`RecordingSealService.publishPrepared(_ candidate:)`（恢复沿用 T3 原子发布）；`SegmentPublicationCandidate { segmentID, segmentIndex, stagingURL, reservedFinalURL, isDirectory, stagedFileURLs, contentHashes, manifestURL?, effectiveRange, coverage }`；`SegmentPublicationHooking.beforePublish(_:) async throws`；`SealedSegment { segmentID, index, files, manifestURL: URL?, effectiveRange, videoBoundary, trackMap }`。单文件 `manifestURL == nil`，不得要求外部 manifest。

**Steps:**
- [ ] 写失败测试：3 个 checkpoint 增量编码到每角色恰好 1 个 m4a，编码上下文不重置；单轨只有 mixed、多轨只有 system/mic；有效样本数/priming/remainder/inserted silence 被记录；coverage missing range 补静音且 role 停止后时间轴不前移；单文件无外部 manifest 且 metadata 可读，多轨目录 manifest 必有；stage 验证后 `beforePublish` 收到**实际 reservedFinalURL**（碰撞 `_2` 由 T3 解析，不猜）与 hashes；hook 抛错保留 stage、不 publish；`publishPrepared` 从已验证 stage 恢复且路径/哈希吻合；publish 返回 URL 与 reserved 不一致 fail-closed；视频 chunk 不被重编码。
- [ ] 运行 `swift test --package-path Packages/CaptureCore --filter AudioTrackEncoderTests`，预期 FAIL。
- [ ] 实现每角色单 audio input；stage 完成/hash 验证后调用 hooks，成功才 `transaction.publish()`；多轨目录整体发布；拒绝不兼容外部资产只用于外部/旧格式，不作为正常录制失败借口。
- [ ] 重跑 `AudioTrackEncoderTests` 与 `RecordingSealServiceTests`，预期 PASS。
- [ ] 记录 `T08.diff` + 日志；真实接缝听测留给 P0-4。

**Covers:** G2, G4, G6, I1, I11。

### Task 9: 恢复账本、索引对账与幂等发布

**Files:**
- Create: `Packages/CaptureCore/Sources/Recording/RecordingSessionLedger.swift`
- Create: `Packages/CaptureCore/Sources/Recording/RecordingIndexRecord.swift`
- Create: `Packages/CaptureCore/Sources/Recording/RecordingPreviewService.swift`
- Create: `Packages/CaptureCore/Sources/Recording/RecordingPortableMetadata.swift`
- Create: `Packages/CaptureCore/Sources/Recording/RecordingSessionPipeline.swift`（唯一组合根；含 `LedgerCheckpointSink`、`LedgerPublicationHook`、`RecordingSpaceGating` 协议）
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/RecordingSessionLedgerTests.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/RecordingPreviewServiceTests.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/RecordingPipelineIntegrationTests.swift`

**Interfaces:**
- Consumes: `RecordingSegmentCheckpointBundle`、`SealedSegment`、`CheckpointCommit`、`RecordingSegmentCoverage`、`AudioRecordingControlling`/`AudioRecordingEngine`（T6 实际产出）、`RecordingSealService`（T8）。
- Produces: `RecordingSessionRecord { id, kind, layout, startedAt, segments: [PublishedSegment] }`、`PublishedSegment { id, index, files, startSample, sampleCount, trackMap, missingRanges: [RecordingSampleRange], state }`、`RecoverableSession { sessionID, segmentIndex, estimatedSeconds, state }`；`RecordingSessionLedger`（单 session actor；`register`、`commit`、`recordPublishIntent`、`markPublished`、`rebuildIndex`；`static recoverableSessions(in:indexURL:)`）；`RecordingPublishIntent { segmentID, reservedFinalURL, stagingURL, isDirectory, contentHashes, effectiveRange, coverage }`；`RecordingPreviewService.leasePreview(for:)`/`release`；`PreviewLease { id, segmentID, mediaURLs, expiresAt }`；`RecordingPortableMetadata.embed/read`；`RecordingSessionPipeline: AudioRecordingControlling`（可选 `spaceGate`，stop 幂等，`resumePublish(segmentID:)`）；`RecordingSpaceGating`（preflightStart/checkpointCommitted/admitSeal/sealFinished/statusStream）。

**Steps:**
- [ ] 写失败测试：`LedgerCheckpointSink.commitCheckpoint` 调 `commitAvailableCheckpoints()` 并逐条 journal，跨边界旧/新段 commit 都不漏、不重复；`beforePublish` 在 T3 rename 前写 `publishIntent`+fsync；hook 失败不 publish；collision reserved `_2` 与最终路径一致；恢复只采用已验证 final 或同名 stage（segmentID/hash），stage 经 `resumePublish`/T8 `publishPrepared` 重试，不误领碰撞文件；已发布未索引只补登记；索引损坏可从账本重建；未知 schema 只读；preview lease 未释放时 GC 不删材料；portable metadata 嵌入/读回可重建；真实 CAF→checkpoint→seal→ledger→preview 集成测试，不只测 fake 管线。
- [ ] 运行 `swift test --package-path Packages/CaptureCore --filter RecordingSessionLedgerTests`，预期 FAIL。
- [ ] 实现账本为事实源、index 为缓存；batch journal 每个 commit；发布意图先行；GC 只回收本事务拥有且已替代材料；preview 只读已关闭 chunk/segment。
- [ ] 重跑 `RecordingSessionLedgerTests`、`RecordingPreviewServiceTests`、`RecordingPipelineIntegrationTests`，预期 PASS。
- [ ] 按 §2.1 记录 `T09`；断电/断盘留给 P0-7。

**Covers:** G2, G5, I4, I8, I12。

### Task 10: 空间预算、backlog 与真实 pipeline wiring

**Files:**
- Create: `Packages/CaptureCore/Sources/Recording/RecordingSpaceBudget.swift`
- Create: `Packages/CaptureCore/Sources/Recording/RecordingBacklogPolicy.swift`
- Create: `Packages/CaptureCore/Sources/Recording/RecordingPipelineSpaceGate.swift`（实现 T9 `RecordingSpaceGating`）
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/RecordingSpaceBudgetTests.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/RecordingPipelineSpaceGateTests.swift`
- Read-only: `Packages/CaptureCore/Sources/Audio/AudioRecordingEngine.swift`（T6 合成注入 seam；不改生产行为，缺 seam 则停/报告）

**Interfaces:**
- Consumes: `AudioOutputLayout`、`RecordingTrackRole`、`RecordingKind`、`RecordingSessionPipeline`（T9）、`RecordingSpaceGating`（T9）。
- Produces: `RecordingStorageConfiguration { kind, layout, channelCountByRole, bitRate, videoBitsPerSecond? }`；`RecordingSpaceBudget.requiredBytes(config:seconds:)`、`.preflight(recordingRoot:recoveryRoot:) -> SpaceBudgetDecision { allowed, requiredBytes, availableBytes, reason }`、`.shouldStop(...)`；`RecordingBacklogPolicy`（capture/checkpoint > seal > export/thumbnail、`maximumConcurrentSeals = 1`、高低水位滞回）；`RecordingPipelineSpaceGate` 实现 T9 预检/checkpoint 低空间/Seal admission/statusStream。双卷检查，volume capacity 不可用 fail-closed；视频按 `videoBitsPerSecond/8×秒 + Seal 读+写峰值`，VBR 不当绝对上限。

**Steps:**
- [ ] 写失败测试：单轨立体声 `0.6912 GB/h`、59 分钟 `0.67968 GB`；分轨 `1.0368 GB/h`、59 分钟 `1.01952 GB`；旧三份 `1.728 GB/h` 不采用；假 volume provider + 实际 T9 pipeline：低空间预检拒绝起录（不建 media）、checkpoint 后低空间安全 stop 保留 committed tail；Seal admission 第二 seal defer 但 capture/checkpoint 继续；正常多段持续录制不被 Seal 堵住；statusStream 报告 backlog/低空间；滞回不抖动；盘满/取消保留 owned 文件、不覆盖 existing（与 T8/T9 联测）。
- [ ] 运行 `swift test --package-path Packages/CaptureCore --filter RecordingSpaceBudgetTests`，预期 FAIL。
- [ ] 实现十进制 GB/双卷预检/滞回/优先级；`RecordingPipelineSpaceGate` 真实接到 T9 start/checkpoint/seal/status；max 1 由实际 gate/pipeline 执行，不是常量。
- [ ] T10 测试使用 T6 已有确定性合成注入 seam；若 T6 无 seam，停并记录 interface request，不改 T6 生产行为。
- [ ] 重跑 `RecordingSpaceBudgetTests`、`RecordingPipelineSpaceGateTests`，预期 PASS。
- [ ] 记录 `T10.diff` + 日志；慢盘/满盘真机留给 P0-11。

**Covers:** G5, I12。

### Phase P4 — 音频 UX

> 阶段文档：`Docs/superpowers/plans/2026-11-11-recording-phase-p4-audio-ux.md`。门禁：P0-8/9/12 `pass` + 文档批准。**执行顺序：T14 → T11 → T12 → T13**；T14 先完成 controller/engine 真实接线，T11 菜单不得早于 T14 暴露可用入口。Task 11 与 Task 12 共享 `PreferenceKeys`/`MenuBarView`，必须串行，不得并行编辑。

### Task 11: 菜单栏、录制设置与快捷键空态

**Files:**
- Create: `Packages/CaptureCore/Sources/Recording/RecordingMenuModel.swift`
- Modify: `App/SnapGlass/Sources/MenuBar/MenuBarView.swift`
- Modify: `App/SnapGlass/Sources/MenuBar/MenuBarStatusLabel.swift`
- Modify: `App/SnapGlass/Sources/MenuBar/CaptureViewModel+Recording.swift`
- Modify: `App/SnapGlass/Sources/Windows/RecordingPreferencesView.swift`
- Modify: `Packages/SharedKit/Sources/HotKeys/HotKeyManager.swift`
- Modify: `App/SnapGlass/Resources/{en,zh-Hans,ja,ko}.lproj/Localizable.strings`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/RecordingMenuModelTests.swift`

**Interfaces:**
- Consumes: `AudioSourceMode`、`AudioOutputLayout`、`AudioRecordingControlling`、Task 2 的偏好键；App 只做引导，不把 App 类型注入 Core。
- Produces: `RecordingMenuModel.modeItems(selectedDefault: AudioSourceMode) -> [RecordingMenuModeItem { mode, isDefault, isCurrent }]`、`.stopTitle(kind: RecordingKind, duration: TimeInterval) -> String`、`.isEnabled(kind: RecordingKind, isRecording: Bool, isSaving: Bool) -> Bool`；`HotKeyManager.audioRecording` 默认 `nil`；菜单区分“默认来源/本次来源”，切换失败保持旧勾选；设置页三卡片（音频/分段与安全/存储；59 分钟只读、恢复不可关）与空态引导。

**Steps:**
- [ ] 写失败测试：默认模式音频=系统+麦克风、录屏=系统声音；未设热键不注册；停止标题含时长；菜单改默认不改本次、改本次不改默认；切换失败保持旧勾选；超长/空态返回正确命令状态。
- [ ] 运行 `swift test --package-path Packages/CaptureCore --filter RecordingMenuModelTests`，预期 FAIL。
- [ ] 实现菜单/设置/HotKey；四语言同任务补齐；`PreferenceKeys` 只在 Task 2 定义，本任务只消费；菜单命令接到 `AudioRecordingControlling`，不直接碰 writer；**T14 未完成真实接线时菜单项 disabled/hidden，不注册假 handler**。
- [ ] 重跑同一命令、`bash scripts/check-localization.sh`、App build（DerivedData `$TMPDIR/snapglass-dd`），预期 PASS。
- [ ] 按 §2.1 记录 `T11`；不打开 GUI 验收，留给主会话/P0-8。

**Covers:** G8, G9。

### Task 12: 录音 HUD、段徽标与 VoiceOver

**Files:**
- Create: `App/SnapGlass/Sources/Recording/RecordingHUDPresentation.swift`
- Modify: `App/SnapGlass/Sources/Recording/RecordingControlPanel.swift`
- Modify: `App/SnapGlass/Sources/Recording/RecordingSessionController+HUD.swift`
- Modify: `Packages/CaptureCore/Sources/RecordingHUDLayout.swift`
- Modify: `App/SnapGlass/Resources/{en,zh-Hans,ja,ko}.lproj/Localizable.strings`
- Modify: `project.yml`（登记新 App 源/测试到 `WindowLifecycleStateTests`；随后运行 `xcodegen generate`）
- Test: `App/SnapGlass/Tests/RecordingHUDPresentationTests.swift`（新增）
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/RecordingHUDLayoutTests.swift`（修改）

**Interfaces:**
- Consumes: Task 6 的泵块、Task 7 的段状态、Task 1 的 `RecordingLifecycle`、`AudioSourceMode`。
- Produces: `RecordingHUDPresentation { mode, duration, systemLevel, micLevel, segmentIndex, savedCount, state, reduceMotion, reduceTransparency }`；`RecordingHUDMetrics.audioRecordingHeight = 44`（高度固定、宽度自适应）；`accessibilityLabel`、`accessibilityValue(seconds:)` 1 Hz 更新；Reduce Motion 时禁用段切换动效，Reduce Transparency 时使用不透明语义底。

**Steps:**
- [ ] 写失败测试：音频 HUD 高度 44；宽度不写死 248；段文案区分“第 N 段/已保存 M 段”；30s 无声只提示一次；VoiceOver 值按秒更新而非按帧；Reduce Motion/Reduce Transparency 分支可断言。
- [ ] 运行 `swift test --package-path Packages/CaptureCore --filter RecordingHUDLayoutTests` 与 `xcodebuild -project SnapGlass.xcodeproj -scheme WindowLifecycleStateTests -configuration Debug test -derivedDataPath "$TMPDIR/snapglass-dd"`，预期 FAIL。
- [ ] 实现 App 展示与控制器喂数；纯 App 展示测试放 App target，不在 CaptureCore 假测 App 类型；复用现有 `glassSurface`/DS；四语言同任务。
- [ ] 重跑上两条命令、`check-localization.sh`、App build，预期 PASS。
- [ ] 按 §2.1 记录 `T12`；视觉效果/四语言截断/Reduce Motion 留给人工验收。

**Covers:** G4, G8。

### Task 13: 截图共存、运行时窗口排除与截图架可见性

**Files:**
- Modify: `Packages/CaptureCore/Sources/RecordingCaptureAvailability.swift`
- Modify: `Packages/CaptureCore/Sources/ScreenRecordingEngine.swift`（新增运行时排除入口，保持旧视频行为）
- Modify: `App/SnapGlass/Sources/MenuBar/CaptureViewModel+Capture.swift`（5 处）
- Modify: `App/SnapGlass/Sources/MenuBar/CaptureViewModel+Scroll.swift`（2 处）
- Modify: `App/SnapGlass/Sources/MenuBar/MenuBarView.swift`（5 处 disabled）
- Modify: `App/SnapGlass/Sources/ScreenshotShelf/ScreenshotShelfManager.swift`（拆分 `setRecordingActive`）
- Create: `App/SnapGlass/Sources/Recording/RecordingWindowExclusionRegistry.swift`
- Modify: `App/SnapGlass/Sources/Recording/RecordingSessionController+HUD.swift`
- Modify: `App/SnapGlass/Sources/Recording/RecordingControlPanel.swift`
- Modify: `App/SnapGlass/Sources/Recording/RecordingCaptureFramePanel.swift`
- Modify: `App/SnapGlass/Resources/{en,zh-Hans,ja,ko}.lproj/Localizable.strings`
- Modify: `project.yml`（登记新 App 源/测试到 `WindowLifecycleStateTests`；随后运行 `xcodegen generate`）
- Test: `App/SnapGlass/Tests/RecordingWindowExclusionRegistryTests.swift`（新增）
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/RecordingCaptureAvailabilityTests.swift`（修改）
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/RecordingWriterLifecycleTests.swift`（修改）

**Interfaces:**
- Consumes: 现有 `CaptureOrchestrator`、`ScreenshotShelfManager`、`ScreenRecordingEngine`、SCK filter。
- Produces: 删除 `canBeginCapture(isRecordingBusy:)`；保留 `canBeginRecording(isCapturing:isScrollCaptureActive:)`；`ScreenRecordingEngine.updateExcludedWindowIDs(_ windowIDs: Set<CGWindowID>) async`（替换 start-only 一次性 getter；不重启视频/音频，空集合恢复旧行为）；`RecordingWindowExclusionRegistry.register(_ window: NSWindow)`、`.unregister(_ windowID: CGWindowID)`、`.currentWindowIDs: Set<CGWindowID>`、`.onChange: (Set<CGWindowID>) -> Void`（onChange 直接调用 engine 入口）；`ScreenshotShelfManager.setRecordingActive(_ active: Bool, hideShelf: Bool)`。

**Steps:**
- [ ] 写失败测试：录制中截图可用；截图进行中仍不可开始录制；`updateExcludedWindowIDs` 增删不重启视频/音频，空集合恢复旧行为；截图架默认可见、`hideShelf=true` 才隐藏；提示音在录制中禁用；窗口 registry 测试放 App target。
- [ ] 运行 `swift test --package-path Packages/CaptureCore --filter RecordingCaptureAvailabilityTests`、`--filter RecordingWriterLifecycleTests` 与 `xcodebuild -project SnapGlass.xcodeproj -scheme WindowLifecycleStateTests -configuration Debug test -derivedDataPath "$TMPDIR/snapglass-dd"`，预期 FAIL。
- [ ] 清除 5+2+5 处拦截/禁用；在 T13 内实现 Core `updateExcludedWindowIDs` 并由 registry `onChange` 调用，不留给 T17；录制中禁用截图音效；四语言“录制时隐藏截图架”同任务。
- [ ] 重跑上两条命令、`check-localization.sh`、App build，预期 PASS。
- [ ] 按 §2.1 记录 `T13`；入镜/提示音真机验收留给 P0-8。

**Covers:** G7, G9。

### Task 14: 会话生命周期、退出流与录制窗口注册

**Files:**
- Modify: `App/SnapGlass/Sources/Recording/RecordingSessionController.swift`
- Modify: `App/SnapGlass/Sources/Recording/RecordingQuitFlow.swift`
- Modify: `App/SnapGlass/Sources/MenuBar/CaptureViewModel+Recording.swift`
- Modify: `App/SnapGlass/Sources/App.swift`
- Modify: `App/SnapGlass/Sources/AppWindowPresenter.swift`
- Create: `App/SnapGlass/Sources/Windows/RecordingsWindow.swift`
- Modify: `project.yml`（登记新源；随后运行 `xcodegen generate`）
- Test: `App/SnapGlass/Tests/RecordingQuitFlowTests.swift`（修改）
- Test: `App/SnapGlass/Tests/WindowLifecycleStateTests.swift`（修改）

**Interfaces:**
- Consumes: `RecordingLifecycle`、`AudioRecordingControlling`、`AudioRecordingEngine`（Task 6）、`RecordingSessionLedger`（Task 9）。
- Produces: `RecordingStopOutcome { saved, noActiveSession, failed }`；`RecordingSessionController.startAudio(_ configuration: AudioRecordingConfiguration) async throws`、`.stopAudio() async -> AudioRecordingResult`、`.applyRoute(_ event: RouteEvent) async -> RouteCommitResult`、`.audioProgress() -> AsyncStream<RecordingProgress>`；旧 `RecordingSessionStatus` 映射给冻结的穷举 switch；`installLifecycleObservers` 中锁屏不主动停止、睡眠尽力提交检查点；`AppWindowPresenter` 注册 `recordings` 窗口。**旧视频路径保留到 Task 17，不在本任务静默替换。**

**Steps:**
- [ ] 写失败测试：Quit 在保存中等待真实结果；失败取消退出；后台保存完成不丢；重复 Quit 不重入；锁屏不触发停止；睡眠中断 Seal 后唤醒可恢复且不误报“已保存”；菜单/快捷键能真实起停新音频 engine；route/progress 入口可观察；`recordings` 窗口可注册/呈现；旧状态 switch 仍编译。
- [ ] 运行 `xcodebuild -project SnapGlass.xcodeproj -scheme WindowLifecycleStateTests -configuration Debug test -derivedDataPath "$TMPDIR/snapglass-dd"`，预期 FAIL。
- [ ] 实现生命周期迁移、退出 outcome、后台保存、窗口注册、音频 engine 真实连接；移除 `installLifecycleObservers` 的锁屏停止分支；不新增旧 enum case；`project.yml` 登记新源后 `xcodegen generate`。
- [ ] 重跑同一 scheme，预期 PASS；再跑 App build。
- [ ] 按 §2.1 记录 `T14`；不启动 GUI。

**Covers:** G5, I8, I9, P0-9。

### Phase P5 — 导出

> 阶段文档：`Docs/superpowers/plans/2026-11-11-recording-phase-p5-export.md`。门禁：P0-4/10/11 `pass` + P3 完成 + 文档批准。

### Task 15: 导出计划器与组合导出器

**Files:**
- Create: `Packages/CaptureCore/Sources/Recording/RecordingExportPlanner.swift`
- Create: `Packages/CaptureCore/Sources/Recording/RecordingCompositionExporter.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/RecordingExportPlannerTests.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/RecordingCompositionExporterTests.swift`

**Interfaces:**
- Consumes: `RecordingSessionRecord`、`PublishedSegment`、`missingRanges`、`RecordingOutputTransaction`。
- Produces: `ExportSelection { segmentIDs, rangesBySegment, trackSelection }`、`ExportPlan { requestedRanges, effectiveRanges, clips, trackMap, audioOperation, videoPassthrough, estimatedDuration, estimatedPeakBytes }`；`RecordingExportPlanner.plan(session:selection:)`；`RecordingCompositionExporter.export(_ plan: ExportPlan, progress: @Sendable (ExportProgress) -> Void) async throws -> URL`；`ExportProgress { fraction, phase }`。

**Steps:**
- [ ] 写失败测试：`7170s` 在吸附后重算，超限返回 `.overLimit`；缺失区间插入等长静音，后续不前移；视频裁剪起点为同步样本；源文件不被覆盖；取消只清理本任务临时文件。
- [ ] 运行 `swift test --package-path Packages/CaptureCore --filter RecordingExportPlannerTests`，预期 FAIL。
- [ ] 实现 planner/exporter；视频 `outputSettings: nil` + 非空 `sourceFormatHint`；音频按需只重编码；进度 ≤4 Hz。
- [ ] 重跑 `RecordingExportPlannerTests` 与 `RecordingCompositionExporterTests`，预期 PASS。
- [ ] 记录 `T15.diff` + 日志；真实载荷比对留给 P0-5/11。

**Covers:** G6, G10, I7, I10, I11。

### Task 16: 导出窗口、预算条与预览

**Files:**
- Create: `App/SnapGlass/Sources/Windows/RecordingExportView.swift`
- Create: `App/SnapGlass/Sources/Recording/RecordingExportViewModel.swift`
- Create: `App/SnapGlass/Sources/Recording/RecordingExportSummary.swift`
- Modify: `App/SnapGlass/Sources/Windows/RecordingsWindow.swift`
- Modify: `App/SnapGlass/Resources/{en,zh-Hans,ja,ko}.lproj/Localizable.strings`
- Modify: `project.yml`（登记新 App 源/测试到 `WindowLifecycleStateTests`；随后运行 `xcodegen generate`）
- Test: `App/SnapGlass/Tests/RecordingExportSummaryTests.swift`（新增）

**Interfaces:**
- Consumes: `ExportPlan`、`PublishedSegment`、`RecordingPreviewService` / `PreviewLease`、`RecordingExportPlanner`、`RecordingCompositionExporter`、Task 14 的 `recordings` 窗口。
- Produces: `RecordingExportSummary { selectedDuration, maximumDuration, overage, videoPassthroughLabel, audioOperationLabel, trackCount, missingState }`；窗口 Tab 顺序、空格勾选、⌘⏎ 导出、Esc 关闭；每行 `[裁剪]` 入口；轨道试听为不落盘混合/独听，试听音量与导出增益分离；missing 行 `[定位]` 可恢复；VoiceOver/Reduce Motion/Reduce Transparency 分支。

**Steps:**
- [ ] 写失败测试：`1:58:00 / 1:59:30`、超出 `0:32` 文案与禁用态；多轨会话显示轨数；单轨不显示灰滑杆；missing 行不可勾选但 `[定位]` 可用；裁剪入口存在；试听音量变化不修改导出增益；停止后试听只通过 `PreviewLease` 读未发布材料。
- [ ] 运行 `xcodebuild -project SnapGlass.xcodeproj -scheme WindowLifecycleStateTests -configuration Debug test -derivedDataPath "$TMPDIR/snapglass-dd"`，预期 FAIL。
- [ ] 实现窗口/ViewModel/Summary/预览；四语言同任务；输出选项随会话类型收敛；不提供“精确重编码”控件；App 纯展示测试在 App target。
- [ ] 重跑同一命令、`check-localization.sh`、App build，预期 PASS。
- [ ] 按 §2.1 记录 `T16`；交互/截断/Reduce Motion 人工验收。

**Covers:** G6, I7, I8。

### Phase P6 — 录屏接入

> 阶段文档：`Docs/superpowers/plans/2026-11-11-recording-phase-p6-screen-integration.md`。门禁：P0-1/2/5/6/8/9 `pass` + P3 完成 + 文档批准。

### Task 17: 录屏分段、MP4 来源多音轨与视频直通

**Files:**
- Modify: `Packages/CaptureCore/Sources/ScreenRecordingEngine.swift`
- Modify: `Packages/CaptureCore/Sources/RecordingConfiguration.swift`（GOP 用秒，硬件不遵循需记录）
- Create: `Packages/CaptureCore/Sources/Recording/ScreenAudioBridge.swift`
- Modify: `Packages/CaptureCore/Sources/Recording/SegmentedWriterCoordinator.swift`（视频分支）
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/RecordingConfigurationTests.swift`（修改）
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/RecordingWriterPipelineTests.swift`（修改）
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/RecordingWriterLifecycleTests.swift`（修改）

**Interfaces:**
- Consumes: 既有像素采集/首发编码、Task 7 协调器、Task 5 来源、Task 8 Seal。
- Produces: `ScreenAudioBridge.append(system: AudioPCMBlock, microphone: AudioPCMBlock?) async throws`（拥有存储的 block 跨 async；借用指针只在同步作用域使用；单生产者/单消费者所有权，不靠 `@unchecked Sendable`）；视频实际 `[SegmentBoundary]`；MP4 每角色一个 audio input；`RecordingConfiguration.maximumKeyFrameIntervalSeconds: TimeInterval = 1`（**唯一 GOP 定义**，由 `videoOutputSettings(frameRate:)` 转成 `AVVideoMaxKeyFrameIntervalDurationKey` 或 `Int(round(fps * seconds))` 帧数）。

**Steps:**
- [ ] 写失败测试：静态画面无新帧仍能切段且首帧可解码；接缝无重复/丢失已接收帧；视频压缩样本 SHA-256 前后一致；MP4 两轨角色/时长正确；零帧不发布空文件但保留音频材料；`maximumKeyFrameIntervalSeconds = 1` 在 30fps 下产生 1 秒或 30 帧，不是每帧关键帧；`AudioPCMBlock` 跨 async 后内容仍有效，不携带借用指针、不靠 `@unchecked Sendable`。
- [ ] 运行 `swift test --package-path Packages/CaptureCore --filter RecordingConfigurationTests` 与 `--filter RecordingWriterPipelineTests`，预期 FAIL。
- [ ] 接入协调器；视频边界按实际帧，不调用固定 3540 算式；旧单 MP4 路径只留开发开关，不做用户静默 fallback；每角色单 audio input，仅视频 MP4 多 input；GOP 只保留一个定义。
- [ ] 重跑 `RecordingConfigurationTests`、`RecordingWriterPipelineTests` 与 `RecordingWriterLifecycleTests`，预期 PASS。
- [ ] 按 §2.1 记录 `T17`；H.264/HEVC/硬件交接真机留给 P0-5/6。

**Covers:** G3, G4, G9, G10。

### Phase P7 — 收尾

> 阶段文档：`Docs/superpowers/plans/2026-11-11-recording-phase-p7-closeout.md`。门禁：**T1–T17 完成 + 本阶段文档批准**；P0 由 T18 创建入口并在 P7 内执行，作为最终验收，不作为 P7 入口或开发前置。

### Task 18: 四语言审计、隐私/变更记录与验收矩阵

**Files:**
- Modify: `Docs/PRIVACY.md`（麦克风权限行）
- Modify: `CHANGELOG.md`
- Modify: `README.md`（如涉及用户可见行为）
- Modify: `App/SnapGlass/Resources/{en,zh-Hans,ja,ko}.lproj/Localizable.strings`（最终键审计）
- Create: `Docs/superpowers/plans/2026-11-11-recording-acceptance-matrix.md`
- Create: `Packages/CaptureCore/Tests/CaptureCoreTests/FinalValidationConfig.swift`
- Create: `Packages/CaptureCore/Tests/CaptureCoreTests/FinalValidationEvidence.swift`
- Create: `Packages/CaptureCore/Tests/CaptureCoreTests/FinalValidationMedia.swift`
- Create: `Packages/CaptureCore/Tests/CaptureCoreTests/RecordingFinalValidationTests.swift`
- Create: `Packages/CaptureCore/Tests/CaptureCoreTests/RecordingFinalValidationAnalysisTests.swift`
- Create: `scripts/final-validation.sh`
- Create: `.superpowers/sdd/2026-11-11-recording-full-delivery/review/task-18/evidence-index.md`
- 完成报告 `Docs/superpowers/plans/2026-11-11-recording-completion-report.md` 由主会话写；`review/final/review.md` 由独立 reviewer 写，均不由 T18 worker 创建。

**Interfaces:**
- Consumes: 全部任务的测试日志、P0 `result.json`、`requirements-map.md`、最终 review 包。
- Produces: G1–G10/I1–I12/UX/四语言/兼容/性能/恢复验收矩阵；VoiceOver/Reduce Motion/Reduce Transparency 验收；已知失败披露；P0 证据索引；独立全量 review 与完成报告。

**Steps:**
- [ ] 运行 `bash scripts/check-localization.sh`，预期 PASS；确认四语言键/占位符一致，无 `NSLocalizedString`/`String(localized:)` 违规。
- [ ] 运行 `swiftlint lint --strict --config .swiftlint.yml`，预期 0；`swift-format` 记录实际告警数与分类，不写“0 告警”。
- [ ] 运行 `bash scripts/test.sh`；记录实际总数、新增测试全部通过、无新增失败；0 测试不得报 pass；既有 `legacyDirectoriesWaitForTheLegacyGrace` 无论本次是否复现都保留记录，不强制它失败、不靠重跑洗绿、不把 known-fail 当全量绿色。
- [ ] 运行 App build：`xcodebuild -project SnapGlass.xcodeproj -scheme SnapGlass -configuration Debug build -derivedDataPath "$TMPDIR/snapglass-dd"`。
- [ ] 按 P0 v1.1 创建验证入口并跑短测默认；测试只写 `facts.json`，runner 最后写 `result.json`；未授权项用 `block` 写权威 blocked result；每项回填 `localVerdict`。
- [ ] 顺序固定：执行 worker 完成实现/自测并交证据（**不得自行派 reviewer**）→ 主会话派独立 reviewer 做全量 review 并写 `review/final/review.md` → worker 按 finding 修正 → 主会话复核 → 最后写 `2026-11-11-recording-completion-report.md`；验收矩阵记录 `T18` 证据；不打包、不签名、不部署、不提交。

**Covers:** 全部 G/I、UX §6、四语言、兼容、性能、恢复。

---

## 4. 覆盖矩阵（G/I → 任务）

| 需求 | 任务 |
|---|---|
| G1 三音频模式 | T4, T5, T6 |
| G2 单/多轨输出 | T1, T3, T7, T8, T11, T15, T16 |
| G3 录屏内嵌来源轨 | T5, T17 |
| G4 59 分钟连续 | T1, T7, T8, T17 |
| G5 抗崩溃/背压 | T4, T7, T9, T10 |
| G6 拼接导出 | T9, T15, T16 |
| G7 录制中截图 | T13 |
| G8 菜单栏/热键 | T11, T12 |
| G9 动态切源 | T5, T17 |
| G10 视频直通 | T15, T17 |
| I1 时间守恒 | T1, T4, T8 |
| I2 时序合法 | T1, T7, T15, T17 |
| I3 单写者 | T7 |
| I4 原子可见 | T3, T9 |
| I5 权限不降级 | T2, T5 |
| I6 回调不阻塞 | T4, T5, T6 |
| I7 缺轨不前移 | T15 |
| I8 用户不见 chunk | T9, T16 |
| I9 切源不重启 | T5, T17 |
| I10 无超长总文件 | T1, T7, T15 |
| I11 不冗余/不重编码 | T4, T7, T8, T15 |
| I12 未发布不误删 | T9, T10 |

## 5. 自检（writing-plans）

| 检查 | 结果 |
|---|---|
| Spec 覆盖 | G1–G10、I1–I12、UX §6、四语言、兼容、性能、恢复均落到任务；详见 `requirements-map.md` |
| 精确路径 | 所有新/改文件给出仓库相对路径；App 新源登记 `project.yml`，不手改 `.xcodeproj` |
| 接口一致 | `RecordingDomain`/`AudioSampleClock` 由 T1 定义；后续任务只消费，不另起名 |
| RED→GREEN | 每任务有失败测试名/断言、失败命令、实现步骤、通过命令 |
| 阶段门禁 | 7 个阶段文档路径明确；阶段文档主会话验收即开工；P0 全矩阵是最终验收条件 |
| F01–F12 + R2-1–R2-6 | 逐项修正并在 ledger 记录 ruling；P0 最终验证入口、证据协议、GOP 秒、回归口径、接口表、T13 engine 入口同步 |
| 证据 | 每任务路径 + SHA-256 + tracked diff + 新文件全文 no-index；不提交，review 包在 plan workspace |
| 比例 | 18 个任务，计划聚焦决策/接口/测试，不写产品实现代码 |
| 未声称 | 未实现、未运行 P0、未给排期、未把 `blocked` 当 `pass` |

## 6. 停止条件（F01 修正）

- 用户已完成唯一一次执行确认（2026-11-11）；主会话验收 P1 阶段文档后，Task 1 即可开工，不再等待第二次确认。R1/R2 的后续新 finding 只做定向修正，不重置开发。
- 确认后，**明确授权**清单内的源码/测试/`project.yml`/Info.plist/entitlements 注释/四语言/PRIVACY/CHANGELOG 与证据文件修改；范围见 Global Constraints。清单外、spec 变更、危险/破坏性/凭证/安装/TCC/GUI/真实采集/签名/系统设置变更才停并回报。
- 执行方式为 **subagent-driven（用户已选）**：主会话派执行与评审 agent；worker 不再派子 agent，不自行扩大任务范围。
- 阶段文档由主会话验收，不再每阶段向用户重复确认；只有实质需求变化或安全范围变化才升级给用户。
- 开发不因 P0 全矩阵未过而停；P0 项在最终验收前补齐，缺 OS/设备/授权只能标 `blocked`，不得静默降级或声称通过。
- 任何任务出现 0 测试、known-fail 被洗绿、视频载荷变化、源文件被覆盖、误报“已保存”，立即停止并升级。
- 不提交、不 push、不建 PR；不安装、不启动 GUI、不做真实桌面录制、不触发 TCC、不切分支/新建 worktree。
