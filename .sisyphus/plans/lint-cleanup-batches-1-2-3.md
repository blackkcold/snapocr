# SnapGlass SwiftLint 债务全量清理计划（方案 D · 批次 1/2/3）

## TL;DR

> **快速摘要**: 全量清理 SnapGlass 的 SwiftLint 债务，分 3 批执行。批次 1 清理本次 PR 引入的违规（解锁 CI 变绿、可合并）；批次 2 清理历史机械性违规（identifier_name / line_length / force_unwrapping）；批次 3 清理历史架构性违规（file_length 拆分 / trailing_comma）。每批次独立可审计、可验证、可回滚。
>
> **交付物**:
> - 批次 1: 9 个 PR 变更文件 lint 清零（含 2 个 file_length ERROR 文件拆分）
> - 批次 2: 历史机械性违规清零（约 135 条）
> - 批次 3: 历史架构性违规清零（file_length 拆分 + trailing_comma）
> - 最终: 全量 `swiftlint lint --strict` 归零 + `./scripts/test.sh` 全绿
>
> **预估工作量**: High
> **并行执行**: 批次内并行，批次间串行（每批次独立验证）
> **关键路径**: 批次 1 → 批次 2 → 批次 3 → 全量验证

---

## Context

### 原始需求
用户确认采用方案 D（全量清理），要求形成修复方案文档，并设置开发 goal 以便每批次可被审计优化。

### 审计背景
- 本次 PR（分支 `kinetic-lemur`，5 commits ahead of `main`）CI lint 失败
- 原方案 B（只 lint 变更文件）经对抗性交叉核查**不成立**：变更文件自身含既有违规（如 `AreaSelectionPanel.swift` 1206 行超 `file_length: error: 1200` 阈值）
- 用户选择方案 D：所有问题都要解决，分批处理

### 违规总览（实测基线，swiftlint 0.65.1 全量扫描）

> **实测方法**: `swiftlint lint --config .swiftlint.yml`，过滤 `.build/`（第三方依赖与派生测试 runner）。
> **关键发现**: 真实源码违规 **295 条**（不含 `.build/`），此前静态估算 ~240 条**低估了**。CI 在干净的 `macos-latest` runner 上（无 `.build/`）实际会遇到这 295 条。
> **`.swiftlint.yml` 无 `excluded` 配置**：本地跑会把 `.build/` 的第三方依赖（KeyboardShortcuts 等）算进去（约 1444 条噪音），但 CI 干净环境不受影响。这是 CI 配置层面的既有缺陷，不在本方案修复范围（方案 D 不动 CI 配置）。

| 规则 | 总数 | 分布 | 批次 |
|------|------|------|------|
| identifier_name | 93 | 集中在 5 个文件 | 批次 1 + 2 |
| line_length | 48 | 集中在 3 个文件 | 批次 1 + 2 |
| function_body_length | 19 | 大函数 | 批次 2 |
| multiple_closures_with_trailing_closure | 12 | 多闭包参数 | 批次 2 |
| file_length | 11 | 2 ERROR + 9 WARNING | 批次 1 + 3 |
| type_body_length | 6 | 大类型 | 批次 3 |
| cyclomatic_complexity | 6 | 复杂函数 | 批次 2 |
| 其他（trailing_newline 2, large_tuple 2, implicit_optional 2, function_parameter_count 2, closure_parameter_position 2, private_over_fileprivate 2, opening_brace 1, non_optional_string 1, legacy_swiftui_aspect_ratio 1, inclusive_language 1, implicitly_unwrapped_optional 1, force_unwrapping 1, for_where 1） | 19 | 散落 | 批次 2 |

> **trailing_comma (81 条) 已在批次 0 通过禁用规则解决**（依据苹果官方规范），不在清理范围内。

