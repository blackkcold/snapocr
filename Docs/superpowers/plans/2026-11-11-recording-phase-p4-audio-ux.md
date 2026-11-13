# 录制 P4 — 音频 UX 阶段计划

> **Status:** `Prepared for implementation after P3`；开发优先，P0 全矩阵仅最终验收。**T3 已 PASS/APPROVED，P1 完成；T4 实现中；P2 尚未完整实现。** 本文件只提前落版，不表示 P4 已实现。
> 母计划：`Docs/superpowers/plans/2026-11-11-recording-full-delivery.md`
> Spec：`Docs/superpowers/specs/2026-11-11-audio-and-segmented-recording-design.md`（修订 2.1）
> 顺序：**T14 → T11 → T12 → T13**。T14 先接 controller/pipeline；T11 菜单不得早于 T14 暴露可用入口。

**Goal:** 把已完成 Core/引擎能力接到菜单、HUD、设置、录音窗口、生命周期与截图共存，保持现有玻璃/DS 视觉体系、macOS 13 降级、四语言和可达性，不重新设计 UX。

**Architecture:** App target 只做展示/窗口/生命周期；Core 纯决策保持可测。HUD/菜单/设置复用现有 `glassSurface`、`PreferencesCard`、`RecordingHUDLayout`；新音频 session 走 `RecordingSessionPipeline`，旧录屏路径保留到 T17。

**Global Constraints**

- 固定 48k/480 帧；UI 不按 10ms 刷新；菜单约 1Hz、电平节流、计时/VoiceOver ≤1Hz、导出进度 ≤4Hz。
- HUD 高 44pt、宽度按四语言自适应；不写死 248pt；语义色/现有 DS；macOS 13 fallback，不发明新主题。
- 四语言 `en/zh-Hans/ja/ko` 同任务补齐；`check-localization.sh`；视图外 `AppLocalization.string`。
- 新 App 源主 target 自动纳入；纯 App 测试 target 逐个列 App 来源；Tests 目录自动收；`xcodegen generate`，不手改 `.xcodeproj`。
- 不请求真实权限：启动只读复检；`requestAccess` 仅显式用户动作；拒绝可改用系统声音。
- 不实际锁屏/睡眠/TCC/GUI；UI 视觉/真机最终验收，未验不声称通过。
- 所有任务按 master §2.1 证据协议；测试全 fake/合成，不写用户真实数据。

---

## Task 14 — Controller/pipeline、退出与录音窗口（最先）

**Files**
- Modify: `App/SnapGlass/Sources/Recording/RecordingSessionController.swift`
- Modify: `App/SnapGlass/Sources/Recording/RecordingQuitFlow.swift`（含纯 `RecordingAudioSessionState`）
- Modify: `App/SnapGlass/Sources/MenuBar/CaptureViewModel+Recording.swift`
- Modify: `App/SnapGlass/Sources/MenuBar/CaptureViewModel.swift`（required factory 调用点；不得用默认/抛错占位）
- Modify: `App/SnapGlass/Sources/App.swift`
- Modify: `App/SnapGlass/Sources/AppWindowPresenter.swift`
- Create: `App/SnapGlass/Sources/Windows/RecordingsWindow.swift`
- Modify: `App/SnapGlass/Resources/{en,zh-Hans,ja,ko}.lproj/Localizable.strings`（窗口/空态）
- Verify only: `project.yml`（`WindowLifecycleStateTests` 的本地 `CaptureCore` dependency 已由 T2 添加；只复用，不重复新增；新测试目录自动收，不改 project）
- Test: `App/SnapGlass/Tests/RecordingQuitFlowTests.swift`
- Test: `App/SnapGlass/Tests/RecordingAudioSessionStateTests.swift`（新增）
- Test: `App/SnapGlass/Tests/WindowLifecycleStateTests.swift`

**Interfaces**
- Consumes: P3 `RecordingSessionPipeline: AudioRecordingControlling`、`RecordingPipelineRoots`、`RecordingAudioPipelineFactory`（实际接口开工前只读适配；不 fake pipeline 到 App）、`RecordingLifecycle`、`AudioRecordingConfiguration`、`RouteEvent`、`RecordingProgress`。
- Produces: `RecordingSessionController.startAudio(_:) async throws`、`.stopAudio() async -> AudioRecordingResult`、`.applyRoute(_:) async -> RouteCommitResult`、`.audioProgress() -> AsyncStream<RecordingProgress>`；`RecordingAudioSessionState { idle, starting, recording, stopping, finalizing, finished, failedRecoverable }` 映射到冻结的 `RecordingSessionStatus`（`.stopping/.finalizing → .saving`），不新增旧 enum case。
- **生产 factory**：`typealias AudioPipelineFactory = @MainActor (AudioRecordingConfiguration, RecordingPipelineRoots) throws -> RecordingSessionPipeline`；`RecordingSessionController.init(captureOrchestrator:defaults:fileManager:pipelineRoots:audioPipelineFactory:)`，factory 为 required，禁止抛错占位/假默认。`configureRecording` 只保存 roots/依赖，**不得构造 pipeline**；`startAudio(configuration)` 才调用 `factory(configuration, pipelineRoots)`，构造按 config 的 coordinator/seal/gate/ledger；`CaptureViewModel.swift` 是现有 required 调用点，必须真实传参。
- `RecordingsWindow` 作为 P5 导出窗口的宿主壳；T14 只做窗口注册/空态/会话列表入口，不实现选段/导出。
- 退出：`RecordingQuitFlow` 覆盖正在录、后台 Seal/未保存材料、失败重试；`stopAndResolveForQuit` 等真实 pipeline 收尾，禁止 silent quit。

