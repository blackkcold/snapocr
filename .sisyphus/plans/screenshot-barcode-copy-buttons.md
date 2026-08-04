# Plan: Screenshot & Barcode Copy Button Optimizations

## TL;DR

> **Quick Summary**: 为 SnapGlass macOS 应用的截图确认 toast 和条码识别结果界面各添加一个复制按钮，复用现有 toast action 模式和 `BarcodeCopyCandidate` 代码模式。
>
> **Deliverables**:
> - 截图立即复制后显示含"复制"动作按钮的确认 toast（复用 `CaptureViewModel` 已有 toast 模式）
> - 条码识别结果区域显示复制按钮（零条码不显示；单条码单项复制；多条码逐项复制+全部复制）
> - 复制失败不报成功：错误路径返回/显示错误提示，不弹出"复制成功"toast
> - en / zh-Hans 本地化字符串
> - CHANGELOG 条目
>
> **Estimated Effort**: Quick (4 个文件，~80 行净增)
> **Parallel Execution**: YES - 2 waves
> **Critical Path**: Task 1 (toast 增强) → Task 3 (条码复制按钮) → Task 6 (本地化)

---

## Context

### Original Request
用户要求：(1) 截图立即复制后，确认界面应提供复制按钮；(2) 识别条码后，条码界面也应提供复制按钮。

### Pre-Analysis Summary
- **截图流程**：普通截图 → EditorView（底栏已有 Copy 按钮）。仅剪贴板截图 → `CaptureViewModel.copyImageToClipboard()` → 显示 toast → 跳过编辑器（当前 toast 无复制动作按钮）。
- **条码流程**：`ToolPickerView` 扫描按钮 → `EditorViewModel.scanBarcodes()` 自动复制（单个 payload 或全部换行连接）。`CaptureViewModel` 已有一个 toast `Copy Content` 动作（仅单条码）。
- **关键事实**：不存在独立的截图确认覆盖层。约束禁止未经用户确认就新建覆盖层。

---

## ⚠️ 待确认产品决策（CRITICAL - 编辑前必须确认）

### "截图确认界面"以什么形式呈现？

当前没有独立截图确认覆盖层。三个选项：

| 选项 | 描述 | 推荐？ |
|------|------|--------|
| **A. 增强 Toast** | 在现有 toast 上添加"复制"动作按钮，类似 `CaptureViewModel` 已有的 `Copy Content` toast | ✅ **强烈推荐** |
| **B. 新建覆盖层** | 创建一个新的模态/浮层显示截图预览+复制按钮 | ❌ 约束禁止未经确认 |
| **C. 进入 EditorView** | 将仅剪贴板截图也路由到 EditorView | ❌ 破坏"跳过编辑器"的现有行为 |

**推荐 A**：完全复用现有 toast 基础设施和 `CaptureViewModel` 中已有的 action toast 模式，零新 UI 组件，符合"最小修改"约束。toast 短暂出现（含"已复制"文本 + "复制"按钮供用户再次复制），符合 macOS 系统通知 banner 交互惯例。

> **请在 `/start-work` 之前确认选择 A，或指定其他方案。**

---

## Work Objectives

### Core Objective
在两个流程中向用户提供可交互的复制按钮：截图后确认 toast 中的复制动作、条码识别结果区域的复制控件。

### Concrete Deliverables
- `CaptureViewModel.swift`: `copyImageToClipboard()` 成功后显示带 action 按钮的 toast
- `BarcodeCopyCandidate` / 条码结果视图: 基于条码数量（0/1/N）的条件复制按钮
- 本地化文件: en + zh-Hans 新增字符串
- `CHANGELOG.md`: 新条目

### Definition of Done
- [ ] 仅剪贴板截图后, toast 显示"已复制到剪贴板"并带有可点击的"复制"按钮
- [ ] 点击 toast 复制按钮后, 图片再次写入剪贴板, toast 更新确认
- [ ] 条码识别后, 单条码: 显示 payload 文本 + "复制"按钮
- [ ] 条码识别后, 多条码: 每条显示 payload + "复制"按钮 + "全部复制"按钮
- [ ] 条码识别后, 零条码: 不显示复制按钮, 显示"未识别到条码"
- [ ] 复制失败时, 不显示"复制成功"toast, 显示错误信息
- [ ] `swift build` 通过, 无 warnings
- [ ] en/zh-Hans 本地化完整

