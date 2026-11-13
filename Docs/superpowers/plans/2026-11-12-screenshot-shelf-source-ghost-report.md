# 截图架原位虚影 — 实施与清理报告

**日期：** 2026-11-12
**状态：** 代码与清理完成；静态检查与不启动应用的编译通过；**未运行任何测试/GUI**，待独立审查。
**分支：** `main`（未提交、未 push、未发版）
**当前方案：** `Docs/superpowers/plans/2026-11-12-screenshot-shelf-source-ghost.md`

---

## 1. 当前实现

拖动开始时源卡立即隐藏，原位显示同尺寸低透明缩略图 + 细虚线轮廓的 ghost；ghost 不参与点击、右键、拖动或拖放目标。本地拖动和原生 session 期间：

- 所有兄弟卡片不位移，不计算插入目标，不调用 `.move`；
- ghost 由稳定 `ghostCardID`（`dragPreview?.cardID ?? nativeDragCardID`）驱动，按 UUID 在当前 layout 中查源卡；卡被删除时 ghost 消失，不复活旧卡；
- 本地松手、Esc/无效释放、拖出后移回松手都保持原顺序，ghost 清除后原卡在原位恢复；
- 外部有效 drop 仍使用 `.copy` 源 mask，复制真实文件，架内卡保留；
- 右键/键盘的显式 move 未移除。

原生交接：

- `handOffDragToNative(cardID:) -> Bool` 先设置 `nativeDragCardID`，再清除 `dragPreview` 并隐藏本地 overlay；`.beginInteraction` 不在交接时重复调用，ghost 不会消失后再出现。handoff 失败不会启动 native；已有 native 身份时不启动第二个 session。
- `endNativeDrag()` 幂等清除 native 身份并释放 `.endInteraction` 恰好一次；`finishSession` 再调用 `endDrag()` 作为本地兜底（native 时 preview 已 nil，不会双释放）。session 用 `sessionGeneration` 校验，旧 `endedAt` 不影响新 session。
- `beginSession` 按 UUID 取当前 layout 的卡片尺寸；删除/非法几何回退 local。local cancel 用 `isLocalDragCancelled` 闩锁，`onEnded` 或新 mouseDown 复位。
- 取消/失败（`operation.isEmpty`）时在标准 `draggingSession(_:endedAt:operation:)` 回调里设 `session.animatesToStartingPositionsOnCancelOrFail = false`，避免系统把拖影滑回交接点；原卡由原位 ghost 清除后恢复。该选择基于 `NSDraggingSession.h` 的公开契约，UI 未实测。
- 删除 `ScreenshotShelfPanel` 的 `.fileURL` 注册和全部 dragging destination 覆写；原生 session 期间本应用没有自有回架 destination，走系统取消/外部 drop。
- 删除 `handle(.leftMouseUp)` 的提前 `handoffActive=false`；只保留 `.leftMouseDragged` 的 drag-out 检测。
- 不把 app 失活当取消；overlay 的既有 resign 观察者在 native 时 `dragPreview == nil`，不会结束 native session。

## 2. 精确改动范围

产品：

- `App/SnapGlass/Sources/ScreenshotShelf/ScreenshotShelfViewModel.swift`：移除 nativeReturn/目标提交；新增 `nativeDragCardID`、`ghostCardID`、`handOffDragToNative -> Bool`、`endNativeDrag`、`isLocalDragCancelled`、`cancelLocalDrag`、`resetLocalDragCancellation`；`beginDrag` 拒绝已有 local preview/native/取消闩锁；`updateDrag` 恢复简单 guard（旧同值去重回退）。
- `App/SnapGlass/Sources/ScreenshotShelf/ScreenshotShelfView.swift`：删除 `dropTargetIndex`、`siblingOffset`、`targetIndex`、`midpoint`、reorder 虚线框和拖动 `.move`；新增原位 `ScreenshotShelfSourceGhostView`；拖动中抑制所有卡片 hover；`onChanged`/`onEnded` guard native 与 local-cancel 闩锁；源卡 `isInteractive: false`。
- `App/SnapGlass/Sources/ScreenshotShelf/ScreenshotShelfDragOutController.swift`：删除 nativeReturn/来源授权/目标几何/动态 return destination；`ScreenshotShelfDraggingSource.onEnd` 传入 `NSDraggingSession` 与 operation；handoff 返回 Bool + `sessionGeneration` 身份；当前 layout 尺寸/非法几何回退；取消/失败关闭系统 slide-back；移除 `leftMouseUp` 提前清 handoff；`prepareForNewPointerDown` 复位 local 闩锁。
- `App/SnapGlass/Sources/ScreenshotShelf/ScreenshotShelfCardView.swift`：新增 `isInteractive`；ghost 源卡不挂 tap/context/accessibility actions，视觉与 contentShape 保留，外层 drag gesture 不动。
- `App/SnapGlass/Sources/ScreenshotShelf/ScreenshotShelfDragOverlayPanel.swift`：resign/space/卡缺失取消改用 `cancelLocalDrag()` 闩锁。
- `App/SnapGlass/Sources/ScreenshotShelf/ScreenshotShelfPanel.swift`：最终状态无 `.fileURL` 注册/dragging 覆写（旧未提交改动回退）；本 diff 为 `leftMouseDown` 闩锁复位 + 过时 “reorder” 注释修正。
- `CHANGELOG.md`：Unreleased 仅保留原位虚影/不排序/外部复制条目。

