# SnapGlass P7 — 收尾与最终验收 阶段计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在所有产品任务完成后，交付可核对的验收矩阵、四语言/隐私/变更记录、全量测试与构建证据、最终独立 review 和完成报告；把“实现已交付”“本环境验证”“全矩阵已验收”分开声明。

**Architecture:** P7 不新增产品能力。T18 在测试 target 内建立薄验证入口并执行《录制最终验证（P0）》的短测默认；真实设备/TCC/长跑只列 `blocked`。顺序固定为：T18 worker 自测并交证据 → 主会话派独立 reviewer 做全分支 review → 原 worker 修复 → 主会话限定复核 → 主会话写完成报告。worker 不派 reviewer、不写 review 结论。

**Tech Stack:** Swift 6、Swift Testing、AVFoundation、shell、XcodeGen/SwiftLint/swift-format；不新增依赖。

**Spec:** `Docs/superpowers/specs/2026-11-11-audio-and-segmented-recording-design.md`（修订 2.1）
**母计划:** `Docs/superpowers/plans/2026-11-11-recording-full-delivery.md`
**P0 最终验证:** `Docs/superpowers/plans/2026-11-11-recording-p0-validation.md`（v1.1）
**Workspace:** `.superpowers/sdd/2026-11-11-recording-full-delivery`

**Status:** `v1.1 fix-round1，prepared，未执行`（2026-11-12）。本文件只写计划、文件、命令与证据；未运行 P0、未实现产品、未提交。P0 不是开发前置；P7 入口 = T1–T17 完成 + 本阶段文档批准，P0 在 T18 内执行并作为最终验收。

> **入口门禁 override（C3）：** 母计划 Phase P7 的“全部 P0 `pass` + 文档批准”是开发优先裁定前的旧措辞，已被本轮主会话书面裁定取代：**P7 入口只要求 T1–T17 完成 + P7 阶段文档批准**；P0 由 T18 创建入口并执行，未通过只阻塞“最终验收声明”，不阻塞 P7 开工或任何开发任务。母计划已同步该行。

---

## Global Constraints

- 不新增 SPM 依赖；不改 `Package.swift` 既有协议；不改最低系统版本；不引入外部二进制；不手改 `.xcodeproj`。
- 不提交、不 push、不打包、不签名安装、不部署、不清理用户材料。
- 每个任务只改 `Files:` 列出的路径；清单外路径先停并报告。
- 四语言 `en`/`zh-Hans`/`ja`/`ko` 必须键与占位符一致；界面文案不得用 `NSLocalizedString`/`String(localized:)`。
- 测试口径：实际总数 + 新增测试全过 + 无新增失败；既有 `legacyDirectoriesWaitForTheLegacyGrace` 无论是否复现都保留记录，不强制它失败、不靠重跑洗绿、不把 known-fail 当全量绿色；0 测试不得报 pass。
- 已知格式债与边界：T3 的 1272 条 `swift-format` 规则告警 + 3 条配置提示（其中产品 615 / 旧测试 657 / 安全测试 0）是**已接受债务**，不得写成“0 告警”；`swiftlint --strict` 必须是 0。T3 残留 `lstat` 后父目录被恶意替换的 TOCTOU 是**已声明的所有权假设**，不得声称完全 race-free。T2 的四语言 `Open System Settings` 重复键（当前第 717 行）必须在 T18 去掉。
- P0 判定只认 `result.json`；没有证据的项写 `incomplete`/`blocked`，不写 `pass`。
- 最终状态只允许四级：`L1 实现已交付`、`L2-partial 本机已执行子集`、`L2-complete 12 项本机子集`、`L3 全矩阵已验收`；未达 L2-complete 不得写“L2 本环境验证完成”，未达 L3 不得写“全验收/可发布”。

---

## Review Focus

1. **用机制短测冒充真机/长时**：P0-3/4/5/7/11 的短测结论是否被写成通过；`requiredMethods` 是否真的全跑。
2. **测试口径洗绿**：known-fail 是否被隐藏、0 测试是否被当 pass、实际总数是否与日志一致。
3. **格式/安全债被淡化**：`swift-format` 1272+3 是否被写成 0；TOCTOU 是否被写成已解决；T2 重复键是否仍存在。
4. **声明越级**：L1/L2-partial/L2-complete/L3 是否被混写；`blocked` 是否被写成“等价通过”。
5. **review 顺序被绕过**：worker 是否自行派 reviewer、自己写 review 结论，或先写完成报告再补 review。

