<h1 align="center">SnapGlass</h1>

<p align="center">
  <strong>离线优先 · 隐私优先 · macOS 截图与 OCR 工具</strong>
</p>

<p align="center">
  <a href="https://github.com/blackkcold/snapocr/releases/latest">
    <img src="https://img.shields.io/github/v/release/blackkcold/snapocr?style=flat&label=version" alt="Version">
  </a>
  <a href="https://github.com/blackkcold/snapocr/releases">
    <img src="https://img.shields.io/github/downloads/blackkcold/snapocr/total.svg?style=flat&label=downloads" alt="Downloads">
  </a>
  <a href="LICENSE">
    <img src="https://img.shields.io/github/license/blackkcold/snapocr?style=flat" alt="License">
  </a>
  <a href="https://www.apple.com/macos/">
    <img src="https://img.shields.io/badge/macOS-13.0%2B-blue?style=flat" alt="macOS">
  </a>
  <a href="https://swift.org">
    <img src="https://img.shields.io/badge/Swift-6.0-orange?style=flat" alt="Swift">
  </a>
  <a href="https://github.com/blackkcold/snapocr/actions">
    <img src="https://img.shields.io/github/actions/workflow/status/blackkcold/snapocr/ci.yml?style=flat&label=CI" alt="CI">
  </a>
</p>

<p align="center">
  <a href="https://github.com/blackkcold/snapocr/stargazers">
    <img src="https://img.shields.io/github/stars/blackkcold/snapocr?style=social" alt="Stars">
  </a>
</p>

<p align="center">
  <a href="#-下载">下载</a> ·
  <a href="#-功能">功能</a> ·
  <a href="#-使用场景">使用场景</a> ·
  <a href="#-快捷键">快捷键</a> ·
  <a href="#-构建">构建</a> ·
  <a href="CHANGELOG.md">更新日志</a> ·
  <a href="Docs/ARCHITECTURE.md">架构</a> ·
  <a href="Docs/PRIVACY.md">隐私</a>
</p>

---

## 📥 下载

<p align="center">
  <a href="https://github.com/blackkcold/snapocr/releases/latest">
    <img src="https://img.shields.io/badge/Download%20Latest-v0.5.0-blue?style=for-the-badge&logo=apple" alt="Download">
  </a>
</p>