测试源（只编译，不运行）：

- `App/SnapGlass/EditorTests/ScreenshotShelfDragOutDecisionTests.swift`：保留 4 个 drag-out decision 测试，删除旧几何/授权测试。
- `App/SnapGlass/EditorTests/ScreenshotShelfDragPreviewTests.swift`：保留 3 个基础测试；新增 ghost handoff 持久/失败、native 期间禁止二次本地拖动、beginDrag 拒绝已有 local、local cancel 闩锁与复位、end 幂等、layout 变化仍按 UUID 保身份、当前宽度/非法几何等契约测试；删除旧 nativeReturn/dedup 断言。

文档：

- `Docs/superpowers/plans/2026-11-12-screenshot-shelf-source-ghost.md`（当前计划）
- `Docs/superpowers/plans/2026-11-12-screenshot-shelf-source-ghost-report.md`（本报告）

## 3. 清理与恢复

**归档目录：** `/Users/11169285/.Trash/SnapGlass-shelf-superseded-20261112-160622`

归档文件：

- `2026-11-12-screenshot-shelf-experience.md`
- `2026-11-12-screenshot-shelf-review.md`
- `2026-11-12-screenshot-shelf-ledger.md`
- `2026-11-12-screenshot-shelf-design-audit.md`
- `2026-11-12-screenshot-shelf-catcher-gate.md`
- `superseded-product.diff`（回退前的完整 `git diff`，可 `git apply` 恢复）

**已恢复到 HEAD 的无关改动：**

- `Packages/CaptureCore/Sources/ScreenshotShelfSessionDirectoryPolicy.swift` 的数字 UUID 修复——与 ghost 无关，已回退；旧 diff 在补丁中。
- `Packages/CaptureCore/Tests/CaptureCoreTests/ScreenshotShelfSessionDirectoryTests.swift` 对应测试——已回退。
- `ScreenshotShelfDragOverlayPanel.swift` 的 overlay 内容去重——当前 ghost 不需要，已回退；本文件当前 diff 仅 `cancelLocalDrag` 闩锁，不是 dedup。
- `ScreenshotShelfViewModel.updateDrag` 的同值去重——当前 ghost 不需要，已回退。

**保留：** 当前 ghost 实现、配套测试源、当前计划/报告、CHANGELOG 当前条目。旧 nativeReturn/目标几何/return destination/相关测试断言已从工作区移除；旧代码文件仍在仓库，以当前正确实现为准；旧差异只在 Trash 补丁中。

未移动：临时工程/DerivedData、`.git`、`.memory`、配置、11-03/08/09 历史计划。

## 4. 静态检查与编译证据

| 检查 | 命令/结果 | 退出 |
|---|---|---|
| diff 空白检查 | `git diff --check` | 0 |
| SwiftLint | `swiftlint lint --config .swiftlint.yml`（8 个改动 Swift 文件）；`Found 0 violations, 0 serious in 8 files.`（仅有既存 analyzer 配置提示） | 0 |
| App 编译 | `xcodebuild build -project .../SnapGlass.xcodeproj -scheme SnapGlass -destination 'platform=macOS,arch=arm64' -derivedDataPath .../snapglass-shelf-baseline-fresh-20261112 CODE_SIGNING_ALLOWED=NO` | **0**；日志末尾 `** BUILD SUCCEEDED **` |
| 测试 target 编译（不运行） | `xcodebuild build -project ... -scheme EditorInteractionTests -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath ... CODE_SIGNING_ALLOWED=NO` | **0**；日志末尾 `** BUILD SUCCEEDED **` |

原始日志：

- `/private/var/folders/ks/flqyrh0j5wvf2t7v4s7lcnz0b5tfzv/T/opencode/snapglass-source-ghost-build.log`
- `/private/var/folders/ks/flqyrh0j5wvf2t7v4s7lcnz0b5tfzv/T/opencode/snapglass-source-ghost-test-target-build.log`

App build 有 2 条既存 warning（SwiftLint analyzer 配置提示、AppIntents metadata）；测试 target build 有既存 import/linker/deployment/AppIntents warning。两者均无新的源码 error，退出码均为 0。

未执行：`xcodebuild test`、`swift test`、任何 xctest、任何应用启动、GUI、截图、录屏、Instruments、LaunchServices、安装、杀进程。

## 5. 最终工作区

`git status --porcelain` 仅含：

```
 M App/SnapGlass/EditorTests/ScreenshotShelfDragOutDecisionTests.swift
 M App/SnapGlass/EditorTests/ScreenshotShelfDragPreviewTests.swift
 M App/SnapGlass/Sources/ScreenshotShelf/ScreenshotShelfCardView.swift
 M App/SnapGlass/Sources/ScreenshotShelf/ScreenshotShelfDragOutController.swift
 M App/SnapGlass/Sources/ScreenshotShelf/ScreenshotShelfDragOverlayPanel.swift
 M App/SnapGlass/Sources/ScreenshotShelf/ScreenshotShelfPanel.swift
 M App/SnapGlass/Sources/ScreenshotShelf/ScreenshotShelfView.swift
 M App/SnapGlass/Sources/ScreenshotShelf/ScreenshotShelfViewModel.swift
 M CHANGELOG.md
?? Docs/superpowers/plans/2026-11-12-screenshot-shelf-source-ghost.md
```

