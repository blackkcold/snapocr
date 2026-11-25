# 录制 P0 · B — 目标卷身份、可用空间与需求预算

> **Status:** `Implemented — 源码已改；parse 与本地化静态检查通过；未构建、未运行测试`，2026-11-18。
> Worktree：`/Users/11169285/.local/share/opencode/worktree/5d0345d699d913b55a21fac44cccbd69a3acb4ec/recording-p0`
> Branch：`fix/recording-p0`（base `84e4a6a`）
> 并行：P0-A（录屏代理）独立处理录屏侧；本文只规划 B，不改录屏行为。B 实施后由主代理统一编译/签名。
> 索引：[`2026-11-18-recording-p0.md`](./2026-11-18-recording-p0.md) · 设计依据：spec §5.4「动态预检」「检查目标卷与应用恢复目录所在卷」
> **对 spec 的证据化收窄：** 当前代码中恢复目录没有任何 writer，恢复材料实际落在目标卷会话根。因此 B 只检查**实际写入卷**；恢复材料保留预算仍在目标卷的 checkpoint/tail 预留内计入，不再检查 Application Support 下无关目录。

---

## 0. 结论摘要

1. **最终音频、检查点、恢复材料当前都只写目标卷**。`recoveryRoot`（Application Support）没有任何 writer 向它写入，因此它不应参与起录检查、不应读容量、不应因缺失/不可写/不可读阻止起录。现有预算却要求目标卷和该无关目录各自满足“两份 59 分钟媒体 + 600 秒预留”，导致外置盘录制被内盘剩余空间误伤。
2. **没有卷身份**。`RecordingSpaceBudget.capacitySnapshot()` 按两个 URL 各读一次容量再取最小值；其中 recovery URL 不是写入路径，这次读取本身就是多余的。
3. **按当前调用图，音频起录有 2 次容量读，B 后应为 1 次**：`capacitySnapshot()` 现在对 recordingRoot 与 recoveryRoot 各调用一次 `attributesOfFileSystem`；B 只对实际写入卷读取，recoveryRoot 完全移出。屏幕起录与设置页本来就各 1 次，B 后仍为 1 次。这是静态调用点计数，不是实测性能结论；不承诺时延或 IO 收益。
4. **默认目录未建时探测口径错误**。设置页对 `~/Movies/SnapGlass/Recordings` 直接读容量；目录不存在时返回 `.unavailable`，被显示成“文件夹不可用”。应向上找到**经存在性确认的最近上级目录**读取同一卷容量；自定义外置目录绝不向上回退。
5. **三种状态被压成两种**。当前 `.unavailable` 同时表示“位置不可用”和“读不到容量”；`.insufficientCapacity` 不带数字。B 拆成位置不可用 / 容量读不到 / 确实不足，后者携带实际可用与需求。
6. **设置页与起录不同口径**。设置页用 60 秒码率估算，起录用 59 分钟峰值；B 统一为“同一探针、同一卷、同一 `minimumStartRequirement()`”，屏幕仍以 1 GiB 起录下限为准，不新增屏幕侧空间门禁。
7. **录制中保护不变**：512 MiB 轮询、checkpoint/seal/tail 预留、低空间停止语义全部保留；轮询只针对实际写入卷。恢复材料保留所需空间已计入写入卷的 checkpoint/tail 预留，不再单独检查 Application Support 目录。

---

## 1. 范围与非目标

### 1.1 本阶段做

- 为**实际写入卷**建立卷身份（同卷/异卷判定）；无 writer 的 Application Support 恢复目录不参与检查，也不读容量。
- 按真实写入路径分配**需求预算**：同卷合计，异卷分担；恢复材料保留仍计入其真实写入卷。
- 起录与设置页统一三态结果（位置不可用 / 容量读不到 / 确实不足），不足时展示实际可用与需求。
- 默认目录未创建时，安全探测**已确认存在的上级目录**；自定义外置目录严格按用户选择路径校验，不回退内盘。
- 保持录制中 512 MiB 保护、checkpoint/seal/tail 门禁与 59 分钟分段不变。

### 1.2 本阶段不做

- 不改录屏采集、分段、封装、码率、画质、丢帧语义；不新增屏幕侧空间 preflight。
- 不跨请求/跨页面缓存容量；不做后台轮询缓存；不弱化外置卷断开识别。
- 不重写 checkpoint 事务、journal 格式、`F_FULLFSYNC` 顺序或 300 秒恢复窗口。
- 不删除 `.insufficientCapacity` 的现有用户可见语义，只补充数字与更细的状态。
- 不提交、不构建、不运行测试/专项/独立评审（本轮）。

---

## 2. 真实调用路径（只读核对，行号以当前 worktree 为准）

> P0-A 合并后行号会漂移，实施时以符号名与调用链为准；本文保留行号仅作当前证据。

### 2.1 最终音频

| 步骤 | 位置 | 事实 |
|---|---|---|
| 1 | `App/SnapGlass/Sources/MenuBar/CaptureViewModel+Recording.swift:237` | `pipelineRoots(for: .audio)` 同步取偏好目录，**不读容量**。 |
| 2 | `CaptureViewModel.swift:126-147` | 恢复根固定为 `~/Library/Application Support/SnapGlass/RecordingRecovery`；工厂闭包交给 setup 队列。 |
| 3 | `RecordingPipelineSpaceGate.swift:337-355` | `makeSpaceGated` 只构造 `RecordingSpaceBudget(recordingRoot: roots.sessionRoot, recoveryRoot: recoveryRoot)`，**不预检**（P2 已移走）。B 将移除 `recoveryRoot`。 |
| 4 | `RecordingSessionPipeline.swift:836-848` | `start` 调 `spaceGate.preflightStart()`，是唯一启动门禁。 |
| 5 | `RecordingSessionPipeline.swift:504-518` | 工厂 `createDirectory` 目标目录、`.SnapGlassSessions`、会话根；检查点与最终音频都从这里派生。 |
| 6 | `RecordingSessionPipeline.swift:1234-1243` | 最终音频由 `RecordingSealService` 写到 `roots.outputDirectory`；`pipelineRoots(for:)` 使 `sessionRoot == outputDirectory == 目标目录`。 |
| 7 | `RecordingSealService.swift:248-258` | 发布是**同目录/同卷** staging → 独占 rename；不会写到恢复根。 |

