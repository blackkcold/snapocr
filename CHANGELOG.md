# Changelog

All notable changes to SnapGlass will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.5.1] - 2026-08-05

### Added
- 完整的多语言支持：补齐菜单栏、权限引导、标注编辑器、历史记录、存储仪表盘、设置页等全部界面文本的本地化，简体中文界面不再出现英文残留
- 新增日文（ja）与韩文（ko）完整翻译；应用语言切换现在可正确显示中文 / 日文 / 韩文
- URL Scheme / App Intents 路由调试页中英混杂文本统一本地化

### Fixed
- 修复窗口截图在无窗口或选择器被取消时卡死、`isCapturing` 永久置位，导致其他截图无法触发的问题
- 修复窗口选择器失焦（点击 History、设置或其他应用）时仅隐藏不结束选择，形成与其它窗口抢焦点的循环 bug
- 修复窗口选择器标题与自绘标题重叠的布局问题，标题层级与间距重新梳理
- 窗口选择器仅显示有一定内容的窗口：过滤 DDPM 等窗口管理软件的悬浮窗，并排除空标题窗口

## [0.5.0] - 2026-08-04

### Added
- 设置面板新增「关于」与「版本更新」标签页：显示版本、构建号、版权、GitHub 链接，并提供检查更新入口
- 聚焦设置窗口时，macOS 菜单栏左上角显示 SnapGlass 应用菜单，含「关于 SnapGlass」与「设置…」入口
- 窗口打开期间应用临时进入 Dock，关闭全部窗口后自动回到纯菜单栏模式

## [0.4.0] - 2026-08-04

### Added
- 设置窗口支持自由调整大小，卡片网格随窗口宽度在单列与双列间自适应重排
- 设置窗口外圈圆角遵循 macOS 26 同心圆设计，低版本按窗口宽度等比缩放圆角
- 侧栏支持折叠与展开，窄窗口下让出更多内容空间
- OCR 语言支持多选启用，可关闭近似语言（如日文汉字与中文汉字）以减少误识别
- OCR 新增语言优先识别（Automatic / English / Chinese / Japanese / Korean First）
- 界面语言新增 Japanese 与 Korean
- 历史记录页面新增存储用量仪表盘：条目数、收藏数、平均置信度、磁盘占用与截图模式分布

### Fixed
- 修复设置窗口圆角与响应式布局在调整窗口大小后不生效的问题

## [0.3.0] - 2026-08-04

### Added
- 区域截图在回车或双击确认选区后，直接在截图覆盖层内提供复制图片、进入编辑器和返回调整操作
- 新增跟随系统、浅色和深色三种外观模式，并统一应用到菜单栏与所有应用窗口
- 设置页面新增可视化外观模块、SF Symbols 侧栏与统一页面标题层级
- 窗口选择器新增按需加载的窗口缩略图预览，并过滤 Dock、菜单栏等系统 UI 窗口
- 滚动截图和竖向长图新增仅调整顶部、底部边界的快速裁切模式

### Fixed
- 移除截图与编辑器之间多余的独立确认窗口，避免打断连续截图交互
- 修复截图操作栏点击后选区状态被错误重置，导致复制和编辑操作无响应的问题

### Changed
- 移除菜单栏中独立的“复制截图”入口，区域截图改由选区内操作条选择复制或编辑
- 区域截图由选区操作条决定复制或编辑；窗口、全屏及滚动截图继续使用截图后偏好设置
- 设置窗口调整为更宽松的原生 macOS 分区布局，并为各模块补充图标和说明
- 区域截图选择复制或编辑时会触发后台历史保存，并立即退出截图模式
- 窗口截图与滚动截图合并到同一窗口预览入口，选中目标后再选择单窗口或窗口内滚动截图

## [0.2.1] - 2026-08-03

### Fixed
- 将条码扫描从菜单栏移至截图编辑器，并支持手动识别后复制内容
- 截图仅检测到一个条码时，在编辑器提示中提供一键复制内容操作
- 普通区域、窗口和全屏截图新增"不进入编辑器、直接复制到剪贴板"入口
- 修复区域截图仅由单个跨屏面板承载，导致副显示器无法进入截图交互的问题
- 修复多显示器与混合缩放环境下区域截图坐标被重复翻转而产生的偏移
- 修复 OCR 文本选中时用近似系统字体重绘导致的字形和基线错位
- 移除 OCR 的 2048px 强制降采样上限，超大图片改为二维重叠分块识别并合并坐标
- 修复编辑器裁剪工具松开鼠标后立即执行，改为可移动、缩放并确认后裁剪
- 修复编辑器裁剪选区上下方向定位错误
- 矩形标注默认启用与描边同色的填充，并在修改描边颜色时保持同步
- 修复编辑器裁剪、撤销或重做后沿用旧 OCR 坐标，并阻止已取消识别任务回写过期结果

### Added
- 添加用户主动触发的 GitHub Release 更新检查、SHA-256 校验下载与 Finder 定位
- 添加开发者模式"强制将最新 Release 视为更新"选项，便于测试更新流程
- 添加带品牌背景、Applications 拖放入口和固定 Finder 布局的 DMG 打包流程

### Changed
- 本地构建与 GitHub Actions 共用 `scripts/package-dmg.sh`，统一 `SnapGlass-vX.Y.Z.dmg` 命名

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

[Unreleased]: https://github.com/blackkcold/snapocr/compare/v0.5.1...HEAD
[0.5.1]: https://github.com/blackkcold/snapocr/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/blackkcold/snapocr/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/blackkcold/snapocr/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/blackkcold/snapocr/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/blackkcold/snapocr/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/blackkcold/snapocr/compare/v0.1.5...v0.2.0
[0.1.5]: https://github.com/blackkcold/snapocr/compare/v0.1.0...v0.1.5
[0.1.0]: https://github.com/blackkcold/snapocr/releases/tag/v0.1.0