前往 [Releases 页面](https://github.com/blackkcold/snapocr/releases) 下载：

- `SnapGlass-vX.Y.Z.dmg` — 安装包
- `SnapGlass-vX.Y.Z.dmg.sha256` — SHA-256 校验文件

> [!WARNING]
> 首次安装需在「系统设置 → 隐私与安全性」中允许打开（未签名应用）。
> 截图功能需授予「屏幕录制」权限。

---

## 🚀 功能

| 模块 | 能力 |
|------|------|
| **📸 截图** | 可调整矩形 / 自由圈选 / 窗口 / 全屏 / 手动滚动截图（ScreenCaptureKit） |
| **🔤 OCR** | Apple Vision 离线识别，Tesseract 降级支持，开发者模式双引擎对比 |
| **📦 条码** | QR / Code128 / EAN / PDF417 / Aztec / DataMatrix 识别 |
| **✏️ 标注** | 箭头、矩形、文本、画笔、高亮、模糊、裁剪，支持撤销/重做 |
| **🔐 隐私** | AES-256-GCM 本地加密历史，零网络请求，不访问系统钥匙链 |
| **🎨 UI** | Liquid Glass 支持（macOS 26+），低版本自动降级 |

### 截图

- 矩形区域 / 自由圈选 / 窗口 / 全屏 / 滚动截图
- 支持多显示器与混合缩放环境
- 实时十字准线，释放后二次调整选区
- 默认 Retina 像素，可切换标准 1x
- 支持 PNG/JPEG 编码与 JPEG 质量设置

### OCR

- Apple Vision 本地框架，完全离线
- 超大图片自动分块识别并合并坐标
- 开发者模式支持 Vision vs Tesseract 双引擎对比
- 识别结果一键复制

### 标注编辑器

- 7 种工具：箭头、矩形、文本、画笔、高亮、模糊、裁剪
- 完整撤销/重做支持
- 矩形标注自动填充与描边同色
- 裁剪工具支持移动、缩放、确认后执行

### 条码识别

- 支持 QR / Code128 / EAN / PDF417 / Aztec / DataMatrix
- 截图后自动检测，一键复制内容
- 编辑器内手动识别

---

## 🎯 使用场景

SnapGlass 可以帮助你：

- 从**不可选文本的 PDF** 中提取文字
- 从**视频会议共享屏幕**中抓取文本
- 从**YouTube 视频 / 在线课程**中复制文字
- 快速**截图并标注**后分享
- 识别截图中的**二维码和条码**
- 批量**截图并自动 OCR** 存档

---

## ⌨️ 快捷键

| 操作 | 快捷键 |
|------|--------|
| 区域截图 | <kbd>⌘</kbd> + <kbd>⇧</kbd> + <kbd>1</kbd> |
| 窗口截图 | <kbd>⌘</kbd> + <kbd>⇧</kbd> + <kbd>2</kbd> |
| 全屏截图 | <kbd>⌘</kbd> + <kbd>⇧</kbd> + <kbd>3</kbd> |
| OCR 识别 | <kbd>⌘</kbd> + <kbd>⇧</kbd> + <kbd>O</kbd> |

---

## 💻 系统要求

- macOS 13.0+
- Xcode 16+（构建）
- Swift 6.0（构建）

---

## 🔧 构建

```bash
# 安装构建工具
brew install xcodegen swiftlint

# 生成 Xcode 工程
xcodegen generate

# 构建 Release 产物
./scripts/build.sh --version 0.5.0

# 构建后打开 Finder（产物统一输出到 release/vX.Y.Z/）
./scripts/build.sh --open

# 运行全量 Package 测试
./scripts/test.sh
```

> 所有临时测试与正式构建产物统一归档到 `release/vX.Y.Z/`，不使用 `output/` 目录。详见 [`Docs/RELEASE.md`](Docs/RELEASE.md)。

更多构建选项见 [`Docs/RELEASE.md`](Docs/RELEASE.md)。

---

## 📁 项目结构

```
SnapGlass/
├── App/SnapGlass/          # macOS GUI App
├── Packages/               # 核心功能模块（SPM）
│   ├── SharedKit/           # 共享工具（日志、加密、错误类型）
│   ├── CaptureCore/         # 截图（ScreenCaptureKit + CG 兼容）
│   ├── OCRCore/             # OCR（Vision + Tesseract 降级）
│   ├── BarcodeCore/         # 条码识别
│   ├── AnnotationCore/      # 标注工具集
│   ├── ScrollCore/          # 滚动截图拼接
│   ├── HistoryCore/         # 本地历史加密存储
│   └── AutomationCore/      # Automation 保留源码（不进入产品构建）
├── Docs/                    # 项目文档
├── scripts/                 # 构建与测试脚本
└── release/                 # 发版产物归档
```

---

## 📖 文档

| 文档 | 说明 |
|------|------|
| [架构设计](Docs/ARCHITECTURE.md) | 协议分层与模块设计 |
| [隐私声明](Docs/PRIVACY.md) | 数据处理与隐私保护 |
| [安全策略](Docs/SECURITY.md) | 安全边界与漏洞报告 |
| [贡献指南](Docs/CONTRIBUTING.md) | 代码规范与 PR 流程 |
| [发版流程](Docs/RELEASE.md) | 构建与发布规范 |
| [CI/CD 说明](Docs/CI.md) | GitHub Actions 工作流 |
| [更新日志](CHANGELOG.md) | 版本历史 |

---

## 🤝 贡献

欢迎贡献！请先阅读 [贡献指南](Docs/CONTRIBUTING.md)。

- **提交 PR**：标题遵循 [Conventional Commits](https://www.conventionalcommits.org/) 格式
- **报告问题**：使用 [GitHub Issues](https://github.com/blackkcold/snapocr/issues)
- **安全漏洞**：请通过 GitHub Issues 私下报告，勿公开披露

---

## 📄 许可证

[MIT License](LICENSE) © SnapGlass Contributors
