# SnapGlass 截图编辑器「分享外观」设计文档

- 状态：方案 A 已实现（未提交）；B0 未开始。构建与测试结果见文末「实施增量」与 `CHANGELOG.md`
- 日期：2026-11-23
- 范围：`Packages/CaptureCore`、`Packages/SharedKit`、`App/SnapGlass/Sources/Editor`、`App/SnapGlass/Sources/App.swift`、四语言文案、`CHANGELOG.md`
- 用户决策：**先交付方案 A（编辑器内可开关、可编辑、可预览），最终目标是方案 B（画布内实时外观）**；本轮不要执行
- 证据边界：设计部分基于当前分支配色、代码与现有文案的静态审查；实施后已跑构建与单测，未运行 GUI、未做性能剖析、未做真机验收。文中所有阈值是设计目标，不是实测结论

---

## 0. 一页结论

分享外观的渲染链已经存在：`MockupStyle` 保存 8 个比例参数，`MockupRenderer` 纯 Core Graphics 合成，8 个预设，历史只存原图 + 样式 JSON。缺的不是渲染器，而是**编辑器里的入口、状态和边框字段**。

方案 A 把编辑器作为分享外观的主场：

1. 底栏一个「分享外观」开关（`⌘B`），当前是否开启一眼可见；
2. 检查器顶部「标注 / 分享外观」两个页签，分享页放模板、留白、圆角、投影、描边和实时预览；
3. 画布保持原图 + 标注，复制/导出/存历史时套用外观；大图预览保证所见即所得。

方案 B 是最终形态：把同一套 `MockupLayout` 与 `MockupRenderer.draw` 接到画布上，让画布直接显示背景、留白、圆角、投影和描边。**A 的架构必须为 B 留下这三个契约**：

- `MockupLayout`：唯一的几何计算，画布和导出共用；
- `MockupRenderer.draw`：唯一的绘制入口，画布和导出共用；
- `EditorViewModel.mockupStyle`：唯一的状态源，检查器、画布、导出共用。

A 不实现画布 WYSIWYG，但 A 结束时 B 只需要改画布的布局与绘制层，不需要重写检查器、预览、数据模型或历史同步。

---

## 1. 意图与原因

用户今天已经可以在截图后给图片加背景、留白与投影，但入口散落在设置、截图架键盘模式、历史右键和独立的 Beautify 浮窗里。编辑器作为“最后一道加工作业面”，反而看不到当前图片有没有分享外观，也不能改边框。

用户要的三件事：

1. 在截图编辑器里**可选打开/关闭**分享外观；
2. 能编辑**边框宽度**等参数，而不是只能选固定模板；
3. 有一张能直接发出去的图——背景、留白、投影、描边在导出前就能看见。

这件事的价值不是“再加一个面板”，而是把分享外观从“事后处理”变成“编辑器的一个输出视图”。它同时解决一个长期存在的不一致：`⌘C` 复制的结果与画布看到的图不同，用户没有任何提示。

---

## 2. 现状

### 2.1 已有能力

| 能力 | 位置 | 说明 |
|---|---|---|
| 样式模型 | `Packages/CaptureCore/Sources/MockupStyle.swift:8-53` | 背景（透明/纯色/线性渐变）、留白、圆角、投影模糊、投影不透明度、投影偏移；全部为相对比例 |
| 预设 | `MockupStyle.swift:57-162` | 浮窗、浅色、深色、纸感、日落、海洋、午夜、透明，共 8 个 |
| 渲染 | `Packages/CaptureCore/Sources/MockupRenderer.swift:31-105` | 纯 Core Graphics；先画背景，再画阴影与圆角裁剪内容；透明源不会被阴影填黑 |
| 捕获时策略 | `Packages/CaptureCore/Sources/MockupPolicy.swift:8-20` | 只对区域/全屏生效；窗口与滚动截图不走这套策略 |
| 窗口浮窗 | `Packages/CaptureCore/Sources/WindowScreenshotStyling.swift:83-120` | 把同一 `MockupStyle` 作为窗口截图的默认外观 |
| 历史持久化 | `Packages/HistoryCore/Sources/HistoryEntry.swift:97` 等 | 原图不动，`mockupStyleJSON` 作为元数据保存 |
| 编辑器继承 | `App/SnapGlass/Sources/Editor/EditorCaptureContext.swift:11`、`EditorViewModel.swift:212` | 编辑器已经拿到样式，但只用于导出 |

### 2.2 入口

| 入口 | 用户可见行为 | 证据 |
|---|---|---|
| 设置 → 截图 → 图像 | 开关 + 模板 + 预览；只影响**之后**的区域/全屏截图 | `App/SnapGlass/Sources/Windows/CapturePreferencesView.swift:147-169` |
| 截图架键盘模式 | `⌘B` 打开美化检查器、`B` 开关、`⇧B` 循环模板 | `ScreenshotShelfKeyboardController.swift:25-55` |
| 截图架右键 | **没有**美化项；`onInspectMockup` 只被键盘控制器调用 | `ScreenshotShelfManager.swift:48-57`、`ScreenshotShelfCardView.swift:198-227` |
| 历史卡片右键 | 美化… / 移除美化 / 复制无样式图 | `App/SnapGlass/Sources/Windows/HistoryView.swift:320-346` |
| 编辑器 | **没有任何入口** | `App/SnapGlass/Sources/Editor/EditorView.swift:148-221` |

### 2.3 输出链

- 编辑器 `⌘C`：`renderOffMain(document)` → `applyingMockup(image, style:)` → 剪贴板（`EditorViewModel+Save.swift:251-282`）。
- 编辑器 `⌘S`：`writeRenderedDocument` 在后台渲染、套样式、编码、落盘（`EditorViewModel+Save.swift:224-239`）。
- 「存入历史」：渲染标注图写入历史，样式 JSON 作为元数据（`EditorViewModel+Save.swift:15-33`）。
- 截图架/历史缩略图：按样式即时渲染，不缓存派生图（`HistoryMockupPresenter`）。

### 2.4 缺口

1. **没有边框字段**：`MockupStyle` 没有描边宽度或颜色。
2. **样式不是 `@Published`**：`EditorViewModel.mockupStyle` 是普通 `var`（`:212`），改样式不会刷新 UI；`hasUnsavedChanges` 只比较 base image 与 nodes（`:140-158`），样式改动不进入 dirty。
3. **没有实时预览**：预览只存在于独立浮窗，1024px 长边、90ms 防抖（`MockupInspectorPanel.swift:50-78`）。
4. **没有迁移**：`MockupStyle` 使用合成 `Codable`，`version` 字段从未参与解码；新增非可选字段会让旧历史样式静默解不出，回到原图。
5. **没有“复制原图”入口**：样式开启时 `⌘C` 只能得到合成图。
6. **窗口/滚动策略不可见**：捕获时策略只对区域/全屏生效，编辑器里没有解释。

### 2.5 已有 UX 摩擦（与本次相关）

