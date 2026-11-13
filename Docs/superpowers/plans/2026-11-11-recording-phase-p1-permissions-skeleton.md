# 录制 P1 — 权限与骨架 阶段计划

> **Status:** `Ready for main-session acceptance`；用户已批准执行（2026-11-11）。**主会话验收本文件即开工，不再等待用户二次确认或 P0 全矩阵。**
> 母计划：`Docs/superpowers/plans/2026-11-11-recording-full-delivery.md`
> Spec：`Docs/superpowers/specs/2026-11-11-audio-and-segmented-recording-design.md`（修订 2.1，开发优先）
> 范围：仅母计划 Task 1–3。P1 完成后由主会话验收；P0 全矩阵/旧 OS/真机/听测/长跑在最终验收前补齐。

**Goal:** 建立录制域的纯类型、整数样本时钟、纯音频分段策略、麦克风授权边界、偏好迁移与输出事务扩展，为 P2 音频引擎提供可编译、可测试、无 App 反向依赖的骨架。

**Architecture:** 新代码全部在 `Packages/CaptureCore`，只依赖 Foundation/CoreMedia/AVFoundation 的确定性类型；App 只做权限引导与偏好 UI。Task 1 不 import AppKit/ScreenCaptureKit，不启动真实采集；Task 2 的 `AVCaptureDevice` 适配与 Task 3 的文件事务都不改变现有录屏行为。

**Global Constraints（继承母计划）**

- 固定 `48000 Hz`；`10ms = 480 frames`；整数样本；纯音频段 `≤3540s`；恢复窗口目标 `≤300s`。
- 视频边界不得使用 `i*3540`；本阶段不实现视频边界。
- `AudioPCMBlock` 拥有 `[[Float]]` 存储；借用指针不得跨 `async`。
- 不新增 SPM 依赖；不改 `Package.swift` 协议；不手改 `.xcodeproj`。
- 不触发 TCC、不启动 App、不做真实采集；敏感操作另授权。
- 所有测试先 RED 后 GREEN；不提交，按母计划 §2.1 保存证据。

---

## 执行顺序

`Task 1 → Task 2 → Task 3`。Task 2 依赖 Task 1 的授权状态/模式类型；Task 3 独立但放在最后，避免与 Task 1 的文件事务测试交叉。

---

## Task 1 — Core 域类型、整数样本时钟、纯音频分段策略

**Files（精确 allowlist；允许预先拆分，不得新增未列文件）**
- Create: `Packages/CaptureCore/Sources/Recording/RecordingDomain.swift`
- Create: `Packages/CaptureCore/Sources/Recording/RecordingInterfaces.swift`
- Create: `Packages/CaptureCore/Sources/Recording/AudioPCMBlock.swift`
- Create: `Packages/CaptureCore/Sources/Recording/RecordingSegmentPolicy.swift`
- Create: `Packages/CaptureCore/Sources/Audio/AudioSampleClock.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/RecordingSegmentPolicyTests.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/AudioSampleClockTests.swift`