**结论：** 最终音频写目标卷。`recoveryRoot` 在最终音频路径上没有 writer。

### 2.2 检查点

| 步骤 | 位置 | 事实 |
|---|---|---|
| 1 | `RecordingSessionPipeline.swift:518-550` | 会话根为 `<目标>/.SnapGlassSessions/<sessionID>`，每段 `segment-%08d` 目录由工厂创建。 |
| 2 | `RecordingCheckpointWriter.swift:744-793` | 检查点只接受 `sessionRoot` 内的真实目录；CAF/sidecar 写在段目录。 |
| 3 | `RecordingCheckpointWriter.swift:130-157` | 文件与目录 fsync 只作用于上述路径。 |
| 4 | `RecordingPipelineSpaceGate.swift:46-104` | 每次 checkpoint 提交后重新读容量并比较 `requiredHeadroomBytes`；这是**录制中独立决策**。 |

**结论：** 检查点写目标卷；恢复根不参与写入。录制中每次 checkpoint 的容量读取是新的决策，不属于起录预检，不应与起录读数共享。

### 2.3 恢复材料

| 步骤 | 位置 | 事实 |
|---|---|---|
| 1 | `RecordingSessionController.swift:872-888` | 恢复材料 URL 来自 `pipeline.ledger.sessionRoot`，即目标卷会话根。 |
| 2 | `RecordingSessionController.swift:178-181, 238-241` | 以 sessionID 隔离登记，不删除、不自动清理。 |
| 3 | `CaptureViewModel.swift:130-132` | Application Support 下的 `RecordingRecovery` 只被传给预算，**没有写入点**。 |

**结论：** “恢复材料”在目标卷；Application Support 下的 `RecordingRecovery` 不是实际恢复写路径，也不是预算检查对象。B 的分配必须反映这一点：**保留预算计入目标卷，无关目录不参与检查。**

### 2.4 起录预检

**音频：**

```
startDefaultAudioRecording
  → pipelineRoots(for: .audio)                 // 无容量读
  → ensureMicrophonePermission
  → startAudio
    → audioPipelineFactory (setup 队列)        // 无容量读
    → pipeline.start
      → spaceGate.preflightStart
        → budget.preflight
          → capacitySnapshot                    // 当前误把 recording + 无关 recovery 各读一次
```

**屏幕：**

```
sourcePickerCompleted
  → RecordingDestinationProbe.prepare
    → 校验/创建目录 + 读一次容量 + 1 GiB 下限
  → 倒计时 → startCapture
    → ScreenRecordingSessionCoordinator.makeProduction   // 无容量读
```

**结论：** 屏幕起录只有 1 次容量读；音频起录当前有 2 次，其中一次读的是无 writer 的恢复目录。B 之后音频起录只读目标卷 1 次。

### 2.5 设置页

| 位置 | 事实 |
|---|---|
| `RecordingPreferencesView.swift:377-388` | `refreshCapacity()` 对 `destinationDirectory` 调 `RecordingDestinationProbe.capacity`，每次刷新 1 次读。 |
| `AudioRecordingPreferencesView.swift:296-307` | 同上。 |
| `RecordingPreferencesView.swift:226-249` | `.available` 显示可用空间；`.unavailable` 显示“文件夹不可用”；`.timedOut` 显示“无法检查”。 |
| `RecordingPreferencesView.swift:325-341` | 每分钟估算 = 视频码率 + 音频码率 × 轨数，与起录峰值预算不是同一口径。 |

---

## 3. 现状缺陷（B 要修的根因）

| 编号 | 缺陷 | 证据 | 影响 |
|---|---|---|---|
| F1 | 无卷身份，按 URL 循环读容量 | `RecordingSpaceBudget.swift:175-199` | 同卷多读一次；异卷也无法按实际写入卷分配。 |
| F2 | 需求整份压到两个 URL，取最小可用 | `RecordingSpaceBudget.swift:127-136, 190` | 无关的 Application Support 目录参与最小值，外置盘录制被内盘剩余空间误伤。 |
| F3 | 无 writer 的 `recoveryRoot` 仍被检查 | §2.1–2.3 | 目录缺失/不可写/不可读也会阻止起录，与真实写入不符。 |
| F4 | 默认目录未建就直读容量 | `RecordingDestinationProbe.swift:251-279` 的 `.capacity` 分支 | 设置页把“尚未创建”误报为“不可用”。 |
| F5 | `.unavailable` 混合位置/容量 | `RecordingDestinationProbe.swift:4-11` | 用户无法区分“盘不在”与“读不到容量”。 |
| F6 | `.insufficientCapacity` 无数字 | `RecordingDestinationProbe.swift:21-31` | 只显示“至少 1 GB”，不显示实际可用与真实需求。 |
| F7 | 设置页与起录口径不同 | §2.5 | 同一目标卷显示“够”，起录却失败，或反之。 |
| F8 | 自定义外置的回退风险 | `PreferenceKeys.swift:406-422` 返回自定义 URL，不检查存在 | 当前**没有**回退；B 的上级探测必须加“仅默认目录”门禁，不能破坏这一点。 |

---

## 4. 方案裁决（实施者按此执行，不再讨论）

### B1 — 卷身份来自同一次文件系统读取

- 在 `URLVolumeCapacityProvider` 的返回中同时带出 `FileAttributeKey.systemNumber`（`st_dev` 等价，随挂载变化，仅用于单次决策的同卷判定）。
- 不新增额外 `stat`/`URLResourceValues` 调用；一次 `attributesOfFileSystem` 同时回答“哪个卷”和“多少可用”。
- 身份只用于**实际写入根**的分组，以及确认默认目录的已确认上级属于哪一卷；无 writer 的目录不读、不参与分组。
- 身份只在**单次决策**内有效：不写偏好、不跨请求缓存、不跨 2 秒轮询复用。卷被拔出不依赖缓存识别，下一次读自然失败。
- 同卷判定必须用身份，不用路径前缀（symlink/firmlink/挂载点会骗过字符串比较）。

### B2 — 需求按真实写入路径分配

