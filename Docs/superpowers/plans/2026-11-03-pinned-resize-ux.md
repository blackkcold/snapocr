# 置顶缩放交互实施计划

> **执行方式：**由主会话按任务顺序实施；执行期间不调用 subagent。步骤使用 checkbox 跟踪。

**Goal:** 置顶图片可通过四边与四角进行等比缩放，所有缩放入口使用明确且稳定的锚点，工具条在交互期间不漂移、翻边或显示陈旧倍率。

**Architecture:** 保留无边框、非激活 `NSPanel` 与 AppKit 手动 frame 更新。把缩放命中区域、方向、等比 frame 推导、锚点感知倍率钳制和屏幕可见范围计算放在可单测的 `CaptureCore` 纯几何层；`PinnedImageView` 负责单点交互分类和事件派发，工具条协调器负责交互期稳定定位与读数同步。

**Tech Stack:** Swift 6、AppKit、CoreGraphics、Swift Testing、XcodeGen + SPM。

**Spec:** 2026-11-03 会话中用户确认的置顶缩放方案；覆盖边/角、工具条滑杆、1:1、滚轮/捏合、适应屏幕与初始置顶定位。

## Global Constraints

- 最低系统仍为 macOS 13；继续使用 borderless / nonactivating panel，不启用系统 `.resizable`。
- 缩放比例维持 `0.1...8`；四边/四角等比；倍率 clamp 后仍须保持当前操作的固定锚点。
- 命中区：边缘 6 pt、角落最多 14 pt；短边小于 48 pt 时只开放自适应角区；关闭按钮优先。
- 滑杆与 1:1 固定左下锚点；滚轮/捏合固定光标锚点且不追加平移；Fit 保留原有 90% 最大占屏尺寸规则，但不强制居中，仅做最小可见性平移。
- 无新增界面文案、依赖、权限、CI 或仓库根目录生成的 `.xcodeproj` 修改；若根项目文件缺失，仅可在忽略的 `.superpowers/sdd/2026-11-03-pinned-resize-ux/generated/` 下生成临时构建工程；不改原工作区的未跟踪 `release/`，不提交、不推送。
- 按 `Docs/AGENTS.md` 更新 `CHANGELOG.md` 与架构说明；新增 public API 补齐 DocC 注释。

## Review Focus

- 最小/最大倍率钳制后，被拖动的对边/对角与光标锚点仍固定；由几何测试覆盖。
- 超宽/超高图片及最小面板尺寸不破坏原始比例或让面板退化到无法操作；由几何测试与手动检查覆盖。
- 小面板、透明边缘、右上关闭按钮和双击关闭之间无误命中；由命中区域纯函数测试与手动检查覆盖。
- 左下锚点缩放时滑杆留在指针下；边缘缩放时工具条不遮挡、翻边或闪烁；由工具条状态/布局测试与手动检查覆盖。
- Fit 的 90% 尺寸规则、无屏幕回退、屏幕非零原点和已在可见区 frame 的位置稳定；由几何测试覆盖。

---

### Task 1: 可测试的锚点几何

**Files:**
- Modify: `Packages/CaptureCore/Sources/PinnedImageGeometry.swift`
- Modify: `Packages/CaptureCore/Sources/PinnedToolbarVisibility.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/PinnedImageGeometryTests.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/PinnedToolbarVisibilityTests.swift`

**Interfaces:**
- Produces `public enum PinnedImageResizeDirection`: `left`, `right`, `top`, `bottom`, `topLeft`, `topRight`, `bottomLeft`, `bottomRight`；提供相对 frame 的固定锚点。
- Produces `PinnedImageGeometry.resizeDirection(at:in:edgeHitSize:cornerHitSize:smallPanelThreshold:) -> PinnedImageResizeDirection?`；角落优先，短边小于阈值时只返回角落。
- Produces `PinnedImageGeometry.resizedFrame(from:direction:translation:minimumSize:) -> CGRect`；按起始 frame 比例计算，固定对边/对角，统一最小宽高。
- Extends `clampFrameToScaleRange(_:imagePixelWidth:displayScale:anchor:)` with normalized `anchor` defaulting to `.zero`, preserving existing callers while retaining the specified anchor at both scale limits.
- Produces `PinnedImageGeometry.clampFrameToVisibleBounds(_:screenFrame:) -> CGRect` for translation-only visibility correction.
- Keeps `fitToScreen(_:screenFrame:)` signature; retains the 90% fit cap, keeps the lower-left anchor before only-minimal visibility correction, and never centers.
- Produces `PinnedToolbarVisibility.panelResizeBegan()`, `panelResizeEnded()` and `shouldShowAfterResize` so the toolbar's temporary hide/restore policy is pure and testable.

