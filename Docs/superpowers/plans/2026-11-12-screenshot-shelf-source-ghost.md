# Screenshot Shelf — 原位虚影极简方案

**日期：** 2026-11-12
**状态：** 已批准，最小实施中；取代此前的 nativeReturn / 动态回架 / catcher 方案。
**范围：** `App/SnapGlass/Sources/ScreenshotShelf` 现有相关文件 + 对应测试源；不改配置、依赖、权限、API 或其他模块。
**验证边界：** 不运行测试、不启动应用、不做 GUI/窗口/Instruments；只做静态 diff 检查与不启动应用的编译。

## 目标

拖动开始时，原卡片位置立即变成一个**同尺寸低透明缩略图 + 细虚线轮廓**的 ghost；ghost 不可点击、不可右键、不可拖动、不作为拖放目标。整个拖动会话中 ghost 始终在源位，所有兄弟卡片不位移，不计算 hover/插入目标，不排序。松手、Esc、无效释放、拖出后移回再松手，都恢复原顺序和原卡；外部有效 drop 仍复制真实文件并保留架内卡。右键/键盘的显式 move 保留。

## 非目标

- 不新增 catcher、回架 drop destination、目标几何、宽限计时、轮询或多 phase 架构。
- 不修改截图架排序算法（因为拖动期间根本不排序）。
- 不把“未实测的 UI 效果”写成已验证。

## 白名单（产品 + 测试 + 文档）

产品：
- `App/SnapGlass/Sources/ScreenshotShelf/ScreenshotShelfViewModel.swift`
- `App/SnapGlass/Sources/ScreenshotShelf/ScreenshotShelfView.swift`
- `App/SnapGlass/Sources/ScreenshotShelf/ScreenshotShelfDragOutController.swift`
- `App/SnapGlass/Sources/ScreenshotShelf/ScreenshotShelfPanel.swift`
- `App/SnapGlass/Sources/ScreenshotShelf/ScreenshotShelfDragOverlayPanel.swift`（只回退旧 dedup）
- `CHANGELOG.md`

测试源（只编译，不运行）：
- `App/SnapGlass/EditorTests/ScreenshotShelfDragOutDecisionTests.swift`
- `App/SnapGlass/EditorTests/ScreenshotShelfDragPreviewTests.swift`

阶段 4 额外允许（仅本次四个 Medium 修正需要）：
- `App/SnapGlass/Sources/ScreenshotShelf/ScreenshotShelfCardView.swift`（ghost 期间关闭源卡 tap/context/accessibility actions，保留外层 drag gesture）
- `App/SnapGlass/Sources/ScreenshotShelf/ScreenshotShelfDragOverlayPanel.swift`（local cancel 改用带闩锁的模型方法）
- `App/SnapGlass/Sources/ScreenshotShelf/ScreenshotShelfPanel.swift`（新 mouseDown 重置 local cancel 闩锁）

文档：
- 本文件
- `Docs/superpowers/plans/2026-11-12-screenshot-shelf-source-ghost-report.md`

## 旧方案清理白名单

以下文件确认是本次新建的旧方案/审查/门禁资料，移动到
`~/.Trash/SnapGlass-shelf-superseded-<唯一时间戳>/`：
- `Docs/superpowers/plans/2026-11-12-screenshot-shelf-experience.md`
- `Docs/superpowers/plans/2026-11-12-screenshot-shelf-review.md`
- `Docs/superpowers/plans/2026-11-12-screenshot-shelf-ledger.md`
- `Docs/superpowers/plans/2026-11-12-screenshot-shelf-design-audit.md`
- `Docs/superpowers/plans/2026-11-12-screenshot-shelf-catcher-gate.md`

旧代码差异先保存为同目录 `superseded-product.diff`（`git diff` 原文），再从工作区精确回退：
- `Packages/CaptureCore/Sources/ScreenshotShelfSessionDirectoryPolicy.swift`
- `Packages/CaptureCore/Tests/CaptureCoreTests/ScreenshotShelfSessionDirectoryTests.swift`
- `ScreenshotShelfDragOverlayPanel.swift` 的 dedup
- `ScreenshotShelfViewModel.swift` 的 `updateDrag` 同值 dedup
- 本轮 nativeReturn / 目标几何 / 动态 return destination / 相关测试断言

保留：当前 ghost 实现、配套测试源、本计划、最终报告、CHANGELOG 当前条目。
不移动：临时工程/DerivedData、`.git`、`.memory`、配置、历史计划（11-03/08/09）。

## 阶段 1：模型与视图（ghost 契约）

编码前落版本阶段；先改模型，再改视图。

