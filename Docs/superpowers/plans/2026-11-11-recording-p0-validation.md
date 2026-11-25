# 录制最终验证（P0）— 验收计划 v1.1

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在产品实现完成后，用产品自身代码与合成媒体入口，对 12 项 P0 硬门禁给出可判定结论；本环境能证的证，不能证的如实 `blocked`/`incomplete`，不以机制短测冒充真机、长时或全矩阵验收。

**Architecture:** 不新建 spike/框架。验证入口在既有 `Packages/CaptureCore/Tests/CaptureCoreTests/`，加一个薄 runner `scripts/final-validation.sh`；真实采集/GUI/TCC 项直接跑产品 App 与人工清单。测试只写 `facts.json`，**runner 在命令结束后核证退出码/日志/哈希并最终写 `result.json`**。P0 是 T18 内的最终验收，不是 T1–T17 的开发前置。

**Tech Stack:** Swift 6、Swift Testing、AVFoundation/CoreMedia、ScreenCaptureKit、AVAudioEngine/CoreAudio、shell；不新增 SPM target/依赖，不改最低系统版本。

**Spec:** `Docs/superpowers/specs/2026-11-11-audio-and-segmented-recording-design.md`（修订 2.1）
**母计划:** `Docs/superpowers/plans/2026-11-11-recording-full-delivery.md`
**r1 评审:** `.superpowers/sdd/2026-11-11-recording-full-delivery/review/p7-plan-review-r1.md`
**v0.3 原文冻结:** `.superpowers/sdd/2026-11-11-recording-full-delivery/review/p0-v03-source.md`（正文 SHA-256 `a2cfacbae415e045bfd7ad9a3ebd1b8e051a69152003e0a89ae35485aa2cf56a`）
**Status:** `v1.1 fix-round1`，2026-11-12。**未运行任何 P0；本文件只写计划。** 用户裁定“最后验证、基于当前环境开发、开发优先”；本计划不阻挡任何开发任务，也不构成验收通过。

---

## Global Constraints

- P0 是**最终验收条件**，不是 T1–T17 的开工前置；P7 入口是 T1–T17 完成 + P7 阶段文档批准。
- 正常产物每段 `≤3540s`；2 小时音频 = `59 + 59 + 2` 三段；主动导出上限 `7170s`；`48000 Hz`；时间轴用整数样本。
- 视频只在录制时首次编码；封装/拼接/裁剪不得再次编码；音频处理单独标识。
- 音源切换是同一 session 的 `RouteEvent`；不新建会话、不轮转段、不重启视频；缺失区间原位补静音。
- 未测门禁不得改为 optional；文档阅读、API 存在、“同分辨率/同码率”都不构成证据。
- 不新增 SPM target/依赖、不改 `Package.swift` 既有协议、不引入外部二进制、不改最低系统版本、不手改 `.xcodeproj`。
- 不提交、不 push、不打包、不签名安装、不部署；CHANGELOG/PRIVACY 由 T18 同步。
- **判定诚实性**：机制短测、真实 59 分钟、2h/8h、真机设备、人工听测是不同证据；任一必需方法未执行 → 该项最高 `incomplete`。
- **安全**：真实 TCC/GUI/锁屏/设备/签名/长跑/外部卷必须另行明确授权；禁止清 TCC、`sudo powermetrics`、填满真实卷、`killall`/宽匹配 kill、杀用户正在录制的实例。

---

## 0. 状态口径：L1 / L2-partial / L2-complete / L3

| 级别 | 名称 | 成立条件 | 可以说 | 不可以说 |
|---|---|---|---|---|
| L1 | 实现已交付 | T1–T18 完成；全量测试/构建/本地化/strictlint 有日志；known-fail 原样记录 | “功能已实现，测试结果如下” | “已验证”“可发布” |
| L2-partial | 本机已执行子集通过 | 至少一个含行为方法的项 `localVerdict=pass`；每项 `localVerdict` 为 `pass/incomplete/blocked/fail`；`blocked` 有原因 | “本机已执行子集通过；以下项 blocked/incomplete” | “12 项本机验证通过” |
| L2-complete | 12 项本机子集全通过 | 12 项 `localVerdict` 全 `pass`，且每项 `requiredObservations` 齐全 | “本机子集全部通过；全矩阵未验收” | “全矩阵验收通过” |
| L3 | 全矩阵已验收 | L2-complete + macOS 13/14/15、x86_64、真实设备、播放器/DAW、听测、外置卷/断电、2h/8h 全部有证据且 `pass` | “全矩阵验收通过” | 任何未跑项的“等价通过” |

- **`localVerdict=pass` 的硬条件**：`localMethods` 全 `pass`，且其中至少一个**行为型方法**（`IT-S/FH/MRT/FI/DEV/SOAK/HUM`）；仅 `STA/UT` 或空集一律 `blocked`。静态检查通过不等于产品行为通过。
- **compile min macOS 13 与强制 legacy backend 都不等于旧系统真机通过**，只能记 `STA`/`UT`。
- 只有 L3 才可写“验收完成”；L1/L2 必须带限定语。

### 0.1 当前实际矩阵（只读基线）

| 项 | 值 |
|---|---|
| 系统 | macOS 26.4.1 / Build 25E253 / arm64 |
| Swift | Apple Swift 6.3.3 |
| 磁盘 | 926 GiB 总 / ~200 GiB 可用（记录时） |
| 既有失败 | CaptureCore `legacyDirectoriesWaitForTheLegacyGrace`（`ScreenshotShelfSessionDirectoryTests.swift:78`） |
| 未具备 | macOS 13/14/15、x86_64、真实设备矩阵、播放器/DAW、签名安装授权、外置卷/断电环境 |

---

## 1. 验证入口与精确 Files（T18 创建，不另建 spike）

| 文件 | 责任 |
|---|---|
| `Packages/CaptureCore/Tests/CaptureCoreTests/FinalValidationConfig.swift` | 唯一配置 schema、显式 `Codable`、`item↔kind` 校验 |
| `Packages/CaptureCore/Tests/CaptureCoreTests/FinalValidationEvidence.swift` | `facts.json` 读取、阈值计算、`result.json` 结构、环境白名单 |
| `Packages/CaptureCore/Tests/CaptureCoreTests/FinalValidationMedia.swift` | 合成 PCM/视频/脉冲/双频 |
| `Packages/CaptureCore/Tests/CaptureCoreTests/RecordingFinalValidationTests.swift` | P0-3/4/5/6/10/11 合成执行；每测试只按精确 item 启用 |
| `Packages/CaptureCore/Tests/CaptureCoreTests/RecordingFinalValidationAnalysisTests.swift` | 对产品产物只读分析（P0-1/2/5/6/7/9/11） |
| `scripts/final-validation.sh` | CLI、命令计划、退出码、冻结校验、日志封存、`result.json` 最终化、矩阵 |
| `Docs/superpowers/plans/2026-11-11-recording-acceptance-matrix.md` | 12 项 × 方法 × 证据 × 判定矩阵 |