### Must Have
- 截图 toast 的复制 action 按钮
- 条码结果复制按钮（0/1/N 行为符合 `BarcodeCopyCandidate` 模式）
- 复制失败 ≠ 复制成功（错误状态不入成功路径）
- 本地化: en + zh-Hans 全覆盖
- CHANGELOG 条目

### Must NOT Have (Guardrails)
- 新建截图预览覆盖层/模态窗口（未经用户确认）
- 新第三方依赖
- 修改 `Package.swift` / `.xcodeproj`
- 重设计无关 UI（EditorView 底栏、ToolPickerView 布局等）
- 修改权限声明
- 破坏 image/text pasteboard 分离路径

---

## Verification Strategy

### Test Decision
- **Infrastructure exists**: YES (Swift Testing for package tests)
- **Automated tests**: NO app-layer tests exist; package tests use Swift Testing
- **Framework**: Swift Testing (package level)
- **Agent-executed QA**: 主要验证方式 — bash + tmux 运行构建、Playwright 不可用（macOS 原生 app）改用手动验证步骤

### QA Policy
由于是 macOS 原生 SwiftUI 应用，无 Playwright 支持。每项任务的 QA 通过以下方式：
- **构建**: `swift build` 确认无编译错误
- **交互验证**: 在 macOS 上运行 app，手动执行以下场景（见各任务 QA Scenarios）
- **本地化检查**: grep 确认所有新增字符串在 en/zh-Hans 文件中存在

---

## Execution Strategy

### Parallel Execution Waves

```
Wave 1 (Start Immediately - 基础 + 类型):
├── Task 1: Toast 系统增强 — 确保 action button 支持就绪 [quick]
├── Task 2: 截图复制 toast 添加 action 按钮 [quick]
└── Task 3: 条码复制行为定义 (0/1/N) [quick]

Wave 2 (After Wave 1 - 集成 + 收尾):
├── Task 4: 条码结果视图复制按钮 [quick]
├── Task 5: 复制失败处理 + 本地化 [quick]
└── Task 6: CHANGELOG + 最终验证 [quick]
```

**Critical Path**: Task 1 → Task 3 → Task 4 → Task 6
**Parallel Speedup**: Wave 2 中 Task 4/5/6 可并行

---

## TODOs

- [ ] 1. Toast 系统增强 — 确保 action button 支持就绪

  **What to do**:
  - 检查现有 toast 系统是否已支持 action button（`CaptureViewModel` 已有 `Copy Content` toast，说明能力存在）
  - 如需要：为 toast 添加可选的 `action: (label: LocalizedStringKey, handler: () -> Void)?` 参数
  - 保持向后兼容：不带 action 的 toast 行为不变

  **Must NOT do**:
  - 新建 toast 组件/框架
  - 改变现有 toast 的消失时机或动画

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: 简单验证/增强现有基础设施
  - **Skills**: None specific (代码量极小)

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1 (with Tasks 2, 3)
  - **Blocks**: Task 4
  - **Blocked By**: None

  **Acceptance Criteria**:
  - [ ] 现有 toast（所有调用点）行为不变
  - [ ] toast 支持可选的 action 按钮参数

  **QA Scenarios**:
  ```
  Scenario: 现有 toast 行为不变
    Tool: interactive_bash (tmux)
    Steps:
      1. swift build → 确认编译通过
      2. 运行 app，触发任意现有 toast（如截图成功）
      3. 确认 toast 正常显示和消失，无视觉变化
    Expected Result: 所有现有 toast 行为与修改前一致
    Evidence: .sisyphus/evidence/task-1-toast-regression.txt (build output)
  ```

  **Commit**: YES
  - Message: `refactor(toast): add optional action button support`
  - Files: toast 相关文件

