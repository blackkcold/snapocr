# SnapGlass 截图编辑器「分享外观」阶段 B — 画布实时外观设计

- 状态：B 阶段已实现（未提交）；A 的分享页与导出保持原契约
- 日期：2026-11-23
- 前置：阶段 A 已实现（编辑器开关、检查器分享页、实时预览、描边、复制原图；`MockupLayout` / `MockupRenderer.draw` / `EditorViewModel.mockupStyle` 已落地）
- 目标：把分享外观直接画进编辑画布，实现真正的所见即所得；编辑、选择、裁剪、OCR、文本、取色、缩放全部不回归
- 证据边界：基于当前实现与画布代码的静态分析与单元测试；未运行 GUI、未做性能剖析、未做真机验收

---

## 0. 一页结论

B 阶段不重写画布，只把画布的**显示层**从“原图 + 标注”换成“外观框 + 原图 + 标注”。

- **唯一不变量**：`imageDisplayRect` 仍然是图片在视图里的矩形，只是它现在等于 `layout.contentRect` 映射到视图后的 **content rect**。所有命中测试、选择手柄、裁剪、OCR、文本编辑、取色器继续只读 `imageDisplayRect`。
- **唯一几何**：`MockupLayout` 给出 `canvasSize`、`contentRect`、padding、radius、border、shadow；画布和导出共用。
- **唯一绘制**：`MockupRenderer.draw(image, style, layout, in:origin:scale:backdrop:)`；画布只负责算 frame rect、调用它、再画交互覆盖层。
- **唯一状态**：`EditorViewModel.mockupStyle`；画布只读，不新增第二份样式。

B 阶段分五步：B0 只读画布 spike（feature flag 后）、B1 缩放/平移语义、B2 缓存与性能、B3 透明/阴影/描边/黄金测试、B4 默认开启。预计 7.5–11.5 个开发日。

---

## 1. 现状与 B 的起点

### 1.1 A 已经提供的东西

| 能力 | 位置 | B 的用法 |
|---|---|---|
| `MockupLayout` | `Packages/CaptureCore/Sources/MockupLayout.swift` | 画布算 `canvasSize` / `contentRect`；导出同一份 |
| `MockupRenderer.draw` | `Packages/CaptureCore/Sources/MockupRenderer.swift` | 画布按 frame 的 origin/scale 调用；背景、阴影、图片、描边一次画完 |
| `mockupStyle` | `EditorViewModel.swift` / `+ShareAppearance` | 画布只读；开关/模板/滑杆已存在 |
| 共享的标注预览 | `Renderer.render(document, maximumDimension:)` | 画布继续用缓存的 annotated preview，不把整张 document 每帧画一遍 |
| 命中测试锚点 | `EditableAnnotationCanvasView.imageDisplayRect` | B 把它设为 content rect；其余代码不改语义 |

### 1.2 画布当前的关键路径

- `EditableAnnotationCanvasView.swift:draw`：填深色底 → `imageDisplayRect = imageRect(for:)` → 缓存 base/preview → 画图 → 画交互节点 → OCR/创建预览/裁剪/选择/取色覆盖层。
- `EditableAnnotationCanvasView+Zoom.swift`：`zoomScale` 相对图片 fit；`fitImageRect`；`imageRect(for:)`；`clampedPan`。
- `EditableAnnotationCanvasView+Mouse.swift`、`+Selection.swift`、`+Crop.swift`、`+OCR.swift`、`CanvasTextEditor.swift`：所有坐标都从 `imageDisplayRect` 派生。
- `EditableAnnotationCanvasRepresentable.swift`：`updateNSView` 在图片变化时重置 `zoomScale`/`panOffset`；样式目前不传入。

B 的改动集中在这三处：representable 传入 `shareStyle`；canvas `draw` 增加外观框；zoom 把 fit 基准从图片换成 frame。其余交互代码只做 `imageRect(for:)` → `contentRect` 的调用替换与审计。

---

## 2. 目标 / 非目标 / 反目标

### 目标

| # | 目标 | 验收 |
|---|---|---|
| B-G1 | 画布实时显示背景、留白、圆角、投影、描边 | 开关/模板/滑杆改动在下一帧可见 |
| B-G2 | 图片坐标与交互不回归 | 标注创建、选择、缩放、裁剪、OCR、文本、取色在 1x/2x/zoom 下都准确 |
| B-G3 | 画布与导出视觉一致 | 同一 document/style 在相同尺寸下黄金测试通过（容差内） |
| B-G4 | 样式改动不触发标注重渲染 | 拖动留白/圆角/投影滑杆时只改 frame/content rect |
| B-G5 | 缩放/平移语义清晰 | Fit 显示整张卡片；⌘1 图片像素 1:1；光标锚点稳定 |
| B-G6 | 透明背景、阴影、描边正确 | 棋盘格不被阴影填充擦掉；边框在内容内侧 |
| B-G7 | 可回滚 | feature flag 关闭立即回到 A 的画布 |

### 非目标（B 阶段）

- 不加每边独立留白、固定画布比例、背景图片、渐变编辑器。
- 不改变捕获时 `MockupPolicy` 的默认行为。
- 不把样式烘焙进原图或历史原图。
- 不重写标注文档/工具/撤销栈。
- 不改窗口截图浮窗的捕获时默认样式。

