# SnapGlass AGENTS.md

> Agent 协作指南 — 面向 AI 和人类开发者的项目共识

SwiftUI macOS 应用，最低部署 macOS 13，使用 Swift 6 和 Swift Testing。基于 XcodeGen + SPM workspace，所有核心功能以独立 Package 组织。

---

## Commands

```bash
# 格式化
swift-format lint -p Packages/OCRCore/Sources/OCRPipeline.swift --configuration .swift-format

# Lint
swiftlint lint --config .swiftlint.yml

# 生成工程
xcodegen generate

# 编译
swift build

# 运行单个 Package 测试
swift test --package-path Packages/OCRCore
swift test --package-path Packages/HistoryCore
swift test --package-path Packages/CaptureCore
swift test --package-path Packages/ScrollCore

# 运行所有 Package 测试
for pkg in Packages/*/; do swift test --package-path "$pkg" || break; done
```

---

## Code Style

- 遵循 `.swift-format`（格式）和 `.swiftlint.yml`（质量）配置
- 所有 `public` API 必须有 DocC 注释（`///`）
- ViewModel 使用 `@MainActor` 隔离 UI 状态
- 后台工作使用 Swift concurrency（`async/await`, `Task`, `actor`）
- 优先使用 `struct` + `protocol`，避免类继承
- 命名约定：
  - 类型：`UpperCamelCase`（`CaptureOrchestrator`, `OCRProtocol`）
  - 方法/属性：`lowerCamelCase`（`recognize(image:)`, `isEnabled`）
  - 常量：`lowerCamelCase`（不用 `k` 前缀）
  - Extension 中不缩写（`isNotEmpty` 而非 `notEmpty`）

---

## Project Structure

```
SnapGlass/
├── App/
│   ├── SnapGlass/            # macOS GUI App
│   │   ├── MenuBar/          # 菜单栏入口
│   │   ├── Windows/          # 偏好设置、历史窗口
│   │   ├── Overlays/         # 截图选区覆盖层
│   │   ├── Editor/           # 标注编辑器
│   │   ├── Permissions/      # 权限引导卡片
│   │   └── Routing/          # URL Scheme / App Intents
│   └── SnapGlassCLI/         # CLI 入口
├── Packages/
│   ├── SharedKit/            # 共享工具（日志、加密、错误类型）
│   ├── CaptureCore/          # 截图（ScreenCaptureKit 主 + CG 兼容）
│   ├── OCRCore/              # OCR（Vision 主 + Tesseract 降级）
│   ├── BarcodeCore/          # 条码识别
│   ├── AnnotationCore/       # 标注工具集
│   ├── ScrollCore/           # 滚动截图拼接
│   ├── HistoryCore/          # 本地历史加密存储
│   └── AutomationCore/       # CLI / URL Scheme / Shortcuts
├── Docs/                     # 文档
└── Tests/                    # 集成/UI 测试
```

---

## Architecture

分层架构遵循 **macOS 原生优先 + 协议导向分层** 设计：

```
Presentation Layer (macOS: SwiftUI + AppKit bridge)
Protocol Layer (CaptureProtocol | OCRProtocol | AnnotationProtocol | ...)
Core Logic (图像预处理、OCR 后处理、拼接算法等)
Platform Adapter (macOS: Vision, SCK, NSPasteboard)
```

详细架构说明见 [ARCHITECTURE.md](./ARCHITECTURE.md)。

---

## Boundaries

### Always
- 修改后跑对应 Package 测试
- 更新 `CHANGELOG.md`
- 添加 DocC 注释
- 遵循 Conventional Commits

### Ask First
- 添加新的 SPM 依赖
- 修改 `Package.swift` 协议定义
- 改动权限逻辑
- 修改 CI 配置
- 引入新的外部库

### Never
- 提交 secrets / 敏感信息
- 修改 `.build/` 或 `DerivedData`
- Force unwrap（`!`）
- 直接 push 到 `main` 分支
- 修改 `.xcodeproj`（由 XcodeGen 生成，禁止手动编辑）

---

## PR Checklist

```markdown
- [ ] Title: type(scope): description (Conventional Commits)
- [ ] CHANGELOG.md 已更新
- [ ] 对应 package 测试通过
- [ ] lint 通过（swift-format + swiftlint）
- [ ] 涉及权限：在 PR 描述中说明权限影响
```

---

## Agent 合作原则

1. **协议优先** — 跨模块依赖通过 `protocol` 而非具体类
2. **最小变更** — 每次只改一个 Package，跑通对应测试再提交
3. **文档同步** — 代码变更必须同步更新相关文档和 CHANGELOG
4. **权限意识** — 所有涉及权限的改动，必须在 PR 中说明
5. **无副作用** — 不修改非目标文件，不引入未授权的依赖