- [ ] 2. 截图复制 toast 添加 Copy action 按钮

  **What to do**:
  - 在 `CaptureViewModel.copyImageToClipboard()` 成功后，将现有纯文本 toast 替换为带 action 的 toast
  - action 标签: "Copy" (en) / "复制" (zh-Hans)
  - action handler: 再次调用 `copyImageToClipboard()`，成功后更新 toast 文本为 "Copied again" / "已再次复制"
  - 如果再次复制失败，更新 toast 为错误文本（不显示 "复制成功"）

  **Must NOT do**:
  - 改变 `copyImageToClipboard()` 的 pasteboard 写入逻辑（image/text 分离路径保持不变）
  - 移除或延迟现有 toast 的自动消失
  - 改动 EditorView 的 Copy 按钮

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: 在已有方法中添加 toast 参数，逻辑简单
  - **Skills**: None specific

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1 (with Tasks 1, 3)
  - **Blocks**: Task 4
  - **Blocked By**: None (Task 1 non-blocking, 可独立进行)

  **Acceptance Criteria**:
  - [ ] 仅剪贴板截图后，toast 显示带 "Copy" 按钮
  - [ ] 点击 "Copy" 按钮再次将图片复制到剪贴板
  - [ ] 再次复制成功后 toast 文本更新确认
  - [ ] 再次复制失败后 toast 显示错误（不是成功文本）
  - [ ] 普通截图（非仅剪贴板）流程不变，EditorView 底栏 Copy 按钮不受影响

  **QA Scenarios**:
  ```
  Scenario: 仅剪贴板截图显示带 action 的 toast
    Tool: interactive_bash (tmux)
    Preconditions: 运行 SnapGlass macOS app
    Steps:
      1. 触发仅剪贴板的区域截图（area capture with clipboard-only mode）
      2. 观察 toast 弹出
      3. 确认 toast 包含 "Copy" / "复制" 按钮
      4. 点击 "Copy" 按钮
      5. 确认 toast 文本更新为 "Copied again" / "已再次复制"
      6. 打开预览/任意 app 粘贴，确认图片在剪贴板中
    Expected Result: toast 含 action 按钮，再次复制成功
    Evidence: .sisyphus/evidence/task-2-copy-toast.txt (步骤记录)

  Scenario: 复制失败不报成功
    Tool: interactive_bash (tmux)
    Preconditions: 模拟粘贴板写入失败场景（如权限受限）
    Steps:
      1. 触发仅剪贴板截图
      2. 如果 pasteboard 写入失败，toast 应显示错误文本
      3. 确认不显示 "复制成功" / "Copied" 文本
    Expected Result: 失败时 toast 显示错误信息，非成功信息
    Evidence: .sisyphus/evidence/task-2-copy-failure.txt
  ```

  **Commit**: YES
  - Message: `feat(capture): add copy action button to screenshot confirmation toast`
  - Files: `CaptureViewModel.swift`