### 反目标

- 画布和导出各算一套 padding/radius/border，结果不一致。
- 样式滑杆每动一次就重渲染整张 5K 标注图，主线程卡顿。
- 把样式画在图片坐标之外，导致选择手柄/裁剪/OCR 全部偏移。
- 用 baked composed image 当画布底图，再在它上面画标注，造成导出二次套样式。
- 为了“看起来对”而在画布里缩放图片本身，破坏 1:1 与命中测试。

---

## 3. 方案比较

| 方案 | 做法 | 优点 | 代价 | 结论 |
|---|---|---|---|---|
| **B1 · 画布展示层**（推荐） | 保留原图/标注/坐标；画布算 `MockupLayout` 的 frame/content，先画外观再画标注 | 坐标语义不变；导出共用 draw；检查器/历史/预览全复用 | 需要处理缩放、缓存、透明/阴影 | **采用** |
| B2 · 独立实时预览栏 | 画布仍编辑原图，旁边加一个只读预览栏 | 风险最低；B0 可先做 | 不是画布 WYSIWYG；压缩画布宽度；最终体验不够 | 只作为 B0 的降级/验证手段，不作为最终 |
| B3 · 烘焙合成图 | 先把外观合成成图片，再在合成图上画标注 | 视觉直接 | 所有命中/裁剪/OCR/手柄要加 offset/scale；导出会二次套样式 | 不采用 |

B1 的核心不是“多画一层”，而是**把画布的内容矩形从 view bounds 里拿出来，变成 layout 的一个映射**。只要 `imageDisplayRect` 仍然指向图片，现有交互就继续工作。

---

## 4. 总体架构

```text
EditorViewModel
  ├─ mockupStyle: MockupStyle?          // 唯一状态
  ├─ share preview (1200px, 防抖)       // 检查器/大图 sheet，继续保留
  └─ document + nodes
            │
            ▼
EditableAnnotationCanvasRepresentable
  ├─ image / nodes / tool / ...
  └─ shareStyle: MockupStyle?           // 新增，只读
            │
            ▼
EditableAnnotationCanvasNSView
  ├─ layout = shareStyle.map(MockupLayout.make) ?? .raw(imageSize)
  ├─ frameRect  = fit/zoom/pan(layout.canvasSize)
  ├─ imageDisplayRect = layout.contentRect(in: frameRect.origin, scale: frameScale)
  ├─ 画布 draw:
  │    1. 工作区底色
  │    2. 透明背景棋盘格（frame 内）
  │    3. MockupRenderer.draw(preview, style, layout, origin: frameRect.origin, scale: frameScale, backdrop: checkerboard)
  │    4. 交互中的标注节点
  │    5. OCR / 创建预览 / 裁剪 / 选择 / 取色覆盖层
  └─ 所有鼠标/选择/裁剪/OCR/文本继续读 imageDisplayRect
```

### 4.1 数据流

- 样式改动：检查器 → `EditorViewModel.updateMockupStyle` → `@Published mockupStyle` → SwiftUI `updateNSView` → `view.shareStyle = style` → `needsDisplay`。
- 标注改动：`document.nodes` → representable update → `view.nodes` → 现有 preview 缓存失效 → 重渲染 annotated preview。
- 图片改动（裁剪/新图）：`view.image` 变化 → 重置 zoom/pan → 新 layout → 新 frame。
- 导出：`EditorViewModel+Save` 的 `MockupRenderer.render` 不变；画布和导出共用 `MockupLayout` 与 `draw`。

### 4.2 为什么不在画布外再包一层 SwiftUI

画布是 `NSViewRepresentable`，内部用 `CGContext` 绘制并处理鼠标。外面再包 SwiftUI 的 padding/shadow 只能改变显示，无法同步命中测试、裁剪、OCR、手柄；而且会引入两套坐标。B 必须把外观画进同一个 `NSView`，让 `imageDisplayRect` 保持唯一。

---

## 5. 几何契约（核心）

### 5.1 坐标定义

- 图片尺寸：`imageSize`（像素）。
- `layout = MockupLayout.make(imageSize: imageSize, style: style)`；`style == nil` 时用 `MockupLayout.raw(imageSize:)`（canvas = image，padding/radius/border/shadow = 0）。
- `layout.canvasSize`：导出画布尺寸（图片 + 2×padding）。
- `layout.contentRect`：图片在画布中的矩形，画布坐标，**原点左下**。
- 视图 bounds：点坐标，NSView 非 flipped（当前画布没有 `isFlipped` override）。
- `frameRect`：画布在视图中的矩形（可能超出 bounds）。
- `imageDisplayRect`：图片在视图中的矩形 = `layout.contentRect` 映射到视图；所有交互的锚点。

### 5.2 计算

