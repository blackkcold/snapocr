# SnapGlass

<p align="center">
  <strong>macOS 开源截图与高效 OCR 应用</strong>
</p>

<p align="center">
  <a href="https://github.com/blackkcold/snapocr/releases">下载</a> ·
  <a href="#功能">功能</a> ·
  <a href="#快速开始">快速开始</a> ·
  <a href="Docs/ARCHITECTURE.md">架构</a> ·
  <a href="Docs/PRIVACY.md">隐私</a> ·
  <a href="CHANGELOG.md">更新日志</a>
</p>

---

## 关于

SnapGlass 是一款 **离线优先、隐私优先** 的 macOS 截图与 OCR 工具。所有截图、OCR、条码识别、标注与历史存储均在本地完成，不向任何远程服务器发送用户数据。

- **开源**：MIT 协议，代码完全公开
- **离线**：OCR 使用 Apple Vision 本地框架，零网络请求
- **隐私**：历史记录 AES-256-GCM 本地加密，不访问系统钥匙链
- **原生**：SwiftUI + AppKit，Swift 6 严格并发，支持 macOS 13+

## 功能

| 模块 | 能力 |
|------|------|
| **截图** | 可调整矩形 / 自由圈选 / 窗口 / 全屏 / 手动滚动截图（ScreenCaptureKit） |
| **OCR** | Apple Vision 离线识别，Tesseract 降级支持，开发者模式双引擎对比 |
| **条码** | QR / Code128 / EAN / PDF417 / Aztec / DataMatrix 识别 |
| **标注** | 箭头、矩形、文本、画笔、高亮、模糊、裁剪，支持撤销/重做 |
| **快捷键** | ⌘⇧1 区域 / ⌘⇧2 窗口 / ⌘⇧3 全屏 / ⌘⇧O OCR |
| **历史** | AES-GCM 本地加密存储，自动清理策略，导出支持脱敏 |
| **UI** | Liquid Glass 支持（macOS 26+），低版本自动降级 |

## 下载

前往 [Releases 页面](https://github.com/blackkcold/snapocr/releases) 下载最新版本：

- `SnapGlass-vX.Y.Z.dmg` — 安装包
- `SnapGlass-vX.Y.Z.dmg.sha256` — 校验文件

> 首次安装需在「系统设置 → 隐私与安全性」中允许打开（未签名应用）。
> 截图功能需授予「屏幕录制」权限。

## 系统要求

- macOS 13.0+
- Xcode 16+（构建）
- Swift 6.0（构建）

## 快速开始

```bash
# 安装构建工具
brew install xcodegen swiftlint

# 生成 Xcode 工程
xcodegen generate

# 构建 Release 产物到 release/vX.Y.Z/
./scripts/build.sh --version 0.2.0

# 运行全量 Package 测试
./scripts/test.sh
```

更多构建选项见 [`Docs/RELEASE.md`](Docs/RELEASE.md)。

## 项目结构

```
SnapGlass/
├── App/SnapGlass/         # macOS GUI App
├── Packages/              # 核心功能模块（SPM）
│   ├── SharedKit/          # 共享工具（日志、加密、错误类型）
│   ├── CaptureCore/        # 截图（ScreenCaptureKit + CG 兼容）
│   ├── OCRCore/            # OCR（Vision + Tesseract 降级）
│   ├── BarcodeCore/        # 条码识别
│   ├── AnnotationCore/     # 标注工具集
│   ├── ScrollCore/         # 滚动截图拼接
│   ├── HistoryCore/        # 本地历史加密存储
│   └── AutomationCore/     # Automation 保留源码（不进入产品构建）
├── Docs/                   # 项目文档
├── scripts/               # 构建与测试脚本
└── release/               # 发版产物归档（按版本子目录）
```

## 文档

| 文档 | 说明 |
|------|------|
| [Docs/ARCHITECTURE.md](Docs/ARCHITECTURE.md) | 架构设计与协议分层 |
| [Docs/PRIVACY.md](Docs/PRIVACY.md) | 隐私声明与数据处理 |
| [Docs/SECURITY.md](Docs/SECURITY.md) | 安全策略与边界核查 |
| [Docs/CONTRIBUTING.md](Docs/CONTRIBUTING.md) | 贡献指南与代码规范 |
| [Docs/AGENTS.md](Docs/AGENTS.md) | Agent 协作指南 |
| [Docs/RELEASE.md](Docs/RELEASE.md) | 发版流程与产物规范 |
| [Docs/CI.md](Docs/CI.md) | CI/CD 说明 |
| [CHANGELOG.md](CHANGELOG.md) | 更新日志 |

## 贡献

欢迎贡献！请先阅读 [贡献指南](Docs/CONTRIBUTING.md)。

- **提交 PR**：标题遵循 [Conventional Commits](https://www.conventionalcommits.org/) 格式
- **报告问题**：使用 [GitHub Issues](https://github.com/blackkcold/snapocr/issues)
- **安全漏洞**：请通过 GitHub Issues 私下报告，勿公开披露

## 许可证

[MIT License](LICENSE) © SnapGlass Contributors