**Interfaces（唯一来源，其他任务不得重定义）**
- `RecordingKind { audio, screen }`
- `AudioSourceMode { system, microphone, systemAndMicrophone, none }`
- `AudioOutputLayout { mixed, separateTracks }`
- `RecordingTrackRole { mixed, system, microphone }`
- `SampleRange { startSample: Int64, sampleCount: Int64 }`
- `SegmentBoundary { index: Int, startSample: Int64, endSample: Int64 }`
- `RecordingLifecycle { idle, preparing, starting, recording, stopping, finalizing, finished, failedRecoverable }`
- `AudioRecordingConfiguration { kind, mode, layout, sampleRate, channelCountByRole: [RecordingTrackRole: Int], bitRate }`
- `AudioPCMBlock { role, range, sampleRate, channelCount, frameCount, hostTime, channels: [[Float]], isSilence }`（拥有存储）
- `CheckpointCommit { checkpointID, segmentIndex, range, trackURLs: [RecordingTrackRole: URL], committedAt }`
- `SegmentCheckpointSet { segmentIndex, checkpoints: [CheckpointCommit] }`
- `MicrophoneAuthorizationState { unknown, denied, restricted, authorized }`
- `MicrophoneAuthorizing { func currentState() -> MicrophoneAuthorizationState; func requestAccess() async -> MicrophoneAuthorizationState }`
- `AudioCheckpointSink { func append(_ block: AudioPCMBlock) async throws; func commitCheckpoint() async throws -> CheckpointCommit }`
- `RouteEvent { atSample: Int64, mode: AudioSourceMode, deviceID: String? }`
- `RoutePreparationResult { prepared | unchangedOnFailure(reason: String) }`
- `RouteCommitResult { committed(atSample: Int64) | unchanged(reason: String) }`
- `RecordingProgress { sessionID, elapsedSeconds, savedSegments, checkpointAgeSeconds, droppedSamples }`
- `AudioRecordingResult { sessionID, kind, layout, segmentCount, droppedRanges, checkpointAge, failure: String? }`
- `AudioRecordingControlling { start(_ configuration: AudioRecordingConfiguration) async throws; stop() async -> AudioRecordingResult; applyRoute(_ event: RouteEvent) async -> RouteCommitResult; makeProgressStream() -> AsyncStream<RecordingProgress> }`
- `RecordingSegmentPolicy.maximumSegmentSamples: Int64 = 169_920_000`；`.maximumCheckpointAge: TimeInterval = 300`；`.audioBoundaries(totalSamples: Int64) -> [SegmentBoundary]`（仅纯音频）
- `AudioSampleClock.init(epochHostTime: UInt64, hostTicksPerSecond: UInt64, sampleRate: Int)`；`.sampleIndex(forHostTime:) -> Int64?`；`.hostTime(forSample:) -> UInt64?`；`.time(forSample:) -> CMTime`

**Tests（RED first）**
- `RecordingSegmentPolicyTests`：
  - `120*60*48_000` → `[169_920_000, 169_920_000, 5_760_000]`
  - 正好 `3540s` → 1 段；`3540s + 1 sample` → 2 段
  - 零样本 → `[]`
  - 边界连续、无重叠，`endSample - startSample` 守恒
  - `maximumCheckpointAge == 300`，不提供关闭开关
- `AudioSampleClockTests`：
  - 1 GHz 时基：epoch 后 10ms = `480`
  - 非 1 GHz（24 MHz）：`240_000` ticks = `480`
  - epoch 前 10ms = `-480`
  - epoch 接近 `Int64.max` 时负 delta 仍正确
  - `28_800 * 48_000`（8h）不溢出
  - 大 hostTime/大 sample 溢出返回 `nil`；`hostTime(forSample: -1) == nil`
  - 可表示网格上的 sample ↔ hostTime 往返误差 0 或 1 tick；任意 hostTime 量化误差 ≤1 样本
  - `sampleRate = 0` / `hostTicksPerSecond = 0` 返回 `nil`/故障，不 trap

**TDD steps**
- [ ] 写两个测试文件，先只放失败断言；`swift test --package-path Packages/CaptureCore --filter RecordingSegmentPolicyTests`，预期 FAIL（类型不存在）。
- [ ] 实现 `RecordingDomain.swift`、`AudioPCMBlock.swift`、`RecordingInterfaces.swift`（纯类型/协议，不 import AppKit/SCStream）。
- [ ] 实现 `RecordingSegmentPolicy.swift`；`audioBoundaries` 只处理纯音频固定样本边界，不提供视频固定算式。
- [ ] 实现 `AudioSampleClock.swift`：`deltaTicks` 先比较 epoch 避免无符号下溢；用 `q = delta / ticksPerSecond`、`r = delta % ticksPerSecond`，`q*sampleRate`、`r*sampleRate`、加法全部用 `multipliedReportingOverflow`/`addingReportingOverflow`；溢出返回 `nil`；`hostTime(forSample:)` 对 `sample < 0` 返回 `nil`。
- [ ] 运行 `swift test --package-path Packages/CaptureCore --filter RecordingSegmentPolicyTests` 与 `--filter AudioSampleClockTests`，预期 PASS。
- [ ] 运行 `swift test --package-path Packages/CaptureCore`，记录实际总数；已知 `legacyDirectoriesWaitForTheLegacyGrace` 仍按基线披露，不修、不洗绿。
- [ ] 按母计划 §2.1 保存 Task 1 证据；报告写 `.superpowers/sdd/2026-11-11-recording-full-delivery/reports/task-01-report.md`；review 包 `.superpowers/sdd/2026-11-11-recording-full-delivery/review/task-01/`。

