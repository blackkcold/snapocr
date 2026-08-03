# SnapGlass 三项 Bug 修复实施计划

## TL;DR

> **快速摘要**: 修复截图坐标位移、OCR字形跳变、OCR 2048px降采样上限三个bug。坐标修复纠正 `quartzScreenRect` 的主屏假设和 `pixelCropRect` 的错误Y-flip公式；OCR渲染改为只绘制选区高亮/光标，保留原始截图像素；OCR降采样改为自适应tile路径，支持中等图片全分辨率和大图分块识别。
>
> **交付物**:
> - 修正的坐标转换（AreaSelectionPanel + SCKAdapter）及对应测试
> - 修正的OCR文本选区渲染（仅高亮和光标，无字体替代）
> - 自适应tile OCR管道（MemoryGuard + OCRPipeline + VisionOCREngine + PostProcessor）
>
> **预估工作量**: Medium
> **并行执行**: YES — 3 个 Wave
> **关键路径**: Task 1 → Task 2 → Task 16 → F1-F4

---

## Context

### 原始需求
修复 SnapGlass 三个已确认的 bug：截图位移、OCR 选中文字跳变、2048px OCR 降采样限制。

### 代码库调研发现

**Bug A — 截图位移**:
- `AreaSelectionPanel.quartzScreenRect` (L611-622): `CGDisplayBounds(CGMainDisplayID()).maxY - appKitRect.maxY` 仅对主显示器正确，副显示器坐标错误
- `SCKAdapter.pixelCropRect` (L349-371): `let localY = displayFrame.maxY - areaRect.maxY` 应为 `areaRect.minY - displayFrame.minY`
- 两个 Bug 在主显示器上恰好抵消，副显示器上叠加导致截图向上偏移
- 现有测试 `CaptureProtocolTests.swift:50` 编码了 Bug 2 的错误公式（期望 `y:1000`，正确值 `y:200`）
- CG 降级路径（`CaptureOrchestrator.fallbackArea`）同样受影响

**Bug B — OCR 选中文字跳变**:
- `EditableAnnotationCanvasView.drawSelectedOCRText` (L817-853): 用 `NSFont.systemFont` (San Francisco) 替代原始截图字体，通过 `horizontalScale` 水平拉伸
- `fittedOCRFont` (L1226-1232): 字体大小 ≈ 78% of bounding box height
- 未选中 OCR 行 (L758-767): 仅截图像素 + 半透明蓝色覆盖 — 正确行为
- 跳变原因: 系统字体 glyphs 与原始截图像素在宽度、baseline、字形上均不匹配

**Bug C — 2048px OCR 降采样上限**:
- `MemoryGuard.maxImageWidth = 2048` (L26), `needsDownsample` 仅检查宽度 (L42-44)
- `OCRPipeline.performMemoryGuard` 强制降采样所有 >2048px 图片
- 无 tile-based 替代路径，无取消检查，`PostProcessor` 为空壳

### 测试基础设施
- 159 个 @Test 分布在 14 个文件，8 个包
- **无多显示器/混合缩放因子测试**
- CI: `swift test --package-path Packages/<PackageName>` 循环

---

## Work Objectives

### 核心目标
修复三个 bug，每个仅做最小目标变更，不引入架构重写。

### 具体交付物
- Bug A: 修正的坐标公式（2处）+ 多显示器像素裁剪测试（4+新增）
- Bug B: 移除 OCR 选中文字的系统字体重绘，仅保留选区高亮和光标
- Bug C: 自适应 OCR 管道（全分辨率中等图 + tile 大图 + IoU 去重 + 阅读顺序 + 取消检查）

### Must Have
- 修正的坐标转换公式（正确适用于任意显示器排列）
- 移除系统字体替代绘制
- 自适应 tile OCR 管道，含 `Task.checkCancellation()`

### Must NOT Have (Guardrails)
- ❌ 不引入广义的规范坐标架构重写
- ❌ 不添加新依赖（第三方库）
- ❌ 不涉及云端 OCR
- ❌ 不修改 CI/xcodeproj/权限配置
- ❌ 不将 `SCDisplay.frame` 视为 AppKit Y-up
- ❌ 不通过仅将 2048 改为 4096 来"修复"降采样
- ❌ 不修改与三个 bug 无关的代码