---

## 1. 文件地图（T18 唯一授权范围）

### 现有文件

| 路径 | 动作 |
|---|---|
| `Docs/PRIVACY.md` | 增加麦克风权限行；与 Info.plist 文案一致 |
| `CHANGELOG.md` | 记录音频录制、分段恢复、多轨、导出、截图共存；注明未发布/未签名 |
| `README.md` | 仅在用户可见行为变化时更新；否则不动 |
| `App/SnapGlass/Resources/en.lproj/Localizable.strings` | 最终键审计；删除 T2 重复 `Open System Settings` |
| `App/SnapGlass/Resources/zh-Hans.lproj/Localizable.strings` | 同上 |
| `App/SnapGlass/Resources/ja.lproj/Localizable.strings` | 同上 |
| `App/SnapGlass/Resources/ko.lproj/Localizable.strings` | 同上 |

### 新建文件

| 路径 | 责任 |
|---|---|
| `Docs/superpowers/plans/2026-11-11-recording-acceptance-matrix.md` | G1–G10、I1–I12、UX §6、四语言、兼容、性能、恢复、P0-1–12 的验收矩阵与证据索引 |
| `Packages/CaptureCore/Tests/CaptureCoreTests/FinalValidationConfig.swift` | 唯一配置 schema、`item↔kind` 校验 |
| `Packages/CaptureCore/Tests/CaptureCoreTests/FinalValidationEvidence.swift` | `facts.json` 读取、阈值计算、`result.json` 结构、环境白名单 |
| `Packages/CaptureCore/Tests/CaptureCoreTests/FinalValidationMedia.swift` | 合成 PCM/视频/脉冲/双频 |
| `Packages/CaptureCore/Tests/CaptureCoreTests/RecordingFinalValidationTests.swift` | P0-3/4/5/6/10/11 合成执行；每测试精确 item 启用 |
| `Packages/CaptureCore/Tests/CaptureCoreTests/RecordingFinalValidationAnalysisTests.swift` | 对产品产物的只读分析 |
| `scripts/final-validation.sh` | CLI/退出码/冻结校验/授权门/命令计划/日志封存/矩阵汇总 |
| `.superpowers/sdd/2026-11-11-recording-full-delivery/review/task-18/evidence-index.md` | T18 证据索引（路径 + SHA-256 + run-id + 未验证项） |

### 母计划 T18 Files 差异表（I8，主会话派工前书面接受）

| 项 | 母计划 T18 Files | P7/T18 实际 allowlist |
|---|---|---|
| 验证测试/支持 | 未列 | 新增 5 个 `Packages/CaptureCore/Tests/CaptureCoreTests/FinalValidation*.swift` / `RecordingFinalValidation*.swift` |
| 验证脚本 | 未列 | 新增 `scripts/final-validation.sh` |
| 证据索引 | 未列 | 新增 `review/task-18/evidence-index.md` |
| 完成报告 | 列为 T18 Create | 改为**主会话**写 |
| `review/final/review.md` | 列为 T18 Create | 改为**独立 reviewer** 写 |

- 不新增 SPM target/依赖；验证测试全部在既有测试 target。

- **不创建** `Spikes/`、不新增 App target、不改 `project.yml`、不改产品源码。验证入口全部在测试 target；脚本是计划工件。
- `review/final/review.md` **不由 T18 worker 创建**；由主会话派出的独立 reviewer 写。
- 若产品内部接口无法从 `@testable import CaptureCore` 驱动，T18 停并报告；不得为测试改产品 API。

---

## 2. 任务

### P7-A1 — 验收矩阵骨架

**Files:** Create `Docs/superpowers/plans/2026-11-11-recording-acceptance-matrix.md`

**Interfaces:** Consumes `requirements-map.md`（v0.5）、母计划 §4、P0 v1.1；Produces 唯一验收矩阵。

- [ ] 建 8 个表（标题固定）：`## P0`、`## G`、`## I`、`## UX`、`## 四语言`、`## 兼容`、`## 性能`、`## 恢复`；每个表必须有表头与至少一行。
- [ ] 每行固定列：`ID | 要求 | 归属任务 | 必需方法 | localVerdict | 证据路径 | 结论 | 未覆盖/阻塞`。
- [ ] 每个 P0 行写 `result.json` 的 run-id；未跑写 `incomplete`/`blocked` 与代码（B1–B11）。
- [ ] 顶部写四级状态：L1/L2-partial/L2-complete/L3；L2 必须按项列 `localVerdict`。
- [ ] 不允许把 probe/短测/合成写成“真机通过”。