（本报告创建后会多一条未跟踪的 `2026-11-12-screenshot-shelf-source-ghost-report.md`。）

未提交、未 push、未发版。

## 6. 未验证 / 残余风险

- 未运行任何测试；测试源只参与编译，不代表行为通过。
- 未启动应用或做任何窗口/GUI 验证；以下均未实测：
  - ghost 的低透明度、虚线轮廓、尺寸和源位对齐；
  - 拖动开始/结束、本地松手、Esc/无效释放的视觉连续性；
  - 原生 session 交接时 drag image 与 ghost 的相对位置（当前宽度、冻结指针 delta 的实际观感）；
  - session generation 在实际 AppKit 回调顺序下的行为；
  - `animatesToStartingPositionsOnCancelOrFail = false` 的实际取消动画效果；
  - `ScreenshotShelfCardView` 的 `isInteractive` 分支切换是否影响正在进行的 SwiftUI gesture；
  - 拖出后移回松手、外部 Finder/浏览器 drop、跨应用兼容；
  - app 失活/切 Space、新截图入架、拖动中删除卡、右屏/多屏；
  - hover 抑制和右键/键盘 move 的交互组合。
- 未引用此前 114/285 基线来证明本次实现；它们与本次行为无关。
- 不声称“根治闪烁”或“UI 已验收”；当前状态是**可编译、待独立审查**。

---

## 7. 独立审查（2026-11-12，只读静态复核）

**审查范围：** 当前 `source-ghost.md`、本报告、`git diff`（7 tracked files，+212/−120），以及相关 HEAD/当前源文件。未读取已移 Trash 的旧计划；未运行测试、构建、应用、GUI、窗口或性能采集；App 与测试 target 的 `BUILD SUCCEEDED` 日志按控制器提供接受，未重跑。以下“通过”均指静态代码契约，不代表运行时行为；UI 效果、AppKit 回调顺序、跨应用 drop 均未实测。

### 7.1 裁决

- **Spec compliance：主契约通过（conditional pass）。** 原位 ghost、低透明缩略图 + 虚线、拖动期间不排序/不移动兄弟/不计算 target/不调用拖动 `.move`、local→native 用稳定 UUID 续接、松手/取消/拖出后移回恢复原顺序、外部 `.copy`、无 catcher/nativeReturn、app 失活不取消 native，均能在代码中找到对应实现。
- **Quality：简洁、聚焦，适合保留。** 没有重新引入旧复杂状态机；建议先完成 4 个 Medium 硬化项，不需要新增 catcher、滞回、动态目标或时序动画。
- **未发现正常路径的 Critical/Blocker。** 下列 Medium 均为边缘/失败路径；Low 为清理、视觉或报告准确性问题。

### 7.2 逐项核对

| 规格 | 结果 | 证据 / 备注 |
|---|---|---|
| 拖动开始原位 ghost，低透明缩略图 + 细虚线 | **通过** | `ScreenshotShelfView.swift:44-58`、`:305-342`；圆角 8、opacity 0.30、虚线 1 pt |
| ghost 不可点击/右键/拖动/拖放目标 | **部分** | ghost 自身 `allowsHitTesting(false)`；但隐藏源卡仍可命中，见 Medium 4 |
| 全程不 hover 排序 | **通过** | `ScreenshotShelfView.swift:152` 在 `ghostCardID != nil` 时所有卡片 `isHovered = false` |
| 不让兄弟位移、不计算 target | **通过** | 删除 `siblingOffset`/`targetIndex`/`dropTargetIndex`；`grep` 在三个 shelf 源文件中无 target/reorder |
| 不调用拖动 `.move` | **通过** | `ScreenshotShelfView.swift:287-293` 只 `endDrag`；`.move` 仅保留在 context menu `:202-204` |
| local→native ghost 不闪断 | **通过（model 层）** | `ScreenshotShelfViewModel.swift:191-196` 先设 `nativeDragCardID` 再清 `dragPreview`；`ghostCardID` 始终为同一 UUID；overlay 只在之后隐藏 |
| 放下恢复原顺序 | **通过** | 拖动路径无 `.move`；native end 只 `endNativeDrag`/`endDrag`；顺序由 `state` 保持 |
| 外部 copy 保留 | **通过** | `ScreenshotShelfDragOutController.swift:34-39` 源 mask `.copy`；`ScreenshotShelfPanel.swift:32-34` 无 `.fileURL` destination |
| 稳定 UUID | **通过** | `ghostCardID` 由 `dragPreview?.cardID ?? nativeDragCardID`；view 按 UUID 查 index |
| native 期间禁止第二本地 drag | **通过** | `ScreenshotShelfViewModel.swift:169`、`ScreenshotShelfView.swift:271`、`:290`；测试 `ScreenshotShelfDragPreviewTests.swift:108-124` |
| interaction 幂等释放 | **通过** | `endNativeDrag`/`endDrag` guard；`finishSession` `handoffActive` guard；测试 `:77-106` |
| 卡删除不复活 | **通过（view）** | `ScreenshotShelfView.swift:46-48` 每次按 UUID 查当前 layout；找不到就不画；无缓存卡 |
| 不在 app 失活时取消 native | **通过** | `ScreenshotShelfDragOverlayPanel.swift:135-141` 只在 `dragPreview != nil` 时 `endDrag`；native 交接后 preview 已 nil |
| 当前 layout width | **部分** | ghost 用 `layout.cardWidths[index]`；native/local preview 仍用冻结 `preview.width`，见 Medium 2 |
| native failure 关闭系统回弹 | **通过（静态契约）** | `ScreenshotShelfDragOutController.swift:226-231` 在 `endedAt` 设 `animatesToStartingPositionsOnCancelOrFail = false`；`NSDraggingSession.h:26-28` 明确该回调是合适时点 |
| session 生命周期 | **部分** | 无 handoff 返回值检查、无当前 `NSDraggingSession` 身份校验，见 Medium 1 |
| 旧代码清理、不丢 HEAD 功能 | **通过（net）** | 无 nativeReturn/catcher/target；CaptureCore/overlay dedup 无 diff；context move 保留；local reorder 是本次批准移除 |
| 测试源合理 | **部分** | 模型契约测试合理；无 view/hit-test/删除/宽度/失败路径测试；只编译，不称通过，见 7.4 |