- 同一功能有 5 种叫法：`Share-ready look`、`Beautify`、`美化…`、`Copy Beautified`、`Beautified`。
- 截图架的 Beautify 检查器只能通过键盘模式进入，右键菜单是断路。
- 检查器的 `X`/`Esc` 实际会 `commitStyle()`（`MockupInspectorPanel.swift:315-342`），“取消”其实是保存。
- `Reset` 固定回到 `.light` 预设（`:251`），不是当前模板默认，也不是“关闭外观”。
- 美化开启时，动作条主按钮仍叫 `Copy Image`，实际复制的是美化图（`CaptureActionBarView.swift:63-71,189-222`）。
- 6K 截图复制前串行渲染，没有进度；预览失败静默保留灰块（`MockupInspectorPanel.swift:60-78`）。

---

## 3. 目标 / 非目标 / 反目标

### 目标

| # | 目标 | 验收 |
|---|---|---|
| G1 | 编辑器内可开关分享外观 | 关闭时输出原标注图；开启时输出带外观图 |
| G2 | 可编辑背景、留白、圆角、投影、描边宽度与颜色 | 每项改动在预览中可见，导出与预览一致 |
| G3 | 实时预览 + 大图预览 | 5K 图开关后 ≤200ms 出现预览；大图可核对透明背景与描边 |
| G4 | 历史 raw + 样式 JSON 往返 | 重开编辑器恢复样式；旧 v1 JSON 仍可解码 |
| G5 | A 的架构可直接支撑 B | B 只改画布布局/绘制层，不改检查器、模型、历史同步 |
| G6 | 统一命名与入口 | 编辑器、截图架、历史、设置都用「分享外观」；复制项分「分享图/原图」 |

### 非目标（A 阶段）

- 不在画布内绘制背景、留白、投影或描边（B 阶段）。
- 不做每边独立留白、固定画布比例、背景图片、渐变编辑器。
- 不改变捕获时的默认策略；只允许在编辑器里对单张图覆盖。
- 不新增 SPM 依赖。
- 不把样式写进标注撤销栈。

### 反目标

- 画布与导出结果不一致，用户复制后才发现背景不对。
- 样式改动静默丢失，或历史缩略图停在旧样式。
- 新增字段导致旧历史样式解码失败。
- 滑杆每动一次就全分辨率重渲染，主线程卡顿。
- 再加一个独立浮窗，和编辑器状态、关闭语义分离。

---

## 4. 约束

- macOS 13+，Swift 6，SwiftUI + AppKit 画布。
- 检查器宽度 240–280pt（`AnnotationInspectorView.swift:98`）；编辑器最小 740×480，工作区最小 800×600（`EditorView.swift:138`、`EditorWorkspaceView.swift:26`）。
- 画布最小 500pt（`EditorView.swift:112`）；不能为新增面板再加第三栏。
- 四语言：`en` / `zh-Hans` / `ja` / `ko`；新增文案必须四份齐全，视图外文本用 `AppLocalization.string`。
- 历史数据加密；样式 JSON 是元数据，不改原图。
- 当前分支有录制 P0 的未提交改动；本设计不触碰录制路径。
- 项目要求：Conventional Commits、DocC 注释、`scripts/check-localization.sh`。

---

## 5. 方案比较

| 方案 | 做法 | 代价 | 结论 |
|---|---|---|---|
| A · 检查器页签 | 底栏开关 + 右侧「分享外观」页 + 大图预览；画布不变 | 约 3.5–5 天；不改画布坐标与命中测试 | **先做** |
| B · 画布 WYSIWYG | 背景、留白、描边直接画进画布 | 约 8–12 天；要同步缩放、裁剪、OCR 覆盖层与手柄坐标 | **最终目标** |
| C · 复用浮窗面板 | 把现有 `MockupInspectorPanel` 挂到编辑器 | 1–2 天；仍是另一个窗口，状态与关闭语义分离 | 不推荐 |

选择 A 的理由：它把“状态、预览、导出、历史”先收敛成一条链，且不碰画布。B 随后只需要替换画布的显示层。C 会把现有浮窗的“关闭即提交、Reset 固定浅色、没有移除入口”一起带进编辑器，问题更多。

---

## 6. 总体架构（A 与 B 共用）

### 6.1 组件图

```text
EditorView
 ├─ 底栏「分享外观」开关 ──────────────┐
 ├─ AnnotationInspectorView             │
 │   ├─ Tab: 标注（现有内容）           │
 │   └─ Tab: 分享外观                   │
 │        └─ ShareAppearanceInspectorView
 │             │ bind
 ├─ EditableAnnotationCanvasView         │
 │   A: 原图 + 标注；B: 读取 layout 绘制外观
 │             │
 └──────── EditorViewModel ─────────────┘
               ├─ mockupStyle: MockupStyle?        // 唯一状态源
               ├─ sharePreview / sharePreviewState
               ├─ EditorViewModel+ShareAppearance  // 开关、预设、预览、防抖、历史写回
               ├─ MockupLayout（CaptureCore）       // 唯一几何
               └─ MockupRenderer.draw（CaptureCore）// 唯一绘制
```

### 6.2 单一真相源

- `mockupStyle: MockupStyle?`，`nil` = 关闭。不要用两个布尔值和样式副本。
- `lastEnabledMockupStyle` 只在关闭时保存“上次开启的样式”，供再次开启恢复；它不是第二个真相源。
- `selectedPreset: MockupPreset?` 只是 UI 选中态；任何滑杆改动把它置为 `nil`（自定义）。
- 检查器、底栏、导出、历史写回全部读同一个 `mockupStyle`。
- 画布在 A 阶段不读；B 阶段只读，不写。

### 6.3 共享几何 `MockupLayout`

新增 `Packages/CaptureCore/Sources/MockupLayout.swift`。所有尺寸计算只在这里做一次：

```swift
public struct MockupLayout: Equatable, Sendable {
    public struct ShadowMetrics: Equatable, Sendable {
        public let blur: CGFloat
        public let offsetY: CGFloat
        public let opacity: CGFloat
    }

    public let imageSize: CGSize
    public let canvasSize: CGSize
    public let contentRect: CGRect      // 画布坐标，CG 原点左下
    public let cornerRadius: CGFloat
    public let borderWidth: CGFloat
    public let shadow: ShadowMetrics

    public static func make(imageSize: CGSize, style: MockupStyle) -> MockupLayout
}
```

计算规则（与现有 `MockupRenderer` 一致，新增边框）：

- `reference = min(long, 1.8 × short)`
- `padding = round(max(0, style.paddingRatio) × reference)`
- `radius = min(max(0, style.cornerRadiusRatio) × reference, min(w, h) / 2)`
- `border = style.borderWidthRatio > 0 ? max(1, round(style.borderWidthRatio × reference)) : 0`；上限为 `min(w, h) × 0.02`，且不超过 12px
- `blur = max(0, style.shadowBlurRatio × reference)`
- `offsetY = max(0, style.shadowOffsetRatio × reference)`
- `canvasSize = (image.width + 2 × padding, image.height + 2 × padding)`
- `contentRect = CGRect(x: padding, y: padding, width: image.width, height: image.height)`

`MockupRenderer.outputSize(for:style:)` 保留为兼容入口，内部转调 `MockupLayout.make`。

### 6.4 共享绘制 `MockupRenderer.draw`

把现有 `render` 拆成“建上下文”和“画内容”两层：