**Verify:**
```bash
grep -cE '^## (P0|G|I|UX|四语言|兼容|性能|恢复)$' matrix.md   # 8
test "$(grep -cE '^\| P0-[0-9]+ \|' matrix.md)" -eq 12
test "$(grep -cE '^\| G[0-9]+ \|' matrix.md)" -eq 10
test "$(grep -cE '^\| I[0-9]+ \|' matrix.md)" -eq 12
awk -F'|' '/^\| (P0|G|I|UX|四语言|兼容|性能|恢复)/ {gsub(/ /,"",$8); if ($8=="") {print "empty conclusion: "$0; bad=1}} END{exit bad}' matrix.md
```
结果写 T18 报告；缺表/空结论 → 不通过。

### P7-A2 — 四语言与重复键

**Files:** Modify 四个 `Localizable.strings`

- [ ] 删除四语言中新增的重复 `Open System Settings`（保留首处；T2 review 记录当前为第 717 行，行号随 T11/T12 变化，按 key 去重）。
- [ ] 跑 `bash scripts/check-localization.sh`；记录实际输出。
- [ ] 抽查所有新增文案键在四语言都存在、占位符 `%@`/`%d` 一致；不新增文案。
- [ ] 确认无 `NSLocalizedString`/`String(localized:)` 新增违规：`git diff` 只读检查，不修改视图代码。

**Verify:** 脚本 PASS；四文件 `grep -c '"Open System Settings"'` 各为 1。

### P7-A3 — PRIVACY / CHANGELOG / README

**Files:** Modify `Docs/PRIVACY.md`、`CHANGELOG.md`、`README.md`（按需）

- [ ] PRIVACY 增加麦克风用途、系统声音=屏幕录制权限、数据不离开本机、诊断不含媒体内容。
- [ ] CHANGELOG 写用户可见变化与已知限制：分段 59 分钟、多轨、导出上限、录屏内嵌音轨、锁屏策略；注明未签名/未发布。
- [ ] README 只在行为变化影响使用时更新；没有则不写。
- [ ] 不写“已验证/已发布/全平台支持”。

**Verify:** `grep -n "麦克风\|屏幕录制" Docs/PRIVACY.md`；`head -40 CHANGELOG.md` 含新增条目；无 `TODO`/`TBD`。

### P7-A4 — 全量测试、构建、lint、本地化

**Files:** 无代码修改；证据写 `.context/recording-full-delivery/logs/T18.log` 与 `review/task-18/`

- [ ] `bash scripts/test.sh`：记录每个 package 与 App scheme 的实际测试数、通过/失败；新增测试必须全过、无新增失败；0 测试记失败。
- [ ] `swift test --package-path Packages/CaptureCore`：记录实际总数与 known-fail 是否复现；无论结果都保留。
- [ ] `xcodebuild -project SnapGlass.xcodeproj -scheme SnapGlass -configuration Debug build -derivedDataPath "$TMPDIR/snapglass-dd"`：记录成功/失败与警告。
- [ ] `swiftlint lint --strict --config .swiftlint.yml`：必须 0；记录命令与退出码。
- [ ] `xcrun swift-format lint --recursive . --configuration .swift-format`：记录实际告警总数与分类（预期 ~1272 + 3 advisories）；**不得写 0**。
- [ ] `bash scripts/check-localization.sh`：PASS。
- [ ] 在报告中写“实际总数 / 新增全过 / 无新增失败 / known-fail 状态”，不写“全绿”。

**Verify:** 日志含每条命令、退出码、总数；T18 报告与日志一致；known-fail 有原文。

### P7-A5 — 最终验证短测与矩阵回填

**Files:** Create `scripts/final-validation.sh`、五个测试/支持文件；Modify 矩阵