- 测试只放在既有测试 target；不新增 App target、不改 `project.yml`、不改产品源码。需要内部 seam 时只用 `@testable import CaptureCore`；无法驱动则 T18 停并报告。
- 每个验证测试用**精确 item** 启用：`.enabled(if: ProcessInfo…["FINAL_VALIDATION_ITEM"] == "P0-4")`；runner 断言 `facts.item` 等于请求项且 run 内只有一个 `facts.json`。普通 `swift test` 默认 skipped；skipped 不算 pass。
- 不创建 `Spikes/`、不建 probe App；P0-8/9/12 直接产品复跑。

---

## 2. 唯一配置、方法与授权 schema

### 2.1 文件位置

```
.context/recording-full-delivery/p0/P0-04/
  config.json        # 输入
  expected.json      # 阈值（运行前）
  method-sets.json   # 主会话冻结的 12 项 required/local/thresholdKeys/UT 命令计划
  freeze.json        # expected + method-sets 的 SHA-256
  authorization.json # 仅长跑/真实操作；主会话在用户确认后写
  run-<UTC>-<pid>/   # 输出，必须为空
```

- 输入永不放进 run 目录；`--out` 不允许覆盖已有目录。
- `P0-04` 是目录名；配置内 `item` 为 `"P0-4"`，脚本做一次映射。

### 2.2 `config.json`

```json
{
  "schemaVersion": 1,
  "item": "P0-4",
  "seed": "42",
  "payload": { "kind": "aac", "aac": {
    "chunksPerSegment": 12, "chunkSeconds": 300, "finalChunkSeconds": 240,
    "segmentCount": 2, "segmentSeconds": 3540, "impulseEverySeconds": 1
  } }
}
```

- `seed` 用十进制字符串；`kind` 显式编码，其他键拒绝；时长/区间只在 payload 内；区间用 `{start,count}`。
- **item↔kind 固定 12 项（唯一表，禁止“其余 manual”缩写）**：

| item | kind | item | kind |
|---|---|---|---|
| P0-1 | `manual` | P0-7 | `crash` |
| P0-2 | `manual` | P0-8 | `manual` |
| P0-3 | `clock` | P0-9 | `manual` |
| P0-4 | `aac` | P0-10 | `metadata` |
| P0-5 | `video` | P0-11 | `space` |
| P0-6 | `multitrack` | P0-12 | `manual` |

- `FinalValidationConfig.validate()` 必须对照上表 12 项逐一校验；缺项、多项、`kind` 不匹配 → 64，不写 result。静态测试覆盖 12 项 + 3 反例（未知 item、未知 kind、错配）。
- `crash.faultPoint` 只允许 `checkpoint|encode|publish|index|gc`；`checkpointIntervalSeconds` 真实运行必须 `290...300`，`5` 仅预跑标记。

payload 字段：

| kind | 字段 |
|---|---|
| `aac` | `chunksPerSegment`, `chunkSeconds`, `finalChunkSeconds`, `segmentCount`, `segmentSeconds`, `impulseEverySeconds` |
| `video` | `codec`, `fps`, `width`, `height`, `boundarySeconds`, `frameCount`, `staticIntervalSeconds` |
| `multitrack` | `systemHz`, `micHz`, `micOff:{start,count}` |
| `metadata` | `containers:[String]`, `embeddedSchemaVersion` |
| `clock` | `inputSampleRate`, `ppm`, `durationSeconds`, `avSync` |
| `space` | `durationSeconds`, `diskFault`(`none|enospc|eagain|slow`) |
| `crash` | `faultPoint`, `checkpointIntervalSeconds`, `dedicatedSessionID`, `outputRoot` |
| `manual` | `procedureID`, `inputPath?` |

### 2.3 `expected.json`

```json
{
  "schemaVersion": 1,
  "item": "P0-4",
  "requiredMethods": ["IT-S", "MRT", "HUM"],
  "localMethods": ["IT-S", "MRT", "HUM"],
  "requiredObservations": ["primingSamples", "remainderSamples"],
  "thresholds": {
    "effectiveSampleDeltaMaxAbs": { "op": "==", "value": 0, "unit": "samples", "source": "definition" },
    "seamGapSamplesMax": { "op": "==", "value": 0, "unit": "samples", "source": "definition" },
    "seamOverlapSamplesMax": { "op": "==", "value": 0, "unit": "samples", "source": "definition" },
    "onsetLagVsControlSamplesMax": { "op": "<=", "value": 1, "unit": "samples", "source": "plan-defined" },
    "onsetLagJitterOverControlSamplesMax": { "op": "<=", "value": 1, "unit": "samples", "source": "plan-defined" },
    "seamDiscontinuityOverControlDbMax": { "op": "<=", "value": 6, "unit": "dB", "source": "plan-defined" },
    "primingDeclaredMismatches": { "op": "==", "value": 0, "unit": "count", "source": "definition" }
  },
  "frozenAt": "2026-11-11T12:00:00Z"
}
```

- `source` 只允许 `spec` / `plan-defined` / `definition`；`480` 样本是**plan-defined 10ms 容差**，不是 spec 原文数字。
- **方法集合只能等于 §4.1 冻结表**；`expected.json` 的 required/local 与之不一致 → 64。
- 缺 threshold key / observation → `incomplete`；测试禁硬编码阈值。

### 2.4 `method-sets.json`（C1 权威）

```json
{
  "schemaVersion": 1,
  "items": {
    "P0-4": {
      "required": ["IT-S", "MRT", "HUM"],
      "local": ["IT-S", "MRT", "HUM"],
      "thresholdKeys": ["effectiveSampleDeltaMaxAbs", "seamGapSamplesMax", "seamOverlapSamplesMax", "onsetLagVsControlSamplesMax", "onsetLagJitterOverControlSamplesMax", "seamDiscontinuityOverControlDbMax", "primingDeclaredMismatches"],
      "observations": ["primingSamples", "remainderSamples"],
      "commands": [{ "id": "suite", "argv": ["swift", "test", "--package-path", "Packages/CaptureCore", "--filter", "RecordingFinalValidationTests"] }]
    }
  }
}
```