**Top 违规文件**（实测）:
| 文件 | 违规数 |
|------|--------|
| AreaSelectionPanel.swift | 25 |
| EditableAnnotationCanvasView.swift | 18 |
| AnnotationCanvasView.swift | 17 |
| FrameDeduper.swift | 16 |
| OverlapDetector.swift | 11 |
| HistoryActor.swift | 11 |
| SCKAdapter.swift | 11 |
| TesseractOCREngine.swift | 10 |
| Package.swift（根） | 10 |
| CLIHandlers.swift | 9 |

> ⚠️ **审计修正**: 根 `Package.swift` 和 8 个包的 `Package.swift` 共 **31 条**违规，**全部是 `trailing_comma`**，且报 "should NOT have trailing commas"。这些是 **SwiftLint 对 SPM 清单的误报**（SPM 多行依赖/参数标准写法用尾逗号，删尾逗号反而破坏规范）。
>
> ### ✅ 已确认决策（用户批准）
> 1. **`.swiftlint.yml` 加 `excluded: [.build]`** — 消除本地 1444 条第三方依赖/派生 runner 噪音，本地数字与 CI 对齐（1739 → 295）。CI 干净环境本无 `.build`，此改动不影响 CI 判定。
> 2. **`.swiftlint.yml` `disabled_rules` 加 `trailing_comma`** — 依据苹果官方规范（详见下方"官方规范依据"），保留多行集合尾逗号。与已禁用的 `comma`/`colon`/`trailing_whitespace`/`vertical_whitespace` 一致（注释"由 swift-format 处理"）。**不需要 excluded 排除 Package.swift**（其 31 条 trailing_comma 一并解决）。
>
> ### 官方规范依据（为何禁用 trailing_comma）
> - **Apple swift-format 默认**: `multiElementCollectionTrailingCommas: true`（实测本机工具确认），要求多行集合有尾逗号
> - **Swift 标准库 / DocC / Xcode**: SE-0084 明确指出广泛采用尾逗号风格
> - **Swift 6.1 (SE-0439，已实现)**: 官方将尾逗号支持扩展到参数/元组/泛型等所有列表，方向是鼓励尾逗号
> - **Google Swift Style Guide**: "Trailing commas ... are required when each element is placed on its own line. Doing so produces cleaner diffs."
> - **结论**: 当前代码的尾逗号**符合官方规范**；SwiftLint `trailing_comma`（`mandatory_comma: false`）报错是与官方规范冲突的过时默认值。删尾逗号会违反 swift-format（CI 的 swift-format job 会失败）。
>
> > ⚠️ **这两项是 CI 配置修改**（`.swiftlint.yml`），属于 guardrail「不修改 CI 配置」之外的操作，**已获用户明确批准**。执行时作为批次 0（前置配置调整）单独提交。
>
> ### 修正后违规基线（排除 .build + 禁用 trailing_comma + 排除 Package.swift）
> 源码违规从 295 → **214 条**（去掉 trailing_comma 81 条）。剩余需清理:
> | 规则 | 数量 |
> |------|------|
> | identifier_name | 93 |
> | line_length | 48 |
> | function_body_length | 19 |
> | multiple_closures_with_trailing_closure | 12 |
> | file_length | 11 |
> | type_body_length | 6 |
> | cyclomatic_complexity | 6 |
> | 其他散落 | 19 |

### 测试基础设施
- 159+ @Test 分布在 14 个文件，8 个包
- CI: `swiftlint lint --strict --config .swiftlint.yml` + `swift-format lint --recursive .`
- 本地: `./scripts/test.sh`（全量 Package 测试）

---

## Work Objectives

### 核心目标
全量清理 SwiftLint 债务，让 `swiftlint lint --strict` 归零，且不破坏任何功能、不引入新依赖、不降低规则强度。

### 具体交付物
- 批次 1: 9 个 PR 变更文件 lint 清零（含 2 个 file_length ERROR 文件拆分）
- 批次 2: 历史机械性违规清零（identifier_name 66 + line_length 48 + force_unwrapping 21）
- 批次 3: 历史架构性违规清零（file_length 9 WARNING 拆分 + trailing_comma ~94）