```swift
public enum MockupRenderer {
    public static func render(_ image: CGImage, style: MockupStyle) -> CGImage?
    public static func render(_ image: CGImage, style: MockupStyle, maximumDimension: CGFloat?) -> CGImage?
    public static func draw(
        _ image: CGImage,
        style: MockupStyle,
        layout: MockupLayout,
        in context: CGContext,
        origin: CGPoint = .zero,
        scale: CGFloat = 1,
        backdrop: ((CGContext, CGRect) -> Void)? = nil
    )
}
```

- `render` 创建画布、`clear`、调用 `draw`、返回 `makeImage`。
- `draw` 负责：背景 → 阴影 → 圆角裁剪内容 → 描边。它不创建位图，不假设画布大小。
- `backdrop` 用于“透明背景 + 阴影”时：阴影需要一个不透明填充来投影，填充后要把圆角内容区清空；导出时清空即透明，画布 B 阶段需要把棋盘格重新画回来。A 阶段传 `nil`。
- B 阶段的画布直接调用 `draw`，因此画布与导出的几何、阴影、描边天然一致。

### 6.5 A 与 B 的边界

| 关注点 | A | B |
|---|---|---|
| 样式状态 | `EditorViewModel.mockupStyle` | 同一个 |
| 检查器 | 绑定状态 | 复用 |
| 预览 sheet | 1200px 合成图 | 复用 |
| 画布 | 原图 + 标注；不读样式 | 读 `mockupStyle`，用 `MockupLayout` 计算 frame/content rect |
| 导出 | `MockupRenderer.render` | 同一个 |
| 历史 | raw + JSON + 防抖写回 | 同一个 |
| 坐标/命中 | `imageDisplayRect` = 图片显示区 | `imageDisplayRect` = `contentRect`，其余映射不变 |
| 缩放 | 相对图片 fit | 相对 frame fit；百分比仍表示图片像素比例 |

A 结束时，B 唯一需要新写的逻辑是“画布如何把 layout 映射到视图坐标并绘制”。这正是 A 不应该提前做、也不应该做死的部分。

---

## 7. 方案 A 详细设计

### 7.1 入口与布局

**底栏开关**

在 `EditorView.bottomBar` 的 OCR 开关之后、`Save to History` 之前加入：

```swift
Toggle(isOn: shareAppearanceEnabledBinding) {
    Label("分享外观", systemImage: "sparkles")
}
.toggleStyle(.button)
.keyboardShortcut("b", modifiers: .command)
.help("分享外观（⌘B）")
.accessibilityLabel("分享外观")
```

- 开启时用强调色/浅色底；关闭时普通。
- 点击开启：若检查器隐藏，先显示检查器并切到分享页；若当前在标注页，也切过去。
- 点击关闭：只关闭本次输出，不清空 `lastEnabledMockupStyle`；面板保持当前页，控件置灰。
- 不新增第三栏；窗口最小宽度不变。

**检查器页签**

`AnnotationInspectorView` 顶部加一个两段切换：`标注` / `分享外观`。

- 标注页：现有 `controls` / `emptyState` 原样。
- 分享页：`ShareAppearanceInspectorView`。
- 选中一个已有标注、或新建标注完成时，自动切回标注页。
- 用户手动切到分享页后，不因为工具切换而强制跳走。
- 页签自身不改变检查器宽度（240–280pt），不做动画位移。

**文案**

- 页签名：`标注` / `分享外观`
- 开关说明：`开启后复制与导出应用外观；画布保持原图。`
- 关闭态：`关闭时不改变导出图像；再次开启会恢复上次的模板与参数。`

### 7.2 分享页控件

从上到下：

1. **总开关** + 说明文字。
2. **导出预览**：208×117，`scaledToFit`，透明背景棋盘格；渲染中显示小号 `ProgressView`；点击打开大图 sheet。
3. **模板**：8 个预设，4×2 色块，48×27；选中描边强调色。
4. **留白**：0–16%，右侧显示 `≈N px`（按当前导出尺寸的参考边换算）。
5. **圆角**：0–24，按参考边比例换算；显示当前导出尺寸下的 ≈px。
6. **投影**：0–60%，0 即无投影；高级项（模糊/偏移）放在“更多”里，A 阶段可只暴露不透明度。
7. **描边**：`无 / 细 / 标准 / 粗` 四段 + 颜色 `自动 / 黑 / 白 / 自定义`。
8. **背景**：模板 + 自定义纯色（`ColorPicker` 写入 `.solid`）；渐变编辑放 P1/P2。
9. **重置**：回到当前模板的默认值；如果当前是自定义，回到“上次选中的模板”。
10. **大图预览**：打开 sheet。

控件全部用 `DS.Space` / `DS.Typography` / `DS.Control` 的既有刻度；滑杆使用系统 `Slider`，不新造视觉。

### 7.3 状态机

| 当前状态 | 事件 | 下一状态 | 行为 |
|---|---|---|---|
| 关闭 | 开关打开 | 开启/渲染中 | `style = lastEnabledMockupStyle ?? preset(global)`；调度预览；切到分享页 |
| 开启/就绪 | 开关关闭 | 关闭 | `lastEnabledMockupStyle = style`；`style = nil`；取消预览任务；控件置灰 |
| 开启/就绪 | 选模板 | 开启/渲染中 | 整体替换样式；`selectedPreset = preset`；调度预览 + 历史写回 |
| 开启/就绪 | 改滑杆/颜色 | 开启/自定义/渲染中 | `selectedPreset = nil`；调度预览 + 历史写回 |
| 开启/渲染中 | 新改动 | 开启/渲染中 | 取消旧任务，generation++，重新防抖 |
| 开启/渲染中 | 渲染成功 | 开启/就绪 | 更新 `sharePreview` |
| 开启/渲染中 | 渲染失败 | 开启/预览失败 | `sharePreviewState = .failed(message)`；保留上一张预览 |
| 任意 | 切换标签/关闭窗口 | 不变 | 取消预览任务；flush 历史写回；不弹“未保存标注” |

**状态字段**

```swift
@Published public var mockupStyle: MockupStyle?
@Published public private(set) var sharePreview: CGImage?
@Published public private(set) var sharePreviewState: SharePreviewState
@Published public private(set) var sharePreset: MockupPreset?
private var lastEnabledMockupStyle: MockupStyle?
private var sharePreviewTask: Task<Void, Never>?
private var sharePreviewGeneration = 0
private var shareStyleCommitTask: Task<Void, Never>?
```

`SharePreviewState` 定义在 App 层：`.idle` / `.rendering` / `.ready` / `.failed(String)`。

**样式是否进入 dirty**

不进入。样式是“呈现偏好”，不是标注内容：

- 有 `sourceEntryID` 时，样式改动 500ms 防抖写回 `updateMockupStyle`，关窗前 flush；历史缩略图随之更新。
- 无 `sourceEntryID`（编辑器先开、历史晚到）时，先存在内存；`attachSourceEntry` 后补写一次。
- 样式同时写入 `PreferenceKeys.editorMockupLastStyleJSON`，作为下次“开启”的恢复值；关闭编辑器不丢。
- 关闭确认仍只针对标注/裁剪；文案保持“未保存的标注”。如果以后要提示样式，再单独改文案，不混进这次。