- 由**主会话**在最终验收开始时按 §4.1 生成；T18 worker 只能读，不得改。
- `freeze.json` 记录 `methodSetsSha256` 与每项 `expectedSha256`；缺/不匹配 → 64。

### 2.5 `authorization.json`（I4）

```json
{
  "schemaVersion": 1,
  "confirmedBy": "user",
  "confirmedAt": "2026-11-12T10:00:00Z",
  "confirmationRef": "ledger/P7-fix-round2#…",
  "scope": ["long-run", "P0-11", "P0-7", "kill"],
  "dedicatedSessionID": "final-p0-7-20261112",
  "expiresAt": "2026-11-13T00:00:00Z"
}
```

- 只能由**主会话**在用户明确确认后写；worker/agent 不得创建或修改；脚本只能检查字段与 scope，**不能认证作者身份**，文件存在本身不是授权。
- 主会话在派工前核对 `confirmationRef` 对应真实记录；无 ref/无 scope/过期 → `blocked`。短测默认不需要该文件。
- **P0-7 kill**：`P0-07/authorization.json` 的 `scope` 必须同时含 `P0-7` 与 `kill`；`dedicatedSessionID` 必须与 config/CLI 一致；`--confirmation-ref` 只是对授权文件内 ref 的复核参数，**不是独立凭据**，缺授权 → 2/blocked 且不执行任何 kill。

---

## 3. CLI、退出码、证据（唯一权威）

### 3.1 命令

```bash
scripts/final-validation.sh run --item P0-4
scripts/final-validation.sh run --item P0-7 --pid 12345 \
  --dedicated-session final-p0-7-20261112 --confirmation-ref <ref>
# authorization.json 必须已由主会话按用户确认写入；--confirmation-ref 只与文件内 ref 交叉核对，不是凭据。
scripts/final-validation.sh record --item P0-8 --checklist artifacts/checklist.md \
  --method STA=pass --method DEV=pass --method HUM=pass \
  --observation screenshots=10 --observation scrollCaptures=3 \
  --observation controlUIFrames=0 --observation soundEvents=0 --observation hangCount=0
scripts/final-validation.sh record --item P0-4 --run-id 20261112T120000Z-12345 \
  --checklist artifacts/hum.md --method HUM=pass
scripts/final-validation.sh block --item P0-9 --prerequisite B8 \
  --reason "lock/sleep not authorized"
scripts/final-validation.sh verify --item P0-4 --run-id 20261112T120000Z-12345
scripts/final-validation.sh matrix
```

- `run` 创建空 `run-<UTC>-<pid>/`，按 `method-sets.json` 的 `commands` 顺序执行，每条写 `raw/<id>.log/.err`，记录 argv/exit/start/end。
- **测试只写 `facts.json`**（measurements、threshold actuals、methods statuses、artifacts），不写 verdict/result。
- 命令全部结束后，runner **先封存并 SHA-256 原始日志/产物**，再读 facts；对 `== / != / < / <= / > / >=` **全部独立复算**（`awk`/`plutil`），actual 必须是**有限 JSON number**（拒绝字符串/bool/NaN/Inf）；facts 的 `pass` 只作交叉检查，不一致、未知运算符、缺 actual → 64（或 incomplete），**不得 pass**。
- 任一必需命令 exit 非 0 且 facts 要求 `pass/fail` → 64（不是 pass）；测试先写 facts 后崩溃同样 64。
- `record` 的 `--run-id` 必须指向已有 run；runner 读取该 run 的 facts/commands/exit/loghash/freeze hash 与旧 result，**保留原自动方法与失败**，只追加人工 method/observation/artifact/checklist，写 `revisions/result-rN.json` 并让 `result.json` 指向最新；不得改自动 facts、不得把自动 `fail/not-run` 改成 pass、不得伪造 UT。
- `record` 的 checklist/artifact 必须在 run 目录内；外部 checklist 复制进 `artifacts/` 后哈希；每个 `pass` 方法必须绑定至少一个命令或 artifact；越界路径 → 64。
- checklist 固定含：操作人、开始/结束时间、逐步骤命令/操作、观察值、artifact 列表、未覆盖边界；缺项 → `incomplete`。
- `block` **先执行 method-sets 中无需授权的 UT/STA/合成命令**并保留其 exit/log/facts；只把未授权的 `DEV/FI/HUM/SOAK` 标 `blocked`，`localVerdict="blocked"`，`thresholdsEvaluated=false`；不得用 block 跳过本地可跑命令，也不得抹掉本地失败（本地失败 → fail/incomplete）。
- `block` 的 `configSha256/expectedSha256/methodSetsSha256`：有对应输入则写实际 hash；无输入时显式 `null`（不是空字符串）；`methods` 逐项列出，本地已跑项保留 pass/fail，未授权项 blocked。
- `matrix` 用系统 `plutil -extract`，不依赖 jq/python；12 行缺一即非 0；blocked 行必须输出 `localVerdict=blocked`。

### 3.2 退出码

| code | 含义 | 条件 |
|---|---|---|
| `0` | pass | result 有效、哈希匹配、required 全 pass、thresholds 全过、必需 observations 齐全 |
| `1` | fail | 方法全执行，至少一条硬阈值 `pass=false` |
| `2` | blocked | 缺授权/设备/OS/环境；有权威 result，`blockReason`+`blockPrerequisite` |
| `3` | incomplete | 方法未跑全/指标缺失/日志不完整/只有静态子集 |
| `64` | run-error | 配置/expected/method-sets 无效、哈希不匹配、命令失败、facts 缺失/多份、路径越界 |

**关键**：`swift test` 非 0 不直接等于 fail；没有匹配 facts/result → 64；只有“命令 exit 0 + facts 完整 + 阈值算出且不过”才是 1。

### 3.3 `result.json`