**Done:** 两个测试文件 GREEN；Core 包可编译；无 App/真实采集依赖；接口与母计划 §2.2 一致；证据完整。

---

## Task 2 — 麦克风授权、偏好迁移与 plist

**Files**
- Create: `Packages/CaptureCore/Sources/Recording/RecordingAudioPreferenceMigration.swift`
- Create: `Packages/CaptureCore/Sources/Recording/AVMicrophoneAuthorizer.swift`
- Create: `App/SnapGlass/Sources/Recording/MicrophonePermission.swift`
- Modify: `App/SnapGlass/Sources/Recording/RecordingPermissionDecision.swift`
- Modify: `Packages/SharedKit/Sources/PreferenceKeys.swift`
- Modify: `App/SnapGlass/Sources/Info.plist`
- Create: `App/SnapGlass/Resources/en.lproj/InfoPlist.strings`（`zh-Hans`/`ja`/`ko` 同任务）
- Modify: `App/SnapGlass/Resources/{en,zh-Hans,ja,ko}.lproj/Localizable.strings`（权限引导，四语言同任务）
- Modify: `App/SnapGlass/SnapGlass.entitlements`（仅注释 `device.microphone` → `device.audio-input`，不加 key）
- Modify: `project.yml`（主 App target 目录自动纳入 `MicrophonePermission.swift`；`WindowLifecycleStateTests` sources 增加该文件，dependencies 增加本地 `CaptureCore` package；`App/SnapGlass/Tests` 自动收测试，不重复单文件登记；随后 `xcodegen generate`）
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/RecordingAudioPreferenceMigrationTests.swift`
- Test: `App/SnapGlass/Tests/RecordingPermissionDecisionTests.swift`（修改）
- Test: `App/SnapGlass/Tests/MicrophonePermissionTests.swift`（新增）

**Interfaces**
- Consumes: Task 1 `AudioSourceMode`、`MicrophoneAuthorizationState`、`MicrophoneAuthorizing`。
- Produces: `RecordingAudioPreferenceMigration.resolve(audioMode:screenMode:legacySystemAudio:) -> Resolution { audioMode, screenMode, persistAudioMode, persistScreenMode }`；`mode(fromPreferenceValue:)` / `preferenceValue(for:)`；`AVMicrophoneAuthorizer: MicrophoneAuthorizing`；App `MicrophonePermission` 只做状态→引导映射。
- 新键：`recordingAudioMode`（默认 `systemAndMicrophone`）、`recordingScreenAudioMode`（默认 `system`）、`recordingOutputLayout`、`recordingHideShelfWhileRecording`、`recordingMenuBarDuration`、`recordingAudioShortcut`、`recordingShortcutHintShown`。

**Migration（D5/§5.11 双类型裁定）**
- 纯音频：新键缺失 → `.systemAndMicrophone`；**旧 bool 不影响纯音频**。
- 录屏：新键缺失 → 旧 `true` = `.system`，旧 `false` = `.none`；新键已存在不覆盖。
- 幂等：只返回 `persist*`，不直接写 `UserDefaults`；测试用隔离 suite，绝不改真实偏好。

**Tests**
- 旧 `true/false` 只迁移 screen；纯音频 nil + 旧 false 仍为 `.systemAndMicrophone`；已有新键不覆盖；重复 resolve 不写。
- fake `MicrophoneAuthorizing` 覆盖 unknown/denied/restricted/authorized；拒绝后降级路径；`requestAccess` 不被测试触发。
- `Info.plist` 含 `NSMicrophoneUsageDescription`；四语言 `InfoPlist.strings`/`Localizable.strings` 键/占位符一致；entitlements 无新 key。

**Steps**
- [ ] 写 Core 迁移测试、App 权限决策/引导测试，运行 `swift test --package-path Packages/CaptureCore --filter RecordingAudioPreferenceMigrationTests` 与 `xcodebuild -project SnapGlass.xcodeproj -scheme WindowLifecycleStateTests -configuration Debug test -derivedDataPath "$TMPDIR/snapglass-dd"`，预期 FAIL。
- [ ] 实现双类型迁移/授权适配/引导；更新 plist、四语言 `InfoPlist.strings` + `Localizable.strings`、entitlements 注释；`project.yml` 登记后 `xcodegen generate`。
- [ ] 运行 `bash scripts/check-localization.sh`、Core 测试、App scheme 测试、App build（`$TMPDIR/snapglass-dd`），预期 PASS；不触发 TCC。
- [ ] 按母计划 §2.1 记录 `T02`。

**Done:** 迁移/权限决策测试 GREEN；四语言通过；无 TCC 触发；Core 不依赖 App。

---

## Task 3 — 输出事务扩展（段号/扩展名/多轨目录）

**Files**
- Modify: `Packages/CaptureCore/Sources/RecordingOutputTransaction.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/RecordingOutputTransactionTests.swift`（修改）

**Interfaces**
- `RecordingOutputRequest { destinationDirectory: URL, stem: String, segmentIndex: Int, shape: Shape }`；`Shape { singleFile(fileExtension: String), directory }`；`init(...) throws` 校验。
- `RecordingOutputRequestError { emptyStem, invalidStem, negativeSegmentIndex, invalidFileExtension }`
- `RecordingOutputTransaction.init(request:now:timeZone:fileManager:)`；保留旧 `init(destinationDirectory:now:timeZone:fileManager:)`。
- `partialURL`（单文件 partial / 目录 staging）、`finalURL`、`isDirectoryOutput`；`publish() throws -> URL` 按 shape 分派。
- 命名：`stem` 含日期，不含段号/扩展名；`-00` 起，碰撞 `-00_2`；单文件 `stem-00.m4a`，目录 `stem-00/`；视频多轨仍是 `.singleFile("mp4")`，不用 `AudioOutputLayout`。

**Tests**
- 单文件 `-00`/`-01`、`_2`、旧 `.mp4` 命名；负段号/空/`../x`/`.m4a` 拒绝。
- 目录 staging 隐藏且同父；`publish` 为同卷 exclusive rename；既有 final 不覆盖；失败保留 staging；不调用 hardlink。
- 既有单文件发布测试全部保持通过。

**Steps**
- [ ] 写失败测试；`swift test --package-path Packages/CaptureCore --filter RecordingOutputTransactionTests`，预期 FAIL。
- [ ] 在 `RecordingOutputTransaction.swift` 内新增 request/validation/directory publisher；旧 init/旧 publish/旧 partial 不改；新 public API DocC；不新增文件、不重构旧逻辑。
- [ ] 重跑该过滤器 + `RecordingWriterLifecycleTests`，预期 PASS；再跑 `swift test --package-path Packages/CaptureCore` 一次并记录已知失败。
- [ ] 按母计划 §2.1 记录 `T03`；报告 `reports/task-03-report.md`，review `review/task-03/`。

**Done:** 段号/扩展名/目录原子发布 GREEN；旧录屏事务与测试不回归；真实用户文件未触碰。

---

## P1 出口（主会话验收即通过，无用户二次确认）

- [ ] Task 1–3 的定向测试全部通过；Core 包可编译。
- [ ] App build 通过；`check-localization.sh` 通过；未触发 TCC/GUI/真实采集。
- [ ] 证据包含每任务精确 Files 的 start/end 内容与 SHA-256、tracked diff、报告；未提交。
- [ ] 已知 `legacyDirectoriesWaitForTheLegacyGrace` 仍按基线披露，不修/不洗绿。
- [ ] P0 项未测的保持 `blocked`，不得写成已验收；最终验收前补齐。

> 本阶段不实现 P2 音频引擎、不实现 P4 UI、不实现 P6 录屏接入。