| 路径 | 承担的真实写入 | 检查与需求 |
|---|---|---|
| 目标目录（recording） | 检查点 PCM/视频 chunk、最终音频 staging/final、发布 rename、**恢复材料保留** | `2 × 59 分钟媒体 + 5 分钟 checkpoint + 5 分钟收尾`（沿用现有峰值公式） |
| `~/Library/Application Support/SnapGlass/RecordingRecovery` | 当前**无 writer** | **不检查**：不读容量、不校验存在/可写、不计需求、不阻止起录 |

- **同卷/异卷只针对实际写入根**：若未来出现第二个真实 writer 且与目标同卷，需求合计后只读该卷一次；异卷则各写卷只比较自己的需求。
- 当前只有一个实际写入根，因此起录预检只读目标卷一次；不需要为了“证明同卷”再读第二次。
- 恢复材料保留预算仍在目标卷的 checkpoint/tail 预留内计入——这是“预算计入真实写入卷”，与“检查无关目录”是两件事。
- 若将来引入恢复根 writer，必须先把该根注册为写入根，再加入需求与容量检查；不得仅凭路径存在就恢复检查。
- `SpaceBudgetDecision` 保留 `requiredBytes`/`availableBytes` 作为“绑定卷”的数字（失败卷优先，否则目标卷），并新增 `volumes` 明细；`RecordingSpaceStatus` 的既有字段继续可用。

### B3 — 三态结果

新增/调整状态，禁止互相冒充；三态只描述**实际写入路径**：

```swift
public enum RecordingDestinationCapacity: Sendable, Equatable {
    case available(bytes: Int64, probedDirectory: URL, volume: RecordingVolumeIdentity?)
    case locationUnavailable
    case capacityUnreadable
}
```

- 位置不可用：自定义写入目录不存在/不是目录/不可写；默认目录的最近已确认上级不存在或跨挂载点；写入卷已卸载。
- 容量读不到：写入位置已确认存在，但 `attributesOfFileSystem` 抛错、缺键、负值，或 5 秒超时。超时**不得**报“空间不足”。
- 确实不足：`available < required`，由起录预检产生，携带 `available`/`required`，不塞进探针的枚举里。
- 无 writer 的目录不产生以上任何状态，也不会出现在设置页或起录错误里。

`RecordingDestinationError` 相应调整：`.insufficientCapacity(available: Int64, required: Int64)`；`.unavailableCapacity`/`.timedOut` 文案保持“无法检查可用空间”，与“文件夹不可用”分开。

### B4 — 默认目录的安全上级探测

仅对**非自定义**目标生效：

1. 从目标 URL 向上逐级找第一个 `fileExists(isDirectory: true)` 的祖先，最多到用户 Home（含）。**这一阶段只做存在性判断，不读容量。**
2. 用真实路径比较确认候选祖先是目标的路径前缀（组件级，不是字符串前缀）。
3. 拒绝跨越挂载点：若候选祖先与目标之间出现卷根（`isVolume == true`）的组件，视为位置不可用。默认路径在 `~/Movies/...` 下，正常不会触发。
4. 只对最终候选祖先做**一次** `attributesOfFileSystem`，同时取得可用空间与卷身份；不再对每一级祖先或目标本身重复读取。
5. 卷身份与路径归属由“一次读取 + 组件级路径比较 + 挂载点检查”共同确认，不以多次容量读取来证明。
6. 探测只读：设置页不创建目录；创建仍由起录 `prepare`/工厂负责。
7. 默认目录尚不存在时，可写性检查落在已确认的上级目录上，不对不存在的目标调用 `isWritableFile`。
8. 探测结果标记 `probedDirectory`，UI 文案说明“默认文件夹将在开始录制时创建”，不把祖先的可用空间说成目标目录已存在。

自定义目录**不走上进逻辑**：必须精确校验用户选择的 URL。

### B5 — 自定义外置绝不回退内盘

- `RecordingDestinationPreferences.directory(for:)` 继续原样返回自定义 URL，不做存在性替换。
- 探针只读用户选择路径**所在写入卷一次**；不涉及 Application Support 恢复目录，也不因该目录状态影响起录。
- 探针失败只返回 `.locationUnavailable`，**不得**改写偏好、不得改写成 Movies、不得触发默认目录创建。
- 起录在位置校验失败时直接失败并提示重新选择；不进入工厂，避免在内部盘创建半成品目录。
- 设置页保留用户路径原样显示为错误态，不自动重置；只有用户点“Reset to Default”才回默认。

### B6 — 设置页与起录同口径

- 两个设置页都调用同一个探针（位置 + 容量）和同一个需求函数：
  - 音频：`RecordingSpaceBudget.minimumStartRequirement()`（与 `preflight()` 共用）。
  - 屏幕：`RecordingStorage.minimumStartFreeSpace`（1 GiB，起录现有下限；不新增屏幕空间门禁）。
- 不足时显示：`可用 X · 需要 Y`，X/Y 都用 `RecordingStorage.formattedBytes`。
- 位置不可用与容量读不到分别显示现有两类文案；默认目录未创建时显示“将在开始录制时创建”，不显示红色“不可用”。
- “Open Folder”仅在精确目标目录存在时启用；默认目录未建时禁用并给说明。

### B7 — 录制中保护原样保留

- 512 MiB 轮询保留，仍只看 recording 卷（目标目录）。
- `.capacityUnreadable`/`.timedOut`：跳过本次轮询，不结束录制。
- `.locationUnavailable`：仍按现有语义结束并提示目标不再可用。
- `RecordingPipelineSpaceGate` 的 checkpoint/seal/tail 阈值、300 秒窗口、单飞 seal、低空间停止全部不变。
- 不把起录预检的卷分配结果缓存给录制中轮询；每个 checkpoint/轮询重新取值。

### B8 — 容量查询只做单次决策内去重

- 当前只有一个实际写入根，起录预检只读它一次；不为“证明同卷”额外读取任何目录。
- 允许：当未来存在多个**实际写入根**时，`capacitySnapshot()` 在单次决策内按卷身份合并同卷读取。
- 不允许：把设置页读数、`prepare` 读数或上一次轮询读数跨阶段/跨请求复用。
- 不允许：为了去重而检查无 writer 的目录；无 writer 目录既不读容量也不做位置校验。
- 起录时重新取值；外置卷断开仍由当次读取失败识别。
- 实际写入路径的可用性必须逐路径检查；这条不因同卷合并而放宽。

