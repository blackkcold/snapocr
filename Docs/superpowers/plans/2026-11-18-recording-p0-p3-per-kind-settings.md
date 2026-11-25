# 录制 P0 · P3 — 设置页拆分与按 kind 独立偏好

> **Status:** `Implemented — targeted Debug build passed; tests not run; not verified`，2026-11-18。§1–§3 为实现前计划；§3.5 为实现前调整；未运行测试、GUI/真机。
> 索引：[`2026-11-18-recording-p0.md`](./2026-11-18-recording-p0.md) · 前置：[`P2`](./2026-11-18-recording-p0-p2-main-thread-and-capture.md) · 后续：[`P4`](./2026-11-18-recording-p0-p4-closeout.md)
> 设计依据：spec §5.10、§5.11、§6.5、§6.7；用户已批准。

**Goal:** 把“音频录制”和“屏幕录制”拆成两个原生设置页；输出目录与 AAC 码率按 kind 独立持久化；旧共享值只在首次启动 seed 一次，之后不再回读共享 key；调用开始时快照偏好，设置变化不影响已开始会话；目录发现、历史/导出列表、恢复与热键不退化；HUD 外观等确实共享的项明确标注。

**Architecture:** `SharedKit` 只提供 kind 无关的存储枚举与路径/迁移原语（不能反向依赖 `CaptureCore.RecordingKind`）；App 层做 `RecordingKind ↔ RecordingOutputKind` 映射。新增 `RecordingExportRoot` 让导出窗口扫描音频/屏幕两个根；ledger、恢复根、59 分钟分段、导出编码均不改。

---

## 1. Owned files（精确 allowlist）

**Create**
- `App/SnapGlass/Sources/Windows/AudioRecordingPreferencesView.swift`
- `App/SnapGlass/Sources/Recording/RecordingExportRoot.swift`

**Modify**
- `Packages/SharedKit/Sources/PreferenceKeys.swift`
- `App/SnapGlass/Sources/Windows/PreferencesNavigation.swift`
- `App/SnapGlass/Sources/Windows/PreferencesView.swift`
- `App/SnapGlass/Sources/Windows/RecordingPreferencesView.swift`
- `App/SnapGlass/Sources/MenuBar/CaptureViewModel.swift`（启动时 seed；屏幕根）
- `App/SnapGlass/Sources/MenuBar/CaptureViewModel+Recording.swift`（按 kind 码率/模式/音频根；调用时快照）
- `App/SnapGlass/Sources/Recording/RecordingSessionController.swift`（快照字段 + `startAudio` roots 参数）
- `App/SnapGlass/Sources/Recording/RecordingExportViewModel.swift`（多根加载/打开/默认输出）
- `App/SnapGlass/Sources/Windows/RecordingsWindow.swift`（构造两个根）
- `App/SnapGlass/Resources/en.lproj/Localizable.strings`
- `App/SnapGlass/Resources/zh-Hans.lproj/Localizable.strings`
- `App/SnapGlass/Resources/ja.lproj/Localizable.strings`
- `App/SnapGlass/Resources/ko.lproj/Localizable.strings`

**Do not touch:** `Packages/CaptureCore/Sources/Recording/RecordingSessionLedger.swift`（历史/恢复语义）、`RecordingPipelineSpaceGate.swift`、`ScreenRecordingEngine.swift`、`RecordingControlPanel*`、截图架、entitlements、TCC、`Package.swift`。

---

## 2. 接口契约

### 2.1 SharedKit（kind 无关）