---

## Verification Strategy

### 测试决策
- **基础设施存在**: YES（Swift Testing + XCTest）
- **自动化测试**: YES（TDD: 先写/修正测试 → 验证失败 → 实现 → 验证通过）
- **框架**: Swift Testing（`@Test`/`#expect`）

### QA 策略
每个任务包含 agent 可执行的 QA 场景。证据保存至 `.sisyphus/evidence/task-{N}-{scenario-slug}.{ext}`。
- **坐标转换**: 单元测试 (`swift test`)
- **OCR 渲染**: Playwright 截图对比
- **OCR 管道**: 程序化生成测试图像 → 验证 tile 合并结果

---

## Execution Strategy

### 并行执行 Wave

```
Wave 1 (立即开始 — Bug A 坐标修复):
├── Task 1: 修复 pixelCropRect 的 Y-flip 公式 [quick]
├── Task 2: 修复 quartzScreenRect 的主屏假设 [quick]
├── Task 3: 更新 pixelCropRect 测试期望值 [quick]
├── Task 4: 新增多显示器坐标转换测试 [deep]

Wave 2 (Wave 1 完成后 — Bug B + Bug C，最大并行):
├── Task 5: OCR 选区——绘制方法重构 [visual-engineering]
├── Task 6: OCR 选区——移除系统字体替代代码 [quick]
├── Task 7: OCR 选区——确认光标完整性 [quick]
├── Task 8: OCR 选区——视觉回归验证 [visual-engineering]
├── Task 9: MemoryGuard 自适应策略 [quick]
├── Task 10: Tile 分割与 Vision OCR 引擎 [deep]
├── Task 11: Tile 结果 IoU 去重与合并 [deep]
├── Task 12: 阅读顺序恢复 [quick]
├── Task 13: 取消检查与 Swift 6 并发安全 [quick]

Wave 3 (Wave 2 完成后 — 集成):
├── Task 14: OCRPipeline 集成 tile 路径 [deep]
├── Task 15: OCR tile 路径单元测试 [deep]
├── Task 16: 端到端验证 (pixelCropRect 调用链) [quick]
├── Task 17: CHANGELOG 更新 + swift-format/swiftlint [quick]

Wave FINAL (ALL 完成后 — 4 个并行审查):
├── F1: Plan Compliance Audit → F2: Code Quality → F3: QA → F4: Scope Fidelity
→ 呈现结果 → 等待用户确认

关键路径: Task 1 → Task 2 → Task 16 → F1-F4
最大并发: 9 (Wave 2)
```

---

## TODOs

### Bug A: 截图坐标位移

- [ ] 1. **修复 `pixelCropRect` 的 Y-flip 公式**

  **What to do**:
  - 在 `SCKAdapter.pixelCropRect` (L349-371)，将 `let localY = displayFrame.maxY - areaRect.maxY` 改为 `let localY = areaRect.minY - displayFrame.minY`
  - 原理：`SCDisplay.frame` 为 Quartz Y-down（原点=主屏左上），CGImage 原点也在左上。选区顶部在 `areaRect.minY`，显示器顶部在 `displayFrame.minY`，所以 `localY = areaRect.minY - displayFrame.minY` 给出正确的裁剪 Y 偏移

  **Must NOT do**: 不改变 X 轴逻辑，不引入新的坐标类型

  **Agent**: `quick` | **Wave**: 1 | **并行**: 与 Task 2-4 并行

  **References**:
  - `Packages/CaptureCore/Sources/SCKAdapter.swift:349-371` — 目标方法
  - `Packages/CaptureCore/Sources/SCKAdapter.swift:226-269` — `captureArea` 调用者
  - CGImage: 原点在左上角，Y向下

  **QA Scenarios**:
  ```
  Scenario: pixelCropRect on main display
    Tool: Bash (swift test --package-path Packages/CaptureCore --filter pixelCropRect)
    Steps: displayFrame=(0,0,1000,800), areaRect=(100,200,300,200), imageSize=(1000,800)
    Expected: cropRect.origin.y == 200 (not 600)
    Evidence: .sisyphus/evidence/task-1-main-display.txt

  Scenario: pixelCropRect on secondary display above main
    Tool: Bash
    Steps: displayFrame=(0,-800,1000,800), areaRect=(100,-600,300,200), imageSize=(2000,1600)
    Expected: localY = (-600) - (-800) = 200; cropY = 200*2 = 400
    Evidence: .sisyphus/evidence/task-1-secondary-display.txt
  ```

  **Commit**: `fix(CaptureCore): correct pixelCropRect Y-flip formula` | Files: `Packages/CaptureCore/Sources/SCKAdapter.swift`

