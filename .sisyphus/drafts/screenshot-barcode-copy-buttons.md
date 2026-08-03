# Draft: Screenshot & Barcode Copy Button Optimizations

## Requirements (confirmed)
- [Feature 1]: 截图立即复制后，确认界面应有复制按钮
- [Feature 2]: 识别条码后，条码界面应有复制按钮
- [Hard constraint]: macOS 13 部署目标
- [Hard constraint]: 保持独立的 image/text pasteboard 路径
- [Hard constraint]: 复用现有 UI 和 toast 约定
- [Hard constraint]: 用已有代码模式定义 zero/one/multiple barcode 行为
- [Hard constraint]: 不引入新依赖
- [Hard constraint]: 包含 CHANGELOG 和 en/zh-Hans 本地化
- [Hard constraint]: 复制失败不能报告为成功

## Technical Decisions
- [待定] "截图确认界面"的形式：增强现有 toast 系统（推荐） vs 新建覆盖层（需要用户确认）

## Research Findings
- 当前没有独立的截图确认覆盖层
- 普通截图打开 EditorView
- 仅剪贴板截图调用 `CaptureViewModel.copyImageToClipboard()`，显示 toast，跳过编辑器
- EditorView 底栏已有 Copy 按钮（用于渲染/标注后的图片）
- ToolPickerView 有条码扫描按钮
- `EditorViewModel.scanBarcodes()` 自动复制一个或全部 payload（换行连接）
- CaptureViewModel 只对单个条码提供 toast "Copy Content" 动作（通过 `BarcodeCopyCandidate.singlePayload()`）
- 应用层测试缺失；包测试使用 Swift Testing
- 支持本地化：en 和 zh-Hans

## Scope Boundaries
- INCLUDE: 截图复制确认界面的复制按钮、条码识别界面的复制按钮
- INCLUDE: CHANGELOG、en/zh-Hans 本地化
- INCLUDE: 复制失败不能报告为成功
- EXCLUDE: 新依赖、无关 UI 重设计、权限修改、Package.swift/xcodeproj 修改
- EXCLUDE: 新建确认覆盖层（除非用户确认）

## Open Questions
- 截图确认界面应该以什么形式呈现？（增强 toast vs 新建覆盖层 vs 重用 EditorView）
  - 推荐：增强现有 toast 系统，添加 action button 支持
  - 理由：已有 `Copy Content` toast action 先例，避免新建 UI 组件，符合最小修改原则