### B9 — 错误与本地化

- CaptureCore 只产出结构化失败（可用、需求、写入卷），不拼用户文案。
- App 层 `AppLocalization.recordingErrorDescription` 映射为四语言；新增 key 同步 `en` / `zh-Hans` / `ja` / `ko`。
- 文案示例（key 语义，不是最终措辞）：
  - 位置不可用：沿用 “The selected recording folder is unavailable…”。
  - 容量读不到：沿用 “Could not check free space in the recording folder.”
  - 不足：`Not enough space: %@ available, %@ required.`（带实际数字）。
- 不为无 writer 的目录新增任何错误文案或角色说明。

### B10 — 自定义外置卷身份（2026-11-18 追加裁决）

**证据（只读核对）：**
- 仓库当前没有 security-scoped bookmark 或卷 UUID 存储；`RecordingDestinationPreferences` 只存标准化路径。
- SDK 头文件明确：`NSURLVolumeIdentifierKey` 的标识“not persistent across system restarts”；`NSURLVolumeUUIDStringKey` 才是持久 UUID（不可用时为 nil）。`FileAttributeKey.systemNumber` 仍只用于单次决策的同卷合并，不落盘。
- macOS 的 `/Volumes/Macintosh HD` 是系统卷别名（符号链接）；不能因为路径以 `/Volumes/` 开头就一律拒绝。

**裁决：**
1. **新选择**：`setCustomDirectory` 同时记录该目录的 `volumeUUIDString`（每 kind 一个 key）；若选中的是 `/Volumes` 残留目录，则不记录 UUID，交由后续判据拒绝。起录、设置页、写入前复核都用它比较；UUID 不一致 → 沿用既有 “selected recording folder is unavailable” 文案，要求重新选择。
2. **既有设置**：没有存储 UUID 时不因缺失而拒绝。仅对 `/Volumes/<Name>` 增加兼容判据：若 `<Name>` 是**真实目录**（非符号链接）且其卷 UUID 等于 `/Volumes` 所在卷的 UUID（启动卷组），则判定为卸载后残留/系统盘同名目录，拒绝；若 `<Name>` 是符号链接（系统卷别名）或真实挂载卷，则接受。
3. **内盘自定义路径**：不在 `/Volumes` 下的自定义路径（如 `~/Movies`、`/Users/Shared/...`）不适用上述拒绝规则，保持可用。
4. **不缓存容量**：UUID 是身份而不是容量；不引入跨请求容量缓存。每次检查仍按需读取当前 UUID。
5. **写入前一致性**：音频由 pipeline 预检在 writer 启动前复核卷身份，屏幕在倒计时结束、`adapter.start` 前再复核一次；容量仍由唯一一次 preflight 读取。
6. **残余 TOCTOU**：从最后一次身份复核到首次 `open`/`createDirectory` 之间仍可能发生卸载；本阶段不把 UUID 传入 CaptureCore 的每个写事务，成本高于收益，报告中明确窗口。

---

## 5. 容量查询次数核对（本轮新增需求的直接回答）

### 5.1 当前每次“起录决策”的容量读取（按调用图静态计数）

| 场景 | 调用点 | 读取次数 | 其中读无关目录 |
|---|---|---:|---|
| 音频起录，默认内盘 | `RecordingSpaceBudget.capacitySnapshot()` 遍历 recording + recovery | 2 | **1 次读 Application Support 恢复目录（无 writer）** |
| 音频起录，自定义外置 | 同上 | 2 | 同上；目标卷 1 次 + 无关内盘 1 次 |
| 屏幕起录 | `RecordingDestinationProbe.prepare` | 1 | 0 |
| 设置页刷新 | `RecordingDestinationProbe.capacity` | 1 | 0（估算为纯算术，0 次读） |
| 录制中每 2 秒轮询 | `RecordingDestinationProbe.capacity` | 1/次 | 0 |
| 每次 checkpoint / seal | `RecordingSpaceBudget.capacitySnapshot()` | 2/次 | 当前同样含 1 次无关恢复目录读取 |

> 以上是源码调用点计数，不是性能测量；不据此承诺时延或 IO 收益。

### 5.2 B 之后

| 场景 | 读取次数 | 说明 |
|---|---:|---|
| 音频起录（默认或自定义） | **1** | 只读实际写入的目标卷；无 writer 的恢复目录不读。 |
| 屏幕起录 | **1** | 目标或已确认上级目录，一次读取。 |
| 设置页刷新 | **1** | 与起录同一探针；需求为纯计算。 |
| 录制中轮询 / checkpoint / seal | **1** | 每次决策只读目标卷；不跨决策复用。 |

> 当前只有一个实际写入根，因此上表是当前调用图的静态计数。未来若新增第二个写入根，将每个根读取一次后按身份合并；本阶段不承诺未来场景的读取次数。

**结论：按当前调用图，可去掉的是音频起录及录制中预算对无 writer 恢复目录的读取，静态计数从 2 降为 1；屏幕与设置保持 1。异卷场景当前不存在第二个写入根，因此不承诺“异卷 2 次”为现状。不要为了去重额外读取目录，也不要检查无 writer 目录来“确认无关”。**

### 5.3 UX 不变量

- 路径可用性只检查实际写入路径：目标目录（或默认目录的已确认上级）逐项做存在/目录/可写校验；Application Support 恢复目录不检查。
- 容量读取与卷身份来自同一次 `attributesOfFileSystem`；不为确认身份再读一次。
- 外置卷断开仍必须当次失败：不做跨请求缓存，卷身份只在单次决策内使用。
- 起录时重新取值：不把设置页或倒计时前的读数带进 `preflight()`。
- 若 B 为音频新增位置校验，必须使用**只查位置、不读容量**的入口，避免变成“位置 1 读 + 预检 1 读”的新重复。

---

## 6. 接口契约（实施时以此为准）

### 6.1 CaptureCore