---

- [ ] 2. **修复 `quartzScreenRect` 的主屏假设**

  **What to do**:
  - 在 `AreaSelectionPanel.AreaTrackingView.quartzScreenRect` (L611-622)，替换 `CGDisplayBounds(CGMainDisplayID())` 为找到选区所在显示器的正确方法
  - 用 `NSScreen.screens.first(where:)` 找到 `appKitRect` 中点所在的屏幕，并用 `CGDisplayBounds(displayID)` 获取该屏幕在 Quartz 全局坐标中的 bounds
  - Y-flip: `cgBounds.minY + (screen.frame.maxY - appKitRect.maxY)` — 等价于 `appKitRect.minY - screen.frame.minY + cgBounds.minY`（距离显示器底部 AppKit + 显示器顶部 Quartz）

  **Must NOT do**: 不改变 X 轴逻辑，不改变 `window.convertToScreen` 调用

  **Agent**: `quick` | **Wave**: 1 | **并行**: 与 Task 1,3,4 并行

  **References**:
  - `App/SnapGlass/Sources/Overlays/AreaSelectionPanel.swift:611-622` — 目标方法
  - `Packages/CaptureCore/Sources/SCKAdapter.swift:374-391` — `displayInfo(for:)` 中的 NSScreen 遍历模式

  **QA Scenarios**:
  ```
  Scenario: quartzScreenRect on main display (backward compatible)
    Tool: Code review / manual check
    Expected: Same output as before for main display selections
    Evidence: .sisyphus/evidence/task-2-regression.txt

  Scenario: quartzScreenRect on secondary display above main
    Tool: Code review with hypothetical coordinates
    Expected: Quartz Y within the target display's CGDisplayBounds range
    Evidence: .sisyphus/evidence/task-2-secondary.txt
  ```

  **Commit**: `fix(AreaSelectionPanel): use correct display bounds for quartzScreenRect Y-flip` | Files: `App/SnapGlass/Sources/Overlays/AreaSelectionPanel.swift`

---

- [ ] 3. **更新 pixelCropRect 测试期望值**

  **What to do**:
  - 在 `CaptureProtocolTests.swift:40-51`，将 `pixelCropRect_convertsDisplayPointsToPixels` 的期望值从 `y: 1000` 更新为 `y: 200`（`(150-50)*2 = 200`）
  - 添加 2 个新测试: 选区在显示器顶部（`localY == 0`）、选区在显示器中心

  **Agent**: `quick` | **Wave**: 1 | **并行**: 与 Task 1,2,4 并行 | **Blocked By**: Task 1

  **References**: `Packages/CaptureCore/Tests/CaptureCoreTests/CaptureProtocolTests.swift:40-51`

  **QA**:
  ```
  Scenario: All pixelCropRect tests pass
    Tool: swift test --package-path Packages/CaptureCore --filter pixelCropRect
    Expected: 4+ tests pass, exit code 0
    Evidence: .sisyphus/evidence/task-3-tests.txt
  ```

  **Commit**: `test(CaptureCore): update pixelCropRect expectations for corrected Y-flip` | Files: `Packages/CaptureCore/Tests/CaptureCoreTests/CaptureProtocolTests.swift`

---

- [ ] 4. **新增多显示器坐标转换测试**

  **What to do**:
  - 在 `CaptureProtocolTests.swift` 中添加构造的多显示器场景测试（不依赖实际硬件）
  - `pixelCropRect_secondaryDisplayAboveMain`: 副屏在主屏上方（displayFrame.minY 为负）
  - `pixelCropRect_secondaryDisplayBelowMain`: 副屏在主屏下方
  - `pixelCropRect_differentScaleFactors`: 验证不同 scale factor 下的裁剪计算

  **Agent**: `deep` | **Wave**: 1 | **Blocked By**: Task 1, 3

  **QA**:
  ```
  Scenario: Multi-display tests pass
    Tool: swift test --package-path Packages/CaptureCore
    Expected: All tests pass including new multi-display cases
    Evidence: .sisyphus/evidence/task-4-multi-display.txt
  ```

  **Commit**: `test(CaptureCore): add multi-display coordinate conversion tests` | Files: `Packages/CaptureCore/Tests/CaptureCoreTests/CaptureProtocolTests.swift`