### 7.4 预览

```text
document ──Renderer.render(maximumDimension: 1200)──> annotated
annotated ──MockupRenderer.render(style)────────────> preview
```

- 1200px 长边：5K/6K 原图降采样后合成，预览足够大图 sheet 使用。
- 120ms 防抖；`sharePreviewGeneration` 丢弃过期结果；全部在 `Task.detached(priority: .userInitiated)`。
- 只在分享页可见、或大图 sheet 打开、或刚切换开关时渲染；标注页编辑时不渲染，切回分享页再刷新。
- 预览失败：`Preview failed: %@` + 保留上一张；不静默留灰块。
- 预览的宽高比必须与导出完全一致（由同一个 `MockupLayout` 计算）；预览只是缩放，不是另一种布局。

**大图 sheet**

- 520×?，`scaledToFit`，透明背景棋盘格。
- 底部：`复制` / `保存…` / `完成`。
- 显示当前尺寸的文字：`导出尺寸 3024 × 1964 · 留白 8% · 描边 2 px`。
- Esc 关闭；不写文件、不改历史。

### 7.5 输出与持久化

**复制**

- 底栏 `复制` 改为菜单：
  - `复制分享图`（样式开启时可用，`⌘C`）
  - `复制原图`（`⌥⌘C`）
- 样式关闭时，主按钮就是“复制”，菜单里只有“复制原图”（或隐藏菜单）。
- Toast 文案区分：`已复制分享图` / `已复制原图` / `复制失败：%@`。

**保存**

- `⌘S` 始终导出当前呈现（样式开启则带外观）。
- 文件名默认 `Snapshot.png`；格式按扩展名。
- 透明背景 + JPEG：**在分享页内提前提示**；同时 `save` 的格式决策要把 `style.background.isTransparent` 纳入，不能只看 `doc.baseImage`。如果用户仍选 JPEG，按现有 `flattenedOnWhite` 铺白底，并在保存后 toast 说明。

**存入历史**

- 继续存 raw 图 + `mockupStyleJSON`；不烘焙。
- 样式改动防抖写回 `updateMockupStyle`；覆盖原图的 `replaceImage + updateMockupStyle` 合并为一次事务（P1，见 §14）。
- 历史缩略图按样式即时渲染，已有机制不变。

**全局设置与本次覆盖**

- 设置里的「分享外观」仍是**新截图的默认值**，只对区域/fullscreen 生效。
- 编辑器里的开关是**本次导出覆盖**，不回写设置。
- 分享页底部一行说明：`设置中的模板只影响新截图；这里只影响当前图片。`

### 7.6 边框规格

**定义**

描边沿截图内容圆角裁剪的**内侧**绘制，不改变画布尺寸。留白是内容外的空白，描边是内容边缘的线，两者独立。

**宽度**

- 存储：`borderWidthRatio`（相对参考边）。
- UI 四段：`无 / 细 / 标准 / 粗`，映射 `0 / 0.0004 / 0.0008 / 0.0016`（可在实现时按视觉效果微调）。
- 显示：按当前导出尺寸的参考边换算成 `≈N px`；1px 以下不显示小数，四舍五入到 0.5px。
- 渲染：`width = max(1, round(ratio × reference))`（ratio > 0 时）；上限 `min(imageShortEdge × 0.02, 12)`，避免异常值。

**颜色**

```swift
public enum BorderColor: Codable, Equatable, Sendable {
    case automatic
    case custom(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)
}
```

自动规则：

- 背景为深色纯色/渐变（平均亮度 < 0.5）→ 白色 55%；
- 背景为浅色纯色/渐变 → 黑色 18%；
- 背景透明 → 白色 55%（默认在深色演示/幻灯片上更常见），用户可改。

**绘制**

- 先 `clip` 到内容圆角路径；
- 内缩 `borderWidth / 2` 生成描边路径，圆角半径同步减 `borderWidth / 2`；
- `lineWidth = borderWidth`，描边；
- 不参与阴影，不改变 `contentRect`。

**预设**

8 个现有预设的 `borderWidthRatio` 默认 0，保持旧观感；用户选“细/标准/粗”后才出现描边。`lastEnabledMockupStyle` 会记住用户的选择。

### 7.7 窗口 / 滚动 / 透明

**窗口截图**

- 捕获时 `MockupPolicy` 不套分享外观，但窗口浮窗样式本身就是一个 `MockupStyle`（透明背景 + 圆角 + 投影）。
- 编辑器从 context 拿到这个样式，默认开启；用户可以换模板或关闭。关闭后回到无圆角的原图，这是预期行为。
- 分享页顶部一行：`窗口截图默认浮窗外观；这里的改动只影响本次导出。`

**滚动长图**

- 捕获时不套样式，编辑器默认关闭。
- 允许开启；`reference = min(long, 1.8 × short)` 已经避免超长图上下留白过大。
- 分享页顶部一行：`滚动长图默认原图；开启后按长图比例留白。`

**透明背景**

- `.transparent` 背景在预览与画布中用棋盘格表示。
- 导出 PNG 保留透明；JPEG 铺白底。分享页内提前提示，不等到保存后。
- `MockupStyle.Background` 增加 `var isTransparent: Bool`，避免每个调用点自己 switch。

### 7.8 键盘与辅助功能

- `⌘B`：开关分享外观。
- `⌥⌘C`：复制原图（样式开启时）。
- `⌘S` / `⌥⌘S`：保持现状（导出 / 存入历史）。
- `⇧⌘B`：循环模板（可选；如果不想加隐藏按钮，可只在分享页提供，不占全局快捷键）。
- 每个滑杆有 `accessibilityLabel` 与当前值；开关有 `accessibilityValue`（开/关）；预览有 `accessibilityLabel("导出预览，点击放大")`。
- 不使用颜色作为唯一状态指示：开关同时有图标/文案/描边。

### 7.9 错误与空态

| 场景 | 表现 |
|---|---|
| 预览渲染中 | 预览区小号 `ProgressView`，保留上一张 |
| 预览失败 | `预览失败：%@`，保留上一张；重试按钮 |
| 无图片/文档 | 分享页显示“当前没有可预览的图片” |
| 历史写回失败 | 轻量 toast：`样式未能写回历史：%@`；不阻塞编辑 |
| 复制失败 | `复制失败：%@`；保留当前状态 |
| 保存取消 | 无 toast；关闭确认按现有逻辑 |
| 透明 + JPEG | 分享页内联提示；保存后 toast 说明已铺白底 |

---

## 8. 数据模型

### 8.1 `MockupStyle` v2

新增字段：

```swift
public var borderWidthRatio: CGFloat = 0
public var borderColor: BorderColor = .automatic
```

保留字段：

```swift
public var version: Int = 2
public var background: Background
public var paddingRatio: CGFloat
public var cornerRadiusRatio: CGFloat
public var shadowBlurRatio: CGFloat
public var shadowOpacity: CGFloat
public var shadowOffsetRatio: CGFloat
```

**迁移**