### Must Have
- 每个批次完成后，对应文件 `swiftlint lint --config .swiftlint.yml <file>` 清零
- 每个文件改动后，对应 Package 测试通过
- 最终全量 `swiftlint lint --strict` 归零 + `./scripts/test.sh` 全绿

### Must NOT Have (Guardrails)
- ❌ 不降低 `.swiftlint.yml` 规则强度（不放宽/禁用规则）
- ❌ 不引入新依赖（第三方库）
- ❌ 不修改 CI/xcodeproj/权限配置
- ❌ 不修改 `.build/` 或 `DerivedData`
- ❌ 不 force unwrap（`!`）作为"修复"手段
- ❌ 不擅自 bump 版本号（lint 清理属 `chore`，不新增版本记录）
- ❌ 不修改与 lint 清理无关的代码

---

## Verification Strategy

### 测试决策
- **基础设施存在**: YES（Swift Testing + XCTest）
- **自动化测试**: YES（每文件改动后跑对应 Package 测试）
- **框架**: Swift Testing（`@Test`/`#expect`）

### QA 策略
每个批次包含 agent 可执行的 QA 场景。证据保存至 `.sisyphus/evidence/`。
- **lint 清零**: `swiftlint lint --config .swiftlint.yml <file>` 输出 0 violations
- **功能回归**: `swift test --package-path Packages/<PackageName>`
- **全量验证**: `swiftlint lint --strict` + `./scripts/test.sh`

---

## Execution Strategy

### 批次间串行，批次内并行

```
批次 0 (前置配置调整 — 依据官方规范):
├── Task 0a: .swiftlint.yml 加 excluded: [.build] [quick] — 消除第三方噪音
├── Task 0b: .swiftlint.yml disabled_rules 加 trailing_comma [quick] — 符合苹果官方规范
└── 验证: swiftlint lint --strict 从 1739 降到 214

批次 1 (PR 引入违规 — 解锁 CI 变绿):
├── Task 1: AreaSelectionPanel.swift 清理 [deep] — 4 id_name + 7 line_len + file_length ERROR
├── Task 2: EditableAnnotationCanvasView.swift 清理 [deep] — 8 id_name + 3 line_len + file_length ERROR
├── Task 3: PreferencesView.swift 清理 [quick] — 3 line_len + file_length WARN
├── Task 4: HistoryView.swift 清理 [quick] — 3 line_len + file_length WARN
├── Task 5: CaptureViewModel.swift 清理 [quick] — 1 line_len + file_length WARN
├── Task 6: EditorViewModel.swift 清理 [quick] — 1 line_len + file_length WARN
├── Task 7: AreaSelectionTypes.swift 清理 [quick] — 1 line_len + 1 IUO
├── Task 8: AnnotationInspectorView.swift 清理 [quick] — 2 line_len
├── Task 9: HistoryStorageDashboard.swift 清理 [quick] — 1 line_len

批次 2 (历史机械性违规):
├── Task 10: identifier_name 93 条清理 [deep] — 5 个文件短名改名
├── Task 11: line_length 48 条清理 [quick] — 3 个文件长行换行
├── Task 12: function_body_length 19 + cyclomatic_complexity 6 + multiple_closures 12 清理 [deep]
├── Task 12b: 其他散落规则 19 条清理 [quick]

批次 3 (历史架构性违规):
├── Task 13: file_length 9 WARNING 文件拆分 [deep] — 逐个拆分
├── Task 13b: type_body_length 6 条清理 [deep]
（trailing_comma 已在批次 0 通过禁用规则解决）

批次 FINAL (ALL 完成后 — 全量验证):
├── F1: 全量 swiftlint lint --strict 归零
├── F2: ./scripts/test.sh 全绿
├── F3: 文档同步（测试通过后更新 Docs/ARCHITECTURE.md + Docs/AGENTS.md 项目结构）
```

---

## TODOs

### 批次 1: PR 引入违规（解锁 CI 变绿）