```swift
// 1. fit：整张画布适配视图
fitFrameRect = aspectFitRect(layout.canvasSize, in: bounds)

// 2. zoom/pan 作用在 frame 上
let width  = fitFrameRect.width  * zoomScale
let height = fitFrameRect.height * zoomScale
let pan = clampedPan(panOffset, for: fitFrameRect, zoom: zoomScale)
frameRect = CGRect(
    x: fitFrameRect.midX + pan.width  - width / 2,
    y: fitFrameRect.midY + pan.height - height / 2,
    width: width,
    height: height
)

// 3. content rect：画布坐标 × frameScale
let frameScale = frameRect.width / layout.canvasSize.width
imageDisplayRect = layout.contentRect(in: frameRect.origin, scale: frameScale)

// 4. 图片像素比例（用于 1:1、缩放标签、预览缓存）
let imageScale = imageDisplayRect.width / imageSize.width
```

`MockupLayout.contentRect(in:scale:)` 已经存在（阶段 A 加的），B 直接使用。

### 5.3 Fit / 1:1 / 缩放

- `zoomScale == 1`：整张 **frame**（含留白、阴影、描边）适配视图。这是“Fit”。
- 图片像素 1:1：`contentRect.width == imageSize.width`，即
  ```swift
  actualSizeZoom = imageSize.width / fitContentRect.width
  ```
  其中 `fitContentRect` 是 zoom=1 时的 content rect。等价于 `layout.canvasSize.width / fitFrameRect.width`（image width 约掉）。
- 缩放范围：1...32（`CanvasZoomController.maximumScale`）。大图 ⌘1 需要约 8–13×，旧的 8× 上限会让 5K/6K 截图停在 90% 左右。
- 缩放锚点：以 **frame** 为基准计算相对位置；因为 content 是 frame 的固定比例，光标下的图片点在缩放前后保持不动。
  ```swift
  let currentFrame = frameRect(for: layout)
  let relX = (anchor.x - currentFrame.minX) / currentFrame.width
  let relY = (anchor.y - currentFrame.minY) / currentFrame.height
  zoomScale = clamped
  let newW = fitFrameRect.width * clamped
  let newH = fitFrameRect.height * clamped
  panOffset = clampedPan(
      CGSize(
          width: anchor.x + (0.5 - relX) * newW - fitFrameRect.midX,
          height: anchor.y + (0.5 - relY) * newH - fitFrameRect.midY
      ),
      for: fitFrameRect,
      zoom: clamped
  )
  ```
  这与现有 `applyZoom` 的形式一致，只是把 `imageDisplayRect`/`fitImageRect` 换成 `frameRect`/`fitFrameRect`。
- Pan 边界：用 **frame** 尺寸与 bounds 计算，不再用图片尺寸。图片小于视图时居中；frame 大于视图时允许拖到边缘。
  ```swift
  let limitX = max(0, (fitFrameRect.width * zoom - bounds.width) / 2)
  let limitY = max(0, (fitFrameRect.height * zoom - bounds.height) / 2)
  ```
- 缩放标签：`zoomScale == 1` 显示 “Fit”；大于 1 显示 `imageScale` 的百分比（图片像素比例），而不是 frame 比例。`onZoomChanged` 的 `pixelScale` 继续用 `imageDisplayRect.width / lastImageSize.width`。

### 5.4 开关样式时的过渡

目标：不要在开关分享外观时让图片突然跳走。

- 记录旧 `imageDisplayRect` 的中心与 `imageScale`。
- 新 layout 计算 `fitContentRect`。
- 如果旧 `imageScale > 0`，令
  ```swift
  zoomScale = clamp(imageScale * imageSize.width / fitContentRect.width, 1...32)
  ```
  然后按新 content 尺寸反推 frame origin，使 content 中心落在旧中心：
  ```swift
  let newContentW = fitContentRect.width * zoomScale
  let newContentH = fitContentRect.height * zoomScale
  let frameScale = (fitFrameRect.width * zoomScale) / layout.canvasSize.width
  let contentOrigin = CGPoint(
      x: oldCenter.x - newContentW / 2,
      y: oldCenter.y - newContentH / 2
  )
  let frameOrigin = CGPoint(
      x: contentOrigin.x - layout.contentRect.minX * frameScale,
      y: contentOrigin.y - layout.contentRect.minY * frameScale
  )
  panOffset = clampedPan(
      CGSize(
          width: frameOrigin.x - fitFrameRect.midX + (fitFrameRect.width * zoomScale) / 2,
          height: frameOrigin.y - fitFrameRect.midY + (fitFrameRect.height * zoomScale) / 2
      ),
      for: fitFrameRect,
      zoom: zoomScale
  )
  ```
- 如果旧 `imageScale == 0`（尚未布局），或新 `fitContentRect.width == 0`，直接 `zoomScale = 1; panOffset = .zero`。
- 图片变化（裁剪/新图）仍走现有规则：重置 zoom/pan，重新 fit。

### 5.5 几何测试

- `fitShowsWholeFrame`：bounds 800×600，image 1000×500，style padding 0.1；`frameRect` 完全在 bounds 内，`imageDisplayRect` 完全在 frame 内。
- `actualSizeUsesImagePixels`：调用 `actualSizeZoom` 后 `imageDisplayRect.width ≈ image.width`。
- `zoomAnchorKeepsImagePoint`：给定 anchor，`applyZoom(2, around: anchor)` 前后同一归一化图片点落在同一视图点（±0.5pt）。
- `panClampUsesFrame`：zoom>1 时把 pan 推过头，frame 不出现“图片已到边但 frame 还有空白”的错误。
- `togglePreservesImageCenter`：启用/关闭 style，`imageDisplayRect.mid` 与 `imageScale` 保持（±1pt / ±0.01）。
- `hitTestUsesContentRect`：padding 内的点不产生标注；content 边界的点映射到 0/1。