### 7.3 Medium（按真实用户影响）

#### Medium 1 — native handoff/session 身份未校验，失败路径可能卡住 ghost/interaction

**位置：** `ScreenshotShelfDragOutController.swift:191-219`（`handoffActive = true` → `model.handOffDragToNative`（void）→ `_ = view.beginDraggingSession`）；`:222-237`（`finishSession` 只检查 `handoffActive`，不检查 session 身份）。`ScreenshotShelfViewModel.swift:191-196` 的 handoff 也可能因 cardID 不匹配/已有 native ID 而静默返回。

**真实影响：** 正常单会话路径下不会触发；但一旦 handoff 静默失败，native session 仍会启动，模型可能停留 local；若 session 启动失败或旧 session 的 `endedAt` 迟到，ghost/`.beginInteraction` 可能无人清理，或被错误的 session 清掉。用户看到 ghost 不消失、架体保持交互锁定，通常只能重启应用恢复。属于生命周期硬化，不是已观察到的正常路径 bug。

**最小修法：**
- `handOffDragToNative` 返回 `Bool`；`beginSession` 只在 `true` 时继续启动 native。
- 保存 `beginDraggingSession` 返回的 `NSDraggingSession`；`finishSession` 先校验 `session === currentSession`，再清理。
- handoff 失败时走一条明确的 rollback：`model.endNativeDrag()` + `model.endDrag()` + 光标复位；不要加 catcher 或计时器。

#### Medium 2 — native 交接仍使用冻结的 `preview.width/startX`，与 ghost 的当前 layout 不一致

**位置：** `ScreenshotShelfDragOutController.swift:195`（`cardSize` 用 `preview.width`）、`:247`（frame 用 `preview.startX + translation`）、`:269`（宽度用 `preview.width`）；ghost 用 `ScreenshotShelfView.swift:49-55` 的当前 `layout.cardWidths[index]`/`startX`；local overlay 也用 `ScreenshotShelfDragOverlayPanel.swift:157,168,177` 的 `preview` 值。

**真实影响：** 拖动期间新截图入架、偏好变化或布局宽度变化时，ghost 已按当前卡片宽度/槽位绘制，但 local overlay/native drag image 仍按拖动开始时的宽度与 `startX`。交接时可能出现宽度或水平位置跳变；严重度取决于新布局是否在拖动中到达，属于中等边缘。

**最小修法：** 在 `beginSession` 按 UUID 重新解析当前 index，使用 `model.layout.cardWidths[index]` 与当前 `startX(for:)` 计算 `cardSize`/`draggingFrame`；或在 layout 变化时更新 `preview.startX/width`。加一个纯几何测试覆盖“宽度变化后交接 frame 使用当前值”。不需要冻结整个 presentation，也不需要旧 catcher。

#### Medium 3 — local cancel 后，仍活跃的 SwiftUI 手势可能重新 beginDrag

**位置：** `ScreenshotShelfDragOverlayPanel.swift:135-141`（app resign/space change 时 `endDrag`）、`:148-153`（卡片缺失时 `endDrag`）；`ScreenshotShelfView.swift:268-292` 的 `onChanged` 在 `dragPreview == nil && nativeDragCardID == nil` 时会再次 `beginDrag`。

**真实影响：** local 拖动期间 app 失活/切 Space 或卡片缺失，overlay 会清掉 preview；如果 SwiftUI 的拖动手势仍然活跃，下一次 `onChanged` 会重新建立 ghost 和 interaction。native 路径不受影响（preview 已 nil，overlay 不会 `endDrag`），但 local 取消会出现“ghost 又回来”的边缘。未做 GUI，无法确认手势是否继续；静态上缺少抑制闩锁。