- [ ] 1. **清理 `AreaSelectionPanel.swift`**（1207 行，PR 变更文件）

  **What to do**:
  - 修复 4 个 `identifier_name`: `x`(1111)、`y`(1116)、`dx`(1184)、`dy`(1185) → 描述性名称
  - 修复 7 个 `line_length`: 334(124)、335(128)、627(126)、654(121)、713(121)、952(141)、1204(142) → 换行
  - 拆分文件（1207 > 1200 error 阈值）: 将 `AreaTrackingView` 或 `WindowSelectionPanel` 拆到独立文件，保持访问级别与功能不变

  **Must NOT do**: 不改变任何坐标/绘制逻辑，不改变访问级别语义，不引入新类型

  **Agent**: `deep` | **批次**: 1 | **并行**: 与 Task 2-9 并行

  **References**:
  - `App/SnapGlass/Sources/Overlays/AreaSelectionPanel.swift` — 目标文件
  - `.swiftlint.yml` — `file_length: error: 1200`

  **QA Scenarios**:
  ```
  Scenario: AreaSelectionPanel lint 清零
    Tool: swiftlint lint --config .swiftlint.yml App/SnapGlass/Sources/Overlays/AreaSelectionPanel.swift
    Expected: 0 violations
    Evidence: .sisyphus/evidence/task-1-lint.txt

  Scenario: 功能回归
    Tool: swift build
    Expected: 编译通过，无错误无警告
    Evidence: .sisyphus/evidence/task-1-build.txt
  ```

  **Commit**: `refactor(AreaSelectionPanel): fix lint violations and split oversized file` | Files: `App/SnapGlass/Sources/Overlays/AreaSelectionPanel.swift` (+ 拆分文件)

---

- [ ] 2. **清理 `EditableAnnotationCanvasView.swift`**（1284 行，PR 变更文件）

  **What to do**:
  - 修复 8 个 `identifier_name`: `x`(888)、`dx/dy`(981-982,1142-1143,1162-1163)、`t`(1166) → 描述性名称
  - 修复 3 个 `line_length`: 1231(121)、1245(128)、1256(151) → 换行
  - 拆分文件（1284 > 1200 error 阈值）: 将绘制/交互逻辑拆到独立文件

  **Must NOT do**: 不改变任何绘制/交互逻辑，不改变 OCR 选区行为

  **Agent**: `deep` | **批次**: 1 | **并行**: 与 Task 1,3-9 并行

  **References**:
  - `App/SnapGlass/Sources/Editor/EditableAnnotationCanvasView.swift` — 目标文件

  **QA Scenarios**:
  ```
  Scenario: EditableAnnotationCanvasView lint 清零
    Tool: swiftlint lint --config .swiftlint.yml App/SnapGlass/Sources/Editor/EditableAnnotationCanvasView.swift
    Expected: 0 violations
    Evidence: .sisyphus/evidence/task-2-lint.txt

  Scenario: 功能回归
    Tool: swift build
    Expected: 编译通过
    Evidence: .sisyphus/evidence/task-2-build.txt
  ```

  **Commit**: `refactor(Editor): fix lint violations and split oversized file` | Files: `App/SnapGlass/Sources/Editor/EditableAnnotationCanvasView.swift` (+ 拆分文件)

---

- [ ] 3. **清理 `PreferencesView.swift`**（773 行，PR 变更文件）

  **What to do**:
  - 修复 3 个 `line_length`: 383(168)、667(138)、724(153) → 换行
  - 处理 `file_length` WARNING（>500）: 拆分或接受 warning（warning 不阻塞 `--strict`？需确认）

  **Agent**: `quick` | **批次**: 1 | **并行**: 与 Task 1,2,4-9 并行

  **References**: `App/SnapGlass/Sources/Windows/PreferencesView.swift`

  **QA**: `swiftlint lint --config .swiftlint.yml App/SnapGlass/Sources/Windows/PreferencesView.swift` → 0 violations

  **Commit**: `refactor(PreferencesView): fix line_length violations` | Files: `App/SnapGlass/Sources/Windows/PreferencesView.swift`