- [ ] 实现 §1 的配置/证据/媒体/测试/脚本，严格按 P0 v1.1 §2–§5；不新增框架、不改产品源码。
- [ ] `scripts/final-validation.sh run --item P0-4` 等本机可执行项；短测默认，`--long` 需主会话写的 `authorization.json`。
- [ ] `record --run-id` 合并同一 run：保留原 facts/commands/exit/loghash/freeze hash 与旧 result，追加人工 checklist/artifact 后重新最终化；人工不得覆盖自动失败或伪造 UT。
- [ ] 测试只写 `facts.json`；runner 在命令结束后核证 exit/日志/哈希并最后写 `result.json`；`swift test` 失败但无有效 facts/result → 64。
- [ ] runner 对 `== / != / < / <= / > / >=` 全部独立复算，actual 必须有限 number；facts.pass 只交叉检查。
- [ ] `block` 项也写权威 `result.json`（verdict/localVerdict/blockReason/blockPrerequisite）；无输入时三个输入 hash 显式 null；先跑 method-sets 中无需授权的 UT/STA/合成命令并保留 exit/log，只对未授权的 DEV/FI/HUM/SOAK 标 blocked；本地失败不得被 block 抹掉。
- [ ] 把 run-id、`localVerdict`、`requiredMethods`、verdict、未覆盖回填矩阵。
- [ ] 未授权项（P0-2/7/8/9/12 等）先跑本地可执行子集，再只对缺失行为方法写 `blocked` + 解除条件；不得整个项跳过。

**Verify:** `scripts/final-validation.sh matrix` 输出 12 行 P0；每个 P0 行有 `verdict` 与 `localVerdict`；blocked 行必须 `localVerdict=blocked`；P0-4/10 必须产出匹配的 `result.json`，产不出即 64 并报告。

### P7-A6 — 证据索引与交接

**Files:** Modify 矩阵；Create `review/task-18/evidence-index.md`（worker 可写）

- [ ] 列每个任务的 report/review/日志/快照路径与 SHA-256。
- [ ] 列 P0 的 `result.json` 路径与 run-id。
- [ ] 列未验证项与阻塞代码（B1–B11）。
- [ ] 写“未提交、未签名、未发布”。
- [ ] **停止**：不派 reviewer、不写 `review/final/review.md`、不写完成报告。

**Verify:** 索引中每个路径存在；`shasum -a 256` 与记录一致；worker 报告明确“等待主会话派 reviewer”。

### P7-B — 独立全分支 review（主会话执行）

**Files:** Create `review/final/review.md`（reviewer 写）

- [ ] 主会话派**独立 reviewer**（非 T18 worker、非本计划作者），输入：全部 task report/review、快照、日志、`result.json`、矩阵、当前工作树、P0 v1.1。
- [ ] reviewer 只读；不改产品/测试/文档。
- [ ] 必查项：
  - P0 方法冻结表是否与 `method-sets.json`/`expected.json` 一致；`localVerdict` 是否只对含行为方法的项给 pass；L2-partial 是否被写成 12 项通过。
  - P0-7 是否只用 290–300s 间隔证明真实损失；5s 是否只作预跑；kill 是否限专用会话/owned root/确认 ref。
  - blocked 项是否也有权威 `result.json`；`record` 是否绑定 run 内 checklist/artifact/hash。
  - 命令/退出码/日志 hash 是否由 runner 在命令结束后核证；测试是否只写 facts、不先写 pass。
  - P0-1/P0-3 是否区分 `wallClockSeconds` 与 `mediaDurationSeconds`；算术/短样本是否被写成真实 SOAK pass。
  - P0 方法覆盖与 L1/L2-partial/L2-complete/L3 是否越级；短测是否冒充真机/长时。
  - known-fail 是否保留、是否被重跑洗绿；0 测试是否报 pass。
  - T3 `swift-format` 1272+3 债务与 TOCTOU 声明是否如实；T2 重复键是否已删。
  - 滚动 minor 清单：T1 两条 DocC 澄清、T2 重复键、T3 格式债/TOCTOU/748 行测试/证据计数标签、known-fail；逐项确认已修或保留说明。
  - 四语言键/占位符；PRIVACY/CHANGELOG 是否与实现一致。
  - 是否有未授权操作、提交、签名、清理。
  - 声明是否超出证据。
- [ ] 结论只能是 `APPROVED` / `CHANGES_REQUIRED`，附 Critical/Important/Minor 与精确文件行号。

**Verify:** `review/final/review.md` 含输入清单、结论、finding 表；无“我运行了 P0”之类未执行声明。

### P7-C — 修复与限定复核（原 worker + 主会话）

**Files:** 只改 review finding 指定路径

- [ ] 原 T18 worker 按 finding 修复；每项写“改了什么/证据/回归命令”。
- [ ] 不扩大范围；finding 外问题只记录，不顺手改。
- [ ] 主会话派 reviewer 做**限定复核**（只查 finding 与回归），写 `review/final/review-fix01.md`。
- [ ] 连续 3 轮未解决则停止，保留最后可用状态并报告。

**Verify:** 每个 finding 有 `ADDRESSED/REJECTED(with reason)`；限定复核结论明确。