- [ ] 3. 条码复制行为定义 — 实现 0/1/N barcode 的 BarcodeCopyCandidate 扩展

  **What to do**:
  - 扩展 `BarcodeCopyCandidate` 枚举/结构，添加以下行为：
    - **0 条码**: 返回 `.none` / `nil`，调用方显示"未识别到条码"，不显示复制按钮
    - **1 条码**: 保持现有 `singlePayload()` 行为 — 返回唯一 payload，显示复制按钮
    - **N 条码 (N>1)**: 新增 `allPayloads()` 方法返回 `[String]`（每个 payload 独立），调用方逐条显示复制按钮 + "全部复制"按钮（join with newline）
  - 不改动 `EditorViewModel.scanBarcodes()` 的自动复制逻辑（保持向后兼容），但在结果展示层面添加复制按钮
  - 确保 text 和 image pasteboard 路径不被混合

  **Must NOT do**:
  - 移除现有自动复制行为（保持向后兼容）
  - 改变 pasteboard 类型（NSPasteboard.PasteboardType 分离保持不变）

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: 纯数据层扩展，无 UI 改动
  - **Skills**: None specific

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1 (with Tasks 1, 2)
  - **Blocks**: Task 4
  - **Blocked By**: None

  **Acceptance Criteria**:
  - [ ] `BarcodeCopyCandidate` 支持 `none`, `single`, `multiple` 三种情况
  - [ ] `allPayloads()` 返回数组，不与 `singlePayload()` 混淆
  - [ ] 现有调用点编译通过无改动

  **QA Scenarios**:
  ```
  Scenario: singlePayload 保持不变
    Tool: interactive_bash (tmux)
    Steps:
      1. swift build → 确认编译通过
      2. 运行现有单条码扫描测试
    Expected Result: 现有行为不变
    Evidence: .sisyphus/evidence/task-3-build.txt

  Scenario: allPayloads 返回正确数组
    Tool: interactive_bash (tmux)
    Steps:
      1. swift test --filter BarcodeCopyCandidate
    Expected Result: 新增 allPayloads 测试通过
    Evidence: .sisyphus/evidence/task-3-test.txt
  ```

  **Commit**: YES
  - Message: `feat(barcode): define 0/1/N copy candidate behavior`
  - Files: `BarcodeCopyCandidate` 相关文件

- [ ] 4. 条码结果视图添加复制按钮

  **What to do**:
  - 找到显示条码识别结果的视图（位于 `ToolPickerView` 附近或 `EditorView` 内）
  - 根据 `BarcodeCopyCandidate` 的 0/1/N 状态条件渲染：
    - **0 条码**: 显示 "No barcode found" / "未识别到条码"，无复制按钮
    - **1 条码**: 显示 payload 文本 + 一个 "Copy" / "复制" 按钮
    - **N 条码**: 每条 payload 显示独立 "Copy" 按钮 + 底部 "Copy All" / "全部复制" 按钮
  - 单个 "Copy" 按钮 handler: 调用 `NSPasteboard` 将 payload 写入 text pasteboard
  - "Copy All" handler: `payloads.joined(separator: "\n")` 写入 pasteboard
  - 复制成功后显示简短 toast（复用 Task 1/2 的 toast 系统）
  - 复制失败显示错误 toast

  **Must NOT do**:
  - 改变 `EditorViewModel.scanBarcodes()` 的自动复制逻辑
  - 添加新的 UI 覆盖层/面板
  - 改动 ToolPickerView 布局结构

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: 在现有视图中添加条件按钮，逻辑简单
  - **Skills**: None specific (SwiftUI 原生按钮)

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2 (with Tasks 5, 6)
  - **Blocks**: None
  - **Blocked By**: Tasks 1, 3

  **Acceptance Criteria**:
  - [ ] 零条码: 显示 No barcode found，无复制按钮
  - [ ] 单条码: 显示 payload + Copy 按钮，点击后 payload 进入剪贴板，toast 确认
  - [ ] 多条码: 每条显示 payload + Copy 按钮，还有 Copy All 按钮
  - [ ] Copy All 把全部 payload 以换行连接写入剪贴板
  - [ ] 复制失败显示错误 toast
  - [ ] 按钮使用 `LocalizedStringKey` 做 en/zh-Hans 本地化

  **QA Scenarios**:
  ```
  Scenario: 单条码复制
    Tool: interactive_bash (tmux)
    Preconditions: 准备含一个 QR code 的截图
    Steps:
      1. 运行 app，打开含单条码的截图
      2. 点击 ToolPickerView 的条码扫描按钮
      3. 确认结果显示单条 payload + Copy 按钮
      4. 点击 Copy 按钮
      5. 粘贴到文本编辑器，确认 payload 正确
      6. 确认 toast 显示 "Copied" / "已复制"
    Expected Result: payload 正确写入剪贴板
    Evidence: .sisyphus/evidence/task-4-single-barcode.txt

  Scenario: 多条码复制
    Tool: interactive_bash (tmux)
    Preconditions: 准备含多个条码的截图
    Steps:
      1. 打开含多条码的截图
      2. 点击条码扫描按钮
      3. 确认显示多条 payload + 每条有 Copy 按钮 + Copy All 按钮
      4. 点击某一条的 Copy 按钮，粘贴确认内容
      5. 点击 Copy All，粘贴确认全部内容（换行分隔）
    Expected Result: 单条和全部复制均正确
    Evidence: .sisyphus/evidence/task-4-multi-barcode.txt

  Scenario: 零条码
    Tool: interactive_bash (tmux)
    Preconditions: 准备不含条码的普通截图
    Steps:
      1. 打开无条码截图
      2. 点击条码扫描按钮
      3. 确认显示 "No barcode found" / "未识别到条码"
      4. 确认无 Copy 按钮出现
    Expected Result: 无复制按钮，显示无条码提示
    Evidence: .sisyphus/evidence/task-4-zero-barcode.txt
  ```

  **Commit**: YES
  - Message: `feat(barcode): add copy buttons to barcode results view`
  - Files: 条码结果视图文件