---

- [ ] 4. **清理 `HistoryView.swift`**（665 行，PR 变更文件）

  **What to do**:
  - 修复 3 个 `line_length`: 300(138)、317(137)、417(149) → 换行
  - 处理 `file_length` WARNING

  **Agent**: `quick` | **批次**: 1 | **并行**: 与 Task 1-3,5-9 并行

  **References**: `App/SnapGlass/Sources/Windows/HistoryView.swift`

  **QA**: `swiftlint lint --config .swiftlint.yml App/SnapGlass/Sources/Windows/HistoryView.swift` → 0 violations

  **Commit**: `refactor(HistoryView): fix line_length violations` | Files: `App/SnapGlass/Sources/Windows/HistoryView.swift`

---

- [ ] 5. **清理 `CaptureViewModel.swift`**（1018 行，PR 变更文件）

  **What to do**:
  - 修复 1 个 `line_length`: 460(124) → 换行
  - 处理 `file_length` WARNING

  **Agent**: `quick` | **批次**: 1 | **并行**: 与 Task 1-4,6-9 并行

  **References**: `App/SnapGlass/Sources/MenuBar/CaptureViewModel.swift`

  **QA**: `swiftlint lint --config .swiftlint.yml App/SnapGlass/Sources/MenuBar/CaptureViewModel.swift` → 0 violations

  **Commit**: `refactor(CaptureViewModel): fix line_length violation` | Files: `App/SnapGlass/Sources/MenuBar/CaptureViewModel.swift`

---

- [ ] 6. **清理 `EditorViewModel.swift`**（798 行，PR 变更文件）

  **What to do**:
  - 修复 1 个 `line_length`: 684(122) → 换行
  - 处理 `file_length` WARNING

  **Agent**: `quick` | **批次**: 1 | **并行**: 与 Task 1-5,7-9 并行

  **References**: `App/SnapGlass/Sources/Editor/EditorViewModel.swift`

  **QA**: `swiftlint lint --config .swiftlint.yml App/SnapGlass/Sources/Editor/EditorViewModel.swift` → 0 violations

  **Commit**: `refactor(EditorViewModel): fix line_length violation` | Files: `App/SnapGlass/Sources/Editor/EditorViewModel.swift`

---

- [ ] 7. **清理 `AreaSelectionTypes.swift`**（151 行，PR 变更文件）

  **What to do**:
  - 修复 1 个 `line_length`: 108(126) → 换行
  - 修复 1 个 `implicitly_unwrapped_optional`: 83 `trackingView: AreaTrackingView!` → 改为可选或延迟初始化

  **Agent**: `quick` | **批次**: 1 | **并行**: 与 Task 1-6,8-9 并行

  **References**: `App/SnapGlass/Sources/Overlays/AreaSelectionTypes.swift`

  **QA**: `swiftlint lint --config .swiftlint.yml App/SnapGlass/Sources/Overlays/AreaSelectionTypes.swift` → 0 violations

  **Commit**: `refactor(AreaSelectionTypes): fix line_length and IUO violations` | Files: `App/SnapGlass/Sources/Overlays/AreaSelectionTypes.swift`

---

- [ ] 8. **清理 `AnnotationInspectorView.swift`**（332 行，PR 变更文件）

  **What to do**:
  - 修复 2 个 `line_length` → 换行

  **Agent**: `quick` | **批次**: 1 | **并行**: 与 Task 1-7,9 并行

  **References**: `App/SnapGlass/Sources/Editor/AnnotationInspectorView.swift`

  **QA**: `swiftlint lint --config .swiftlint.yml App/SnapGlass/Sources/Editor/AnnotationInspectorView.swift` → 0 violations

  **Commit**: `refactor(AnnotationInspectorView): fix line_length violations` | Files: `App/SnapGlass/Sources/Editor/AnnotationInspectorView.swift`