- 模型：
  - 删除 `ScreenshotShelfNativeReturn`、`nativeReturn`、`updateNativeReturn`、`commitNativeReturn`、`endNativeReturn`。
  - 保留 `ScreenshotShelfDragPreview` 作为本地拖动预览。
  - 新增 `@Published private(set) var nativeDragCardID: UUID?` 和计算属性 `ghostCardID: UUID? { dragPreview?.cardID ?? nativeDragCardID }`。
  - `beginDrag` guard `nativeDragCardID == nil`，防止 native handoff 中开始第二次本地拖动。
  - 新增 `handOffDragToNative(cardID:)`：校验当前 preview 的 cardID；**先**设 `nativeDragCardID`，再清 `dragPreview` 并通知 overlay 隐藏；不调用 `.endInteraction`（interaction 从 beginDrag 持续）。
  - `endNativeDrag()`：幂等清 `nativeDragCardID`，释放 `.endInteraction` 恰好一次。
  - `endDrag()`：本地结束清 preview；不碰 native 状态。
  - `updateDrag` 恢复简单 guard：无 preview 时忽略；不做同值去重（旧优化回退）。
- 视图：
  - 删除 `dropTargetIndex`、`reorderZoneOverlay`、`siblingOffset`、`targetIndex`、`midpoint` 和拖动中的 `.move`。
  - 新增 `ScreenshotShelfSourceGhostView`：源卡同尺寸、低透明缩略图（约 0.30）+ 圆角 8 细虚线轮廓；`allowsHitTesting(false)`、`accessibilityHidden(true)`；不使用右键/菜单/手势。
  - `cardsRow` 不再 offset；源卡按 `ghostCardID` 隐藏并 `accessibilityHidden`；其他卡不动。
  - `ghostView` 按 `ghostCardID` 在 `layout.cards` 中按 UUID 查 index；找不到（卡被删除）就不画，不复活旧卡；index 只用于当前布局的 `startX`，不缓存宽度。
  - 拖动期间所有卡片 `isHovered = false`，避免兄弟卡 hover tilt；`onChanged` guard native 状态；`onEnded` guard native 状态后只 `endDrag()`，不排序。
- 测试源（不运行）：
  - 删除 nativeReturn/几何/动态目标断言。
  - 保留 decision 的 4 个测试。
  - 保留 preview 的 3 个基础测试；新增 ghost/handoff/幂等测试：handoff 后 ghost 保持、local 不能重启、end 只释放一次、local end 清 ghost。

## 阶段 2：原生交接与取消

编码前落版本阶段。

- `ScreenshotShelfDragOutController`：
  - 删除 `ScreenshotShelfDragReturnAuthorization`、`ScreenshotShelfDragReturnGeometry`、`updateReturn`、`exitReturn`、`prepareReturn`、`performReturn`。
  - `ScreenshotShelfDraggingSource` 的结束回调改为 `(NSDraggingSession, NSDragOperation) -> Void`。
  - `beginSession`：构建 drag image 后调用 `model.handOffDragToNative(cardID:)`，不再 `model.endDrag()`/`.beginInteraction`；保持 interaction 连续。
  - `finishSession(session:operation:)`：幂等；若 operation 为空（取消/失败/无目标），在标准源回调里设 `session.animatesToStartingPositionsOnCancelOrFail = false`，避免系统把拖影滑回交接点；随后清 source、`model.endNativeDrag()`、光标。真实卡由 ghost 清除后在原顺序出现。
  - 删除 `handle(.leftMouseUp)` 的提前清 `handoffActive`；只保留 `.leftMouseDragged` 的 drag-out 检测。
- `ScreenshotShelfPanel`：
  - 移除 `hostingView.registerForDraggedTypes` 和全部 dragging destination 覆写；原生 session 期间本应用没有回架 destination，走系统取消/外部 drop。
- 不改 Manager lifecycle；`isNativeDragSessionActive` 仍由 `handoffActive` 提供，跨屏跟随/交互抑制沿用现有条件。
- 不处理 app 失活为 cancel；失活是拖到其他应用的正常路径，overlay 的既有 resign 观察者只清本地 preview（native 时 preview 已 nil）。

## 阶段 3：清理、静态复核、编译

编码前落版本阶段。

1. 归档旧文档；保存旧 `git diff` 到 Trash；精确回退 CaptureCore 两文件、overlay dedup、updateDrag dedup。
2. `git diff --check`；检查 `git status` 只含白名单文件。
3. 不启动应用的编译：
   ```bash
   xcodebuild build \
     -project /private/var/folders/ks/flqyrh0j5wvf2t7v4s7lcnz0b5tfzv/T/opencode/snapglass-shelf-project-20261112/SnapGlass.xcodeproj \
     -scheme SnapGlass -destination 'platform=macOS,arch=arm64' \
     -derivedDataPath /private/var/folders/ks/flqyrh0j5wvf2t7v4s7lcnz0b5tfzv/T/opencode/snapglass-shelf-baseline-fresh-20261112 \
     CODE_SIGNING_ALLOWED=NO
   ```
4. 测试源改动后，只 build 测试 target，不运行 xctest：
   ```bash
   xcodebuild build \
     -project .../SnapGlass.xcodeproj -target EditorInteractionTests \
     -configuration Debug -destination 'platform=macOS,arch=arm64' \
     -derivedDataPath .../snapglass-shelf-baseline-fresh-20261112 \
     CODE_SIGNING_ALLOWED=NO
   ```