```json
{
  "schemaVersion": 1,
  "revision": 2,
  "previousResultSha256": "…",
  "item": "P0-4",
  "verdict": "pass|fail|blocked|incomplete",
  "localVerdict": "pass|incomplete|blocked|fail",
  "configSha256": "…|null", "expectedSha256": "…|null", "methodSetsSha256": "…|null",
  "methods": [{ "code": "IT-S", "status": "pass|fail|not-run|blocked", "behavior": true }],
  "thresholds": [{ "key": "seamGapSamplesMax", "op": "==", "expected": 0, "actual": 0, "source": "definition", "pass": true }],
  "observations": { "primingSamples": 0 },
  "measurements": { "perSegment": [], "perRole": [], "perSeam": [] },
  "commands": [{ "id": "suite", "argv": ["…"], "exitCode": 0, "stdoutPath": "raw/suite.log", "stderrPath": "raw/suite.err", "logSha256": "…" }],
  "environment": { "osProductVersion": "26.4.1", "osBuild": "25E253", "arch": "arm64", "hwModel": "…", "swiftVersion": "6.3.3", "xcodeVersion": "…", "diskFreeBytes": 0 },
  "artifacts": [{ "path": "artifacts/seam-00.m4a", "sha256": "…" }],
  "manualArtifacts": [{ "path": "artifacts/hum.md", "sha256": "…", "method": "HUM" }],
  "boundaries": ["…"],
  "thresholdsEvaluated": true,
  "blockReason": null,
  "blockPrerequisite": null
}
```

- `measurements` 必须保留逐段/逐角色/逐接缝值；`thresholds[].actual` 是**最坏值**，不是平均/总和。
- `record --run-id` 生成新 revision：旧 `revisions/result-rN.json` 不改；新 result 的 `previousResultSha256` 指旧 result SHA；`result.json` 是“最新 revision”的副本/指针。自动 commands exit/loghash 原样保留；人工 artifact 进 `manualArtifacts`。
- `record` 只能追加人工 method/observation/artifact；自动 `methods`、commands、exit、loghash、thresholds 不得改；自动 fail/not-run 不得改成 pass；`UT/FI/DEV` 不能仅凭 `--method` 伪造，必须有对应命令/artifact。
- `block` 的 result：`verdict=blocked`、`localVerdict=blocked`、`thresholdsEvaluated=false`；输入存在则三个 hash 为实际值，无输入显式为 `null`；不得用空字符串。
- 降级：`localMethods` 全 pass 但含非行为方法 → `localVerdict=blocked`；`pass` 但 observations 缺 → `incomplete`；`blockReason` 非空但 verdict 非 blocked → `incomplete`。
- **加速算术**（如 P0-3 注入）单独可 `assertionPass=true`，但 `localVerdict=incomplete`，item 仍 `incomplete`；只有真实 2h SOAK（`wallClockSeconds>=7200`）才可 `localVerdict=pass`。

### 3.4 环境与隐私

- `env.json` 只允许：`osProductVersion/osBuild/arch/hwModel/swiftVersion/xcodeVersion/diskFreeBytes/volumeFsType`。
- 不采集 serial/UUID/用户名/home/设备昵称/完整设备列表/TCC 内容；`command.txt`/`run.log` 发现 `$HOME` 或用户名 → 64。
- 合成项不读真实桌面/麦克风；真实项只留判定指标与产物哈希；指标只来自本次进程（`ps -o rss=`、产品 diagnostics、测试内单调时钟）。

---

## 4. 判定、冻结与聚合

### 4.1 12 项方法与阈值冻结表（C1）

| 项 | requiredMethods | localMethods | localVerdict 资格 | threshold keys（actual=最坏值） |
|---|---|---|---|---|
| P0-1 | DEV, IT-S, SOAK | DEV, IT-S, SOAK | 行为（DEV/IT-S/SOAK） | `sampleCountDeltaMax<=480`(plan-defined)、`silenceTimelineJumps==0`、`ptsMonotonic==1`、`soakWallClockSeconds>=7200`(plan-defined)；observations `cpuPercentSamples`、`rssBytesSamples`、`observedDurationSeconds`、`mediaDurationSeconds`、`audioOnlyComparison`(`pass/fail/not-run`) |
| P0-2 | UT, DEV, FI | UT, DEV, FI | 行为（DEV/FI） | `routeEventErrorSamplesMax<=480`(plan-defined)、`sessionIDChanges==0`、`segmentIndexIncrements==0`、`videoRestarts==0`、`missingRangesUnlocated==0` |
| P0-3 | IT-S, DEV, SOAK, HUM | IT-S, SOAK | 行为（IT-S/SOAK） | `hardDropCount==0`、`residualSamplesMax<=480`(plan-defined)、`avSyncMsMax<50`(spec)、`wallClockSeconds>=7200`(plan-defined)；observations `mediaDurationSeconds` |
| P0-4 | IT-S, MRT, HUM | IT-S, MRT, HUM | 行为（IT-S/MRT/HUM） | `effectiveSampleDeltaMaxAbs==0`、`seamGapSamplesMax==0`、`seamOverlapSamplesMax==0`、`onsetLagVsControlSamplesMax<=1`、`onsetLagJitterOverControlSamplesMax<=1`、`seamDiscontinuityOverControlDbMax<=6`、`primingDeclaredMismatches==0`；observations `primingSamples`、`remainderSamples` |
| P0-5 | IT-S, FH, DEV | IT-S, FH, DEV | 行为（IT-S/FH/DEV） | `firstFrameDecodeFailures==0`、`duplicateFrames==0`、`lostFrames==0`、`payloadHashMismatches==0`、`maxSegmentSeconds<=3540`、`ptsDtsViolations==0`、`handoffFailures==0` |
| P0-6 | IT-S, DEV, HUM | IT-S, DEV, HUM | 行为（IT-S/DEV/HUM） | `trackCountMismatches==0`、`roleMismatches==0`、`durationDeltaSamplesMaxAbs==0`、`micOffNonSilentSamples==0` |
| P0-7 | UT, FI, DEV | UT, FI | 行为（FI） | `lossSecondsMax<=300`、`expectedLossSeconds<=min(300,interval+10)`、`duplicateSegments==0`、`visibleHalfProducts==0`、`directoryAtomic==1`、`indexRebuilt==1`、`unpublishedRetained==1`、`falseSavedReports==0` |
| P0-8 | STA, DEV, HUM | STA, DEV, HUM | 行为（DEV/HUM） | `screenshots>=10`、`scrollCaptures>=3`、`controlUIFrames==0`、`soundEvents==0`、`hangCount==0`、`excludedWindowUpdates>=1` |
| P0-9 | DEV, HUM, FI | DEV, HUM, FI | 行为（DEV/HUM/FI） | `lockStops==0`、`sleepLossSecondsMax<=300`、`falseSavedReports==0`、`wakeRecovery==1` |
| P0-10 | IT-S, MRT, DEV | IT-S, MRT | 行为（IT-S/MRT） | `fieldMismatches==0`、`trimMismatches==0`、`payloadHashMismatches==0`、`unknownSchemaWrites==0`、`legacyMisclassified==0` |
| P0-11 | UT, IT-S, SOAK, FI | UT, IT-S, SOAK, FI | 行为（IT-S/SOAK/FI） | `rssGrowthMiB<32`(spec)、`callbackP99Ms<2`(spec)、`checkpointAgeSecondsMax<=300`(spec)、`sealThroughputRatioMin>=1`、`queueOverflows==0`、`peakSpaceOverBudget==0`；observations `stopToPreviewP50/P95Ms`、`stopToFinalP50/P95Ms` |
| P0-12 | STA, UT, DEV, HUM | STA, UT, DEV, HUM | 行为（DEV/HUM） | `migrationMismatches==0`、`firstPromptOnlyOnMic==1`、`deniedFallback==1`、`revokedGuidance==1`、`tapWithoutNeed==0`、`tccAfterUpdateRecorded==1` |