---

- [ ] 9. **清理 `HistoryStorageDashboard.swift`**（215 行，PR 变更文件）

  **What to do**:
  - 修复 1 个 `line_length` → 换行

  **Agent**: `quick` | **批次**: 1 | **并行**: 与 Task 1-8 并行

  **References**: `App/SnapGlass/Sources/Windows/HistoryStorageDashboard.swift`

  **QA**: `swiftlint lint --config .swiftlint.yml App/SnapGlass/Sources/Windows/HistoryStorageDashboard.swift` → 0 violations

  **Commit**: `refactor(HistoryStorageDashboard): fix line_length violation` | Files: `App/SnapGlass/Sources/Windows/HistoryStorageDashboard.swift`

---

### 批次 2: 历史机械性违规

- [ ] 10. **清理 `identifier_name` 66 条**（历史遗留）

  **What to do**:
  - 5 个主要文件短名改名:
    - `AnnotationCanvasView.swift`(16): `a/b/r/p0/p1/p2/o/w/h` → 描述性名称
    - `FrameDeduper.swift`(13): `w1/h1/w2/h2/x1/y1/x2/y2/x/y/n/c1/c2` → 描述性名称
    - `OverlapDetector.swift`(9): `x1/x2/x/y/n/c1/c2` → 描述性名称
    - `EditableAnnotationCanvasView.swift`(8): 已在批次 1 处理
    - `AreaSelectionPanel.swift`(4): 已在批次 1 处理
  - 其余散落文件（BarcodeResult、ArrowTool、HighlightTool、BlurTool、RectTool、CropTool、PreferencesGlass 等）逐个改名

  **Must NOT do**: 不改变任何算法逻辑，仅重命名局部变量

  **Agent**: `deep` | **批次**: 2 | **Blocked By**: 批次 1

  **References**: 各目标文件

  **QA**:
  ```
  Scenario: identifier_name 清零
    Tool: swiftlint lint --config .swiftlint.yml <各文件>
    Expected: 0 identifier_name violations
    Evidence: .sisyphus/evidence/task-10-lint.txt

  Scenario: 功能回归
    Tool: swift test --package-path Packages/ScrollCore && swift test --package-path Packages/AnnotationCore
    Expected: 全部通过
    Evidence: .sisyphus/evidence/task-10-tests.txt
  ```

  **Commit**: `refactor: rename short identifiers to descriptive names` | Files: 各目标文件

---

- [ ] 11. **清理 `line_length` 48 条**（历史遗留）

  **What to do**:
  - 3 个主要文件长行换行:
    - `AreaSelectionPanel.swift`(7): 已在批次 1 处理
    - `RoutingView.swift`(5): 199-203(144/155/147/140/154) → 换行
    - `OCRPipeline.swift`(5): 89(145)、115(198)、144(133)、157(140)、168(150) → 换行
  - 其余散落文件（SCKAdapter、TesseractOCREngine、MenuBarView、AboutPreferencesView、PreferencesLayout、PreferencesViewModel、HotKeyManager、VisionBarcodeEngine、CLIHandlers、CGCompatAdapter、LanguagePackDownloader 等）逐个换行

  **Agent**: `quick` | **批次**: 2 | **Blocked By**: 批次 1

  **References**: 各目标文件

  **QA**: `swiftlint lint --config .swiftlint.yml <各文件>` → 0 line_length violations

  **Commit**: `refactor: wrap long lines to satisfy line_length` | Files: 各目标文件

---