- [ ] 5. 复制失败处理 + 本地化

  **What to do**:
  - 审计所有 pasteboard 写入点（`CaptureViewModel.copyImageToClipboard()`、条码复制 handler）
  - 确保每次写入后检查返回值/clear 状态
  - 写入失败路径 → 显示错误 toast（"Copy failed" / "复制失败"），不显示成功 toast
  - 写入成功路径 → 显示成功 toast（"Copied" / "已复制"）
  - 添加/更新 en 和 zh-Hans 本地化字符串:
    ```
    "Copy" = "复制"
    "Copied" = "已复制"
    "Copied again" = "已再次复制"
    "Copy All" = "全部复制"
    "Copy failed" = "复制失败"
    "No barcode found" = "未识别到条码"
    ```
  - 如项目使用 `.xcstrings` String Catalog，更新对应条目；如使用 `.strings`，更新 `en.lproj/Localizable.strings` 和 `zh-Hans.lproj/Localizable.strings`

  **Must NOT do**:
  - 用 `print()` 替代 toast 显示错误
  - 硬编码中文字符串（必须用 `LocalizedStringKey` 或 `NSLocalizedString`）
  - 遗漏任何成功/失败 toast 的本地化

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: 添加 guard/if-else 和本地化字符串，纯机械操作
  - **Skills**: None specific

  **Parallelization**:
  - **Can Run In Parallel**: YES (可与 Task 4 并行，各自独立)
  - **Parallel Group**: Wave 2 (with Tasks 4, 6)
  - **Blocks**: None
  - **Blocked By**: Tasks 2, 3

  **Acceptance Criteria**:
  - [ ] 每条 pasteboard 写入路径都有失败处理
  - [ ] 所有用户可见字符串在 en 和 zh-Hans 中都有对应本地化
  - [ ] `grep -r '"Copy"' *.lproj/` 返回 en + zh-Hans 各一条
  - [ ] `grep -r '"No barcode found"' *.lproj/` 返回 en + zh-Hans 各一条

  **QA Scenarios**:
  ```
  Scenario: 本地化完整性
    Tool: Bash (grep)
    Steps:
      1. grep -r "复制" zh-Hans.lproj/
      2. grep -r "Copy" en.lproj/
      3. 确认所有新增字符串在两个文件中都存在
    Expected Result: 6 个键值对在 en 和 zh-Hans 中各有对应
    Evidence: .sisyphus/evidence/task-5-localization-check.txt
  ```

  **Commit**: YES
  - Message: `fix: ensure copy failure not reported as success; add localizations`
  - Files: 本地化文件, `CaptureViewModel.swift`, 条码视图文件