```swift
public enum RecordingOutputKind: String, Sendable, CaseIterable {
    case audio, screen
}

public enum PreferenceKeys {
    // 既有 key 全部保留
    public static let recordingAudioBitRate = "recording_audioBitRate"
    public static let recordingScreenAudioBitRate = "recording_screenAudioBitRate"
    public static let recordingAudioCustomOutputDirectory = "recording_audioCustomOutputDirectory"
    public static let recordingScreenCustomOutputDirectory = "recording_screenCustomOutputDirectory"
    public static let recordingPerKindPreferencesSeeded = "recording_perKindPreferencesSeeded"
}

public enum RecordingDestinationPreferences {
    // 旧无参 API 保留，等价于 .screen，避免破坏现有调用
    public static func directory(for kind: RecordingOutputKind = .screen, in: UserDefaults = .standard, moviesDirectory: URL? = nil, fileManager: FileManager = .default) -> URL?
    public static func customDirectory(for kind: RecordingOutputKind = .screen, in: UserDefaults = .standard) -> URL?
    public static func setCustomDirectory(_ directory: URL, for kind: RecordingOutputKind, in: UserDefaults = .standard)
    public static func reset(for kind: RecordingOutputKind, in: UserDefaults = .standard)

    /// One-time copy of legacy shared keys into per-kind keys. Sets a marker; never runs twice.
    public static func seedLegacySharedValuesIfNeeded(in: UserDefaults = .standard)
}
```

**优先级（必须写成注释）**
- 首次 seed 前：per-kind key → legacy `recording_customOutputDirectory` → 默认 `Movies/SnapGlass/Recordings`。
- seed 后：只读 per-kind key → 默认；**不再回读** legacy。用户 reset 某 kind 后，该 kind 回默认，不把另一个 kind 的值耦回来。
- 默认目录两者可以相同（保持现有路径发现），但 key 独立；不得把“相同默认”实现成共享 key。

### 2.2 App

```swift
enum RecordingAudioPreferenceStore {
    static func bitRate(for kind: RecordingKind, in defaults: UserDefaults = .standard) -> Int
    static func setBitRate(_ bitRate: Int, for kind: RecordingKind, in defaults: UserDefaults = .standard)
    // audioBitRateKey 作为既有别名保留，值改为 PreferenceKeys.recordingAudioBitRate
}

struct RecordingExportRoot: Sendable, Hashable {
    let kind: RecordingKind
    let root: URL
    let indexURL: URL
}

// RecordingSessionController
func startAudio(_ configuration: AudioRecordingConfiguration, roots: RecordingPipelineRoots) async throws
```

- `RecordingPreferenceSnapshot` 增加 `screenAudioMode: AudioSourceMode`、`screenAudioBitRate: Int`；`RecordingSessionSnapshot` 同步保存，`startCapture` 只用快照，不再读 live defaults。
- 音频：`CaptureViewModel.startDefaultAudioRecording` 在调用瞬间构造 `AudioRecordingConfiguration` + `RecordingPipelineRoots`（`.audio` 目录），再 `startAudio`；热键入口同样走该函数。
- 屏幕：picker 返回时快照已含 screen mode/bitrate/destination；倒计时期间改设置不影响本次。

---

## 3. 实施步骤（顺序执行）

### Step 1 — 新 key 与一次性 seed

1. 在 `PreferenceKeys` 增加 §2.1 的 key 与默认值（码率默认 128000，与现状一致）。
2. `RecordingDestinationPreferences` 按 kind 读写；旧无参 API 映射 `.screen`。
3. 实现 `seedLegacySharedValuesIfNeeded`：
   - 若 marker 已存在：直接返回；
   - 若 legacy 自定义目录非空：写入两个 per-kind key（仅当对应 key 不存在）；
   - 若 legacy 码率 key 存在：写入 screen 码率（仅当不存在）；audio 码率继续用原 key；
   - 写 marker。任何一步失败不写 marker 以外的半状态？最小实现：先算值，再一次性写入，最后 marker；不做网络/外部 I/O。
4. 在 `CaptureViewModel.init` 最早处调用一次 seed（在任何根计算之前）。
5. 不得删除 legacy key；不得把 legacy key 继续作为运行时读写目标。

### Step 2 — 按 kind 的码率与模式