- [ ] 12. **清理 `force_unwrapping` 21 条**（历史遗留）

  **What to do**:
  - `URLSchemeRouterTests.swift`(19): `URL(string: "...")!` → `try #require(URL(string: "..."))`
  - `FrameDeduper.swift`(1): `uniqueFrames.last!` → guard 或 `#require`
  - `AreaSelectionTypes.swift`(1 IUO): 已在批次 1 处理

  **Agent**: `quick` | **批次**: 2 | **Blocked By**: 批次 1

  **References**: `Packages/AutomationCore/Tests/AutomationCoreTests/URLSchemeRouterTests.swift`、`Packages/ScrollCore/Sources/FrameDeduper.swift`

  **QA**: `swift test --package-path Packages/AutomationCore && swift test --package-path Packages/ScrollCore` → 全部通过

  **Commit**: `refactor: replace force unwraps with safe unwrapping` | Files: `URLSchemeRouterTests.swift`、`FrameDeduper.swift`

---

### 批次 3: 历史架构性违规

- [ ] 13. **清理 `file_length` 9 WARNING 文件**（历史遗留）

  **What to do**:
  - 逐个拆分 9 个超 500 行文件:
    - `HistoryActor.swift`(952)
    - `SCKAdapter.swift`(669)
    - `TesseractOCREngine.swift`(637)
    - `ScrollStitchEngine.swift`(513)
    - `SharedKitTests.swift`(505)
    - `PreferencesView.swift`(773) — 批次 1 已处理
    - `HistoryView.swift`(665) — 批次 1 已处理
    - `CaptureViewModel.swift`(1018) — 批次 1 已处理
    - `EditorViewModel.swift`(798) — 批次 1 已处理
  - 每个文件拆分后跑对应 Package 测试

  **Must NOT do**: 不改变任何功能逻辑，仅按职责拆分文件

  **Agent**: `deep` | **批次**: 3 | **Blocked By**: 批次 2

  **References**: 各目标文件

  **QA**: `swiftlint lint --config .swiftlint.yml <各文件>` → 0 file_length violations + 对应 Package 测试通过

  **Commit**: `refactor: split oversized files to satisfy file_length` | Files: 各目标文件

- [ ] 13b. **清理 `type_body_length` 6 条**（历史遗留）

  **What to do**: 拆分超 400 行类型的文件

  **Agent**: `deep` | **批次**: 3 | **Blocked By**: 批次 2

  **QA**: `swiftlint lint --config .swiftlint.yml <各文件>` → 0 type_body_length violations

  **Commit**: 与 Task 13 一起提交

---

## Final Verification Wave (MANDATORY — after ALL batches)

> 全量验证。ALL 必须通过。

- [ ] F1. **全量 lint 归零** — `swiftlint lint --strict --config .swiftlint.yml` → 0 violations
- [ ] F2. **全量测试通过** — `./scripts/test.sh` → 全部 Package 通过
- [ ] F3. **文档同步** — 测试通过后更新 `Docs/ARCHITECTURE.md` + `Docs/AGENTS.md` 项目结构（若拆分文件改变了结构）

---

## Commit Strategy

| 批次 | Tasks | Message |
|------|-------|---------|
| 1 | 1,2 | `refactor(AreaSelectionPanel/Editor): fix lint violations and split oversized files` |
| 1 | 3-9 | `refactor: fix line_length/IUO violations in PR files` |
| 2 | 10 | `refactor: rename short identifiers to descriptive names` |
| 2 | 11 | `refactor: wrap long lines to satisfy line_length` |
| 2 | 12 | `refactor: replace force unwraps with safe unwrapping` |
| 3 | 13 | `refactor: split oversized files to satisfy file_length` |
| 3 | 14 | `refactor: add trailing commas to multiline collections` |
| Final | F3 | `docs: update project structure after file splits` |

---

## Success Criteria

### Verification Commands
```bash
swiftlint lint --strict --config .swiftlint.yml   # 全量归零
./scripts/test.sh                                  # 全量测试通过
swift build                                        # 无错误无警告
```

### Final Checklist
- [ ] 所有 "Must Have" 已实现
- [ ] 所有 "Must NOT Have" 无违规
- [ ] 全量 `swiftlint lint --strict` 归零
- [ ] `./scripts/test.sh` 全绿
- [ ] 版本号未擅自变更（lint 清理属 `chore`）
- [ ] 文档已同步（测试通过后）
