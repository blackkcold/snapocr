# 批次 0 基线（可复现）

## 工具版本
- SwiftLint: 0.65.1
- Swift: 6.3.3 (Xcode 16 toolchain)
- swift-format: 6.3.0 (xcrun, XcodeDefault toolchain)
- 部署目标: macOS 13.0, Swift 6.0

## 配置决策（批次 0）
1. `.swiftlint.yml` 新增 `excluded`，显式列出所有嵌套 `.build` 目录。
   - **关键事实**: SwiftLint 的 `excluded` 不支持 glob 通配（`**/.build`、`Packages/*/.build` 均无效），必须逐目录显式列出。
   - 效果: 本地 1739 → 220 violations，`.build` 不再产生违规。
2. `.swiftlint.yml` 新增 `trailing_comma: mandatory_comma: true`。
   - 与 swift-format 的 `multiElementCollectionTrailingCommas: true`（实测确认）对齐。
   - 效果: trailing_comma 从 81 → 6（仅剩真正缺尾逗号的，swift-format 也会要求补）。

## 基线（配置后，机器生成）
- 全量: **220 violations, 3 serious in 138 files**

### 3 个 serious (error)
| 文件 | 行 | 规则 |
|------|-----|------|
| App/SnapGlass/Sources/Overlays/AreaSelectionPanel.swift | 1206 | file_length (error: 1200) |
| App/SnapGlass/Sources/Editor/EditableAnnotationCanvasView.swift | 1283 | file_length (error: 1200) |
| Packages/OCRCore/Sources/TesseractOCREngine.swift | 542 | large_tuple |

### 按规则分布
| 规则 | 数量 |
|------|------|
| identifier_name | 93 |
| line_length | 48 |
| function_body_length | 19 |
| multiple_closures_with_trailing_closure | 12 |
| file_length | 11 (2 error + 9 warning) |
| type_body_length | 6 |
| cyclomatic_complexity | 6 |
| trailing_comma (缺逗号) | 6 |
| trailing_newline | 2 |
| private_over_fileprivate | 2 |
| large_tuple | 2 (1 error + 1 warning) |
| implicit_optional_initialization | 2 |
| function_parameter_count | 2 |
| closure_parameter_position | 2 |
| opening_brace | 1 |
| non_optional_string_data_conversion | 1 |
| legacy_swiftui_aspect_ratio | 1 |
| inclusive_language | 1 |
| implicitly_unwrapped_optional | 1 |
| force_unwrapping | 1 |
| for_where | 1 |

### 11 个超 500 行文件（实测 wc -l）
| 文件 | 行数 | 状态 |
|------|------|------|
| EditableAnnotationCanvasView.swift | 1283 | error |
| AreaSelectionPanel.swift | 1206 | error |
| CaptureViewModel.swift | 1017 | warning |
| HistoryActor.swift | 951 | warning |
| EditorViewModel.swift | 797 | warning |
| PreferencesView.swift | 772 | warning |
| SCKAdapter.swift | 668 | warning |
| HistoryView.swift | 664 | warning |
| TesseractOCREngine.swift | 636 | warning |
| ScrollStitchEngine.swift | 512 | warning |
| SharedKitTests.swift | 504 | warning |

## 验证命令
```bash
swiftlint lint --config .swiftlint.yml
```