- 这张表是唯一权威；`method-sets.json` 由主会话据此生成，`freeze.json` 同时冻结其哈希。T18 worker 增删任何一项 → 64。
- `localVerdict=pass` 还要求 `localMethods` 含至少一个行为型方法（`IT-S/FH/MRT/FI/DEV/SOAK/HUM`）；`STA/UT` 不计行为。
- `thresholds[].actual` 聚合：对每段、每角色、每接缝分别计算，取**最坏绝对值或 any-fail**；禁止平均/求和抵消；逐单元值进 `measurements`。

### 4.2 阈值来源（I11）

| 项 | 数字 | 来源 |
|---|---|---|
| P0-1/P0-2/P0-3 | 480 样本 | **plan-defined 10ms 容差**；spec 只定义 480 帧块，未给验收容差 |
| P0-1/P0-3 | 7200s `wallClockSeconds` | plan-defined 真实 2h 连续观测；`mediaDurationSeconds` 不等于墙钟 |
| P0-3 | A/V <50ms | spec §5.2/验收清单 |
| P0-4 | gap/overlap=0 | 定义（PCM 拼接） |
| P0-4 | onset 对照相对值、6dB | plan-defined 余量，冻结前用对照运行确认 |
| P0-5 | 3540s | spec §4.3/§5.5 |
| P0-7 | 300s | spec §5.7 |
| P0-8 | 0 帧/0 声/0 卡死 | spec G7/§5.10（二值观察） |
| P0-9 | 300s | spec §5.7 |
| P0-11 | 32MiB/2ms/300s | spec §5.13/§5.7 |
| P0-12 | 不主动弹麦/无麦不持 tap | spec §5.11 |

- 没有“行业惯例”；`spec` 以外的数字必须在 threshold 里标 `plan-defined`。

### 4.3 现有 UT 的命令来源（I2）

| 项 | UT filter（以实际 suite 名为准，主会话写入 method-sets） |
|---|---|
| P0-2 | `AudioRouteControllerTests`、`RecordingSegmentPolicyTests`、权限决策既有测试 |
| P0-7 | `RecordingOutputTransactionTests`、`RecordingOutputTransactionDirectorySafetyTests`、`RecordingSessionLedgerTests` |
| P0-11 | `RecordingSpaceBudgetTests`、`RecordingPipelineSpaceGateTests` |
| P0-12 | `RecordingAudioPreferenceMigrationTests` |

- `method-sets.json` 的 `commands` 必须列出 argv；runner 逐条执行并记录 exit/log hash；`record --method UT=pass` 没有对应命令/日志 → 拒绝。
- 不存在的 suite 不得写进命令；T18 开工时按实际测试名由主会话核对后冻结。

### 4.4 判定与冻结

- `pass`：required 全 pass、thresholds 全过、observations 齐全、证据完整。
- `fail`：方法全执行，至少一条硬阈值不过。
- `blocked`：缺 OS/设备/授权/环境；必须有 result、`blockReason`、`blockPrerequisite`。
- `incomplete`：方法未跑全/指标缺失/日志不完整/仅静态子集。
- **L2-partial**：按项列 `localVerdict`（`pass/incomplete/blocked/fail`）；`incomplete` 表示已执行但缺实时/人工/长时证据，不算 pass；L2-complete 才可写“12 项本机子集全通过”。
- 多环境按“最差-of-矩阵单元”；重跑只在原因与对照写入 `boundaries` 时替换。
- 阈值修改必须新建 `expected.v2.json` + 新 `freeze.json` key，旧结果保留；`freeze.json` 的 key 为 `<item>@v1` / `<item>@v2`。

---

## 5. 执行步骤（每项）

- [ ] 确认依赖已实现（T4/T6/T8/T9/T10/T13/T14/T17），只读检查接口。
- [ ] 写 `config.json` 与 `expected.json`；主会话按 §4.1 生成 `method-sets.json` + `freeze.json`。
- [ ] `run`；命令逐条记录 argv/exit/日志；测试只写 facts。
- [ ] runner 封存日志 → 哈希 → 计算 → 写 result（最后一步）。
- [ ] 人工项 `record`：checklist 必须在 run 目录内，含操作人/时间/步骤/观察；每个 pass 绑定命令或 artifact。
- [ ] 无授权/设备：`block --prerequisite Bx --reason …`，不伪造 result。
- [ ] 回填矩阵：item/methods/localVerdict/verdict/run-id/未覆盖。
- [ ] 人工/设备项另写 checklist；agent 不代听/代看/代授权。

---

## 6. 12 项任务

### P0-1 SCK 音频路径

- **Gate:** 2×2 录音样本/时轴/PTS；audio-only 对照；CPU 与实际样本；真实 2h 连续 SOAK。
- **Entry:** 产品 App 2×2 600s → `RecordingFinalValidationAnalysisTests` → `run`；人工观察用 `record --run-id <同一 run>` 合并。
- **Criteria:** 表中 keys；CPU/RSS 为必需 observations，缺 → `incomplete`（不降为 optional）。
- **SOAK（F-I6）:** `SOAK` 是**另行授权的真实 2h 连续观测**（`wallClockSeconds>=7200`），不是 600s 短样本；600s 只做样本/时轴/CPU 短检查。2h 需独占机器、`--long`、B4 与 §8 预算；未授权 → `blocked B4`，短样本通过不能替代 SOAK。
- **audio-only:** 未实现/未测 → `incomplete`（m3），2×2 是开发基线，不判 fail、不改设计。
- **Blocked:** 无屏幕录制授权 → B5；13/14/15 → B1；无 2h 独占/授权 → B4。