```swift
public struct RecordingVolumeIdentity: Sendable, Hashable {
    public let systemNumber: UInt64
}

/// 只有实际接收字节的根才进入预算；无 writer 目录没有角色、不参与检查。
public enum RecordingWriteRole: String, Sendable, Hashable {
    case recording
    // 未来新增真实写入根时在此增加 case，并同时接入需求与容量检查。
}

public struct RecordingVolumePlan: Sendable, Hashable {
    public let role: RecordingWriteRole
    public let path: URL
    public let identity: RecordingVolumeIdentity?
    public let requiredBytes: Int64
    public let availableBytes: Int64?      // nil = 容量读不到
    public let isLocationAvailable: Bool
}

public enum RecordingSpaceDenial: Sendable, Hashable {
    case locationUnavailable(role: RecordingWriteRole, path: String)
    case capacityUnreadable(role: RecordingWriteRole)
    case insufficient(role: RecordingWriteRole, available: Int64, required: Int64)
}

public struct SpaceBudgetDecision: Sendable, Hashable {
    public let allowed: Bool
    public let requiredBytes: Int64        // 绑定卷需求（兼容字段）
    public let availableBytes: Int64       // 绑定卷可用（兼容字段）
    public let reason: String?
    public let volumes: [RecordingVolumePlan]   // 每个实际写入卷一条；无 writer 目录不出现
    public let denial: RecordingSpaceDenial?
}

public struct RecordingSpaceBudget: Sendable {
    /// 只接收实际写入根；不再接收 Application Support 恢复目录。
    public init(
        configuration: RecordingStorageConfiguration,
        capacityProvider: any VolumeCapacityProviding,
        recordingRoot: URL
    )

    /// 测试用：显式注册多个写入根，验证同卷合并与异卷分担。
    init(
        configuration: RecordingStorageConfiguration,
        capacityProvider: any VolumeCapacityProviding,
        writeRoots: [RecordingWriteRoot]
    )

    /// 纯计算：音频起录峰值需求；不读容量、不依赖 roots。
    public static func minimumStartRequirement(
        for configuration: RecordingStorageConfiguration
    ) -> Int64

    /// 实例入口：与 preflight 共用同一公式。
    public func minimumStartRequirement() -> Int64

    public func preflight() throws -> SpaceBudgetDecision
}
```

- `RecordingVolumeSnapshot` 增加 `identity`；provider 返回 nil 表示“读不到”，预检用 `reason`/`denial` 区分。
- `preflight()` 的输入只有实际写入根：每个写入根读取一次容量快照，随后按卷身份合并同卷需求；当前只有一个写入根，因此只有一次读取，也不为“证明同卷”额外读取。
- `makeSpaceGated` 删除 `recoveryRoot` 参数，新增 `expectedVolumeUUID: String?`；`CaptureViewModel` 不再为预算计算或传递 Application Support 路径。预算在每次容量决策前用持久卷 UUID 校验写入根身份（见 B10）。
- `RecordingPipelineError.spacePreflightDenied` 的关联值改为结构化 `SpaceBudgetDecision`（`catch ...(_)` 的既有写法仍可编译）。

### 6.2 App 探针

```swift
struct RecordingDestinationProbe: Sendable {
    /// 屏幕起录：创建默认目录（自定义不创建）+ 位置/卷身份校验 + 一次容量读 + 1 GiB 下限。
    static func prepare(
        directory: URL,
        isCustom: Bool,
        expectedVolumeUUID: String? = nil,
        deadline: Duration = defaultDeadline
    ) async throws

    /// 设置页：只读，不创建；默认目录允许已确认上级探测；一次容量读。
    static func inspect(
        directory: URL,
        isCustom: Bool,
        expectedVolumeUUID: String? = nil,
        deadline: Duration = defaultDeadline
    ) async -> RecordingDestinationCapacity

    /// 音频起录：只做位置/卷身份校验，不创建、不读容量；容量由 pipeline 预检负责。
    static func validateLocation(
        directory: URL,
        isCustom: Bool,
        expectedVolumeUUID: String? = nil,
        deadline: Duration = defaultDeadline
    ) async throws
}
```

- `prepare` 保留给屏幕起录，语义与现在一致（默认目录创建 + 1 GiB 下限），只把结果改为三态/带卷身份；自定义路径先校验持久卷 UUID（或 B10 的 `/Volumes` 兼容判据）。
- `inspect` 是设置页的只读入口；默认目录可向上找已确认上级，自定义只接受精确路径并校验卷身份。
- `validateLocation` 只做存在/目录/可写/上级确认与卷身份校验，**不读容量**；供音频起录在工厂前与 writer 启动前使用，避免与 `preflight()` 形成新的重复读。
- 三者共用同一 single-flight 队列与 5 秒 deadline；同一路径同一请求类型与同一 expected UUID 仍合并。

### 6.3 App 展示

```swift
enum RecordingStorage {
    static let minimumStartFreeSpace: Int64 = 1_024 * 1_024 * 1_024
    static let minimumContinueFreeSpace: Int64 = 512 * 1_024 * 1_024
    static func formattedBytes(_: Int64) -> String
}
```

- 设置页和起录错误都用 `formattedBytes`。
- 音频需求调用 `RecordingSpaceBudget.minimumStartRequirement(for:)`，不在视图里复制公式。

---

## 7. 实施步骤

### Step 1 — 卷身份与容量快照（CaptureCore）

1. `RecordingVolumeCapacitySnapshot` 增加 `identity: RecordingVolumeIdentity?` 与 `availableBytes: Int64?`。
2. `URLVolumeCapacityProvider` 从同一次 `attributesOfFileSystem` 读取 `systemNumber` 与 `systemFreeSize`；缺 `systemNumber` 时身份为 `nil`，同卷退化为“路径相同才合并”，不阻塞。
3. `RecordingSpaceBudget.capacitySnapshot()` 的输入改为**实际写入根**：当前只有 `recordingRoot`，因此只调用一次 provider；未来新增写入根时，每个根读取一次后按身份合并，不为去重额外读取。
4. 需求分配：
   - `recordingRequirement = segmentBytes × 2 + checkpointAndTailBytes`；恢复材料保留已包含在 checkpoint/tail 预留内；
   - 不再设置 `recoveryRequirement`，也不再传入 Application Support 恢复目录；
   - 多写入根时同卷求和，异卷分别比较。
