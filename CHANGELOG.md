# Changelog

All notable changes to SnapGlass will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.2.0] - 2026-07-31

### Added
- 自由圈选截图与透明 PNG 蒙版输出
- PNG/JPEG 统一 ImageIO 编码器及本地密钥权限回归测试
- AutomationCoreTests: URLSchemeRouter 路由解析、CommandParser CLI 解析、CLIHandlers 未实现占位行为测试
- OCRCoreTests: PostProcessor.detectURLs 多场景 URL 检测测试
- HistoryCoreTests: CleanupPolicy 策略逻辑、TextAnonymizer 脱敏、HistoryEntry Codable 编解码测试
- BarcodeCoreTests: QR 识别、类型过滤和结果编解码测试
- ScrollCoreTests: 帧去重、重叠检测和原分辨率拼接测试
- 统一 `release/vX.Y.Z/` 发版产物目录规范与 `Docs/RELEASE.md` 发版流程文档
- GitHub Actions release workflow（tag `v*` 触发自动构建并上传 `.dmg` + `.sha256`）

### Changed
- 区域截图改为实时十字准线；矩形选区支持释放后二次调整尺寸和位置
- 截图默认使用显示器原生 Retina 像素，设置中可切换标准 1x
- 截图原图支持 PNG/JPEG 与 JPEG 质量设置；透明自由圈选固定使用 PNG
- 历史加密密钥改为 App Support 本地 0600 权限文件，不再访问系统钥匙链
- 新历史写入独立 `History/v2/`，旧钥匙链加密历史原样保留但不读取或迁移
- 更新 README 构建脚本路径 `Scripts` → `scripts`
- 修正 SECURITY.md 历史存储路径 `texts` → `entries`
- 修正 SECURITY.md/PRIVACY.md 中 PrivacyInfo.xcprivacy 引用标注为"文件待创建"
- 全局快捷键在菜单首次打开前即可使用窗口路由和权限引导
- AutomationCore 源码继续保留，但不再链接到 GUI App 产品
- 本地构建脚本改为输出唯一的 `release/vX.Y.Z/` 目录并拒绝覆盖已有产物
- CI build 改为 Release 配置并上传构建产物 artifact；补齐全量 Package 测试

### Removed
- 移除 GUI App 的 Automation 窗口、`snapglass://` URL Scheme、App Intents 产品依赖和 CLI 构建目标
- 移除临时构建产物目录 `output/`，统一收敛到 `release/`

## [0.1.5] - 2026-06-11

### Fixed
- 修复 macOS 15 Sequoia 上屏幕录制权限检查失败的问题（P0）
  - 根因：`CGPreflightScreenCaptureAccess()` 对 ad-hoc 签名应用返回 false
  - 修复：移除对 CGPreflight 的 guard 依赖，改用 SCShareableContent 作为主要验证手段
- 修复 `SCKAdapter.checkPermissionStatus()` 与 `PermissionService` 逻辑不一致的问题
- 修复 `PermissionService.currentState()` 无法区分 denied 和 degraded 状态的问题
- 修复权限请求等待时间不足的问题（1 秒 → 轮询，成功立即返回）

### Added
- 创建 `App/SnapGlass/SnapGlass.entitlements` 文件（Hardened Runtime 支持）
- 添加权限检查的详细日志输出，便于调试
- 配置代码签名环境变量（DEVELOPMENT_TEAM, CODE_SIGN_IDENTITY）
- SCKAdapter 添加 `openScreenCaptureSettings()` 方法支持 macOS 14 及以下
- 添加历史自动保存开关与 OCR 全文保存开关（默认关闭全文持久化）
- 添加交互式窗口选择面板，支持悬停高亮、单击选择和 ESC 取消

### Changed
- 优化权限请求流程，一旦检测到权限授予立即返回
- 更新设计文档 Section 7.2 权限检查代码示例
- Scripts/package.sh 支持 entitlements 签名
- 优化区域截图选择面板，预捕获降采样背景快照以减少拖拽绘制开销
- 修正隐私声明中的历史存储路径说明，与实际 `entries/` 存储结构保持一致

## [0.1.0] - 2026-06-09

### Added
- Initial project scaffolding (XcodeGen + SPM workspace)
- Screen capture via ScreenCaptureKit with CG fallback
- OCR via Apple Vision framework with confidence scoring
- OCR via Tesseract (opt-in developer mode)
- Barcode detection (QR, Code128, EAN, PDF417, Aztec, DataMatrix)
- Global keyboard shortcuts (⌘⇧1/2/3, ⌘⇧O)
- Menu bar app with capture actions
- Annotation editor with 7 tools (arrow, rect, text, pen, highlight, blur, crop)
- Encrypted history storage (AES-GCM via CryptoKit)
- CLI tool (`snapglass-cli ocr/barcode/capture`)
- App Intents for Shortcuts integration
- URL Scheme routing (`snapglass://capture/ocr/barcode`)
- Preferences window with 6 tabs
- History window with search, delete, export
- Permission guide for screen recording access
- DevMode engine comparison (Vision vs Tesseract)
- Tesseract language pack downloader
- Liquid Glass UI support (macOS 26+) with material fallback
- Memory pressure monitoring and automatic degradation

[Unreleased]: https://github.com/blackkcold/snapocr/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/blackkcold/snapocr/compare/v0.1.5...v0.2.0
[0.1.5]: https://github.com/blackkcold/snapocr/compare/v0.1.0...v0.1.5
[0.1.0]: https://github.com/blackkcold/snapocr/releases/tag/v0.1.0