### P0-2 动态路由与会话连续性

- **Gate:** 系统→麦克风→双源→静音→恢复；session/段号/视频流不重启；缺失区间可定位。
- **Entry:** `AudioRouteControllerTests` + `RecordingSegmentPolicyTests`（UT）+ 产品 App（DEV/FI）→ `run` → 人工步骤 `record --run-id <同一 run>`。
- **Steps:**
  - [ ] 起录系统声音，切麦克风、双源、静音、恢复；每次切换前后各留 10s 标记音。
  - [ ] 首次拒绝麦克风；系统设置撤回；默认设备切换；蓝牙连接/断开；有线拔插（需设备/授权）。
  - [ ] 检查输出目录：无新 session、段号不增加、视频 PTS 连续、缺失区间可定位。
- **Criteria:** 表中 keys；首次拒绝、默认设备、蓝牙、拔插；切换失败保留旧路由。
- **Blocked:** 无麦克风/设备 → B2/B5；先跑无需授权的 UT，不能整个项跳过。

### P0-3 双时钟、漂移与 A/V 同步

- **Gate:** 44.1/48kHz、±100/±300ppm、回调抖动与水位、A/V；不得周期性硬丢。
- **Entry:** `RecordingFinalValidationTests`（ppm 注入）→ `run`；真实 2h/设备用产品 App，人工 A/V 用 `record --run-id <同一 run>` 合并。
- **Criteria:** 表中 keys；`wallClockSeconds` 是真实墙钟，`mediaDurationSeconds` 只是合成内容长度；加速注入可 `assertionPass=true`，但 `localVerdict=incomplete`、item `incomplete`；只有真实 2h SOAK（`wallClockSeconds>=7200`）可 `localVerdict=pass`。A/V 用产品最高帧率，30fps ±33ms 不足以证明 <50ms。
- **Blocked:** 真实设备/2h → B2/B4/B5；先跑无需授权的 ppm/UT，不能整个项跳过。

### P0-4 PCM→AAC 有效样本与接缝

- **Gate:** 每段 11×300s + 240s 尾块（`chunksPerSegment=12`）同一 `AudioTrackEncoder` 上下文；有效样本/trim/编码延迟/接缝能量。
- **Entry:** `RecordingFinalValidationTests` → `run`；听测后用 `record --item P0-4 --run-id <同一 run> --method HUM=pass --checklist artifacts/hum.md` 合并。
- **Criteria:** 表中 keys；逐段/逐角色/逐接缝值进 measurements；control 产物 `control-<role>.m4a` 与 test 同编码参数、同内容，hash 入 artifacts。
- **Aggregation:** gap/overlap/effective 取 max abs；一个坏接缝即 fail，不平均。
- **Blocked:** 人耳听测 → B5；播放器 → B7；先跑 IT-S/MRT，不能整个项跳过。

### P0-5 视频 chunk/segment 轮转与直通

- **Gate:** H.264/HEVC、同步首帧、静态画面、B 帧/PTS/DTS、≤3540s、载荷一致、双 writer。
- **Entry:** `RecordingFinalValidationTests`（短边界，IT-S/FH）→ `run`；真实 3540s 产品 App/DEV 后 `record --run-id <同一 run>` 合并。
- **Criteria:** 表中 keys；载荷按 `CMSampleBuffer` 载荷+PTS 逐样本哈希，不是文件字节。
- **Blocked:** 真实 59 分钟/其他硬件 → B4/B10；短边界先跑，不能整个项跳过。

### P0-6 MP4 内来源多音轨

- **Gate:** system/mic 独立轨；轨 ID/角色/时长；mic 关区间静音；产品预览；外部播放器。
- **Entry:** `RecordingFinalValidationTests`（合成 MP4，IT-S）→ `run`；产品预览/播放器人工后用 `record --run-id <同一 run>` 合并 DEV/HUM。
- **Criteria:** 表中 keys；外部播放器逐条记录，未记录 → `not-run`。
- **Blocked:** GUI/播放器/DAW → B5/B7；IT-S 先跑，不能整个项跳过。

### P0-7 崩溃事务矩阵

- **Gate:** checkpoint/encode/publish/index/gc 强杀；恢复公共尾端；损失窗口；目录原子；索引重建。
- **Entry:** 现有 `RecordingOutputTransactionTests`/`RecordingOutputTransactionDirectorySafetyTests`（UT）+ T9 ledger 测试（UT）+ 产品 App 专用会话（FI/DEV）；边界标记分析在 `RecordingFinalValidationAnalysisTests`，kill 由 runner 执行。
- **Criteria:** 表中 keys；真实 kill 单元 `checkpointIntervalSeconds∈[290,300]`，`expectedLossSeconds<=min(300, interval+10)`；5s 仅状态机预跑，不得写 pass；5 边界逐点，无法定位标记 → `incomplete`。
- **授权门（F-I5）:** `run --item P0-7 --pid … --dedicated-session <id>` 必须读取 `P0-07/authorization.json`（主会话按用户确认写，scope 含 `P0-7`+`kill`，`confirmationRef/confirmedAt/dedicatedSessionID` 齐全）；`--confirmation-ref` 只是交叉复核，不是独立凭据。缺授权 → `blocked`，**不执行任何 kill**。
- **专用会话（I12）:** 只杀本次新建、`dedicatedSessionID` 匹配、PID start time ≥ 授权 `confirmedAt`、`outputRoot` 在 `.context/recording-full-delivery/p0/` 下的产品 App；`lsof -p` 发现 outputRoot 外打开的 `.mp4/.m4a/.caf` → 64；多 SnapGlass PID → 64；禁止杀用户正在录制的实例。kill 后校验无残留子进程。
- **Blocked:** 外置卷/断电 → B3；无授权/专用会话 → B3/B5；先跑 UT，不能整个项跳过。

### P0-8 截图共存与窗口排除（产品复跑）