5. `preflight()` 产出 `volumes` 与 `denial`；兼容字段取绑定卷。
6. 加 `minimumStartRequirement()`，`preflight()` 与设置页共用。
7. `makeSpaceGated` 删除 `recoveryRoot` 参数，新增 `expectedVolumeUUID: String?`；`CaptureViewModel` 不再为预算计算或传递 `~/Library/Application Support/.../RecordingRecovery`。若该路径在别处确无用途，一并移除本地变量。

### Step 2 — 探针三态与默认上级探测（App）

1. `RecordingDestinationCapacity` 改为三态；`.available` 带 `probedDirectory` 与 `volume`。
2. 保留 `prepare`（屏幕起录，创建 + 1 GiB），新增只读 `inspect`（设置页）与不读容量的 `validateLocation`（音频起录）。
3. 默认目录的 `inspect`：按 B4 找已确认祖先，只读一次；结果标记 `probedDirectory`。
4. 自定义目录：精确校验，不创建、不上进、不回退。
5. `perform` 中把“位置检查”和“容量读取”分开返回，避免一个失败被另一个冒充；每个入口最多一次容量读。

### Step 3 — 起录接线（App 控制器）

1. 音频起录在工厂前对**目标目录**调用 `validateLocation`（不读容量）；失败直接给出结构化位置错误。Application Support 恢复目录不参与该检查。
2. `pipeline.start` 的 `spacePreflightDenied` 携带 `SpaceBudgetDecision`；`AppLocalization` 映射不足数字。
3. 屏幕起录保留 `prepare` 的 1 GiB 下限与现有行为；只更新返回类型与文案。
4. 录制中轮询：`.capacityUnreadable`/`.timedOut` 跳过；`.locationUnavailable` 维持现有结束语义；512 MiB 阈值不变。

### Step 4 — 设置页同口径

1. 两个设置页改用 `inspect`，并用同一 `formattedBytes`。
2. 音频页显示 `minimumStartRequirement()`；屏幕页显示 1 GiB 起录下限。
3. 默认目录未建时显示“将在开始录制时创建 + 该卷可用空间”，不再显示红色不可用；`Open Folder` 仅在精确目录存在时启用。
4. 不足时显示“可用 X · 需要 Y”；容量读不到与位置不可用分开显示。

### Step 5 — 测试与文档（实施轮执行，本轮不跑）

1. 更新 `RecordingSpaceBudgetTests`：
   - 当前单写入根：只读目标卷一次；恢复目录不传入、不查询。
   - 未来两个实际写入根同卷：合并为一次读取，需求求和。
   - 未来两个实际写入根异卷：各自只承担自己的需求；内盘低不阻塞外置录制。
   - 无 writer 目录缺失/不可读：不产生 provider 调用，也不影响 `allowed`。
   - 写入卷容量读不到：fail closed，但不报“空间不足”。
2. 更新 `RecordingPipelineSpaceGateTests` 的结构化错误。
3. 新增/调整本地化 key，四语言一致。
4. 更新 `CHANGELOG.md`（实施轮）。

---

## 8. 预期修改文件（含与录屏共享的标注）

| 文件 | 改动 | 与录屏共享 |
|---|---|---|
| `Packages/CaptureCore/Sources/Recording/RecordingSpaceBudget.swift` | 卷身份、只按实际写入根分组、三态快照、`minimumStartRequirement()`；移除 `recoveryRoot` | 当前仅音频使用；若 A 给屏幕加门禁，必须复用，不得复制 |
| `Packages/CaptureCore/Sources/Recording/RecordingPipelineSpaceGate.swift` | `makeSpaceGated` 移除 `recoveryRoot`、只传实际写入根、预检状态发布 | 否（当前音频专用）；A 若新增屏幕门禁则共享 |
| `Packages/CaptureCore/Sources/Recording/RecordingSessionPipeline.swift` | `spacePreflightDenied` 结构化关联值 | 是（`RecordingSessionPipeline` 同时被音频与屏幕适配器引用） |
| `App/SnapGlass/Sources/MenuBar/CaptureViewModel.swift` | 不再为预算计算/传递 Application Support 恢复目录 | **是**（应用装配同时服务音频/屏幕） |
| `App/SnapGlass/Sources/Recording/RecordingDestinationProbe.swift` | 三态、`validateLocation`/`inspect`、默认上级探测、卷身份透传；只处理目标写入路径 | **是**（屏幕设置页与音频设置页共用；P0-A 可能同时改） |
| `App/SnapGlass/Sources/Recording/RecordingSessionController.swift` | 音频位置校验、结构化错误、轮询状态分支；不检查恢复目录 | **是**（同一控制器承载音频/屏幕生命周期） |
| `App/SnapGlass/Sources/Windows/RecordingPreferencesView.swift` | 屏幕设置页同口径、默认目录文案、可用/需求 | **是**（P0-A 的录屏 UI 可能同文件） |
| `App/SnapGlass/Sources/Windows/AudioRecordingPreferencesView.swift` | 音频设置页同口径、可用/需求 | 否（音频专属），但共用探针 |
| `Packages/SharedKit/Sources/PreferenceKeys.swift` | 记录/清除/读取每 kind 的持久卷 UUID；**不改**自定义目录回退语义 | **是**（两种 kind 的目录解析） |
| `Packages/SharedKit/Sources/RecordingVolumeIdentityPolicy.swift` | 共享 `volumeUUIDString` 与 `/Volumes` 残留判据；设置写入与探针共用 | **是**（两种 kind 共用） |
| `App/SnapGlass/Resources/{en,zh-Hans,ja,ko}.lproj/Localizable.strings` | 新增/调整错误与设置文案 | **是**（A 也会改同文件，注意合并） |
| `Packages/CaptureCore/Tests/CaptureCoreTests/RecordingSpaceBudgetTests.swift` | 单写入根一次读、无 writer 目录零查询、未来同/异卷分配、不可读用例 | 否 |
| `Packages/SharedKit/Tests/ScreenshotShelfPreferencesTests.swift` | 选择时 UUID 记录与 reset 清除 | 否 |
| `Packages/CaptureCore/Tests/CaptureCoreTests/RecordingPipelineSpaceGateTests.swift` | 结构化错误适配 | 否 |
| `CHANGELOG.md` | 实施轮记录 | 是（收尾统一） |