---

### Bug B: OCR 选中文字跳变

- [ ] 5. **OCR 选区——绘制方法重构，仅绘制高亮**

  **What to do**:
  - 在 `EditableAnnotationCanvasView.drawSelectedOCRText` (L817-853)，将方法重构为:
    1. 保留 `ocrSelectionRects` 计算（用于高亮矩形尺寸和位置）
    2. 用半透明系统蓝色填充选区矩形（替换原有 `CTLineDraw` 调用）
    3. 移除: `CTLineCreateWithAttributedString`、`context.translateBy`/`context.scaleBy` 水平拉伸、`CTLineDraw`
  - 原始截图像素已在 `draw` 方法 (L182) 通过 `context.draw(displayImage, in: imageDisplayRect)` 渲染——选中时仅加一层高亮
  - 保留 `drawOCROverlay` (L758-767) 不变、保留 `drawOCRInsertionPoint` 光标

  **Must NOT do**: 不删除 `fittedOCRFont`（可能仍被 `ocrLineLayout` 和 `addOCRLineAsAnnotation` 间接使用）

  **Agent**: `visual-engineering` | **Wave**: 2 | 并行 (Task 5-8) | **Blocked By**: Wave 1

  **References**:
  - `App/SnapGlass/Sources/Editor/EditableAnnotationCanvasView.swift:817-853` — 目标方法
  - `App/SnapGlass/Sources/Editor/EditableAnnotationCanvasView.swift:758-767` — `drawOCROverlay` 参考
  - `App/SnapGlass/Sources/Editor/EditableAnnotationCanvasView.swift:799-815` — `ocrSelectionRects`

  **QA Scenarios**:
  ```
  Scenario: Selected OCR text shows original pixels with selection highlight
    Tool: Playwright
    Steps: Open editor with OCR results → click-drag select text → screenshot
    Expected: Original text pixels visible through highlight overlay; no text "jump"
    Evidence: .sisyphus/evidence/task-5-selection.png

  Scenario: Drag-selecting across lines does not displace text
    Tool: Playwright
    Steps: Drag from middle of line A to line B → observe during drag
    Expected: Text stays stationary; only highlight rectangle moves
    Evidence: .sisyphus/evidence/task-5-drag.png
  ```

  **Commit**: `fix(Editor): replace OCR selection text redraw with highlight-only overlay` | Files: `App/SnapGlass/Sources/Editor/EditableAnnotationCanvasView.swift`

---

- [ ] 6. **OCR 选区——移除系统字体替代绘制调用**

  **What to do**:
  - 确认 Task 5 后清理: 移除 `CTLineDraw(selectedLine, context)` (L850)、`CTLineCreateWithAttributedString` (L828-838)、`context.translateBy`/`context.scaleBy` (L847-848)
  - 保留 `context.clip(to: selectionRect)`——如仍需要限制高亮边界
  - 验证无编译警告（未使用变量/类型）

  **Agent**: `quick` | **Wave**: 2 | **Blocked By**: Task 5

  **QA**: `swift build` → 无错误无警告 | Evidence: `.sisyphus/evidence/task-6-build.txt`

  **Commit**: 与 Task 5 一起提交 | Files: `App/SnapGlass/Sources/Editor/EditableAnnotationCanvasView.swift`

---

- [ ] 7. **OCR 选区——确认光标绘制完整性**

  **What to do**:
  - 验证 `drawOCRInsertionPoint` (L855-873) 在重构后仍被正确调用
  - 确认光标高度匹配所在 OCR 行的高度
  - 若 `fittedOCRFont` 仅被光标使用，可内联简化

  **Agent**: `quick` | **Wave**: 2 | **Blocked By**: Task 5, 6

  **QA**:
  ```
  Scenario: Cursor appears and blinks when clicking OCR text
    Tool: Playwright
    Steps: Click inside OCR line → wait 2s → screenshot
    Expected: Blinking I-beam cursor matching line height
    Evidence: .sisyphus/evidence/task-7-cursor.png
  ```

  **Commit**: 与 Task 5/6 一起提交