1. `RecordingAudioPreferenceStore.audioBitRateKey` 改为 `PreferenceKeys.recordingAudioBitRate` 的别名；`audioConfiguration` 用 `bitRate(for: .audio)`。
2. 新增 `bitRate(for:)`：`.audio` 读 audio key；`.screen` 读 screen key；两处都做 `[96k,128k,192k,256k]` 校验并回落 128k。
3. 屏幕启动：`startCapture` 用快照的 `screenAudioBitRate`，不再 `defaults.object(forKey: audioBitRateKey)`。
4. 来源模式 key 原样保留：音频 `recordingAudioMode`，屏幕 `recordingScreenAudioMode`；不改迁移函数 `RecordingAudioPreferenceMigration` 的语义。
5. 不改默认值（音频默认 systemAndMicrophone，屏幕默认 system），不改旧 `recording_systemAudio` 升级路径。

### Step 3 — 设置页拆分（原生、紧凑、macOS 13 兼容）

1. `PreferencesSection` 增加 `.audioRecording`（放在 `.recording` 之前）；`.recording` 仍是屏幕页。
   - `.audioRecording`：title `Audio Recording`，subtitle 说明“选择音源、音质与保存位置”，icon `waveform`。
   - `.recording`：title 保持 `Screen Recording`，subtitle 移除“audio”，改为“视频质量、屏幕音源与保存位置”。
2. `PreferencesView` 增加 case：`.audioRecording: AudioRecordingPreferencesView()`；`.recording: RecordingPreferencesView()`。
3. 新 `AudioRecordingPreferencesView`（结构沿用 `PreferencesCardGrid` / `PreferencesCard`）：
   - 音频来源 Picker（system / microphone / systemAndMicrophone）；
   - 输出形态 Picker（mixed / separateTracks）；
   - “Audio quality” Picker（4 档，绑定 audio 码率）；
   - 音频保存位置卡片：路径、可用空间、Choose/Open/Reset；caption 明说“仅用于音频录制，不移动既有文件”；
   - 快速录音快捷键行 + 首次空态提示（复用现有 `KeyboardShortcuts.Recorder`，不新增 Name）；
   - 不出现“屏幕音源/视频质量”，不出现被灰掉的屏幕控件。
4. `RecordingPreferencesView` 改为屏幕页：
   - 顶部屏幕音源 Picker（保留 `screenAudioModeBinding` 对旧 `recordingSystemAudio` 的兼容写入）；
   - 屏幕 AAC 码率 Picker（绑定 screen key）；
   - 视频 codec/resolution/frame rate/bitrate 原样；
   - 屏幕保存位置卡片（screen key），caption 明说“仅用于屏幕录制”；
   - “Segmentation & Safety” 卡片保留 59 分钟/恢复常开，并把“隐藏截图架/菜单栏时长”标注为“适用于所有录制”；
   - “Control panel” 卡片保留在屏幕页，加 caption：“面板外观由音频与屏幕录制共享”；现有“HUD 隐藏时禁用透明度/悬停”属于依赖项，保留但文案说明优先级，不新增禁用核心功能。
5. 共享项只保留：HUD 外观、截图架隐藏、菜单栏时长、reveal on finish、capture frame；全部在 caption/标题中明确“共享”。其余（来源、布局、码率、目录、快捷键）按 kind 独立。
6. macOS 13：不使用 `ContentUnavailableView`、`@Observable`、双参 `onChange`；沿用现有 `PreferencesCard*` 与 `.pickerStyle(.menu)`。

### Step 4 — 调用时快照

1. `RecordingPreferenceSnapshot.init` 增加 screen mode/bitrate；`RecordingSessionSnapshot` 保存。
2. `sourcePickerCompleted` 用快照构造 `RecordingSessionSnapshot`；`startCapture` 只读 `activeSession`，删除 live defaults 读取（屏幕模式、屏幕码率）。
3. 目标目录：`prepareDestination` 与 `pipelineRoots(for:)` 继续用快照 `destinationDirectory`；不得在倒计时后重新读偏好。
4. 音频：`startAudio(_:roots:)`；控制器内部 `pipelineRootsForCurrentDestination()` 删除或改为显式 roots 参数；`startAudio` 只使用传入 roots。
5. 录制中通过 HUD/菜单改来源仍走 `applyRoute`，不影响“默认来源”持久化语义；设置页修改只影响下一次会话。

