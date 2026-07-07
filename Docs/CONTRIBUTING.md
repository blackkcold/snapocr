# Contributing to SnapGlass

> 贡献指南 — 代码规范、Git 工作流与 PR 要求

---

## 代码规范

### 格式化与 Lint

| 工具 | 用途 | 配置 |
|------|------|------|
| `swift-format` | 自动格式化（缩进、空格、换行） | 项目根 `.swift-format` (JSON) |
| `SwiftLint` | 代码质量（安全、复杂度） | 项目根 `.swiftlint.yml` (YAML) |

**分工原则**: SwiftFormat 管格式（自动化修复），SwiftLint 管质量（代码审查把关）。两者规则不重叠。

#### 运行命令

```bash
# 格式化检查
swift-format lint --recursive . --configuration .swift-format

# Lint 检查
swiftlint lint --strict

# 自动格式化
swift-format format --recursive . --configuration .swift-format -i
```

#### .swift-format 配置要点

```json
{
  "version": 1,
  "lineLength": 120,
  "indentation": { "spaces": 2 },
  "maximumBlankLines": 1,
  "respectsExistingLineBreaks": true,
  "indentConditionalCompilationBlocks": true,
  "rules": {
    "AlwaysUseLowerCamelCase": true,
    "DoNotUseSemicolons": true,
    "NeverForceUnwrap": true,
    "NeverForceTry": true,
    "NeverUseImplicitlyUnwrappedOptionals": true,
    "OrderedImports": true,
    "UseTripleSlashForDocumentationComments": true,
    "ValidateDocumentationComments": true,
    "AllPublicDeclarationsHaveDocumentation": true
  }
}
```

#### .swiftlint.yml 配置要点

```yaml
opt_in_rules:
  - empty_count
  - force_unwrapping
  - implicitly_unwrapped_optional
  - unused_import
  - duplicate_imports
  - toggle_bool
  - private_action
  - private_outlet

disabled_rules:
  - trailing_whitespace  # 由 swift-format 处理
  - vertical_whitespace  # 由 swift-format 处理
  - colon                # 由 swift-format 处理
  - comma                # 由 swift-format 处理

line_length: 120
file_length:
  warning: 500
  error: 1200
type_body_length:
  warning: 400
identifier_name:
  min_length: 3
  excluded: [id, URL, key, tag]
```

---

## 命名约定

```swift
// 类型: UpperCamelCase
public struct CaptureOrchestrator { }
public protocol OCRProtocol { }
public enum OCREngineType { }

// 方法/属性: lowerCamelCase
func recognize(image: CGImage) async throws -> OCRResult
var isEnabled: Bool { get set }

// 常量: lowerCamelCase（不用 k 前缀）
let defaultConfidenceThreshold: Float = 0.7

// extension 中不缩写
extension String {
    var isNotEmpty: Bool { !isEmpty }
}
```

---

## DocC 注释规范

所有 `public` API 必须有完整的 DocC 注释：

```swift
/// 对图像执行 OCR 识别。
///
/// 使用 Apple Vision 框架进行文本识别，支持多种语言和输出格式。
/// 当置信度低于阈值时会展示降级提示。
///
/// - Parameters:
///   - image: 要识别的 CGImage
///   - languages: 语言列表，按优先级排序，例如 `["zh-Hans", "en-US"]`
///   - options: 识别选项
/// - Returns: 包含文本、置信度、引擎信息的 `OCRResult`
/// - Throws: `OCRError` 如果图像无法处理
///
/// - Note: 在开发者模式 (`devMode`) 下会同时运行 Vision 和 Tesseract
///   并将对比结果写入日志。
/// - Important: 此方法在主引擎失败时自动尝试 Tesseract 降级
public func recognize(
    image: CGImage,
    languages: [String],
    options: OCROptions = .default
) async throws -> OCRResult
```

---

## Git 规范

### Commit 格式

采用 **Conventional Commits** 规范：

```
type(scope): description

[optional body]
```

| type | 用途 |
|------|------|
| `feat` | 新功能 |
| `fix` | 修复 Bug |
| `docs` | 文档更新 |
| `test` | 测试相关 |
| `refactor` | 重构 |
| `chore` | 构建/CI/工具 |
| `perf` | 性能优化 |

示例：

```
feat(OCRCore): add language-specific confidence thresholds

Implement per-language confidence thresholds:
zh-Hans=0.6, en-US=0.8, ja-JP=0.65
```

### 分支策略

- `main` — 保护分支，禁止直接推送
- `feat/xxx` — 功能开发分支
- `fix/xxx` — 修复分支

### 版本号

遵循 SemVer `vX.Y.Z` 规范。

---

## PR 要求

1. **标题**: 符合 Conventional Commits 格式
2. **内容**:
   - 变更说明
   - 测试证据
   - 权限影响说明（如涉及）
   - `CHANGELOG.md` 已更新
3. **检查清单**:
   - [ ] 对应 Package 测试通过
   - [ ] `swift-format` / `swiftlint` 通过
   - [ ] `CHANGELOG.md` 已更新
   - [ ] 涉及权限：说明权限影响
   - [ ] 涉及新依赖：在 PR 描述中说明理由

---

## 构建与测试

```bash
# 生成 Xcode 工程
xcodegen generate

# 编译
swift build

# 测试单个 Package
swift test --package-path Packages/OCRCore

# 测试所有 Package
for pkg in Packages/*/; do swift test --package-path "$pkg" || break; done
```

---

## 项目结构

```
SnapGlass/
├── App/
│   ├── SnapGlass/          # macOS GUI App target
│   └── SnapGlassCLI/       # CLI target
├── Packages/
│   ├── SharedKit/           # 共享工具
│   ├── CaptureCore/         # 截图
│   ├── OCRCore/             # OCR
│   ├── BarcodeCore/         # 条码
│   ├── AnnotationCore/      # 标注
│   ├── ScrollCore/          # 滚动截图
│   ├── HistoryCore/         # 历史
│   └── AutomationCore/      # CLI/URL/Shortcuts
├── Docs/                    # 文档
└── Tests/                   # 测试样本和 golden dataset
```

---

## 代码风格指南

### Swift 并发

```swift
// UI 层：@MainActor
@MainActor
class EditorViewModel: ObservableObject {
    @Published var mode: CaptureMode = .area
}

// 后台任务：actor 序列化
actor HistoryActor {
    func save(entry: HistoryEntry) async throws { ... }
}

// 无状态工具：struct
struct CryptoService {
    func encrypt(_ data: Data) throws -> Data { ... }
}
```

### 协议优先

```swift
// ✅ 正确：依赖协议
func process(engine: OCRProtocol) async throws { ... }

// ❌ 避免：依赖具体实现
func process(engine: VisionOCREngine) async throws { ... }
```
