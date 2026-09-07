# Changelog

All notable changes to SnapGlass will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.7.0] - 2026-09-07

### Added
- 历史截图自适应图片网格：保留原始比例、淡阴影、时间及可切换收藏星标，支持收藏筛选、收藏分组与时间双向排序。
- 文字标注改为画布内原位多行编辑，新建/双击编辑统一；支持 Enter 与 Shift+Enter 提交/换行互换设置，Esc 或失焦取消。


### Changed
- 代码规范：全量清理 SwiftLint 债务（295 → 0 违规），拆分超长文件为扩展/新文件，统一命名与行宽，`.swiftlint.yml` 显式排除各包 `.build` 目录并启用 `trailing_comma: mandatory_comma`，与 swift-format 对齐

### Fixed
- CI unit-test 卡住：为 job 与 step 增加 `timeout-minutes`，避免单个 Package 挂起导致无限等待；OCRCore 在 CI 上跳过依赖真实 Vision OCR 的集成测试（无头 runner 上 Vision 首次初始化可能挂起），本地仍完整运行（`scripts/test.sh`）
- 本地打包失败：SwiftLint 0.65+ 移除 `--path` 选项，`project.yml` 的 SwiftLint build phase 改用位置参数（新旧版本均兼容）

## [0.6.1] - 2026-09-02

### Added
- 取色显示：hex 旁同时显示 RGB 值（区域截图悬停气泡、编辑器悬停气泡、编辑器 Inspector 色块三处两行显示）
- 取色历史：取色器复制的颜色记录到本地 AES-256-GCM 加密历史（复用截图历史密钥，单文件存储）；历史窗口新增「截图 / 颜色」分段，颜色段支持网格浏览、hex 过滤、点击复制与右键删除
- 存储管理：偏好设置新增取色历史卡片（启用开关、数量上限、清空），存储概览新增颜色记录数；清空截图历史时同步清空取色历史，取色历史也可单独清空

### Fixed
- 修复多显示器副屏区域截图取色无效（预捕获改用 Quartz 全局坐标边界）、悬停与编辑器取色气泡缺失色块
- 修复取色历史复制通知无自动消失、常驻遮挡界面

### Changed
- toast 通知位置可配置，无固定底栏窗口（偏好设置/历史/权限）移至底部，避开操作栏

## [0.6.0] - 2026-09-01

### Added
- 取色器：区域截图 overlay 与标注编辑器新增取色工具，悬停实时显示 hex，单击复制单色，拖拽采样区域的平均色与主色（主色数量可在偏好设置中调整，默认 5）

### Fixed
- 更新检查改用 GitHub Release 静态清单，避免匿名 REST API 的共享 IP 限额导致 HTTP 403
- 更新下载同时校验清单内 SHA-256 与 Release sidecar，拒绝版本、资源路径或校验值不一致的发布
- 更新检查先通过 `/releases/latest` 重定向发现版本并先行比较，无清单的旧版本按命名约定确定性降级，消除「无清单即报错」的问题

### Changed
- Release 流程自动生成并核验 `SnapGlass-update.json`，SHA-256 文件改用可移植的相对文件名

## [0.5.6] - 2026-08-28

### Fixed
- 修复截图编辑器可能在打开约 3 秒后因窗口注册状态与真实可见状态不一致而被切回纯菜单栏模式并隐藏的问题

### Changed
- 矩形标注默认改为纯线框（不再自动填充描边同色），可通过填充开关或 `.note`/`.monochrome` 预设显式填充
- 选择（select）工具下可直接选取 OCR 文本（点击定位 / 双击选词 / 三击选行 / 拖拽连续选 / Shift 扩展），并支持右键菜单；方向键仍用于微调标注，不抢冲突
- 从标注工具栏移除 OCR 工具按钮（右下角 OCR 识别与复制入口保留）

## [0.5.5] - 2026-08-26

### Fixed
- 重构菜单栏应用窗口生命周期：先切换常规激活策略并请求激活，再打开或前置窗口，修复关闭后第二次打开不显示 Dock 且窗口被遮挡的问题
- 使用 `didBecomeKey` / `willClose` 事件确认窗口状态，并在关闭事件后统一重算激活策略，移除固定延迟、跨窗口共享重试任务和关闭阶段竞态
- 修复应用生命周期视图重入时无条件切回纯菜单栏激活策略，避免已打开窗口意外失焦
- 修复窗口关闭观察覆盖缺口和编辑器无图像时未注册，确保关闭最后一个窗口后可靠回落纯菜单栏模式
- 修复本地 Debug 构建默认混编 arm64 与 x86_64，导致 Swift Package 模块架构冲突的问题

### Changed
- 同步项目营销版本配置至 `0.5.5`

## [0.5.3] - 2026-08-07

### Fixed
- 确认窗口截图选中后点击「Capture Window」或双击预览即强制进入截图编辑器，不再受「截图后打开编辑器」偏好影响
- 窗口截图流程从选中到编辑器跳转全链路验证通过

## [0.5.2] - 2026-08-06

### Fixed
- 窗口截图选择器移除悬浮高亮，选中态由点击驱动，仅保留选中高亮
- 点击「Capture Window」现在强制进入截图编辑器，不再受“截图后打开编辑器”偏好影响
- 截图进入编辑器时不再叠加成功提示，避免与编辑器 UI 产生层级遮挡；捕获或复制失败时仍显示错误提示
- 窗口截图裁剪为仅窗口高清图，去除环绕窗口的黑色全屏背景；对部分离屏窗口优雅降级
- 修复窗口截图预览缓存陈旧，跨会话与会话内均能跟随窗口实时刷新

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

[Unreleased]: https://github.com/blackkcold/snapocr/compare/v0.7.0...HEAD
[0.7.0]: https://github.com/blackkcold/snapocr/compare/v0.6.1...v0.7.0
[0.6.1]: https://github.com/blackkcold/snapocr/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/blackkcold/snapocr/compare/v0.5.6...v0.6.0
[0.5.6]: https://github.com/blackkcold/snapocr/compare/v0.5.5...v0.5.6
[0.5.5]: https://github.com/blackkcold/snapocr/compare/v0.5.3...v0.5.5
[0.5.3]: https://github.com/blackkcold/snapocr/compare/v0.5.2...v0.5.3
[0.5.2]: https://github.com/blackkcold/snapocr/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/blackkcold/snapocr/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/blackkcold/snapocr/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/blackkcold/snapocr/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/blackkcold/snapocr/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/blackkcold/snapocr/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/blackkcold/snapocr/releases/tag/v0.2.0