---

## 6. 画布绘制

### 6.1 绘制顺序

```text
1. context.fill(bounds)                          // 工作区深色底
2. if style != nil && style.background.isTransparent:
       drawCheckerboard(in: frameRect)
3. if style != nil:
       MockupRenderer.draw(
           displayImage, style, layout,
           in: context,
           origin: frameRect.origin,
           scale: frameScale,
           backdrop: { ctx, rect in drawCheckerboard(ctx, rect) }
       )
   else:
       context.draw(displayImage, in: imageDisplayRect)
4. 交互中的节点（拖拽/缩放/样式滑杆）
5. OCR overlay
6. 创建预览 / 裁剪 / 选择手柄 / 取色 overlay
```

- `MockupRenderer.draw` 自己画背景、阴影、圆角裁剪图片、描边；画布不要再画一遍背景。
- `displayImage` 是缓存的 annotated preview（标注已烘焙），不是原图；它是 `MockupRenderer.draw` 的图片参数，会被缩放到 `layout.contentRect`。
- 透明背景：画布先画棋盘格到 frame；`draw` 的阴影填充会 `clear(contentRect)`，随后 `backdrop` 把棋盘格补回 content 区域；再画图片。这样透明源/自由圈选的 alpha 不会变成黑块。
- 非透明背景：`draw` 的背景覆盖棋盘格，不需要 backdrop；传了也无害。
- 边框：`draw` 在圆角裁剪内侧画，画布与导出一致。

### 6.2 棋盘格

- 在画布内用 `CGContext` 画 8pt 方格；颜色用 `NSColor.textBackgroundColor` / `controlBackgroundColor`，跟随浅色/深色外观。
- 缓存一张 16×16 的 pattern image 或 `CGPattern`，避免每帧画几百个矩形。
- 只在 `style.background.isTransparent` 时画；非透明背景不需要。
- 棋盘格只覆盖 `frameRect`（导出画布），不覆盖整个工作区；工作区仍是深色。

### 6.3 非 flipped 假设

- 当前 `EditableAnnotationCanvasNSView` 没有 `isFlipped` override，原点左下，与 `MockupLayout`/`draw` 的坐标一致。
- B 的实现必须保留这个假设；在 `draw` 里加一条注释和测试。如果未来改成 flipped，`draw` 需要翻转 y 轴，不能在画布内另算 padding。

### 6.4 阴影裁剪

- `MockupRenderer.draw` 的阴影被裁剪在 `layout.canvasSize` 内；画布与导出一致。
- 现有预设的 padding 通常大于 shadow blur；如果用户把 shadow 调得很大，边缘可能被裁。B 不新增 `shadowMargin`，保持与导出一致；如后续要加，必须先改导出画布尺寸，不能只改画布。

### 6.5 视觉细节

- 工作区深色不变，让浅色卡片突出；深色外观下卡片与工作区靠留白/阴影区分。
- 选择手柄当前是白填充 + 黑描边，在浅色背景上仍可见；B 不改手柄视觉。
- OCR 高亮/裁剪遮罩继续用 `imageDisplayRect`；padding 区域不参与遮罩。
- 取色器悬浮标签在卡片外时仍显示在画布上；不裁剪到 frame。

---

## 7. 交互不变量

B 的硬约束：**所有交互只读 `imageDisplayRect`，不读 `frameRect`**。

| 交互 | 位置 | B 的改动 |
|---|---|---|
| 鼠标按下/拖动/坐标映射 | `+Mouse.swift` | 无；`imageDisplayRect` 已是 content rect |
| 选择/手柄/命中容差 | `+Selection.swift` | 无；容差按 `imageDisplayRect` 宽度算 |
| 裁剪遮罩/移动/缩放 | `+Crop.swift` | 无；遮罩只盖 content |
| OCR 行/文本选择 | `+OCR.swift` / `+OCRInteraction.swift` | `imageRect(for:)` 改为 contentRect 计算 |
| 内联文本编辑 | `CanvasTextEditor.swift` | `refreshTextEntryLayout` 改为 contentRect |
| 取色器 | `+Selection.swift` / canvas | 无；坐标从 `imageDisplayRect` 派生 |
| 垂直裁剪 | `+Crop.swift` | 无；content rect 可能很窄，按现有比例 |
| 拖拽/缩放节点 | `+Resize.swift` | 无 |
| 缩放/平移/滚动 | `+Zoom.swift` / `+Mouse.swift` | frame 基准重写；`clampedPan` 用 frame |

**审计清单**：所有 `imageRect(for:`、`fitImageRect`、`lastImageSize`、`imageDisplayRect =` 的调用点都要过一遍。当前已知：