### Step 5 — 导出/历史窗口双根

1. 新建 `RecordingExportRoot`；`RecordingsWindow` 用 seed 后的偏好构造音频/屏幕两个根；若两个 root 相同，只保留一个扫描项（`kind` 用 `.screen` 占位，实际按 record.kind 展示）。
2. `RecordingExportViewModel`：
   - 主 init 改为 `init(roots: [RecordingExportRoot], defaultStem:)`；保留 `init(recordingRoot:indexURL:)` 作为单根便捷入口（测试/旧调用）；
   - `loadPublishedSessions` 逐根调用 `RecordingSessionLedger.publishedSessions`，按 `sessionID` 去重（同 id 取较新 `startedAt`），记录 `rootBySessionID`；
   - `selectSession` 用 `rootBySessionID[sessionID]` 调 `openExisting`；找不到时给 `.sessionUnavailable`；
   - 选中会话时若用户尚未手动改输出目录，把 `outputDirectory` 设为该会话所在根；`setOutputDirectory` 置 `hasUserChosenOutputDirectory = true`；
   - 导出输出仍允许用户另选目录；不得覆盖源文件（沿用 planner）。
3. 左侧会话列表沿用现有 `publishedSessions`；不新增窗口、不改视觉体系；空态/错误文案不退化。
4. 恢复：`recoverableSessions` 的调用方式不在本阶段新增；确保 roots 只影响“已发布列表/打开”，不改恢复根（Application Support）。
5. 热键：`PreferenceKeys.recordingAudioShortcut`、`KeyboardShortcuts.Name.audioRecording` 原样；只把设置行移到音频页。

### Step 6 — 四语言与静态核对

1. 新增 key（键=英文原文，四语言同步，占位符一致）：
   - `Audio Recording`
   - `Choose audio sources, quality, and save location.`
   - `Screen Recording`（若已存在则复用）
   - `Choose video quality, screen audio, and save location.`
   - `Applies to audio and screen recordings.`
   - `Panel appearance is shared by audio and screen recordings.`
   - `Shelf visibility and menu-bar duration apply to every recording.`
   - `This folder is used for audio-only recordings. Existing files are not moved.`
   - `This folder is used for screen recordings. Existing files are not moved.`
   - `Audio quality`
   - `Screen audio quality`
   - `Selected AAC bitrate is applied to each encoded track.`（若已存在则复用）
2. 视图内用字面量；NSOpenPanel/AppKit 用 `AppLocalization.string`；不改 InfoPlist 文案。
3. `grep` 确认：设置页无 `recording_customOutputDirectory` 直接读写；无 live `audioBitRateKey` 用于屏幕；`startCapture` 无 defaults 读取。

---

## 3.5 实现前调整（先记录，再改产品代码）