**与 P0-A 的关系（已核对 A 文档 §1.3）：** A 明确“不动录音容量/码率”，也不新增屏幕侧空间预检；A 的改动集中在准备期、停流确认、首帧失败分类、`RecordingSessionController` 与 HUD/本地化。B 与 A 的重叠是文件级而非语义级。

**共享文件处理顺序（必须遵守）：**
1. 等 P0-A（`2026-11-18-recording-p0a-screen-stream-lifecycle.md`，当前 `Planned → Implementing`）合并后再改 `RecordingDestinationProbe.swift`、`RecordingSessionController.swift`、`RecordingPreferencesView.swift`、四个 `Localizable.strings`。
2. 只做加法式改动（新增 case/字段/入口），不重排 A 已改的行；冲突时以 A 的录屏语义为准。
3. 不修改 A 的录屏预检/门禁/停止语义；B 的卷分配只在音频预算内生效。

---

## 9. 失败处理

| 场景 | 必须行为 |
|---|---|
| 自定义外置目录不存在/卷已卸载 | `.locationUnavailable`；提示重新选择；不改偏好、不回退 Movies、不创建目录。只检查该写入卷。 |
| 默认目录不存在 | 设置页 `inspect` 找已确认上级读一次；起录（屏幕 `prepare` / 音频 `preflight`）创建后读目标一次；两者是不同请求，不共用读数、不叠加。 |
| 默认目录上级也不存在/跨挂载点 | `.locationUnavailable`；不借用其他卷容量。 |
| 位置存在但容量读不到 | `.capacityUnreadable`；起录 fail closed（音频/屏幕均不开始），文案为“无法检查可用空间”，不报“空间不足”。 |
| 容量超时 | 同上；录制中轮询跳过本次，不结束。 |
| `available < required` | `.insufficient(available, required)`；UI 显示实际可用与需求；不启动。 |
| Application Support 恢复目录缺失/不可写/不可读 | **不检查、不读容量、不影响起录**；它没有 writer，恢复材料仍在目标卷计入预算。 |
| 未来两个实际写入根同卷 | 需求求和，只读一次容量；两个写入路径仍逐个校验。 |
| 未来两个实际写入根异卷 | 各卷只比较自己的需求；内盘低不阻塞外置录制。 |
| 录制中容量读不到 | 跳过轮询；不改变 512 MiB 保护与 checkpoint 门禁。 |

---

## 10. 验收口径（本阶段只到 `Implemented`）

- Owned files 之外无改动；`git diff --stat` 可核对。
- 音频起录（默认或自定义）的容量读取从 2 次降为 1 次；屏幕起录与设置页保持 1 次；无 writer 的 Application Support 恢复目录零读取、零检查。
- 路径可用性只对实际写入路径检查；恢复材料保留预算仍计入目标卷峰值。
- 默认目录未建时设置页不再误报“不可用”；自定义外置断开时明确报位置不可用且不回退。
- 不足文案包含实际可用与需求；容量读不到与位置不可用文案分开。
- 512 MiB 轮询、checkpoint/seal/tail、59 分钟分段、码率/画质、录屏行为不变。
- 四语言 key/占位符一致；`plutil -lint` 通过。
- 不声称 `Validated`；测试、GUI、真机、外置盘拔插、长录均未运行。

---

## 11. 交接与后续

1. P0-A 完成后，主代理通知本 session；B 从本文件 Step 1 开始，只改上表文件。
2. 实施轮只做静态核对与必要的定向编译（由主代理统一安排），不运行专项/独立评审。
3. 完成后在 `.context/recording-p0/progress.md` 追加 B 条目：状态、文件、接口变化、未验证项。
4. 最终由主代理统一编译/签名；B 不触碰已安装 App、真实数据或系统设置。

---

## 12. 实施记录（2026-11-18）

**Status:** `Implemented — parse / 本地化静态检查通过；未构建、未运行测试`

### 12.1 实际改动

- `RecordingSpaceBudget.swift`
  - 新增 `RecordingVolumeIdentity`、`RecordingVolumeSnapshot`、`volumeSnapshot(at:)`；`systemNumber` 与 `systemFreeSize` 来自同一次 `attributesOfFileSystem`。
  - 移除 `recoveryRoot`；预算只持有 `RecordingWriteRoot`（当前仅目标目录）。
  - `capacitySnapshot()` 只读注册的写入根；按卷身份合并同卷需求，异卷各自比较。
  - 新增 `minimumStartRequirement(for:)` / `minimumStartRequirement()`；`preflight()` 复用同一公式。
  - `SpaceBudgetDecision` 增加 `volumes` 与 `denial`；容量读不到与确实不足分开。
  - 新增持久 `expectedVolumeUUID`：每次容量决策前校验写入根 UUID，不匹配按容量不可读 fail closed；无 UUID 时用共享 `/Volumes` 残留判据。
- `RecordingSessionPipeline.swift`
  - 新增 `RecordingWriteRole`、`RecordingVolumePlan`、`RecordingSpaceDenial`。
  - `spacePreflightDenied` 的关联值改为 `SpaceBudgetDecision`。
- `RecordingPipelineSpaceGate.swift`
  - `makeSpaceGated` 删除 `recoveryRoot`，新增 `expectedVolumeUUID`；只传目标写入根。
- `PreferenceKeys.swift`
  - 新增每 kind 的卷 UUID key；`setCustomDirectory` 记录 `volumeUUIDString`，`reset` 清除，`customDirectoryVolumeUUID` 读取。
  - 选择时若路径是 `/Volumes` 残留目录，不记录系统 UUID，避免绕过后续判据。
- `RecordingVolumeIdentityPolicy.swift`（SharedKit）
  - 共享持久 UUID 读取与 `/Volumes` 残留判据；设置写入与 App 探针共用同一逻辑。
- `CaptureViewModel.swift` / `CaptureViewModel+Recording.swift`
  - 移除 Application Support 恢复目录的预算接线。
  - 音频起录快照中携带 `isCustomDestination` / `expectedVolumeUUID`，在权限提示前捕获。
  - 工厂闭包把 UUID 传入 `makeSpaceGated`。