- `+Zoom.swift`：`imageRect(for:)`、`fitImageRect`、`applyZoom`、`refreshTextEntryLayout`、`notifyZoomChanged`。
- `+OCR.swift:182`：`imageDisplayRect = imageRect(for:)`。
- `+Mouse.swift:71`：`clampedPan(for: fitImageRect)`。
- `+Zoom.swift:166`：滚轮 pan 的 `fitImageRect`。
- `draw`：`imageDisplayRect = imageRect(for:)`。
- `CanvasTextEditor` 读 `imageDisplayRect`（不改）。

---

## 8. 缓存与性能

### 8.1 内容预览与外观分离

- **annotated preview**：只随 document（图片/标注）变化；样式变化不触发重渲染。
- **layout/frame/content**：只随样式/缩放/窗口变化；每帧重算，纯数学，成本可忽略。
- 画布 `draw` 里不再因为 `imageDisplayRect` 尺寸变化而同步 `Renderer.render` 整张图。

### 8.2 预览目标尺寸

- 当前 `CanvasRenderScale.quantize(max(imageDisplayRect) * backingScale)` 依赖 content rect；B 中 content 会因 padding 变小，样式滑杆可能跨量化档位。
- B 的目标：用 **frameRect** 的尺寸（`max(frameRect.width, frameRect.height) * backingScale`）作为预览目标，因为 frame 是画布在视图中的整体尺寸，样式改变时变化较小；preview 画进更小的 content 时只是缩小，不会糊。
- 如果 frame 尺寸仍跨档位，B2 允许一次后台重渲染；拖动结束后补一张高质量。
- 备选：固定 2048 或 4096 的 annotated preview，样式变化完全零重渲染；代价是内存/缩放清晰度。B2 用 Instruments 在 5K/6K 上比较后决定。

### 8.3 主线程预算

| 场景 | 目标 |
|---|---|
| 样式滑杆拖动 | 60fps；每帧只做 layout + draw，不重渲染标注 |
| 标注拖动/缩放 | 沿用现有 live node 绘制，不因 B 变慢 |
| 缩放/平移 | 60fps；只改 frame/content，不重渲染 |
| 首次打开/裁剪 | 允许一次 annotated preview 渲染；后台/缓存 |
| 5K/6K 导出 | 仍走全分辨率 `MockupRenderer.render`，不因 B 改变 |

### 8.4 缓存失效规则

- `nodes` 变 → annotated preview 失效。
- `image` 变 → base/preview 全失效，zoom/pan 重置。
- `shareStyle` 变 → 只重算 layout；annotated preview 不失效。
- `bounds`/backingScale 变 → frame 重算；preview 目标跨档位时才重渲染。
- `zoomScale`/pan 变 → frame/content 重算；preview 目标跨档位时才重渲染。

---

## 9. UI / UX

### 9.1 分享页文案

- A 现在的说明是“添加背景、留白与投影”；B 改为明确的“画布、复制与导出都应用外观”。
- 新文案键（四语言）：
  - `Canvas, copy and export use this appearance` → 画布、复制与导出都应用外观
  - `Canvas preview is on`（可选状态标签）→ 画布预览已开启
- 分享页的“导出预览”卡片继续保留：它用于 1:1/透明检查；画布本身已经是实时预览。
- 大图 sheet 继续保留：用于透明/描边/1:1 核对，不重复主画布职责。

### 9.2 画布状态

- 开启外观时，画布直接显示卡片；不需要额外的“预览模式”开关。
- 底栏开关保持；`⌘B` 开关。
- 如果 feature flag 关闭（B0/B1 期间），画布保持 A 的原图；分享页文案提示“画布预览将在后续版本开启”。
- B4 默认开启后，移除 A 的“画布保持原图”类文案。

### 9.3 视觉

- 工作区深色背景不变；卡片在深色上更清楚。
- 透明背景在画布内用棋盘格；导出 PNG 仍透明。
- 选择/裁剪/OCR 覆盖层颜色不变；在浅色卡片上已有黑/白描边，保持可读。
- 不在画布上加“分享外观”悬浮按钮；底栏和检查器已经足够。

### 9.4 可访问性

- 画布本身不新增控件；分享页开关/滑杆已有 label。
- 画布的可访问性描述继续是“Annotation canvas”；不把外观读成图片内容。
- 如果加“画布预览已开启”状态，用文字 + 图标，不只靠颜色。

---

## 10. 状态 / Feature Flag / 回滚

- 新偏好键（B0–B3）：
  ```swift
  public static let editorShareCanvasPreview = "editor_shareCanvasPreview"
  ```
  默认 `false`；在开发者设置页加“画布实时分享外观（实验）”，方便测试。
- `EditorView` 把 `shareStyle` 传给画布；flag 关闭时传 `nil`，画布完全走 A 路径。
- B4：默认值改 `true`（或删除键/迁移），移除开发者开关；保留一键回到 A 的能力一个版本。
- 回滚：flag 关 → 画布不读样式；分享页/导出/历史完全不受影响。

---

## 11. 文件级改动