**Steps**
- [ ] 写失败测试：音频 state 转换/旧 status 映射；`startAudio` 用 config+roots 才构造 pipeline；`configureRecording`/init 不构造；factory required 无默认/无抛错占位；退出时后台 seal 未完成等待；失败取消退出；重复 Quit 不重入；锁屏不主动停；睡眠安全收尾；`recordings` 窗口路由；旧视频 status switch 仍编译。
- [ ] 运行 `xcodebuild ... -scheme WindowLifecycleStateTests test`，预期 FAIL。
- [ ] 实现 pipeline 接线、state 映射、quit/后台保存、窗口注册；旧 `ScreenRecordingEngine` 路径保留到 T17；不 requestAccess；**验证 T2 已加 CaptureCore 测试依赖，不重复新增/不改 project.yml**。
- [ ] 重跑 App scheme、App build、`check-localization.sh`、lint；按 §2.1 记录 T14。

**Done:** 音频/视频 quit 状态与后台保存测试 GREEN；窗口可注册；旧录屏不回归；无真实 TCC/GUI。

---

## Task 11 — 菜单栏、设置、快捷键（T14 后）

**Files**
- Create: `Packages/CaptureCore/Sources/Recording/RecordingMenuModel.swift`
- Modify: `App/SnapGlass/Sources/MenuBar/MenuBarView.swift`
- Modify: `App/SnapGlass/Sources/MenuBar/MenuBarStatusLabel.swift`
- Modify: `App/SnapGlass/Sources/MenuBar/CaptureViewModel+Recording.swift`
- Modify: `App/SnapGlass/Sources/Windows/RecordingPreferencesView.swift`
- Modify: `Packages/SharedKit/Sources/HotKeys/HotKeyManager.swift`
- Modify: `App/SnapGlass/Resources/{en,zh-Hans,ja,ko}.lproj/Localizable.strings`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/RecordingMenuModelTests.swift`

**Interfaces**
- `RecordingMenuModel.modeItems(selectedDefault:isCurrent:) -> [RecordingMenuModeItem { mode, isDefault, isCurrent }]`；`stopTitle(kind:duration:) -> String`；`isEnabled(kind:isRecording:isSaving:) -> Bool`。
- 菜单区分“默认来源/本次来源”；切换失败保持旧勾选；未设热键 `nil`；快捷录音空态只提示一次。
- 设置三卡片：音频（音频三选一/录屏四选一、单/多轨、音质）、分段与安全（59 分钟只读、恢复不可关、隐藏截图架）、存储（体积/峰值估算）。
- T11 首次资源修改时清理 T2 Minor `Open System Settings` 重复键（四语言同一次，保留译文）。

**Steps**
- [ ] 写失败测试：默认/本次来源分离、失败保持、停止标题、热键空、超限/空态。
- [ ] 实现模型/菜单/设置/热键；菜单命令接 `AudioRecordingControlling`，T14 未接线时 disabled/hidden；四语言同任务。
- [ ] 跑 Core filter、`check-localization.sh`、App build；按 §2.1 记录 T11。

**UX 验证 owner:** 菜单路径/HUD 组合由主会话人工走查；视觉/四语言截断最终 T18/P0-8，不在本阶段声称通过。

---

## Task 12 — 录音 HUD、段徽标与 VoiceOver

**Files**
- Create: `App/SnapGlass/Sources/Recording/RecordingHUDPresentation.swift`
- Modify: `App/SnapGlass/Sources/Recording/RecordingControlPanel.swift`
- Modify: `App/SnapGlass/Sources/Recording/RecordingSessionController+HUD.swift`
- Modify: `Packages/CaptureCore/Sources/RecordingHUDLayout.swift`
- Modify: `App/SnapGlass/Resources/{en,zh-Hans,ja,ko}.lproj/Localizable.strings`
- Modify: `project.yml`（登记 App 源/测试到 `WindowLifecycleStateTests`；`xcodegen generate`）
- Test: `App/SnapGlass/Tests/RecordingHUDPresentationTests.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/RecordingHUDLayoutTests.swift`

**Interfaces**
- `RecordingHUDPresentation { mode, duration, systemLevel, micLevel, segmentIndex, savedCount, state, reduceMotion, reduceTransparency }`。
- `RecordingHUDMetrics.audioRecordingHeight = 44`；宽度自适应；双电平 3pt；30s 无声提示一次；段徽标“第 N 段/已保存 M 段”。
- 停止后真实整理进度；尾部检查点就绪即 [试听]；完成态 [打开] [Finder] [拼接与导出]；多段“打开”进会话列表。
- VoiceOver label/value 1Hz；Reduce Motion 关闭段切换动效；Reduce Transparency 用不透明语义底；键盘/28pt 点击区/WCAG AA 由人工走查。

**Steps**
- [ ] 写失败测试：高度 44、宽度不写死、段文案、30s 一次、VoiceOver 1Hz、Reduce 分支。
- [ ] 实现 HUD 纯展示/控制器喂数；复用 `glassSurface`/DS；四语言同任务；停止后 preview lease 入口由 T14/P3 提供。
- [ ] 跑 Core HUD filter、App scheme、`check-localization.sh`、App build；按 §2.1 记录 T12。

**UX 验证 owner:** 视觉/四语言/Reduce/键盘人工 T18；代码/单测 T12。

---

## Task 13 — 截图共存、动态窗口排除、截图架

**Files**
- Modify: `Packages/CaptureCore/Sources/RecordingCaptureAvailability.swift`
- Modify: `Packages/CaptureCore/Sources/ScreenRecordingEngine.swift`（`updateExcludedWindowIDs`）
- Modify: `App/SnapGlass/Sources/MenuBar/CaptureViewModel+Capture.swift`（5 处）
- Modify: `App/SnapGlass/Sources/MenuBar/CaptureViewModel+Scroll.swift`（2 处）
- Modify: `App/SnapGlass/Sources/MenuBar/MenuBarView.swift`（5 处 disabled）
- Modify: `App/SnapGlass/Sources/ScreenshotShelf/ScreenshotShelfManager.swift`
- Create: `App/SnapGlass/Sources/Recording/RecordingWindowExclusionRegistry.swift`
- Modify: `App/SnapGlass/Sources/Recording/RecordingSessionController+HUD.swift`
- Modify: `App/SnapGlass/Sources/Recording/RecordingControlPanel.swift`
- Modify: `App/SnapGlass/Sources/Recording/RecordingCaptureFramePanel.swift`
- Modify: `App/SnapGlass/Resources/{en,zh-Hans,ja,ko}.lproj/Localizable.strings`
- Modify: `project.yml`（登记 registry/测试；`xcodegen generate`）
- Test: `App/SnapGlass/Tests/RecordingWindowExclusionRegistryTests.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/RecordingCaptureAvailabilityTests.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/RecordingWriterLifecycleTests.swift`

**Interfaces**
- 删除 `canBeginCapture(isRecordingBusy:)`；保留 `canBeginRecording(isCapturing:isScrollCaptureActive:)`。
- `ScreenRecordingEngine.updateExcludedWindowIDs(_ windowIDs: Set<CGWindowID>) async`：运行时更新，不重启视频/音频，空集合恢复旧行为；由 registry `onChange` 直接调用。
- `RecordingWindowExclusionRegistry.register/unregister/currentWindowIDs/onChange`；`ScreenshotShelfManager.setRecordingActive(_:hideShelf:)` 默认可见、可选隐藏。
- 录制中禁用截图音效；清除 5+2+5 处拦截/禁用；窗口 registry 测试在 App target，Core engine 测试在 CaptureCore。

**Steps**
- [ ] 写失败测试：录制中普通/滚动截图、截图架默认可见、hide 设置、动态新窗口排除、engine 空集合旧行为、提示音。
- [ ] 实现 Core 入口 + App registry/菜单/截图架；不把 registry 当接线；四语言同任务。
- [ ] 跑 Core filters、App scheme、`check-localization.sh`、App build；按 §2.1 记录 T13。

**UX 验证 owner:** 入镜/提示音/截图架视觉真机 P0-8/T18；代码/单测 T13。

---

## P4 出口

- [ ] T14→T11→T12→T13 顺序完成；T14 先接线，T11 不早于 T14 暴露入口。
- [ ] 旧 `RecordingSessionStatus` 不新增 case；旧视频路径到 T17 不回归。
- [ ] 四语言/本地化脚本/App build/lint；无真实 TCC/GUI/采集。
- [ ] 视觉/真机/Reduce/键盘最终验收未跑明确标 `blocked`，不称 P4 UX 已验收。