5. 不运行 `swift test` / `xcodebuild test` / 应用 / GUI；不声称行为已验证。

## 阶段 4：独立审查 4 个 Medium 的定点硬化（编码前落版）

只修这四个正确性边界，保留极简 ghost；不新增 catcher、目标几何、时间门或大状态机。

1. **handoff/session 身份**
   - `handOffDragToNative(cardID:)` 返回 `Bool`；`beginSession` 只有成功才启动 native。
   - 控制器用 `sessionGeneration`（begin 前递增、source 闭包捕获）作为最小 session 身份；`finishSession` 校验 generation，旧 `endedAt` 不能清理新 session。
   - handoff 失败且当前没有 native 身份时回退 `endDrag`/光标；已有 native 身份时不启动第二个 session，也不杀当前 session。
   - 不新增 `willBegin` 状态机；generation 在 `beginDraggingSession` 前确定，因此同步 `endedAt` 也能正确匹配。

2. **当前 layout 几何**
   - `beginSession` 按 UUID 重新查当前 index、`cardWidths[index]`、`cardHeight`；删除/非法尺寸直接回退 local，不启动 native。
   - drag image 的尺寸与 item frame 使用同一当前宽度/高度。
   - **坐标分离：** `preview.startX + preview.translation` 是冻结的指针 delta 基准，用来让 native image 与正在隐藏的 local overlay 位置连续；当前 layout 只用于解析卡片身份、尺寸和 ghost 槽位。不得用当前 `startX` 重算 image origin，否则新截图插入时会把拖影从指针处弹到新槽位。抓取点 clamp 到当前宽/高，避免宽度变化时越界。

3. **local cancel 闩锁**
   - 模型新增 `isLocalDragCancelled`；`cancelLocalDrag()` 清 preview、释放 interaction、置闩锁；`endDrag()` 清 preview/释放 interaction 并复位闩锁。
   - `beginDrag` guard `dragPreview == nil && nativeDragCardID == nil && !isLocalDragCancelled`；view 的 `onChanged` 同样检查。
   - overlay 的 resign/space/卡缺失取消改调 `cancelLocalDrag()`；`onEnded` 调 `endDrag()` 复位；`ScreenshotShelfPanel.sendEvent(.leftMouseDown)` 调控制器 `resetLocalDragCancellation()`，保证下一次合法拖动不被永久阻止。新 mouseDown 重置不是全局事件监听、不是计时器。

4. **ghost 源卡交互**
   - `ScreenshotShelfCardView` 增加 `isInteractive: Bool = true`；`true` 分支保留 tap/context/accessibility actions，`false` 分支只保留视觉与 contentShape。
   - `ScreenshotShelfView` 对 `ghostCardID == card.captureID` 传 `isInteractive: false`；外层 `.gesture(dragGesture)` 仍在父视图，正在进行的拖动不被禁用。
   - 其他卡片在 native 期间保持原有交互，不扩大 scope；右键/键盘显式 move 对非 ghost 卡保留。

测试源（只编译）：补 handoff 返回值/失败、`beginDrag` 二次 local 拒绝、local cancel 闩锁与复位、当前宽度交接的纯模型/几何断言；不运行。

## 停止条件

- 需要修改白名单外产品文件、配置、依赖、权限或系统设置。
- 编译需要启动 app/xctest 才能继续。
- 发现工作区有非本任务的新改动：保留、报告，不覆盖。
- 旧代码差异未归档就准备回退：先归档再继续。

## 验收边界

- 通过：静态 diff 只含当前 ghost 修复；编译 exit 0；报告明确“未运行测试/GUI，UI 效果未实测”。
- 不通过：仍保留 nativeReturn/动态回架/catcher；或无法在不运行测试的情况下编译；或回退了来源不明的改动。

## 阶段 5：最终 rollback 闩锁修正（2026-11-12 静态复核）

只修一个窄回归，不扩 scope。

- 发现：`rollbackLocalHandoff()` 在 native 为 nil 时调用 `model.endDrag()`；`endDrag()` 会复位 `isLocalDragCancelled`，鼠标仍按下时同一 SwiftUI 手势可再次 `beginDrag`。
- 修正：
  - `rollbackLocalHandoff()` 在 native 为 nil 时改调 `model.cancelLocalDrag()`；native 非 nil 时不动当前合法 session。
  - `handOffDragToNative` 失败统一走 `rollbackLocalHandoff()`，去掉重复的 `endDrag` 分支。
  - `cancelLocalDrag()` 先置闩锁再做 preview guard：preview 已 nil 时也保住“同次手势不得重启”，但有 preview 时才释放 interaction；`endDrag()`/新 mouseDown 仍负责复位。
- 契约断言（只编译）：rollback 式取消后 ghost 清除、interaction 只释放一次、同次手势 `beginDrag` 被拒；`endDrag` 或新 mouseDown 后允许下一次合法拖动。
- 验证：`git diff --check`、targeted SwiftLint、App build、EditorInteractionTests target build；不运行测试/GUI。