**最小修法：** 加一个 `dragCancelled`/`suppressLocalDragUntilEnded` 标志：overlay cancel/`endDrag` 置位，`onChanged` 检查，`onEnded` 清除；或让 overlay cancel 不直接 `endDrag`，交给手势 `onEnded`。同时给 `beginDrag` 加 `dragPreview == nil` guard。不要用时序动画。

#### Medium 4 — ghost 自身不可命中，但隐藏源卡仍可点击/右键

**位置：** `ScreenshotShelfView.swift:155-164` 只用 `.opacity(0)` + `.accessibilityHidden`，仍保留 `.gesture`；`ScreenshotShelfCardView.swift:54-69` 仍有 `onTapGesture`、`contextMenu`、accessibility actions；ghost 在 `ScreenshotShelfView.swift:339` `allowsHitTesting(false)`。

**真实影响：** SwiftUI 的 `.opacity(0)` 不会自动关闭 hit testing；ghost 区域的点击/右键会落到隐藏源卡，可能打开编辑/复制/删除菜单或触发 tap。左侧拖动期间，隐藏卡必须保持可命中以承接当前 `.gesture`，所以不能简单把整张卡 `.allowsHitTesting(false)`（可能中断正在进行的手势）。这是“ghost 不可点击/右键”字面要求与“手势需要源视图”之间的折中；用户实际触发概率低，但静态上未闭环。

**最小修法：** 给 `ScreenshotShelfCardView` 增加 `isSourceGhost`/`isInteractive` 参数，在 ghost 期间只跳过 tap/context/accessibility actions（保留外层拖动手势）；或用一个透明 gesture proxy 承接手势、卡本体禁用交互。不要直接禁用整张卡而不验证正在进行的 drag。

### 7.4 Low 与验证缺口

- **Low — `beginDrag` 不拒绝已存在的 local preview。** `ScreenshotShelfViewModel.swift:168-181` 只 guard `nativeDragCardID == nil`；view 的 `dragPreview == nil` 检查能挡住正常路径，但 model API 仍可被第二次调用覆盖 preview/重复 `.beginInteraction`。加 `dragPreview == nil` guard；补一个模型测试。
- **Low — `ScreenshotShelfDragPreview.startIndex` 已是死状态。** 排序删除后只在 `beginDrag`/测试中传递；产品无读取。删除字段与参数，减少状态面。
- **Low — native 结束后可能用 stale pointer 恢复 hover。** `finishSession`/`endNativeDrag` 不清 `pointerLocation`；`ScreenshotShelfView.swift:152` 只在 ghost 期间强制 `isHovered = false`。若 native 期间没有收到 `mouseExited`，外部 drop 后源卡可能在错误位置显示 hover tilt。UI 未验证；可在 handoff/end 清 pointer，或要求新的 `mouseMoved` 才恢复 hover。
- **Low — mockup ghost 用了 `scaledToFill`。** `ScreenshotShelfView.swift:321-327` 对 mockup 会裁剪，而真实卡片 `ScreenshotShelfCardView.swift:113-119` 用 `scaledToFit` + `.quaternary` 背景。低透明 ghost 的差异较小；如需一致，按 `card.isMockup` 选择 fit/fill。
- **Low — 报告对 Panel 改动的描述偏大。** 本报告 §1/§2 说“删除 `.fileURL` 注册和全部 dragging 覆写”，但最终 `ScreenshotShelfPanel.swift` 的 diff 只有注释；这些注册/覆写本就不在 HEAD，是旧未提交改动被回退。net 结果正确，建议改成“最终状态无注册/覆写；本 diff 仅注释”，避免把回退说成产品改动。
- **验证缺口 — 测试只覆盖模型，不代表 ghost 行为。** `ScreenshotShelfDragPreviewTests.swift:77-160` 覆盖 handoff 连续性、native 期间禁止第二 local、endNative 幂等、UUID 跨 layout；没有覆盖 `beginDrag` 二次 local、handoff cardID 不匹配、session 身份/失败、删除后 ghost 不画、当前宽度交接、实际 hit-test/hover。测试 target 只编译，不能声称通过。建议补纯模型测试 + 一个纯几何 frame 测试；view/hit-test 只能靠人工验收。

### 7.5 优点与未丢失的 HEAD 功能

- `handOffDragToNative` 先写 `nativeDragCardID` 再清 `dragPreview`，`ghostCardID` 在两步之间仍是同一 UUID；overlay 随后隐藏。model 层没有 ghost 空窗。
- 拖动路径完全移除了 target/reorder/`.move`；context menu 的 Move Left/Right 仍在 `ScreenshotShelfCardView.swift:196-204`，键盘 focus 逻辑未动；没有把既有显式移动功能一起删掉。
- 源卡保留在 HStack 中（只 opacity 0），兄弟不位移；ghost 按当前 layout 的 UUID/index 绘制，不缓存卡、不复活删除卡。
- `finishSession` 的 `handoffActive` guard 与 `endNativeDrag`/`endDrag` 的 guard 保证 native interaction 只释放一次；测试覆盖。
- `.copy` 源 mask 和无 destination 注册保留外部复制；`animatesToStartingPositionsOnCancelOrFail` 按 `NSDraggingSession.h` 的公开契约在 `endedAt` 设置，静态上正确。
- 清理范围：无 CaptureCore/overlay dedup diff、无 nativeReturn/catcher/target；旧 local reorder 的移除是本次批准的行为变更，不是意外丢功能。