---

- [ ] 8. **OCR 选区——视觉回归验证**

  **What to do**: 构建 app → 加载含文字截图 → 验证: (1) 未选中: 蓝色边框+原始像素 (2) 选中: 高亮+像素原位 (3) 拖选跨行: 无跳变 (4) 光标正常

  **Agent**: `visual-engineering` + `playwright` | **Wave**: 2 | **Blocked By**: Task 5-7 | **Commit**: NO

  **QA**: 截图证据 `.sisyphus/evidence/task-8-{1,2,3,4}.png`

---

### Bug C: 2048px OCR 降采样

- [ ] 9. **MemoryGuard 自适应策略**

  **What to do**:
  - 新增 `adaptiveFullResMaxWidth: CGFloat = 4096`（宽度 ≤4096px 全分辨率 OCR）
  - 保留 `maxImageWidth = 2048`（用于 tile 目标尺寸）
  - 新增 `static func tileSize(for image: CGImage) -> (tileWidth: CGFloat, tileCount: Int)`: 宽度 ≤4096 返回 (image.width, 1); 否则返回 (2048, ceil(image.width/2048))
  - 更新 `needsDownsample` 返回 `image.width > adaptiveFullResMaxWidth`

  **Agent**: `quick` | **Wave**: 2 | 并行 (Task 9-13)

  **References**: `Packages/OCRCore/Sources/MemoryGuard.swift:22-44`

  **QA**:
  ```
  Scenario: 3000px image bypasses downsample; 5000px triggers tile path
    Tool: swift test --package-path Packages/OCRCore
    Expected: needsDownsample(3000px)=false, tileSize(5000px)=(2048, 3)
    Evidence: .sisyphus/evidence/task-9-thresholds.txt
  ```

  **Commit**: `feat(OCRCore): add adaptive resolution thresholds to MemoryGuard` | Files: `Packages/OCRCore/Sources/MemoryGuard.swift`

---

- [ ] 10. **Tile 分割与 Vision OCR 引擎**

  **What to do**:
  - 在 `VisionOCREngine` 新增 `recognizeTiled(image:tileWidth:languages:options:) async throws -> OCRResult`
  - 按 tileWidth 水平分割（含重叠 `overlap = tileWidth/8`，每个 tile 通过 `CGImage.cropping(to:)` 裁剪）
  - 对每个 tile 调用现有 `recognize(image:tileImage,...)` 
  - Tile-local Vision boundingBox (0-1) 重新映射到全图归一化坐标: `globalX = (tileOriginX + localX * tileWidth) / fullWidth`, `globalWidth = localWidth * tileWidth / fullWidth`, Y/height 不变
  - Tile 间检查 `try Task.checkCancellation()`
  - 处理最后 tile 宽度不足 tileWidth 的边界情况

  **Agent**: `deep` | **Wave**: 2 | **Blocked By**: Task 9

  **References**:
  - `VisionOCREngine.swift:43-121` — 现有 `recognize`
  - `OCRResult.swift` — OCRLine.boundingBox (0-1 归一化, Vision Y-up origin=bottom-left)
  - `MemoryGuard.swift:55-74` — CGImageSource 裁剪用法参考

  **QA**:
  ```
  Scenario: 3-tile OCR produces correctly remapped bounding boxes
    Tool: swift test
    Steps: 5000x1000 test image → recognizeTiled(tileWidth=2048)
    Expected: All boundingBox in [0,1], tile boundary text captured (may be duplicated)
    Evidence: .sisyphus/evidence/task-10-coordinates.txt

  Scenario: Mid-tile cancellation
    Tool: swift test
    Steps: Start tiled OCR → cancel after first tile
    Expected: CancellationError thrown
    Evidence: .sisyphus/evidence/task-10-cancel.txt
  ```

  **Commit**: `feat(OCRCore): add tiled OCR recognition with coordinate remapping` | Files: `VisionOCREngine.swift`

---