| 文件 | 动作 | 职责 |
|---|---|---|
| `Packages/CaptureCore/Sources/MockupLayout.swift` | 修改 | 增加 `raw(imageSize:)`；`contentRect(in:scale:)` 已有；补 DocC |
| `Packages/CaptureCore/Sources/MockupRenderer.swift` | 可能修改 | `draw` 已有；补画布所需的注释/测试；不新增第二套绘制 |
| `App/SnapGlass/Sources/Editor/EditableAnnotationCanvasRepresentable.swift` | 修改 | 新增 `shareStyle: MockupStyle?`；`updateNSView` 传入并触发 needsDisplay |
| `App/SnapGlass/Sources/Editor/EditableAnnotationCanvasView.swift` | 修改 | 新增 `shareStyle`/`frameRect`/`fitFrameRect`；draw 走 `MockupRenderer.draw`；棋盘格；缓存目标改用 frame |
| `App/SnapGlass/Sources/Editor/EditableAnnotationCanvasView+Zoom.swift` | 重写核心 | `frameRect(for:)`、`contentRect(for:)`、`clampedPan`、`applyZoom`、`actualSizeZoom`、`refreshTextEntryLayout`、`notifyZoomChanged` |
| `App/SnapGlass/Sources/Editor/EditableAnnotationCanvasView+Mouse.swift` | 修改 | `clampedPan(for: fitFrameRect)` |
| `App/SnapGlass/Sources/Editor/EditableAnnotationCanvasView+OCR.swift` | 修改 | `imageDisplayRect = contentRect` |
| `App/SnapGlass/Sources/Editor/EditorView.swift` | 修改 | 传 `shareStyle` 给画布；B4 文案 |
| `App/SnapGlass/Sources/Editor/ShareAppearanceInspectorView.swift` | 修改 | B 文案；可选“画布预览已开启” |
| `App/SnapGlass/Sources/Editor/EditorViewModel+ShareAppearance.swift` | 可能修改 | 暴露 `isCanvasPreviewEnabled`（flag）；不新增样式状态 |
| `Packages/SharedKit/Sources/PreferenceKeys.swift` | 修改 | `editorShareCanvasPreview` + 默认值 |
| `App/SnapGlass/Sources/Windows/DeveloperPreferencesView.swift` | 修改 | 实验开关（B0–B3） |
| `App/SnapGlass/EditorTests/CanvasShareAppearanceTests.swift` | 新建 | fit/1:1/锚点/pan/开关过渡/命中 |
| `Packages/CaptureCore/Tests/CaptureCoreTests/MockupLayoutTests.swift` | 新建/扩展 | raw、contentRect(in:scale:)、边框/阴影几何 |
| `CHANGELOG.md` | 修改 | B0–B4 记录 |

**不新建**：不新增 SPM 包、不新增依赖、不新增第三栏、不重写 `AnnotationCanvasView`（历史遗留、当前编辑器未使用）。

---

## 12. 测试计划

### 12.1 几何单元测试（App）

- `fitShowsWholeFrame`
- `actualSizeUsesImagePixels`
- `zoomAnchorKeepsImagePoint`
- `panClampUsesFrame`
- `togglePreservesImageCenter`
- `hitTestUsesContentRect`
- `paddingClickDoesNotCreateAnnotation`
- `contentEdgeMapsToZeroAndOne`
- `styleChangeDoesNotResetZoom`（仅样式变化）

### 12.2 画布/导出黄金测试（B3）

- 固定小图（400×200）+ 2 个标注 + 一个 style（浅色/深色/透明/描边）。
- 画布在 1:1、frame 与导出同尺寸时绘制到 bitmap；`MockupRenderer.render` 生成同尺寸 PNG；逐像素比较，允许抗锯齿容差。
- 透明背景 + 阴影 case 必须覆盖 `backdrop` 路径。
- 边界：0 留白、0 圆角、0 投影、最大留白、描边四档。

### 12.3 交互回归（App）

- 在 padding 内点击不创建标注。
- 在 content 边缘创建标注，归一化坐标正确。
- 选择/拖拽/八向缩放/手柄命中在 1x/2x/zoom 下正确。
- 裁剪框移动/缩放/确认后，新图重新 fit。
- OCR 行覆盖在 content 上，点选/复制/转标注正确。
- 内联文本编辑器跟随 content rect，缩放/平移后仍对齐。
- 取色器在 content 内取色；padding 内不取色。
- 垂直裁剪长图在 content 内工作。

### 12.4 性能

- 5K/6K 图，拖动留白/圆角/投影滑杆 30 步：60fps，主线程无 >16ms 空档。
- 样式改动 0 次 `Renderer.render`（用 Instruments signpost/计数验证）。
- 缩放/平移 60fps；annotated preview 只在跨量化档位时重渲染。
- 内存：预览缓存不超过预算；不复制整张 6K 图到第二份。

### 12.5 手动矩阵

- macOS 13/14/15/26；浅色/深色/降低透明度；1x/2x。
- 5K/6K/竖图/超宽/滚动长图/窗口浮窗/自由圈选透明。
- en/zh-Hans/ja/ko；VoiceOver；键盘缩放（⌘0/⌘1/⌘+/⌘−）。

---

## 13. 阶段与验收门