- 实现自定义 `init(from:)`，所有字段 `decodeIfPresent`，缺失时用默认值：
  - `version` → 1
  - `background` → `.transparent`
  - `paddingRatio` → 0.08
  - `cornerRadiusRatio` → 0.012
  - `shadowBlurRatio` → 0.03
  - `shadowOpacity` → 0.28
  - `shadowOffsetRatio` → 0.012
  - `borderWidthRatio` → 0
  - `borderColor` → `.automatic`
- 编码继续用合成 `encode(to:)`，写入 `version = 2`。
- 旧版本 App 解码新 JSON 时会忽略未知字段，不会崩；但会丢失边框，这是可接受的降级。
- 新增 `MockupStyleTests`：
  - 用当前 v1 JSON fixture 解码，断言所有旧字段与默认边框；
  - 编码后再解码，断言 `borderWidthRatio` / `borderColor` 往返；
  - 未知字段不导致失败；
  - `borderWidthRatio` 极端值不产生负宽度。

### 8.2 `MockupLayout`

见 §6.3。补充：

- `contentRect` 的坐标约定是**画布坐标、原点左下**；SwiftUI/NSView 在 B 阶段映射时统一转换，避免两套坐标系。
- 提供 `func contentRect(in origin: CGPoint, scale: CGFloat) -> CGRect` 作为 B 的视图映射辅助；A 可以不用。
- 不把 view 尺寸、zoom、pan 放进 `MockupLayout`；它只描述“图片像素 → 导出画布”的几何，视图缩放是 B 的事。

### 8.3 偏好键

新增：

```swift
public static let editorMockupLastStyleJSON = "editor_mockupLastStyleJSON"
```

默认 `nil`。只保存“上次开启的样式”，不保存“是否开启”；新编辑器是否开启由 context 决定，避免隐式继承。

编码/解码用 `JSONEncoder` / `JSONDecoder`；失败时静默丢弃并回退到全局模板，不阻塞编辑器。

### 8.4 历史 JSON

- 继续使用 `HistoryMockupPresenter.styleJSON(for:)` 的格式。
- `updateMockupStyle` 只改元数据，不动加密原图。
- 写回失败不改变本地 `mockupStyle`，下次改动会重试。

---

## 9. 渲染与性能

### 9.1 预览管线

```text
nodes/baseImage
   │  Renderer.render(document, maximumDimension: 1200)
   ▼
annotated (≤1200px)
   │  MockupRenderer.render(annotated, style)   // 或 layout + draw
   ▼
preview (canvas = annotated + 2×padding)
```

- 1200px 足够 208pt 预览和 520pt 大图；Retina 2x 下大图约 1040px。
- 全部在后台线程；主线程只接收 `CGImage` 并 `needsDisplay`。
- 预览失败保留上一张，避免闪白。
- 预览与导出的比例一致；预览只是缩放。

### 9.2 导出管线

- 保持现状：`Renderer.render(document)` 全分辨率 → `MockupRenderer.render(style)` → 编码。
- 边框在 `MockupRenderer.draw` 内完成，导出尺寸不变。
- 透明背景 + JPEG 的格式决策见 §7.5。
- 可选优化（P1）：按 `document` 内容哈希 + `style` 哈希缓存最近一次导出图，连续“复制→保存”不重复渲染。不是 A 的必需项。

### 9.3 性能预算

| 场景 | 目标 | 说明 |
|---|---|---|
| 5K 图开关后首张预览 | ≤200ms | 1200px 降采样 + 合成 |
| 滑杆连续拖动 | 每帧 ≤16ms 主线程 | 预览在后台；主线程只更新状态 |
| 预览重算 | 120ms 防抖 + 丢弃过期 | 拖动结束前不排队 |
| 全分辨率导出 | 不阻塞主线程 | 现有 `Task.detached` 保持 |
| 内存 | 预览 ≤ 1200×1200×4B ≈ 5.8MB | 不含原图；导出仍是百 MB 级，需注意 6K + 大留白 |

### 9.4 失败处理

- 预览失败：文案 + 重试；不自动重试循环。
- 导出失败：现有 toast；不把“已保存”说成成功。
- 历史写回失败：toast；不阻塞关闭。
- 样式解码失败：回退到全局模板；不把旧图变成空白。

---

## 10. 文件结构

| 文件 | 动作 | 职责 |
|---|---|---|
| `Packages/CaptureCore/Sources/MockupStyle.swift` | 修改 | v2 字段、`BorderColor`、自定义解码、`isTransparent` |
| `Packages/CaptureCore/Sources/MockupLayout.swift` | 新建 | 唯一几何计算 |
| `Packages/CaptureCore/Sources/MockupRenderer.swift` | 修改 | `layout`、`draw`、边框、预览缩放、backdrop |
| `Packages/CaptureCore/Tests/CaptureCoreTests/MockupStyleMigrationTests.swift` | 新建 | v1→v2 解码、往返、极端值 |
| `Packages/CaptureCore/Tests/CaptureCoreTests/MockupRendererTests.swift` | 修改 | 边框像素、layout、透明、预览缩放 |
| `Packages/SharedKit/Sources/PreferenceKeys.swift` | 修改 | `editorMockupLastStyleJSON` |
| `App/SnapGlass/Sources/Editor/EditorViewModel.swift` | 修改 | `@Published` 样式/预览状态、`lastEnabledMockupStyle` |
| `App/SnapGlass/Sources/Editor/EditorViewModel+ShareAppearance.swift` | 新建 | 开关、预设、更新、重置、预览防抖、历史写回、偏好持久化 |
| `App/SnapGlass/Sources/Editor/EditorViewModel+Save.swift` | 修改 | 复制原图、样式快照、透明格式决策、历史样式写回 |
| `App/SnapGlass/Sources/Editor/ShareAppearanceInspectorView.swift` | 新建 | 分享页控件与预览 |
| `App/SnapGlass/Sources/Editor/ShareAppearancePreviewSheet.swift` | 新建 | 大图预览 |
| `App/SnapGlass/Sources/Editor/AnnotationInspectorView.swift` | 修改 | 页签与自动切换 |
| `App/SnapGlass/Sources/Editor/EditorView.swift` | 修改 | 底栏开关、复制菜单 |
| `App/SnapGlass/Sources/App.swift` | 修改 | 必要的命令/快捷键（如 `⌘B`） |
| `App/SnapGlass/Resources/{en,zh-Hans,ja,ko}.lproj/Localizable.strings` | 修改 | 新增文案 |
| `CHANGELOG.md` | 修改 | Unreleased 记录 |

**不新建**：不新增 SPM 包、不新增依赖、不新建第三栏、不改历史存储格式。

---

## 11. 测试计划

### 11.1 单元测试（CaptureCore）

- `MockupStyle` v1 JSON 解码：旧字段值不变，边框默认 0/自动。
- v2 编码往返：边框宽度、颜色、背景、投影全部保留。
- `MockupLayout`：
  - 8% 留白 + 3000×2000 → 画布 3480×2480，`contentRect` 正确；
  - 超长图参考边 `min(long, 1.8 × short)`；
  - 圆角不超过短边一半；
  - 边框宽度 > 0 时至少 1px，且不超过短边 2%；
  - 0 留白 + 0 圆角 + 0 投影 → 输出等于输入尺寸。