1. **设置页容量读取走异步探测。** 两个设置页用 `RecordingDestinationProbe.capacity(at:)`（P2 提供，单路径 single-flight、5 s 超时），页面不调用同步 `RecordingStorage.availableBytes`；`.unavailable` 与 `.timedOut` 使用现有“Could not check free space…”文案，不把超时说成卷已满。`RecordingStorage.availableBytes` 保留原实现，不再被设置页引用。
2. **导出发现根扩展到“用过的目录”。** 新增 `PreferenceKeys.recordingKnownOutputRoots`；`seed`、选择目录、应用启动时记录（标准化路径、去重、上限 12）。导出窗口扫描：当前 audio 根 → 当前 screen 根 → 已记录根 → 旧 `recording_customOutputDirectory`（**仅用于发现**）。这样用户改目录/reset 后旧会话仍可被发现，且新录制不回读旧 key。
3. **多根列表失败口径。** 单根缺失静默跳过；单根索引读取失败继续其它根；只有“没有任何已发布会话且有根失败”时显示现有 `.listingFailed`，避免历史根损坏时用红色错误覆盖可用列表。
4. **音频启动快照提前。** `startDefaultAudioRecording` 在 `await ensureMicrophonePermission` 之前构造 `AudioRecordingConfiguration` 与 `RecordingPipelineRoots`（`.audio` 目录），再调用 `startAudio(_:roots:)`。控制器删除 `pipelineRoots` 初始化参数及 `pipelineRootsForCurrentDestination()`；唯一构造点 `CaptureViewModel.init` 同步删除该参数。录制中的 `applyRoute` 仍走实时路由，不改。
5. **屏幕页固定分轨。** 屏幕页不提供音频布局 Picker（`ScreenRecordingPipelineAdapter.makeStartConfiguration` 已固定 `.separateTracks` 内嵌）；音频页的输出形态只影响纯音频。屏幕页不出现纯音频音源/布局，音频页不出现屏幕音源/视频项。
6. **估算按 kind 实际码率与轨数。** 音频：`bitRate(for: .audio) × 编码轨数`（mixed=1，separate 的 system+mic=2）；屏幕：视频码率 + `bitRate(for: .screen) × 内嵌轨数`（system=1、mic=1、both=2、none=0）。不使用旧 `recording_systemAudio` 布尔或固定 128k 估算。
7. **快捷键首次提示改为页内提示。** 不再在进入设置时弹 alert；音频页在快捷键为空时显示现有“No shortcut assigned”，并在首次进入时显示一条轻量说明。保留 `recordingShortcutHintShown` 与 `KeyboardShortcuts.Name.audioRecording`。
8. **共享项与过时文案。** 删除“屏幕录音仍只支持系统音频、麦克风待接入”的过时 caption；HUD 外观、截图架隐藏、菜单栏时长、reveal on finish、capture frame 明确标注为共享。
9. **可访问性。** 只使用现有标准控件（Picker/Button/Toggle/KeyboardShortcuts.Recorder），为目录路径、可用空间、质量选择补 accessibility label/hint 与 `.help`；不使用自定义手势或 hover-only 操作；保持 macOS 13 单参 `onChange`。
10. **Owned files 不变。** 两个新源文件需 P4 在构建前运行 `xcodegen generate`；P3 不手改 `.xcodeproj`、不改 scheme。

## 4. 失败处理

| 场景 | 必须行为 |
|---|---|
| 旧共享目录存在、新 key 不存在 | 首次 seed 复制到两个 kind；旧录音仍可在导出窗口看到 |
| marker 已写、用户 reset 一个 kind | 该 kind 回默认；不回读另一个 kind/legacy |
| 新目录不可写/空间不足 | 现有 `RecordingDestinationError`；开始前失败，不半启动 |
| 两个 kind 指向同一目录 | 只扫描一次；按 `record.kind` 展示与选默认输出 |
| 某根索引损坏 | 该根报现有 listing 错误；不阻断另一个根的列表（最小实现：记录错误并继续，若框架只支持单错误则保留第一个错误并说明） |
| 选中会话的根已失联 | 现有 `sessionUnavailable`；不尝试从另一根猜路径 |
| 设置页共享项被误当独立 | caption 明确“共享”；不得复制出第二套 HUD key |
| macOS 13 API 不可用 | 只用现有卡片/菜单 Picker/单参 onChange；不引入新框架 |

---

## 5. 验收（本阶段只到 Implemented）

- 新页与旧页均无禁用核心功能；音频页可独立完成音频录制配置，屏幕页可独立完成屏幕录制配置。
- 旧用户升级：原自定义目录仍被发现；旧码率仍生效；不主动弹麦克风权限。
- 历史/导出窗口能列出两个根中的会话；导出默认输出到该会话所在根，用户可另选。
- 59 分钟分段、恢复语义、热键、截图共存无改动。
- 四语言 key 完整（P4 跑本地化脚本）。
- **不运行** App、设置页 UI、真机、测试、TCC。