- **Gate:** 录制中普通/滚动截图、10 分钟连续录屏、热切来源、新窗口；控制 UI 不入镜、无提示音、无卡死。
- **Entry:** 产品 App；`record`；无 probe。
- **Steps:** 10 次普通截图 + 3 次滚动截图；新建/重建窗口；切一次来源；录屏 10 分钟；控制 UI 关键区间逐帧、全程抽帧（m9）。
- **Criteria:** 表中 keys；checklist 必须含截图计数、hangCount、入镜检查抽样规则。
- **Blocked:** 屏幕录制授权/GUI → B5/B9；先跑 STA，再 block DEV/HUM。

### P0-9 锁屏/休眠（产品复跑）

- **Gate:** 锁屏不主动停止；睡眠前提交检查点；唤醒恢复；不误报已保存。
- **Entry:** 产品 App；`record`；无 probe。
- **Steps:** 录音/录屏各锁屏 5 分钟；睡眠 1 分钟；在 `sealing` 期间触发睡眠（日志/状态）。
- **Criteria:** 表中 keys；`已保存` 只在事务成功后出现。
- **Blocked:** 锁屏/睡眠授权 + 独占本机 → B8；未跑 DEV/HUM/FI 时 `localVerdict=blocked`。

### P0-10 格式与元数据

- **Gate:** M4A trim、CAF、MP4 `sourceFormatHint` 直通、嵌入/manifest 往返、未知 schema/旧 MP4。
- **Entry:** `RecordingFinalValidationTests`。
- **Criteria:** 表中 keys；trim 从容器字段读，不用 `asset.duration`；旧 v1.4 缺失 → `blocked`。
- **Blocked:** B11。

### P0-11 资源、空间与长时

- **Gate:** 采集/Seal/导出并发；慢盘/ENOSPC/断盘；RSS、回调 p99、吞吐、停止等待、检查点年龄、峰值空间。
- **Entry:** `RecordingSpaceBudgetTests`/`RecordingPipelineSpaceGateTests`（UT）+ `RecordingFinalValidationTests`（短时/预算）+ 产品 App（SOAK）+ `FI` 注入。
- **Criteria:** 表中 keys；回调 p99 只接受产品 diagnostics；无指标 → `not-run`/`incomplete`；停机时延只记录 p50/p95，不设通过阈值；ENOSPC 只注入自有空间抽象，不声称覆盖 AVFoundation 内部写盘。
- **Budget:** 按 `RecordingSpaceBudget.requiredBytes(config:seconds:)` 目标配置计算；示例 2h 分轨≈2.1GB、8h≈8.3GB；`--long` + `authorization.json`；机器独占。
- **Blocked:** 2h/8h → B4；真实满盘/断盘 → B3；先跑 UT/短时，不能整个项跳过。

### P0-12 权限与签名回归（产品复跑）

- **Gate:** 首次/拒绝/撤回；迁移；旧用户升级不主动开麦；无麦不持 tap；更新后 TCC。
- **Entry:** `RecordingAudioPreferenceMigrationTests`（UT）+ `STA` + 产品 App（DEV/HUM）。
- **Steps:**
  - [ ] 跑迁移 UT：`true→systemAudio`、`false→none`、全新安装默认。
  - [ ] 首次含麦：仅在用户本人执行或另行授权的一次性用户/VM/已确认未授权状态执行；worker 不得自行新建用户/改系统；否则 `blocked B5/B6`。
  - [ ] 拒绝：系统弹窗拒绝 → 降级引导；不重置 TCC。
  - [ ] 撤回：系统设置手动撤回 → 已录来源不中断。
  - [ ] 升级：旧签名构建→更新→复检；无旧构建 → `blocked B6`。
- **Criteria:** 表中 keys；不得用清 TCC/换 Bundle ID/临时签名绕过。
- **Blocked:** B5/B6；先跑 UT/STA，不能整个项跳过。

---

## 7. 合成信号与媒体

| 信号 | 用途 | 参数 |
|---|---|---|
| 正弦 | 轨道分离/电平 | 440Hz system、1000Hz mic，-18dBFS |
| 脉冲 | chunk/接缝/trim | 每 1s 一个 1 样本脉冲，-6dBFS |
| 扫频 | 重采样 | 20Hz–20kHz，10s |
| 静音 | 缺源/时钟 | 全零 |
| 双频 | 多音轨 | 两轨不同频率 |
| 帧号/时间码 | 视频接缝/首帧/丢帧 | 每帧 frame index+PTS |

- 由 `seed` 决定、可复现；不读真实桌面/麦克风/系统音频。control 产物与 test 同参数、同内容。

---

## 8. 长跑、预算与机器独占

| 项 | 默认短测 | 长跑/独占 | 磁盘 | 授权 |
|---|---|---|---|---|
| P0-4 | 2×3540s 合成 | 真实 59 分钟另跑 | ~2GB | 无 |
| P0-5 | 缩短边界 | 真实 3540s × H.264/HEVC | ~2GB | 长跑 |
| P0-7 | UT + 专用会话一次 kill | 5 边界真实 kill | <1GB | 录制+kill |
| P0-11 | ≤10 分钟 | 2h/8h | 按 SpaceBudget 目标配置；示例 2.1/8.3GB | `--long`+独占 |
| P0-3 | ppm 算术 | 2h×4ppm+设备 | ~2GB | 长跑+设备 |
| P0-1 | 600s 短样本 | **2h SOAK 连续观测** | 按 SpaceBudget 配置；示例 1.4–2.1GB | 屏幕录制 + `--long` + 独占 |
| P0-2/6/8/9/12 | 10–30 分钟 | 跨 OS/设备 | <2GB | TCC/GUI/设备/签名 |

- 墙钟：短测批 ≤90 分钟；P0-7 ≤60 分钟；2h 长跑 2.5h；8h 8.5h；P0-3 8.5h；P0-1 SOAK 2.5h。
- 磁盘：一律用 `RecordingSpaceBudget.requiredBytes(config:seconds:)`（产品目标配置）估算，不写死 2.1GB 口号；单轨立体声 2h ≈1.4GB、分轨立体声+单声道 ≈2.1GB、8h ≈5.5–8.3GB，另加发布 partial 与检查点。
- 保留磁盘：`diskFreeBytes ≥ 预算×1.2 + 5GiB`，不足 `blocked`；写入 freeze。
- 2h/8h 期间无并行构建/测试/其他 agent；记录起止与 diskFree。

---

## 9. 授权与禁止