- `MockupRenderer`：
  - 边框像素在内容边缘内侧；
  - 透明背景 + 阴影不产生黑块；
  - 预览缩放不改变比例；
  - 6K 大留白不崩溃、不产生负尺寸。

### 11.2 编辑器测试（App）

- 开关：开 → `mockupStyle != nil`；关 → `nil`，`lastEnabledMockupStyle` 保留。
- 预设：选“深色”后样式等于 `MockupPreset.dark.style`；改滑杆后 `selectedPreset == nil`。
- 预览：连续改 5 次，只保留最后一次结果（generation 丢弃旧的）。
- 历史写回：有 `sourceEntryID` 时，500ms 内多次改动只写一次；关窗 flush。
- 复制：样式开启时 `⌘C` 走合成图；“复制原图”跳过样式。
- 透明 + JPEG：格式决策选 PNG 或提示铺白底。
- 关闭确认：只改样式不触发“未保存标注”提示。

### 11.3 手动矩阵

| 维度 | 取值 |
|---|---|
| 系统 | macOS 13、14、15、26（至少 13 与当前主力） |
| 外观 | 浅色、深色、降低透明度 |
| 缩放 | 1x、2x |
| 图片 | 区域 1200×800、5K 全屏、6K、竖图、超宽、透明自由圈选、滚动长图、窗口 |
| 语言 | en、zh-Hans、ja、ko |
| 输入 | 鼠标、触控板、键盘、VoiceOver |
| 输出 | PNG、JPEG、剪贴板、存历史、覆盖原图 |

---

## 12. 阶段与验收门

### M1 — 模型与渲染（0.5–1 天）

- `MockupStyle` v2 + 迁移测试；
- `MockupLayout`；
- `MockupRenderer.draw` + 边框 + 预览缩放；
- 验收：CaptureCore 测试全绿；旧 JSON 解码不变；边框像素测试通过。

### M2 — 编辑器状态与分享页（1.5–2 天）

- `EditorViewModel` 状态与 `+ShareAppearance`；
- 底栏开关；
- 检查器页签与 `ShareAppearanceInspectorView`；
- 四语言初版；
- 验收：开关、模板、滑杆、重置、关闭态；800×600 不裁切；预览在 200ms 内出现。

### M3 — 输出闭环（0.5–1 天）

- 大图 sheet；
- 复制原图菜单；
- 历史防抖写回与关窗 flush；
- 透明 + JPEG 提示；
- 验收：复制/导出/历史三者一致；旧历史重开恢复；样式改动不触发关闭确认。

### M4 — UX 收口（1–2 天，可与 M3 并行）

- 统一命名；
- 截图架右键「分享外观…」+「保存图片…」；
- 动作条主按钮文案随状态；
- 设置卡合并/说明；
- 验收：见 §14 的 P0 项。

### B 阶段（后续）

- B0 spike（开关隐藏）→ B1 缩放/平移 → B2 缓存/性能 → B3 视觉一致性/验收。
- 详见 §13。

---

## 13. 最终目标 B：画布 WYSIWYG

### 13.1 为什么 A 不会成为死路

A 已经把三件事固定下来：

1. **几何**：`MockupLayout` 是唯一的画布尺寸、内容矩形、圆角、描边、阴影计算；
2. **绘制**：`MockupRenderer.draw` 是唯一的绘制入口，画布和导出都调用它；
3. **状态**：`EditorViewModel.mockupStyle` 是唯一状态源，检查器和画布都读它。

B 不需要改模型、检查器、预览、历史写回或导出；只改画布的布局与绘制。

### 13.2 画布改造

`EditableAnnotationCanvasView` 当前：

- `imageRect(for:)` 用 `aspectFitRect(imageSize, in: bounds)` 算 `fitImageRect`；
- `zoomScale` 相对图片 fit；
- 所有命中测试、裁剪、OCR、手柄、文本编辑都从 `imageDisplayRect` 派生。

B 改为：

```text
layout = MockupLayout.make(imageSize: imageSize, style: shareStyle)   // nil → 现有行为
fitFrame = aspectFitRect(layout.canvasSize, in: bounds)
frame = zoom/pan(fitFrame)
contentRect = frame.origin + layout.contentRect * scale
imageDisplayRect = contentRect
```

- 绘制顺序：画布底色 → `MockupRenderer.draw`（背景、阴影、图片、描边）→ 交互中的标注 → 选择/裁剪/OCR/手柄。
- `imageDisplayRect` 仍是 `contentRect`，所以绝大多数映射代码不需要改。
- `fitImageRect` 语义改为 `fitContentRect`；`zoomScale = 1` 表示整个 frame 适配窗口，`actualSizeZoom` 仍按 `contentRect.width / image.width` 算 1:1。
- `clampedPan` 用 frame 尺寸，不用图片尺寸。
- 裁剪遮罩、文本编辑框、OCR 高亮、取色器全部继续用 `contentRect`。
- 透明背景：画布在 frame 内画棋盘格；`MockupRenderer.draw` 的 `backdrop` 负责在阴影清空内容区后把棋盘格补回来。

### 13.3 坐标与缩放

| 概念 | A | B |
|---|---|---|
| `zoomScale` | 相对图片 fit | 相对 frame fit |
| 1:1 | 图片像素 = 屏幕点 | 图片像素 = 屏幕点（frame 可能大于窗口） |
| 缩放百分比 | `imageDisplayRect.width / image.width` | `contentRect.width / image.width` |
| 缩放锚点 | 光标下的图片点 | 光标下的 frame 点 → 映射到图片点 |
| Pan 边界 | 图片 vs 窗口 | frame vs 窗口 |

B 必须先写一个小的缩放/锚点测试，验证：
- fit 时整个 frame 可见；
- 1:1 时图片像素与屏幕点一致；
- 光标锚点在缩放前后落在同一图片像素；
- 样式改变（留白 0→16%）后，fit 重新计算且不跳动到屏幕外。

### 13.4 缓存与性能

B 的主要风险不是画不出来，而是“拖动留白滑杆时每次重渲染标注”。

- 标注内容预览与外观布局解耦：`annotatedPreview` 只随 document 变化；`layout` 只随样式变化。
- 画布用 `CanvasRenderScale.quantize` 缓存 annotated preview；样式变化只改 `contentRect` 与 `draw`，不触发 `Renderer.render`。
- 如果内容尺寸跨过量化档位（例如 1024→768），允许一次重渲染；拖动结束后再补一次高质量预览。
- 目标：留白/圆角/投影滑杆拖动 60fps；主线程不出现 >16ms 的空档（Instruments 验证）。

### 13.5 视觉一致性

- 画布与导出共用 `MockupLayout` + `MockupRenderer.draw`。
- 新增黄金测试：同一张 1200px 图 + 同一 `MockupStyle`，一边走 `MockupRenderer.render` 生成 PNG，一边把画布绘制到同尺寸 bitmap，逐像素比较（允许抗锯齿容差）。
- 透明背景、描边、阴影、圆角四个 case 各一条。
- 画布缩放只是把同一几何乘以 scale；不允许画布自己另算 padding 或 radius。

### 13.6 B 的风险