- [ ] 11. **Tile 结果 IoU 去重与合并**

  **What to do**:
  - 在 `PostProcessor` 新增 `deduplicateTiledResults(_ lines: [OCRLine]) -> [OCRLine]`
  - 计算每对 boundingBox 的 IoU（`intersectionArea / unionArea`）
  - IoU > 0.5 且文本完全相同 → 保留置信度高的
  - IoU > 0.5 但文本不同 → 保留两个（重叠区域可能多行）
  - IoU ≤ 0.5 → 保留两个

  **Agent**: `deep` | **Wave**: 2 | **Blocked By**: Task 10

  **References**: `PostProcessor.swift`, IoU = intersection/union

  **QA**:
  ```
  Scenario: Same text in overlap deduplicated; different text preserved
    Tool: swift test
    Expected: Duplicate removed (keep higher confidence); different text both kept
    Evidence: .sisyphus/evidence/task-11-dedup.txt
  ```

  **Commit**: `feat(OCRCore): add IoU-based tile result deduplication` | Files: `PostProcessor.swift`

---

- [ ] 12. **阅读顺序恢复**

  **What to do**:
  - 在 `PostProcessor` 新增 `restoreReadingOrder(_ lines: [OCRLine]) -> [OCRLine]`
  - 按 `boundingBox.minY` 降序排序（Vision Y-up, minY 越大越靠"上"，越靠前阅读）
  - Y 坐标接近（差值在行高 0.3 倍内）的行按 `boundingBox.minX` 升序（从左到右）

  **Agent**: `quick` | **Wave**: 2

  **QA**: `swift test` → 多行从上到下，同行从左到右 | Evidence: `.sisyphus/evidence/task-12-order.txt`

  **Commit**: `feat(OCRCore): add reading order restoration` | Files: `PostProcessor.swift`

---

- [ ] 13. **取消检查与 Swift 6 并发安全**

  **What to do**:
  - `VisionOCREngine.recognize` 开始处 + `OCRPipeline.performMemoryGuard` 降采样后 + Tile 循环每块间：添加 `try Task.checkCancellation()`
  - 验证 `@unchecked Sendable` 标注不因新增属性违反——如有需要添加 `nonisolated(unsafe)`

  **Agent**: `quick` | **Wave**: 2

  **QA**: `swift build` → 无并发警告 | `swift test` → 取消传播正确 | Evidence: `.sisyphus/evidence/task-13-cancel.txt`

  **Commit**: `feat(OCRCore): add Task.checkCancellation() at key checkpoints` | Files: `VisionOCREngine.swift`, `OCRPipeline.swift`

---

### 集成

- [ ] 14. **OCRPipeline 集成 tile 路径**

  **What to do**:
  - 在 `OCRPipeline.performMemoryGuard` 中集成自适应逻辑:
    - `needsDownsample` 返回 false → 全分辨率路径（不变）
    - `needsDownsample` 返回 true → 调用 `MemoryGuard.tileSize(for:)` → `visionEngine.recognizeTiled(...)` → `postProcessor.deduplicateTiledResults(...)` → `postProcessor.restoreReadingOrder(...)`
  - 保持向后兼容: 小图（≤2048px）走原有单次 `recognize` 路径

  **Agent**: `deep` | **Wave**: 3 | **Blocked By**: Task 9, 10, 11, 12

  **References**: `OCRPipeline.swift:78-108` — `recognize` 主流程

  **QA**:
  ```
  Scenario: Pipeline routes correctly based on image width
    Tool: swift test
    Steps: Test with 1000px (full-res), 3000px (full-res), 5000px (tiled)
    Expected: Correct OCR results from all paths
    Evidence: .sisyphus/evidence/task-14-pipeline.txt
  ```

  **Commit**: `feat(OCRCore): integrate adaptive tile path into OCRPipeline` | Files: `OCRPipeline.swift`

---

- [ ] 15. **OCR tile 路径单元测试**

  **What to do**:
  - 在 `OCRCoreTests` 中新增 tile 路径测试:
    - `testTiledOCR_producesCompleteText`: 验证 tile 合并后文本完整
    - `testTiledOCR_deduplicatesOverlap`: 验证去重正确
    - `testTiledOCR_readingOrder`: 验证阅读顺序
    - `testTiledOCR_cancellation`: 验证取消传播
  - 测试图片使用程序化生成（绘制已知文本的 CGImage）

  **Agent**: `deep` | **Wave**: 3 | **Blocked By**: Task 10, 11, 14

  **QA**: `swift test --package-path Packages/OCRCore` → 全部通过

  **Commit**: `test(OCRCore): add tiled OCR pipeline tests` | Files: `Packages/OCRCore/Tests/OCRCoreTests/`