### 7.6 未验证 / 残余风险

- ghost 的 0.30 透明度、虚线对比度、圆角/源位对齐；local overlay 到 native image 的视觉连续性；native `endedAt` 与系统拖影移除的先后；取消回弹是否真的被抑制。
- 外部 Finder/浏览器 copy、拖出后移回松手、Esc/无效释放、app 失活/切 Space、全屏、多屏、新截图入架、拖动中删除卡、右键/点击 ghost、hover 恢复。
- 测试未运行；App/test target 只编译；无 GUI/窗口/性能证据。
- 以上不能由静态代码证明“无闪烁”；最终仍需用户人工拖动验收。

### 7.7 最小接受清单

1. Medium 1：handoff 返回 Bool + session 身份校验 + 失败 rollback。
2. Medium 2：handoff 时按 UUID 使用当前 layout 宽度/起点（或更新 preview）。
3. Medium 3：local cancel 闩锁 + `beginDrag` 拒绝已有 local preview。
4. Medium 4：ghost 期间禁用源卡 tap/context（保留外层拖动）。
5. Low：清 stale pointer、删除 `startIndex`、mockup ghost fit、修正报告 Panel 措辞。
6. 测试：补上述模型/几何用例；view/hit-test 留人工；不要新增 catcher/滞回/动态目标/时序动画。

**结论：当前简化 ghost 方案的主契约成立，代码结构比旧方案简单且可维护；在完成 Medium 1-4 的硬化与对应静态测试后，可进入人工验收。当前不能声称 UI 已通过，也未发现需要推翻简化方案的理由。**

## 8. 四 Medium 定点修正结果（2026-11-12）

### 8.1 Medium 1 — handoff/session 身份

**采纳并实现。**

- `ScreenshotShelfViewModel.handOffDragToNative(cardID:)` 现在返回 `Bool`；只有 cardID 匹配且没有 native 身份时返回 true。
- `ScreenshotShelfDragOutController.beginSession` 只有 handoff 成功才设置 `handoffActive`；失败时若当前没有 native 身份，`rollbackLocalHandoff()` 结束 local preview/interaction；若已有 native 身份，不启动第二个 session，也不杀当前 session。
- 控制器新增 `sessionGeneration`：在 `beginDraggingSession` 前递增并由 source 闭包捕获；`finishSession(session:operation:generation:)` 校验 `handoffActive && generation == sessionGeneration`。旧 session 的迟到 `endedAt` 不会清理新 session；同步 `endedAt` 也能匹配，因为 generation 在启动前已确定。
- 未引入 `activeSession`/`willBegin` 状态机；generation 是本次最小身份。

**测试源：** `handOffRejectsAMismatchedOrRepeatedCard` 覆盖失败/重复；`handOffKeeps...` 覆盖成功与一次释放。只编译，不运行。

### 8.2 Medium 2 — 当前 layout 几何

**部分采纳，位置部分按代码证据保留。**

- 采纳：`beginSession` 按 UUID 重新查当前 index，使用 `ScreenshotShelfNativeDragGeometry.cardSize(at:layout:)` 的当前 `cardWidths[index]`/`cardHeight`；卡删除、index 越界、宽高非有限/非正直接 `rollbackLocalHandoff()`，不启动 native。
- 采纳：drag image 的 `cardSize` 与 item frame 使用同一个当前宽度/高度；抓取点 clamp 到当前宽/高，宽度缩小时不越界。
- **保留：image origin 仍用冻结的 `preview.startX + preview.translation`。** 依据是 `ScreenshotShelfDragOverlayPanel.swift` 的 local overlay 位置就是 `preview.startX + preview.translation`；native image 必须替换正在隐藏的 overlay 才不跳。若按当前 `startX` 重算 origin，新截图插入导致源卡槽位右移时，image 会从指针处弹到新槽位，违反“抓取点合理不跳”。当前 layout 的 `startX` 由 view 的 ghost 槽位使用；这里明确区分“冻结指针 delta”与“当前几何尺寸/身份”。
- **测试源：** `nativeDragUsesCurrentCardSizeAndRejectsInvalidGeometry` 覆盖当前宽度/高度与非法几何；只编译，不运行。

### 8.3 Medium 3 — local cancel 闩锁

**采纳并实现。**

- 模型新增 `isLocalDragCancelled`；`cancelLocalDrag()` 置闩锁、清 preview、释放 interaction；`endDrag()` 清 preview 并复位闩锁；`beginDrag` guard `dragPreview == nil && nativeDragCardID == nil && !isLocalDragCancelled`。
- overlay 的 resign/space/卡缺失取消改调 `cancelLocalDrag()`；view 的 `onChanged` guard 闩锁，`onEnded` 调 `endDrag()` 复位。
- `ScreenshotShelfPanel.sendEvent(.leftMouseDown)` 调 `dragOutController.prepareForNewPointerDown()` 复位；这是新 mouseDown 复位，不是全局事件监听或计时器。下一次合法拖动不会被永久阻止。
- **测试源：** `localCancelLatchesUntilTheGestureEndsOrANewPointerDown`、`beginDragRejectsAnExistingLocalPreview`；只编译，不运行。