| 风险 | 说明 | 缓解 |
|---|---|---|
| 坐标回归 | `imageDisplayRect` 被 20+ 处使用，改错会选中错位 | 保持 `imageDisplayRect = contentRect` 的契约；逐项跑选择/裁剪/OCR/文本测试 |
| 缩放锚点 | frame 与图片的 fit 基准不同 | 先写锚点单元测试，再改画布 |
| 性能 | 滑杆触发标注重渲染 | 内容/布局解耦 + 量化缓存 |
| 阴影裁剪 | 现有导出画布不含阴影外扩，阴影可能被裁 | 与导出一致；如需更大阴影，另加 `shadowMargin`，不在 B0 做 |
| 透明背景 | 阴影填充清空内容区会擦掉棋盘格 | `draw` 的 `backdrop` 回调 |
| 视觉不一致 | 画布用 AppKit，导出用 CG | 黄金测试 + 共用 draw |
| 旧版兼容 | B 上线后旧样式 JSON 仍要能解码 | A 的 v2 迁移先落地 |

### 13.7 B 的阶段

- **B0（spike，1–2 天）**：在 feature flag 后把 frame 画进画布，只读预览，不改变编辑；验证坐标、缩放、裁剪、OCR、文本。
- **B1（2–3 天）**：缩放/平移语义、fit/1:1、锚点、pan 边界。
- **B2（2–3 天）**：缓存与性能、量化、拖动流畅度。
- **B3（2–3 天）**：透明棋盘格、阴影、描边、黄金测试、四语言、无障碍。
- **B4**：默认开启，移除“画布为原图”的提示；A 的预览 sheet 保留为辅助。

---

## 14. 全应用 UX 清单

### P0（建议与 A 同批）

| # | 问题 | 证据 | 建议 |
|---|---|---|---|
| 1 | 编辑器看不到分享外观状态，⌘C 结果与画布不一致 | `EditorViewModel.swift:212`、`Save.swift:263-268` | 本次开关 + 预览 + 复制原图 |
| 2 | 同一功能 5 种叫法，入口分散 | `CapturePreferencesView.swift:149`、`HistoryView.swift:330`、`ShelfCardView.swift:118` | 统一「分享外观 / 复制分享图 / 复制原图」 |
| 3 | 截图架美化只有键盘可达，右键菜单没有 | `ShelfManager.swift:53`、`ShelfCardView.swift:198-227` | 右键 + 悬停补「分享外观…」「保存图片…」 |
| 4 | 检查器 X/Esc 即提交，Reset 固定浅色 | `MockupInspectorPanel.swift:251,315-342` | 区分「完成 / 取消」；Reset 回当前模板或关闭外观 |
| 5 | 截图架隐藏被下一次截图覆盖；容量满静默淘汰 | `ScreenshotShelfPresentationState.swift:28-41`、`ShelfManager.swift:203-210` | 尊重隐藏直到手动唤起；淘汰给一次性提示 |
| 6 | 6K 复制前串行渲染无进度；预览失败静默 | `CaptureViewModel+Capture.swift:517-522`、`MockupInspectorPanel.swift:60-78` | 防抖 + 进度；失败文案 |

### P1（下一版）

| # | 问题 | 证据 | 建议 |
|---|---|---|---|
| 7 | 美化开启时主按钮仍叫 Copy Image | `CaptureActionBarView.swift:63-71,189-222` | 文案随状态；chevron 分原图/分享图 |
| 8 | Save 与 Save to History 都叫保存 | `EditorView.swift:187-220` | 「导出图片…」「存入历史」；Copy 分裂菜单 |
| 9 | 两套美化设置竞争（区域/全屏 vs 窗口） | `CapturePreferencesView.swift:151,211`、`CaptureViewModel+Capture.swift:525-541` | 合并一张「分享外观」卡，注明适用模式 |
| 10 | 历史覆盖写两次，非原子 | `EditorViewModel+Save.swift:26-32` | 合并为一次图像 + 元数据事务 |
| 11 | 截图架键盘模式无键位提示 | `ScreenshotShelfView.swift:222-226` | 进入时一行提示条 |
| 12 | 保存面板一模态一非模态 | `CaptureViewModel+ScreenshotShelf.swift:191-195`、`Save.swift:107` | 统一非模态 |
| 13 | ⌘⇧3 / ⌘⇧S 与系统语义冲突 | `HotKeyManager.swift:14-23` | 设置页提示冲突，保留可改 |

### P2（观察）

- 历史工具栏没有美化入口（只在右键）。
- 检查器空状态占 240pt；是否自动收起需要单独评估，避免画布宽度跳动。
- Clear Shelf 无确认/撤销；可加撤销 toast。
- 6K 导出缓存；连续复制/保存不重复渲染。

---

## 15. 验收标准

### A

- [ ] 5K 区域截图：开关后 ≤200ms 出现预览；滑杆更新 ≤250ms；主线程无肉眼可见卡顿。
- [ ] 复制/导出结果与预览一致（背景、留白、圆角、投影、描边）。
- [ ] 「复制原图」返回原标注图；「复制分享图」返回合成图；toast 文案区分。
- [ ] 历史 raw + JSON 往返；重开编辑器样式恢复；旧 v1 JSON 仍能解码。
- [ ] 窗口截图默认浮窗外观；关闭后回到原图；滚动长图默认关闭。
- [ ] 透明背景 + JPEG 有明确提示；PNG 保留透明。
- [ ] 800×600 最小窗口不裁切；检查器 240pt 可用。
- [ ] 四语言键齐全；`scripts/check-localization.sh` 通过。
- [ ] VoiceOver 可读开关、滑杆、预览。
- [ ] 只改样式不触发“未保存标注”确认；关窗前历史样式写回 flush。

### B

- [ ] 画布显示背景、留白、圆角、投影、描边；标注编辑、选择、裁剪、OCR、文本编辑坐标不回归。
- [ ] fit 显示完整 frame；1:1 图片像素 = 屏幕点；光标锚点稳定。
- [ ] 留白/圆角/投影滑杆拖动 60fps；不触发全图标注重渲染。
- [ ] 画布与 `MockupRenderer.render` 黄金测试通过（4 个 case）。
- [ ] 透明棋盘格、阴影、描边在浅色/深色外观下正确。
- [ ] 窗口/滚动/5K/6K/竖图/超宽均通过。

---

## 16. 默认决策与未决问题

### 已定（用户已选 A，B 为最终目标）

- A 先行；B 为最终形态。
- 边框画在内容圆角内侧，不改变画布尺寸。
- 样式不进入标注撤销栈，不触发“未保存标注”确认。
- 历史有链接时防抖写回；无链接时记住为下次开启的样式。
- 编辑器允许覆盖窗口/滚动截图的默认外观，只影响本次导出。
- 统一命名「分享外观」；复制项「复制分享图 / 复制原图」。

### 需要用户确认的细节（不阻塞规格）

1. 描边四档的比例是否按“细 1px、标准 2px、粗 4px @ 2x 截图”来标定？当前给的是相对参考边的比例，UI 显示 ≈px。
2. 透明背景的自动描边默认白色 55% 是否合适？如果主要发浅色文档，改成黑色 18% 更稳。
3. 分享页是“检查器页签”还是“底栏弹出面板”？本规格选页签；如果更看重画布高度，可改为 popover。
4. 是否要在 A 阶段就加「设为新截图默认」按钮？当前不做，避免把本次覆盖和全局设置混在一起。