### P7-D — 完成报告（主会话执行）

**Files:** Create `Docs/superpowers/plans/2026-11-11-recording-completion-report.md`

- [ ] 写：交付范围、任务清单、实际测试/构建总数、known-fail、格式债、P0 矩阵、四级状态（L1/L2-partial/L2-complete/L3）。
- [ ] 明确“未验证项”：13/14/15、x86_64、设备、播放器/DAW、TCC 更新、外置卷/断电、2h/8h、人耳听测。
- [ ] 证据索引：report/review/log/snapshot/P0 run 路径 + SHA-256。
- [ ] 只声明达到的级别；未达 L2-complete 只能写 `L2-partial` 并列出未 pass/blocked 项；未达 L3 写“全矩阵未验收”。
- [ ] 写“未提交、未签名、未发布、未安装”。

**Verify:** 报告每个结论都有路径/命令/日志；无“全部通过”而无证据。

### P7-E — 停止线

- [ ] 不执行 release、签名、公证、DMG、appcast、部署。
- [ ] 不删除证据、不清理 `.context`、不重置分支。
- [ ] 需要发版时另立任务并重新授权。

---

## 3. 顺序与角色

```
T18 worker: 实现收尾 + 自测 + P0 短测 + 矩阵 + 证据索引
   ↓ 停止（不派 reviewer）
主会话: 派独立 full-branch reviewer → review/final/review.md
   ↓
原 T18 worker: 按 finding 修复
   ↓
主会话: 派限定复核 → review/final/review-fix01.md
   ↓
主会话: 完成报告 + 四级状态
```

- worker 不写 review 结论、不派 reviewer、不跳过矩阵直接写报告。
- reviewer 不改文件；只读 + 写自己的 review。
- 主会话负责最终判定与报告，不把 reviewer 结论直接当验收。

---

## 4. 验证命令清单（T18 实际执行并记录）

```bash
bash scripts/test.sh
swift test --package-path Packages/CaptureCore
xcodebuild -project SnapGlass.xcodeproj -scheme SnapGlass -configuration Debug \
  build -derivedDataPath "$TMPDIR/snapglass-dd"
swiftlint lint --strict --config .swiftlint.yml
xcrun swift-format lint --recursive . --configuration .swift-format
bash scripts/check-localization.sh
scripts/final-validation.sh matrix
```

- 每条命令记录：命令、退出码、stdout/stderr 路径、实际总数。
- 已知失败：`legacyDirectoriesWaitForTheLegacyGrace`；记录是否复现，不修断言、不删用例、不以重跑覆盖。
- `swift-format` 允许非 0 退出（仓库现状），但必须记录总数与分类；不得写“0 告警”。

---

## 5. 完成定义

- [ ] 验收矩阵 12 个 P0 行 + G/I/UX/兼容/性能/恢复均有结论或 `blocked`。
- [ ] 全量测试/构建/本地化/strictlint 有实际日志与总数；新增测试全过；无新增失败。
- [ ] 独立 review `APPROVED`；所有 Critical/Important 关闭或有主会话裁定。
- [ ] 完成报告写清 L1/L2-partial/L2-complete/L3 与未验证项；未达 L2-complete 不得写“L2 本环境验证完成”。
- [ ] 未提交、未签名、未发布。

---

## 6. 自检

| 检查 | 结果 |
|---|---|
| 任务顺序 | worker 自测 → 独立 review → 修复 → 限定复核 → 报告；worker 不派 reviewer |
| 文件精确 | T18 只改列出的 4 个 strings + 3 个文档；新建 5 个测试/支持文件 + 1 脚本 + 1 验收矩阵 + 1 证据索引；完成报告由主会话写 |
| 测试口径 | 实际总数/新增全过/无新增失败；known-fail 保留；0 测试失败 |
| 债务如实 | T3 1272+3 格式告警、TOCTOU 声明、T2 重复键均进入 review |
| P0 诚实 | 12 项方法冻结表 + method-sets hash；短测/真机/长跑分开；wallClock/mediaDuration 分开；未跑即 incomplete/blocked；不冒充 L3 |
| blocked/证据 | blocked 也写 result；先跑本地 UT/STA；测试只写 facts；runner 全运算符复算；日志先封存后 hash |
| 人工合并 | `record --run-id` 保留旧 revision/自动失败；人工只追加 artifact/checklist |
| 安全 | 无提交/签名/安装/清理；P0-7 限专用会话；长跑需主会话写的授权 ref |