### 8.4 Medium 4 — ghost 源卡交互

**采纳并实现，保留外层 drag gesture。**

- `ScreenshotShelfCardView` 新增 `isInteractive: Bool = true`；`true` 分支保留 tap/context/accessibility actions，`false` 分支只保留视觉与 contentShape。
- `ScreenshotShelfView` 对 `ghostCardID == card.captureID` 传 `isInteractive: false`；外层 `.gesture(dragGesture)` 仍在父视图，未把整张卡 `.allowsHitTesting(false)`，避免直接禁用正在进行的 gesture。
- 其他卡片在 native 期间保持原交互，未扩大 scope；context menu 的 Move Left/Right 和键盘 focus 未动。
- **未验证：** SwiftUI body 分支切换是否会影响正在进行的 gesture；按静态结构外层 gesture 保留，UI 未实测。

### 8.5 Low 与验证缺口处置

- 已修：`beginDrag` 拒绝已有 local preview；`handOff` 失败/重复测试；报告 Panel 措辞已改为“最终状态无注册/覆写；本 diff 为 mouseDown 复位 + 注释”。
- 未修（记风险，避免扩大）：`ScreenshotShelfDragPreview.startIndex` 仍是死状态；native 结束后 stale `pointerLocation` 可能恢复错误 hover；mockup ghost 仍用 `scaledToFill` 而非 `scaledToFit`。这些不影响本次 4 Medium 的正确性边界。
- 测试只覆盖模型/几何；view/hit-test/hover/实际 gesture 连续性仍只能人工验收。

### 8.6 本轮验证

- `git diff --check` exit 0。
- SwiftLint 8 个改动 Swift 文件：`Found 0 violations, 0 serious in 8 files.`，exit 0（仅有既存 analyzer 配置提示）。
- App build exit 0，日志 `.../snapglass-source-ghost-build.log` 末尾 `** BUILD SUCCEEDED **`。
- EditorInteractionTests target build exit 0，日志 `.../snapglass-source-ghost-test-target-build.log` 末尾 `** BUILD SUCCEEDED **`。
- **未运行**任何 `xcodebuild test`、`swift test`、xctest、应用、GUI、窗口、Instruments。
- 结论：四个 Medium 的代码边界已落地并可编译；UI/回调时序未实测，待独立审查与人工验收。

## 9. 四 Medium 独立复核（2026-11-12，只读静态）

**范围：** 只复核 §8 的 M1-M4 及这些修正的直接回归；未重跑构建/测试/GUI，不引用旧 114/285 作为新行为证据，未改产品代码。

**总评：** 四项均有代码落地，静态质量通过；未发现正常路径阻塞。一个窄回归：M1 新增的 `rollbackLocalHandoff()` 在 native 为 nil 时调用 `model.endDrag()` 而非 `model.cancelLocalDrag()`，会清掉 M3 的 local-cancel 闩锁；仅当非法几何/卡删除/handoff 失败时，仍活跃的 SwiftUI 手势可能再次 `beginDrag`。一行改为 `cancelLocalDrag()`（native nil 时），并补一个模型断言即可；不影响正常路径。

| 项 | 状态 | 证据 / 结论 |
|---|---|---|
| M1 | **Addressed** | `handOffDragToNative` 返回 Bool（`ViewModel:195-202`）；`beginSession` 只有成功才 `handoffActive` 并启动（`Controller:246-273`）；`sessionGeneration` + `finishSession:288` 防旧/迟到回调；失败分支 `rollbackLocalHandoff`；测试 `handOffRejectsAMismatchedOrRepeatedCard`。残余：`beginDraggingSession` 无失败返回值，session 启动失败仍无兜底；非本次回归，UI 未验证。 |
| M2 | **Addressed** | `beginSession:209-225` 按 UUID 取当前 index / `cardSize`；`ScreenshotShelfNativeDragGeometry` 校验宽高有限且 >0；非法/删除走 rollback；`draggingFrame:318-338` 使用当前宽高并 clamp 抓取点；origin 保留冻结 `preview.startX + translation` 与 local overlay 替换点一致，静态上不跳槽。测试只覆盖 `cardSize`，未直接覆盖 frame/clamp，属验证缺口非失败。 |
| M3 | **Addressed（指定取消路径）** | `cancelLocalDrag` 置闩锁（`ViewModel:212-220`）；`beginDrag` guard `dragPreview/native/latch`（`:173`）；view `onChanged/onEnded` 守卫（`View:273,289-294`）；panel 新 `leftMouseDown` 复位（`Panel:46-48`）；native 失活时 preview 已 nil，overlay 不会 cancel。直接回归见上：rollback 走 `endDrag` 绕过闩锁。 |
| M4 | **Addressed** | `ScreenshotShelfCardView.isInteractive` 分支（`:25-55`）；源卡传 false（`View:207`）；false 分支只保留 `cardSurface`/contentShape，tap/context/accessibility actions 被移除；外层 `.gesture` 仍在父视图（`View:164`），未整卡 `allowsHitTesting(false)`；兄弟卡仍 true。UI 手势连续性未实测。 |