---

## 17. 不做的事

- 本轮不写产品代码、不提交、不跑构建。
- A 阶段不做画布 WYSIWYG。
- 不做每边独立留白、固定画布比例、背景图片、渐变编辑器。
- 不新增 SPM 依赖。
- 不改变捕获时的 `MockupPolicy` 默认行为；只允许编辑器覆盖。
- 不把样式烘焙进历史原图。
- 不改录制、截图架、历史存储的既有协议（除 P1 的原子写建议）。

---

## 附录 A：新增文案键（草案）

| Key | zh-Hans | 说明 |
|---|---|---|
| `Share Appearance` | 分享外观 | 页签/开关 |
| `Show a background, padding, corner radius, shadow and border` | 添加背景、留白、圆角、投影与描边 | 设置/说明 |
| `Export preview` | 导出预览 | 预览标题 |
| `Preview` | 预览 | 按钮 |
| `Border` | 描边 | 控件 |
| `Border width` | 描边宽度 | 控件 |
| `Border color` | 描边颜色 | 控件 |
| `Automatic` | 自动 | 颜色 |
| `None` | 无 | 宽度档位 |
| `Thin` | 细 | 宽度档位 |
| `Standard` | 标准 | 宽度档位 |
| `Thick` | 粗 | 宽度档位 |
| `Reset` | 重置 | 按钮 |
| `Copy Share Image` | 复制分享图 | 菜单 |
| `Copy Original Image` | 复制原图 | 菜单 |
| `Copied share image` | 已复制分享图 | toast |
| `Copied original image` | 已复制原图 | toast |
| `Window captures use the float look by default; changes apply to this export only` | 窗口截图默认浮窗外观；改动只影响本次导出 | 说明 |
| `Scrolling captures have no share appearance by default` | 滚动长图默认原图 | 说明 |
| `JPEG cannot keep a transparent background; it will be filled with white` | JPEG 不支持透明背景，将铺白底 | 提示 |
| `Rendering preview…` | 正在渲染预览… | 状态 |
| `Preview failed: %@` | 预览失败：%@ | 错误 |
| `Style could not be written back to history: %@` | 样式未能写回历史：%@ | 错误 |
| `Settings templates only affect new captures; this applies to the current image` | 设置中的模板只影响新截图；这里只影响当前图片 | 说明 |

四语言键与占位符必须一致；运行 `bash scripts/check-localization.sh`。

---

## 附录 B：快捷键

| 键 | 动作 | 范围 |
|---|---|---|
| `⌘B` | 开关分享外观 | 编辑器 |
| `⌥⌘C` | 复制原图（样式开启时） | 编辑器 |
| `⌘C` | 复制当前呈现（分享图/原图） | 编辑器 |
| `⌘S` | 导出图片 | 编辑器 |
| `⌥⌘S` | 存入历史 | 编辑器 |
| `⇧⌘B` | 循环模板（可选） | 编辑器 |
| `⌘0` / `⌘1` | 适应窗口 / 实际大小 | 编辑器画布（B 阶段语义调整） |

与截图架键盘模式的 `B / ⇧B` 保持同一心智：`B` 是分享外观，`⌘B` 是打开/开关。编辑器里 `B` 仍是模糊工具，不冲突，因为上下文不同；文档中要写明。

---

## 18. 实施增量（2026-11-23）

> 本节记录实现相对设计稿的差异，供 B 阶段接手。

### 已实现

- `MockupStyle` v2：`borderWidthRatio`、`borderColor`、`isTransparent`、自定义 `init(from:)`（v1 缺字段回退默认）；`version = 2`。
- `MockupLayout`：`referenceSide`、`canvasSize`、`contentRect`、`padding`、`cornerRadius`、`borderWidth`、`shadow`；`contentRect(in:scale:)` 供 B 阶段映射。
- `MockupRenderer`：`layout(for:style:)`、兼容入口 `outputSize`、`render(_:style:)`、`render(_:style:maximumDimension:)`、`draw(_:style:layout:in:origin:scale:backdrop:)`；描边画在内容圆角内侧。
- `EditorViewModel`：`mockupStyle` 改为 `@Published`；新增 `sharePreview`、`sharePreviewState`、`selectedMockupPreset`、`inspectorTab`、`captureMode`、`historyStyleUpdater`、`lastEnabledMockupStyle`、`baselineMockupStyle`、`lastCommittedMockupStyle`、预览/写回任务；新扩展 `EditorViewModel+ShareAppearance.swift`。
- UI：`AnnotationInspectorView` 顶部改为「标注 / 分享外观」页签；新增 `ShareAppearanceInspectorView`（模板、留白、圆角、投影、描边四档与颜色、自动颜色、重置、预览、上下文说明、JPEG 提示）；新增 `ShareAppearancePreviewSheet`；底栏新增「分享外观」开关（⌘B）与复制分裂菜单（复制分享图 / 复制原图，⌥⌘C）。
- 历史：样式改动 500ms 防抖写回 `updateMockupStyle`；编辑器关闭/换标签 flush；`attachSourceEntry` 补写；样式不进入 dirty。
- 文案：四语言新增 23 个键；统一「分享外观」术语；旧 Beautify 浮窗与历史菜单使用同一名称；浮窗注入应用语言，Reset 回到当前模板。
- 截图架：右键与辅助功能新增「分享外观…」；`ScreenshotShelfAction.inspectMockup` 接到既有 `onInspectMockup`。
- 测试：`MockupStyleMigrationTests`、`MockupRendererTests` 边框/布局/预览用例、`ShareAppearanceStateTests`。

### 相对设计稿的差异

- `MockupRenderer.draw` 需要 `style` 参数（背景、描边颜色无法只从几何推导）；设计稿 §6.4 已同步。
- 预览使用 `Renderer.render(document, maximumDimension: 1200)` 后直接 `MockupRenderer.render`；`MockupRenderer.render(_:style:maximumDimension:)` 也已提供，供 B/其他调用点使用。
- 编辑器预览在标注变化时强制刷新（`changeCount`），避免分享页打开时预览过期。
- 样式写回使用注入的 `historyStyleUpdater`，默认走 `HistoryActor.updateMockupStyle`；测试可注入闭包避免写真实历史。
- 为修复 `EditorInteractionTests` 既有编译缺口，把 `RecordingStorage` 抽到独立文件并加入该测试 target；另加入 `RecordingWindowExclusionRegistry.swift`。这是测试 target 的依赖修复，不是功能逻辑变更。

### 未完成 / B 阶段

- B0/B1/B2/B3：画布布局、缩放/平移、缓存、视觉一致性、黄金测试均未开始。
- 未做 GUI/真机/性能/VoiceOver/透明 JPEG 实际导出验收。
- P1：历史覆盖写两次的原子化、设置卡合并、截图架保存面板非模态、键盘模式提示条。
- P2：每边独立留白、固定画布比例、背景图片、渐变编辑、导出缓存。
