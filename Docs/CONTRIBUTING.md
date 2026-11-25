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
# 格式闸门：版本校验 + 全仓零诊断（budget 必须保持 0）
bash scripts/check-swift-format.sh

# 只看指定目录/包：零容忍，用于验收单批改动
bash scripts/check-swift-format.sh App Packages/CaptureCore

# Lint 检查（先确认 SwiftLint 版本命中 .swiftlint-version）
bash scripts/check-swiftlint-version.sh
swiftlint lint --strict --config .swiftlint.yml

# 自动格式化
xcrun swift-format format --recursive . --configuration .swift-format -i
```

#### 格式器版本固定

CI 与本地必须使用同一版本的 `swift-format`，否则同一份代码会被两种排版互相改写。

- 版本契约写在仓库根 `.swift-format-version`：首行为规范版本，其余为**已验证输出一致**的等价构建。
- `bash scripts/check-swift-format-version.sh` 校验当前工具链；CI 在 lint 前执行同一脚本，版本不符直接失败，而不是用新版本静默重排整个仓库。
- 规范版本取自 Xcode 工具链（`xcrun swift-format --version`），不再通过 Homebrew 安装，避免 brew 升级造成漂移。
- 升级格式器 = 有意为之的一次全量格式化：改 `.swift-format-version` → `xcrun swift-format format -i -r .` → 单独提交并加入 `.git-blame-ignore-revs`。

#### 零诊断硬闸门

- `scripts/check-swift-format.sh` 使用 `swift-format lint --strict`（普通 lint 有诊断也返回 0，不能当闸门），并核对诊断数。
- `.swift-format-budget` 必须保持 0：Phase 2 已把 698 条 DocC 诊断清零，任何新增诊断都会失败；不要为通过分支而调高预算。
- 传入路径时同样零容忍，用于本地迭代。
- 新增或修改代码不得引入任何诊断；提交前先跑 `bash scripts/check-swift-format.sh`。

#### SwiftLint 版本固定

- 版本契约写在仓库根 `.swiftlint-version`：首行为规范版本（CI 下载对应 release 的 `portable_swiftlint.zip`），其余为**已验证等价**的构建。
- `bash scripts/check-swiftlint-version.sh` 校验当前二进制；CI 在 lint 前执行，版本不符直接失败。
- 本地安装固定版本：

```bash
VERSION="$(grep -vE '^[[:space:]]*(#|$)' .swiftlint-version | head -1)"
mkdir -p "$HOME/.local/bin"
curl -fsSL -o /tmp/swiftlint.zip \
  "https://github.com/realm/SwiftLint/releases/download/${VERSION}/portable_swiftlint.zip"
unzip -oq /tmp/swiftlint.zip -d "$HOME/.local/bin"
bash scripts/check-swiftlint-version.sh
```

- 升级 SwiftLint = 有意为之：先跑全仓 `swiftlint lint --strict` 对比违规集，再更新 `.swiftlint-version`。

#### 配置以文件为准

`.swift-format` 与 `.swiftlint.yml` 是唯一事实来源；本文不再复制完整内容，避免文档与配置版本漂移。要点：

- 缩进 4 空格，`lineLength: 120`，尊重既有换行。
- 分工：`swift-format` 管排版与安全规则（`NeverForceUnwrap`、`NeverUseForceTry`、`NeverUseImplicitlyUnwrappedOptionals` 等）；`SwiftLint` 管质量（`force_unwrapping`、`implicitly_unwrapped_optional`、`unused_import`、`private_outlet` 等）。
- 排版规则在 SwiftLint 侧关闭（`trailing_whitespace`、`vertical_whitespace`、`colon`、`comma`、`opening_brace`、`trailing_comma`），由 `swift-format` 负责。
- 结构阈值按现状设定：`file_length` 780/1200、`type_body_length` 470、`function_body_length` 75、`cyclomatic_complexity` 12。
- 全量 lint 已达到 0 条诊断（Phase 2 清掉 698 条 DocC：`AllPublicDeclarationsHaveDocumentation` 626 + `ValidateDocumentationComments` 72）；`.swift-format-budget` 锁定 0。

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