- `RecordingDestinationProbe.swift`
  - 三态：`available(bytes:probedDirectory:volume:)` / `locationUnavailable` / `capacityUnreadable`。
  - `prepare`（屏幕起录，创建 + 1 GiB）、`inspect`（设置页，只读）、`validateLocation`（音频起录，不读容量）、`capacity`（录制中轮询）。
  - 新增 `expectedVolumeUUID`：新选择严格比较持久 UUID；既有设置无 UUID 时只守 `/Volumes/<Name>` 与 `/Volumes` 同卷的真实目录，符号链接系统别名与真实挂载卷放行。
  - 默认目录未建时只对已确认上级读取一次；自定义目录精确校验，不上溯、不回退。
  - 拒绝跨挂载点与断链符号链接，避免借用内盘容量。
- `RecordingSessionController.swift`
  - 音频起录在工厂前做位置/卷身份校验；writer 启动前由 pipeline 预检复核卷身份；容量只由 pipeline 预检读取。
  - 屏幕倒计时结束后、writer 启动前再校验一次；轮询携带 expected UUID。
  - 录制中轮询：`capacityUnreadable` 跳过，`locationUnavailable` 结束，512 MiB 阈值不变。
- `RecordingPreferencesView.swift` / `AudioRecordingPreferencesView.swift`
  - 统一用 `inspect` 与 `formattedBytes`，并传入每 kind 的 expected UUID。
  - 可用空间、容量读不到、位置不可用分开展示。
  - 不足时显示实际可用与需求；默认目录未建时显示“将创建”，`Open Folder` 仅在精确目录存在时启用。
  - 音频需求来自 `minimumStartRequirement(for:)`；屏幕需求仍为 1 GiB 起录下限。
- `AppLocalization.swift` 与四个 `Localizable.strings`
  - 新增 `Not enough space: %@ available, %@ required.` 与 `The default recording folder is unavailable.`。
  - `spacePreflightDenied` 按 `denial` 映射为可操作文案。
- 测试
  - `RecordingSpaceBudgetTests`：单写入根只读一次、无 writer 目录零查询、同卷合并、异卷分担、容量不可读。
  - `RecordingPipelineSpaceGateTests`：移除 `recoveryRoot` 参数，断言结构化拒绝。

### 12.2 静态检查

- `xcrun swiftc -frontend -parse`：13 个改动 Swift 文件（含新增 `RecordingVolumeIdentityPolicy`）全部通过。
- `bash scripts/check-localization.sh`：通过（键集、占位符、源引用、视图语言）。
- `plutil -lint`：四个 `Localizable.strings` 全部 OK。
- `git diff --check`：exit 0。

### 12.3 未验证与编译风险

- 未运行 `xcodebuild`、SwiftPM 测试、GUI/TCC、真机、外置盘拔插或长录；由交付阶段统一编译。
- 主要编译风险：
  - `FileAttributeKey.systemNumber` 与 `URLResourceKey.isVolumeKey` 的 SDK 可用性（macOS 13 目标，已核对头文件 `NSFileSystemNumber` 与 `NSURLIsVolumeKey`）。
  - `RecordingPipelineError.spacePreflightDenied` 关联值类型变化；现有 `catch ...(_)` 仍可编译，但任何读取 `reason` 的外部调用需改用 `decision.denial`。
  - `makeSpaceGated` 与 `startAudio` 的签名变化；仓库内调用点已更新。
  - SwiftUI 的两处多插值 `Text` 依赖 `%@` 键；本地化脚本已通过，但尚未做 UI 渲染验证。
- 行为未验证：同卷/异卷真实卷行为、默认目录上级探测、外置卷断开、设置页显示、升级路径。

### 12.4 与方案的差异

- 未新增公开 `additionalWriteRoots`；生产只注册目标写入根，测试用内部 `writeRoots` 入口验证同卷/异卷分配。这样避免为尚不存在的第二 writer 扩大公开 API。
- 当前只有一个写入根，因此静态容量读取次数为 1；不承诺未来多写入根场景的读取次数。

### 12.5 外置卷身份判据与残余窗口

**判据顺序（自定义路径）：**
1. 位置必须是存在、目录、可写。
2. 若选择时记录了 `volumeUUIDString`：当前 UUID 必须相等；读不到 UUID 也视为不匹配，fail closed。
3. 若没有记录 UUID（既有设置/卷不提供 UUID）：仅当路径位于 `/Volumes/<Name>`、`<Name>` 是真实目录（非符号链接）、且其卷 UUID 等于 `/Volumes` 所在卷的 UUID 时拒绝；`/Volumes/Macintosh HD` 这类符号链接系统别名、真实挂载卷、以及 `/Volumes` 之外的内盘自定义路径均放行。
4. 选择时：若选中的是上述 `/Volumes` 残留目录，不写入 UUID；设置页会立即按同一判据拒绝，避免把系统 UUID 记成“预期卷”而绕过检查。

**不误伤内盘与别名的原因：**
- 新选择的 `/Volumes` 内盘目录会记录该路径所在卷的 UUID，之后按 UUID 相等放行。
- 既有设置没有 UUID 时才使用 `/Volumes` 兼容判据；该判据不覆盖 `/Volumes` 之外的路径。
- 持久身份用 `volumeUUIDString`，不用会随重启变化的 `systemNumber`；后者只保留在单次预检的同卷合并中。

**覆盖点：**
- 设置页 `inspect`。
- 屏幕起录 `prepare` 与倒计时结束后的 `validateLocation`，以及录制中 2 秒轮询。
- 音频起录工厂前的 `validateLocation`；音频预算在 preflight 与每次 checkpoint/seal 前校验写入根 UUID。

**残余 TOCTOU：**
- 从最后一次 UUID 校验到首次 `open`/`createDirectory` 之间仍可能发生卸载；未把 UUID 下沉到 CaptureCore 的每个文件事务。
- 音频工厂在首次校验后创建目录；若窗口内卷被替换，第二次 writer 前校验会拒绝启动，但可能留下空的会话目录。
- 既有设置（无 UUID）且自定义路径不在 `/Volumes` 下，或是 `/Volumes` 下的符号链接路径时，若卸载后同名目录被重建在系统盘，无法仅凭路径区分；重新选择一次即可写入 UUID。
- 这些窗口依赖用户主动卸载/替换卷，且不引入跨请求容量缓存。