- [ ] 6. CHANGELOG 更新 + 最终验证

  **What to do**:
  - 在 `CHANGELOG.md` 顶部添加新版本条目:
    ```markdown
    ## [Unreleased]
    ### Added
    - Screenshot confirmation toast now shows a Copy action button for clipboard-only captures
    - Barcode results view now shows Copy buttons for single and multiple barcode payloads
    - Zero-barcode state: "No barcode found" message, no copy button
    ### Fixed
    - Copy failure no longer incorrectly reports as success
    ```
  - 运行最终验证:
    - `swift build` — 确认零错误零 warning
    - 运行 package tests: `swift test` — 确认全部通过
    - 手动验证 Task 2, 4 的 QA 场景（截图复制 + 条码复制）

  **Must NOT do**:
  - 修改已有 CHANGELOG 条目
  - 添加 `BREAKING CHANGES` 条目（本次无破坏性变更）

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: 文档更新 + 验证，无代码逻辑
  - **Skills**: None specific

  **Parallelization**:
  - **Can Run In Parallel**: YES (与 Task 4, 5 并行)
  - **Parallel Group**: Wave 2
  - **Blocks**: None
  - **Blocked By**: Tasks 1-5

  **Acceptance Criteria**:
  - [ ] CHANGELOG 含新条目（Added + Fixed）
  - [ ] `swift build` 通过
  - [ ] `swift test` 通过
  - [ ] 手动 QA 截图和条码复制按钮均正常

  **QA Scenarios**:
  ```
  Scenario: 构建验证
    Tool: Bash
    Steps:
      1. swift build 2>&1
      2. swift test 2>&1
    Expected Result: BUILD SUCCESS, ALL TESTS PASSED
    Evidence: .sisyphus/evidence/task-6-build-test.txt
  ```

  **Commit**: YES
  - Message: `docs(changelog): add copy button optimizations entry`
  - Files: `CHANGELOG.md`

---

## Final Verification Wave (MANDATORY — after ALL implementation tasks)

> 由于本次变更范围小（~4 文件），Final Verification 合并为一个验证步骤。

- [ ] F1. **综合验证** — `quick`
  1. `swift build` — 确认编译通过零 error 零 warning
  2. `swift test` — 确认全部 package tests 通过
  3. 手动验证截图复制 toast action 按钮（Task 2 QA）
  4. 手动验证条码 0/1/N 复制按钮（Task 4 QA）
  5. `grep -r "复制"` 确认所有中文字符串使用 `LocalizedStringKey`，非硬编码
  6. 检查 diff 确认无文件超范围修改

  Output: `Build [PASS/FAIL] | Tests [PASS/FAIL] | Screenshot QA [PASS/FAIL] | Barcode QA [PASS/FAIL] | Localization [PASS/FAIL] | Scope [CLEAN/DIRTY] | VERDICT`

---

## Commit Strategy

| # | Message | Files |
|---|---------|-------|
| 1 | `refactor(toast): add optional action button support` | toast 相关文件 |
| 2 | `feat(capture): add copy action button to screenshot confirmation toast` | `CaptureViewModel.swift` |
| 3 | `feat(barcode): define 0/1/N copy candidate behavior` | `BarcodeCopyCandidate` 相关文件 |
| 4 | `feat(barcode): add copy buttons to barcode results view` | 条码结果视图文件 |
| 5 | `fix: ensure copy failure not reported as success; add localizations` | 本地化文件, `CaptureViewModel.swift`, 条码视图文件 |
| 6 | `docs(changelog): add copy button optimizations entry` | `CHANGELOG.md` |

> 建议合并为 2-3 个逻辑 commit 后 squash merge:
> - Commit A: Toast + 截图复制按钮 (Tasks 1+2)
> - Commit B: 条码复制按钮 + 行为定义 (Tasks 3+4)
> - Commit C: 本地化 + CHANGELOG (Tasks 5+6)

---

## Success Criteria

### Verification Commands
```bash
swift build              # Expected: Build complete, 0 errors, 0 warnings
swift test               # Expected: All tests passed
```

### Final Checklist
- [ ] 截图复制 toast 含 action 按钮，可再次复制
- [ ] 条码结果 0/1/N 正确显示对应复制按钮
- [ ] 复制失败不报成功
- [ ] en + zh-Hans 本地化完整
- [ ] CHANGELOG 含条目
- [ ] 无新依赖、无 Package.swift 修改
- [ ] image/text pasteboard 路径保持分离

