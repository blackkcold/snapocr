# Changelog

All notable changes to SnapGlass will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

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