- [x] **Step 1: Write failing package tests** for all 8 resize zones, small-panel corner-only hit zones, four-edge/four-corner anchor preservation, aspect ratio, minimum dimensions, anchor-aware min/max scale clamping, fit-cap behavior, origin stability, minimum screen translation and toolbar resize visibility transitions.
- [x] **Step 2: Run the targeted tests and confirm expected failures** with `swift test --package-path Packages/CaptureCore --filter 'PinnedImageGeometryTests|PinnedToolbarVisibilityTests'`.
- [x] **Step 3: Implement the documented pure geometry APIs** in `PinnedImageGeometry.swift`, preserving current public API behavior when the new anchor argument is omitted.
- [x] **Step 4: Implement the resize visibility transitions** in `PinnedToolbarVisibility.swift` with tests proving the toolbar stays hidden while resizing and restores only when the pointer remains inside.
- [x] **Step 5: Run the targeted tests, then the full CaptureCore package suite** with `swift test --package-path Packages/CaptureCore`.

### Task 2: AppKit hit testing, resize feedback and toolbar stability

**Files:**
- Modify: `Packages/CaptureCore/Sources/PinnedImageGeometry.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/PinnedImageGeometryTests.swift`
- Modify: `App/SnapGlass/Sources/Pins/PinnedImageView.swift`
- Modify: `App/SnapGlass/Sources/Pins/PinnedToolbarView.swift`
- Modify: `App/SnapGlass/Sources/Pins/PinnedToolbarWindow.swift`
- Modify: `App/SnapGlass/Sources/Pins/PinnedWindowManager.swift`

**Interfaces:**
- Consumes Task 1's direction classifier, resize geometry, anchor-aware clamp and visible-bounds helper.
- Adds a pure `PinnedImageInteraction` classifier in `CaptureCore` so close-button priority, transparent-edge resize and transparent-body pass-through are unit tested without editing the XcodeGen test-target configuration.
- `PinnedImageView` uses one `interaction(at:)` classification for hit testing, cursor selection and mouse dispatch, with priority `close > corner > edge > move/transparent`; only an interior move double-click closes the pin.
- `PinnedImageView` reports resize begin/end to `PinnedToolbarCoordinator`; it keeps aspect ratio from the current start frame to avoid a first-drag jump caused by pixel-integral crop rounding.
- `PinnedToolbarView` reports scale-slider drag begin/end separately from generic toolbar interaction.
- `PinnedToolbarCoordinator` freezes toolbar placement while the scale slider is dragged, hides the toolbar only during edge/corner resize, refreshes readouts after panel geometry changes, and only remeasures toolbar size when available screen width changes.

- [ ] **Step 1: Implement shared interaction classification, transparent-edge resize hits, direction cursors, edge-only hover accent and gesture routing.** Preserve close-button hit priority and existing body-to-move behavior.
- [ ] **Step 2: Wire toolbar behavior**: hide during edge/corner resize, restore only if the pointer remains on the pin, freeze toolbar frame during scale-slider drag, refresh readouts on geometry changes and remeasure only when available screen width changes.
- [ ] **Step 3: Fix initial pin fallback** so absence of a real `NSScreen` does not treat the candidate frame as a screen and shrink it by 10%.
- [ ] **Step 4: Run `swift test --package-path Packages/CaptureCore` and build the macOS app.** If the generated project is absent, create it only in the plan's ignored `generated/` folder with `xcodegen --project-root "$PWD"`; manually verify all directions, transparent edges, tiny panels, close behavior, live slider tracking, toolbar visibility/readouts, and mixed-screen fit behavior.

### Task 3: Project behavior documentation

**Files:**
- Modify: `Docs/ARCHITECTURE.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Update the pin interaction contract** to describe all edge/corner anchors, slider/1:1 lower-left anchoring, cursor-anchored wheel/pinch and the non-centering 90% Fit behavior, including initial placement.
- [ ] **Step 2: Add an Unreleased changelog entry** without changing version numbers.
- [ ] **Step 3: Run Swift formatting/lint, localization check (no new strings expected), and review the complete diff.**

## Verification Commands

- `swift test --package-path Packages/CaptureCore`
- `xcodegen generate --spec project.yml --project .superpowers/sdd/2026-11-03-pinned-resize-ux/generated --project-root "$PWD"`
- `xcodebuild -project .superpowers/sdd/2026-11-03-pinned-resize-ux/generated/SnapGlass.xcodeproj -scheme SnapGlass -configuration Debug -derivedDataPath /private/var/folders/ks/flqyrh0j5wvf2t7v4s7lcnz0b5tfzv/T/opencode/snapocr-pin-resize-ux build CODE_SIGNING_ALLOWED=NO`
- `swift-format lint -p <each changed Swift file> --configuration .swift-format`
- `swiftlint lint --config .swiftlint.yml`
- `bash scripts/check-localization.sh`

No commit is part of this task. AppKit drag-event integration has no current UI automation target; the listed manual checks are required after build, and any unperformed UI check must be reported explicitly.