**直接回归（唯一）：** `ScreenshotShelfDragOutController.rollbackLocalHandoff()`（`:276-281`）使用 `endDrag()`；`endDrag` 会复位 `isLocalDragCancelled`。如果 `beginSession` 因非法 geometry、卡删除或 handoff 失败走 rollback，而鼠标仍未释放，下一次 `onChanged` 会通过 `beginDrag` 重新开始 local drag。最小修法：native nil 时改用 `model.cancelLocalDrag()`（保留闩锁），弹起/新 mouseDown 再复位；不要新增计时器或状态机。

**其他静态核对：**
- M1 同步 `endedAt` 在 generation 确定后才启动；旧 generation 回调被 guard 丢弃；`endNativeDrag`/`endDrag` 仍有幂等 guard，没有双释放。
- M2 固定抓取点以当前宽高 clamp；若当前宽度缩小，图像仍在指针下，不跳到 ghost 槽位；ghost 仍用当前 layout。没有新增 target/排序/位移。
- M3 的闩锁只影响 local；native 跨应用失活不 cancel；新 mouseDown 与 `onEnded` 都能复位；测试 `localCancel...`/`beginDragRejects...` 覆盖模型层。
- M4 源卡仍可承接外层 drag gesture；tap/context/accessibility 已移除；其他卡片交互未变；context move 保留。
- 测试/构建未运行；App 与测试 target 的 `BUILD SUCCEEDED` 日志按提供证据接受；UI、gesture 连续性、真实 drag 回调顺序仍未验证。未发现需要扩大范围的新问题。

**静态结论：** M1/M2/M3/M4 的代码边界均成立；只有一个窄 rollback 回归，建议接受前一行的最小修正。静态质量通过，运行时体验未验证；不需要 catcher/动态排序/ghost 移位。

## 10. 最终 rollback 闩锁修正（2026-11-12）

**发现（报告 §9）：** `rollbackLocalHandoff()` 在 native 为 nil 时调用 `model.endDrag()`；`endDrag()` 会复位 `isLocalDragCancelled`，鼠标仍按下时同一 SwiftUI 手势可再次 `beginDrag`。

**修正：**

- `ScreenshotShelfDragOutController.rollbackLocalHandoff()` 在 native 为 nil 时改调 `model.cancelLocalDrag()`；native 非 nil 时不动当前合法 session。
- `beginSession` 的 handoff 失败分支统一走 `rollbackLocalHandoff()`，不再重复 `endDrag`。
- `ScreenshotShelfViewModel.cancelLocalDrag()` 先置 `isLocalDragCancelled = true`，再做 `dragPreview` guard：preview 已 nil 时仍保住“同次手势不得重启”，但不会凭空释放 interaction；有 preview 时仍释放一次。
- 复位路径保持：`endDrag()`（`onEnded`）与 `ScreenshotShelfPanel` 的新 `leftMouseDown` 都清闩锁；native 非 nil 的 rollback 不碰当前 session。

**契约测试源（只编译，不运行）：**

- `cancelWithoutAPreviewStillLatchesWithoutReleasingInteraction`：preview nil 时 cancel 置闩锁、无 interaction 释放；endDrag 复位后允许新拖动。
- `cancelThenGestureEndResetsLatchAndAllowsTheNextDrag`：cancel 后同一手势的 begin 被拒，`endDrag` 后允许下一次合法拖动，interaction 只释放一次。
- 既有 `localCancelLatchesUntilTheGestureEndsOrANewPointerDown`、`beginDragRejectsAnExistingLocalPreview` 仍覆盖主路径。

**验证（只静态/编译）：**

- `git diff --check` exit 0。
- targeted SwiftLint 3 个改动文件：`Found 0 violations, 0 serious in 3 files.`，exit 0。
- App build exit 0，`.../snapglass-source-ghost-build.log` 末尾 `** BUILD SUCCEEDED **`。
- EditorInteractionTests target build exit 0，`.../snapglass-source-ghost-test-target-build.log` 末尾 `** BUILD SUCCEEDED **`。
- 未运行 `xcodebuild test`、`swift test`、xctest、应用、GUI、窗口或 Instruments；不声称测试通过。

**结论：** rollback 失败路径现在保留 local-cancel 闩锁，ghost 清除、原卡恢复，同次手势不重启；native 非 nil 的合法 session 不被误结束。该修正只影响失败/非法几何路径，正常路径不变；待最终静态复核。

## 11. 发版准备补充核验（2026-11-12）

- 修复分支从 `main` 创建，当前修复与原工作区的跟踪文件差异逐字节一致。
- `ScreenshotShelfDragPreviewTests` 与 `ScreenshotShelfDragOutDecisionTests` 共 16 项通过；仅运行这两个模型/决策套件，不涉及窗口操作测试。
- `Packages/CaptureCore` 全量 284 项通过；应用 Debug 构建通过；变更 Swift 文件严格 SwiftLint 与本地化检查通过。
- 未运行窗口交互测试，实际拖拽视觉、闪烁、多显示器及跨应用拖放仍未验收。
- 现有 `main` 分支保护要求 GitHub CI 的 `unit-test` 检查；该检查包含会调用 `NSWindow.orderFront` 的窗口生命周期测试。在用户禁止窗口测试的限制下，尚未触发远端 CI。