| 阶段 | 内容 | 估算 | 验收 |
|---|---|---|---|
| **B0 · 只读 spike** | feature flag；传入 style；画布画 frame + `draw`；debug overlay 显示 frame/content；不改交互 | 1–2 天 | fit 完整显示卡片；在图片上创建标注位置正确；选择/裁剪/OCR/文本对齐；flag 关立即回 A |
| **B1 · 缩放/平移** | frame fit、1:1、zoom anchor、pan clamp、开关过渡 | 2–3 天 | 几何单测全绿；开关不跳；⌘0/⌘1 正确；所有 zoom 级别交互正确 |
| **B2 · 缓存/性能** | 内容/外观解耦；frame-based preview 目标；必要时后台重渲染；Instruments | 2–3 天 | 样式滑杆 60fps；0 次标注重渲染；5K/6K 无卡顿 |
| **B3 · 透明/阴影/描边/一致性** | 棋盘格、backdrop、border、黄金测试、4 语言、无障碍 | 2–3 天 | 画布/导出视觉一致；透明不变黑；边框/阴影正确；测试矩阵通过 |
| **B4 · 默认开启** | 默认 true/移除实验开关；文案；CHANGELOG | 0.5–1 天 | 默认路径全绿；回滚 flag 可用一个版本 |

总计 7.5–11.5 个开发日。B0 可独立合并（flag 关），B1–B3 可在同一分支推进。

---

## 14. 风险与缓解

| 风险 | 说明 | 缓解 |
|---|---|---|
| 坐标回归 | `imageDisplayRect` 有 20+ 处使用，改错会选中错位 | 保持 `imageDisplayRect = contentRect` 契约；逐项跑选择/裁剪/OCR/文本测试；B0 debug overlay |
| 缩放锚点 | frame 与图片 fit 基准不同 | 用 frame 做 zoom 基准；content 是固定比例，图片点自然稳定；单测 |
| Pan 边界 | 用图片尺寸会把 frame 拖出屏幕 | `clampedPan` 改用 frame 尺寸 |
| 样式滑杆卡顿 | content 变小导致 preview 重渲染 | 内容/外观解耦；frame-based target；B2 量化/后台 |
| 视觉不一致 | 画布/导出各算几何 | 共用 `MockupLayout` + `MockupRenderer.draw`；黄金测试 |
| 透明+阴影 | clear 擦掉棋盘格 | `backdrop` 回调；透明 case 测试 |
| 阴影裁剪 | 与导出一致但可能看起来被切 | 不新增 margin；文档说明；需要时先改导出尺寸 |
| 开关跳变 | 图片缩放/中心突变 | 5.4 的 preserve center/scale 规则；单测 |
| 非 flipped 假设 | 未来改 flipped 会错位 | 注释 + 测试；不在画布内另算几何 |
| 性能回归 | 预览缓存失效 | B2 计数 `Renderer.render` 次数；不达标不上默认 |

---

## 15. 验收标准

- [ ] `zoomScale == 1` 时整个 frame（含 padding/shadow/border）完整可见。
- [ ] `⌘1` 时图片像素 1:1；缩放锚点在光标下的图片点保持。
- [ ] pan 边界按 frame 计算；图片小于视图时居中。
- [ ] 开关分享外观时图片中心与像素比例保持（或明确 reset 规则），无突兀跳变。
- [ ] padding 内点击不创建标注/不选中；content 内所有交互坐标正确。
- [ ] 选择/拖拽/缩放/裁剪/OCR/文本/取色/垂直裁剪全部通过回归。
- [ ] 画布与导出在同尺寸黄金测试通过（浅色/深色/透明/描边/阴影）。
- [ ] 样式滑杆 60fps；样式改动 0 次 annotated preview 重渲染；5K/6K 无主线程卡顿。
- [ ] 透明背景显示棋盘格；PNG 导出保留透明；JPEG 提示铺白。
- [ ] 浅色/深色/降低透明度、1x/2x、5K/6K/竖图/超宽/长图/窗口、四语言、VoiceOver 通过。
- [ ] feature flag 关闭立即回到 A 的画布；无数据/历史副作用。

---

## 16. 默认决策与未决问题

### 默认决策

- 采用 B1 画布展示层；不采用 baked image。
- `imageDisplayRect = contentRect`；交互不改语义。
- `zoomScale == 1` 是 frame fit；`⌘1` 是图片 1:1。
- 开关样式：Fit 状态下重新适配整张卡片；已放大时保持图片的屏幕宽度与中心。
- 工作区深色不变；透明用棋盘格。
- 预览目标用 frame 尺寸量化；B2 用 Instruments 决定是否改固定 2048/4096。
- feature flag 开发者开关；B4 默认开启并保留一个版本回滚。
- 阴影不新增 margin，保持与导出一致。

### 需要确认

1. 开关样式时是“保持图片中心/比例”（推荐）还是“直接 fit 整张卡片”？前者更适合放大编辑细节，后者更像预览。
2. 画布工作区是否在浅色外观下改为浅灰（更像设计工具），还是保持深色（更像截图工具）？
3. B0 是否先做独立预览栏作为降级验证，还是直接做画布 frame？
4. 预览缓存目标用 frame 量化还是固定 2048/4096？建议先 frame 量化，B2 实测后定。

---

## 17. 不做的事