- **另行授权：** 屏幕/麦克风/系统音频 TCC、GUI、锁屏/睡眠、真实设备、签名安装/更新、真实录制、外置卷/断电、2h/8h 独占、人耳/人眼。
- **禁止：** 清/改 TCC、换 Bundle ID 绕过、`sudo powermetrics`、`system_profiler SPHardwareDataType`、填满真实卷、`killall`/宽匹配 kill、杀用户正在录制的 App、修改产品/测试/构建/权限/签名、提交/推送/打包/安装/清理。
- **授权文件：** 只记录主会话在用户确认后的 `confirmationRef/confirmedAt/scope`；worker 不得写；脚本不能认证作者，文件存在不是授权。
- **P0-7：** 只杀专用、一次性、明确授权的测试会话；`P0-07/authorization.json` 必须由主会话按用户确认写，scope 含 `P0-7`+`kill`；检查 outputRoot/PID start time/lsof；无授权 → blocked，无 side effect。
- **P0-1：** 2h SOAK 是另行授权的真实连续观测；600s 短样本不替代。
- **ENOSPC：** 只注入自有抽象；不覆盖 AVFoundation 内部写盘。

---

## 10. 矩阵与整体结论

| P0 | required | local | localVerdict 预期 | 全矩阵 |
|---|---|---|---|---|
| P0-1 | DEV,IT-S,SOAK | DEV,IT-S,SOAK | incomplete（短样本）/pass（2h SOAK） | 13/14/15 |
| P0-2 | UT,DEV,FI | UT,DEV,FI | blocked（未跑即 blocked） | 蓝牙/拔插 |
| P0-3 | IT-S,DEV,SOAK,HUM | IT-S,SOAK | incomplete（算术）/pass（真实 SOAK） | 44.1k/听测 |
| P0-4 | IT-S,MRT,HUM | IT-S,MRT,HUM | pass（含听测）/incomplete | 人耳/播放器 |
| P0-5 | IT-S,FH,DEV | IT-S,FH,DEV | pass（含真实边界）/incomplete | 59min/硬件 |
| P0-6 | IT-S,DEV,HUM | IT-S,DEV,HUM | pass（含预览）/incomplete | 播放器/DAW |
| P0-7 | UT,FI,DEV | UT,FI | blocked（未跑即 blocked） | 外置卷/断电 |
| P0-8 | STA,DEV,HUM | STA,DEV,HUM | blocked（未跑即 blocked） | 13/14/15 |
| P0-9 | DEV,HUM,FI | DEV,HUM,FI | blocked（未跑即 blocked） | 跨版本 |
| P0-10 | IT-S,MRT,DEV | IT-S,MRT | pass（合成）/incomplete | v1.4 |
| P0-11 | UT,IT-S,SOAK,FI | UT,IT-S,SOAK,FI | pass（含长跑）/incomplete | 2h/8h |
| P0-12 | STA,UT,DEV,HUM | STA,UT,DEV,HUM | blocked（未跑即 blocked） | 更新路径 |

- 本表是预期，不是结果；以 `result.json` 与矩阵为准。
- L2-partial 只列“已执行子集”，不得写“12 项本机验证通过”；L2-complete 才可写 12 项本机子集全通过。

---

## 11. 与 T18/P7 的顺序

1. 主会话确认 P7 入口（T1–T17 完成 + 阶段文档批准），接受 T18 扩展 allowlist。
2. T18 worker 建入口、先跑短测/无需授权的 UT/STA/合成命令，写 facts/result/矩阵；只对未授权的 DEV/FI/HUM/SOAK 用 `block`。
3. worker 交证据后停止，不派 reviewer、不写 final review/完成报告。
4. 主会话派独立 reviewer 全分支 review；原 worker 修复；限定复核。
5. 主会话写完成报告，声明 L1/L2-partial/L2-complete/L3。

---

## 12. 自检（对应 review）

| 检查 | 结果 |
|---|---|
| C1 方法冻结 | §4.1 12 项 required/local/thresholdKeys 唯一表；method-sets.json+freeze hash；集合不等 → 64 |
| C2 L2 | localVerdict 需行为方法；仅 STA/UT 或空集 → blocked；L2-partial 与 L2-complete 分开；notes/P7 统一四级 |
| C3 入口 | P7 入口改为 T1–T17 + 阶段批准；P0 在 T18 内执行（母计划同步修正） |
| C4 P0-7 payload | 映射 12 项完整表含 P0-7→crash；brief 同步；faultPoint 枚举；静态反例 |
| C5 长间隔 | 真实 290–300s；loss≤min(300,interval+10)；5s 仅预跑 |
| C6 blocked | `block` 写权威 result；`localVerdict=blocked`；null hash 规则；matrix 读取 |
| I1 入口 | 每测试精确 item；runner 断言单一 facts/item |
| I2 UT | method-sets 的 commands 含现有 UT filter；argv/exit/log 绑定 |
| I3 结果 | 测试只写 facts；runner 全运算符复算、有限 number；命令后封存日志→hash→最后写 result |
| I4 授权 | 主会话写 confirmationRef；worker 禁写；P0-7 也读 authorization scope |
| I5 P0-12 | UT 迁移 + 首次/拒绝/撤回/升级步骤；新用户/VM 需用户执行或另授权 |
| I6 方法/观察 | P0-1/2/5 按表；CPU/RSS 必需 observations；P0-1 SOAK 真实 2h |
| I7 聚合 | 逐段/角色/接缝最坏值；control 产物入 artifacts |
| I8 allowlist | P7/brief 加 evidence-index；母计划 T18 差异表 |
| I9 矩阵 | 8 表 + 空结论检查命令 |
| I10 人工证据 | `record --run-id` 合并同一 run；checklist/artifact/hash；不覆盖自动失败 |
| I11 480 | 标 plan-defined；不冒充 spec |
| I12 kill | 专用会话/owned root/PID start/lsof/authorization scope；缺授权无 side effect |
| F-I1 | 全运算符独立复算；facts.pass 仅交叉检查 |
| F-I2 | record 合并/旧 revision 保留；P0-3/4/5/6 先 run 后 record |
| F-I3/I4 | block 先跑本地；只标未授权方法；失败不被抹掉 |
| F-I5 | P0-7 authorization.json scope 含 P0-7+kill；ref 非凭据 |
| F-I6/I7 | P0-1 2h SOAK；P0-3 wallClock/mediaDuration 分开；算术 incomplete |