---

- [ ] 16. **端到端验证：pixelCropRect 调用链**

  **What to do**:
  - 验证修复后的完整调用链: `AreaSelectionPanel.quartzScreenRect → CaptureMode.area → SCKAdapter.captureArea → pixelCropRect → fullImage.cropping(to:)`
  - 在 `CaptureProtocolTests` 中添加端到端模拟测试: 模拟 AppKit 选区 → 验证最终裁剪坐标正确

  **Agent**: `quick` | **Wave**: 3 | **Blocked By**: Task 1, 2, 4

  **QA**: `swift test --package-path Packages/CaptureCore` → 全部通过

  **Commit**: `test(CaptureCore): add end-to-end area capture coordinate test` | Files: `CaptureProtocolTests.swift`

---

- [ ] 17. **Housekeeping: CHANGELOG + lint + format**

  **What to do**:
  - 在 `CHANGELOG.md` 的 `[Unreleased]` 部分添加三项 bug fix 条目
  - 运行 `swiftlint --path Packages/` 和 `swift-format lint -r Packages/`（如有）
  - 确认 `swift build` 全量通过

  **Agent**: `quick` | **Wave**: 3 | **Commit**: `chore: update CHANGELOG and run linters`

---

## Final Verification Wave (MANDATORY — after ALL implementation tasks)

> 4 个审查 agent 并行运行。ALL 必须 APPROVE。呈现合并结果给用户并等待明确确认。

- [ ] F1. **Plan Compliance Audit** — `oracle`
  验证每个 "Must Have" 实现存在，"Must NOT Have" 无违规，证据文件存在于 `.sisyphus/evidence/`
  输出: `Must Have [N/N] | Must NOT Have [N/N] | Tasks [N/N] | VERDICT: APPROVE/REJECT`

- [ ] F2. **Code Quality Review** — `unspecified-high`
  运行 `swift build` + linter + `swift test`。检查: `as any`、`@ts-ignore` 等价、空 catch、未使用导入、AI slop
  输出: `Build [PASS/FAIL] | Lint [PASS/FAIL] | Tests [N pass/N fail] | VERDICT`

- [ ] F3. **Real Manual QA** — `unspecified-high` (+ `playwright` if UI)
  从干净状态启动。执行所有 QA 场景。测试跨任务集成。边界情况: 空状态、无效输入
  输出: `Scenarios [N/N pass] | Integration [N/N] | Edge Cases [N tested] | VERDICT`

- [ ] F4. **Scope Fidelity Check** — `deep`
  逐任务读取 "What to do" + git diff。验证 1:1 对应。检查 "Must NOT do" 合规
  输出: `Tasks [N/N compliant] | Contamination [CLEAN/N issues] | VERDICT`

---

## Commit Strategy

| Wave | Tasks | Message |
|------|-------|---------|
| 1 | 1,2,3,4 | `fix(CaptureCore): correct area capture coordinate Y-flip for multi-display` |
| 2a | 5,6,7 | `fix(Editor): replace OCR selection text redraw with highlight-only overlay` |
| 2b | 9,13 | `feat(OCRCore): add adaptive resolution thresholds and cancellation checks` |
| 2c | 10 | `feat(OCRCore): add tiled OCR recognition with coordinate remapping` |
| 2d | 11,12 | `feat(OCRCore): add IoU deduplication and reading order restoration` |
| 3 | 14,15,16 | `feat(OCRCore): integrate adaptive tile path into OCRPipeline` |
| Final | 17 | `chore: update CHANGELOG for three bug fixes`

---

## Success Criteria

### Verification Commands
```bash
swift test --package-path Packages/CaptureCore    # 坐标测试全通过
swift test --package-path Packages/OCRCore         # OCR + tile 测试全通过
swift build                                         # 无错误无警告
```

### Final Checklist
- [ ] 所有 "Must Have" 已实现
- [ ] 所有 "Must NOT Have" 无违规
- [ ] 159+ 测试通过（回归 + 新增）
- [ ] CHANGELOG 已更新
- [ ] swift-format/swiftlint 通过