- 不写产品代码（本文件只是 B 方案）。
- 不做每边独立留白、固定比例、背景图片、渐变编辑。
- 不改变 A 的检查器/历史/复制/导出契约。
- 不把样式写进标注文档或撤销栈。
- 不新增 SPM 依赖。
- 不在 B 阶段改窗口截图捕获逻辑。

---

## 附录 A：实现检查表

- [ ] `MockupLayout.raw(imageSize:)` 或 `style: MockupStyle?` 分支。
- [ ] `EditableAnnotationCanvasRepresentable` 传 `shareStyle`。
- [ ] `EditableAnnotationCanvasView` 存 `shareStyle`/`frameRect`/`fitFrameRect`。
- [ ] `draw` 先算 layout/frame/content，再画外观。
- [ ] 棋盘格 pattern 缓存；透明 + 阴影 `backdrop`。
- [ ] `+Zoom` 用 frame 基准；`clampedPan` 用 frame；`actualSizeZoom` 用 fitContent。
- [ ] `+Mouse`/`+OCR` 的 `fitImageRect`/`imageRect(for:)` 全部替换/审计。
- [ ] `refreshTextEntryLayout` 用 content rect。
- [ ] feature flag + 开发者开关。
- [ ] 几何单测 + 黄金测试 + 交互回归 + 性能计数。
- [ ] B4 文案与 CHANGELOG。

## 附录 B：与 A 的接口对照

| A 接口 | B 用法 |
|---|---|
| `MockupLayout.make(imageSize:style:)` | 画布每次 layout 计算 |
| `layout.canvasSize` | frame fit/zoom 的尺寸 |
| `layout.contentRect` | 映射成 `imageDisplayRect` |
| `layout.contentRect(in:scale:)` | 视图坐标映射 |
| `layout.borderWidth` | 画布无需单独画；`draw` 负责 |
| `MockupRenderer.draw` | 画布唯一外观绘制入口 |
| `EditorViewModel.mockupStyle` | 画布只读；不新增状态 |
| `Renderer.render(document, maximumDimension:)` | annotated preview |
| `MockupRenderer.render(style:)` | 导出；黄金测试基准 |

---

## 18. 实施增量（2026-11-23）

> 本节记录实际落地与设计稿的差异，供后续维护。

### 已实现

- `MockupLayout.raw(imageSize:)`：无外观时 canvas = 图片、所有处理参数为 0，画布与导出共用同一套几何代码。
- `EditableAnnotationCanvasNSView`：新增 `shareStyle`、`fitCanvasRect`、`canvasRect(for:)`、`imageRect(for:)`、`applyShareStyle(_:preservingPresentation:)`、棋盘格绘制。
- 绘制：工作区底 → 透明时棋盘格 → `MockupRenderer.draw`（背景/阴影/图片/描边）→ 交互节点 → OCR/创建预览/裁剪/选择/取色。`backdrop` 在阴影清空内容后补回棋盘格。
- 缩放：Fit = 整张卡片适配；⌘1 = 图片像素 1:1（上限 32×，大图需要约 8–13×）；缩放锚点以内容矩形为准，锚点下的图片点保持；pan 以 frame 边界夹取。
- 开关过渡：Fit 状态下开关重新适配整张卡片；已放大时保持图片的屏幕宽度与中心（与设计稿 §5.4 的“始终保持”不同，避免 Fit 时卡片被裁切）。
- 样式编辑（非开关）不改 `zoomScale`；只重新映射 frame/content。
- 预览缓存：标注预览按 `max(frame, bounds)` 量化，并以原图最长边封顶；样式滑杆与高倍缩放都不再触发逐帧标注重渲染。
- 画布与导出对齐：`MockupRenderer.draw` 在画布尺寸处裁剪，阴影像素不会超出导出画布；透明背景的棋盘格在 padding 与内容区使用同一 8 pt 尺寸与相位。
- 交互：点击卡片留白取消选择；取色标签在留白内按整张卡片定位；裁剪/文本/OCR/选择手柄继续只读内容矩形。
- `EditorView` 通过 `@AppStorage(editorShareCanvasPreview)` 传 `shareStyle`；开发者设置新增「编辑器画布」开关，默认开启，关闭即回 A 路径。
- 测试：`CanvasShareAppearanceGeometryTests`（13 个用例：fit、padding 命中、1:1、5K 1:1、锚点、开关、深度缩放开关、样式编辑、pan clamp、坐标往返、裁剪矩形、重置）；`MockupLayout.raw` 与边框 origin/scale、阴影裁剪、状态平衡测试。
- 验证：`scripts/test.sh` 全绿（CaptureCore 686、EditorInteractionTests 132、WindowLifecycle 41、BarcodePanel 7 及全部 package）。

### 仍未完成

- 未运行 GUI/真机/性能剖析/VoiceOver；画布与导出逐像素黄金测试尚未落地（当前依赖同一 `MockupLayout`/`draw` 调用与几何单测）。
- 透明 + 阴影的棋盘格视觉、6K/长图缩放清晰度、样式滑杆 60fps 需在真机验收。
- B 的非目标仍不做：每边独立留白、固定比例、背景图片、渐变编辑。
