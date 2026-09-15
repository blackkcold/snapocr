# SnapGlass Architecture

> 跨平台架构文档 — 协议导向分层设计

---

## 总体策略

**先 macOS 原生 → 协议抽象 → 平台扩展**

- 首版全部代码用 Swift 实现，不做跨平台编译
- 核心能力通过 `protocol` 定义接口，每个 Package 暴露协议而非具体实现类
- 未来 Windows 版本用 C#/C++ 实现相同协议，通过 FFI 或独立进程与核心逻辑桥接

---

## 分层架构

```
┌─────────────────────────────────────────────────────────┐
│               Presentation Layer (平台特定)               │
│  ┌──────────────────────┐  ┌──────────────────────────┐ │
│  │  macOS: SwiftUI      │  │  Windows (未来): WPF/     │ │
│  │  + AppKit bridge     │  │  WinUI 3 + C#            │ │
│  └──────────────────────┘  └──────────────────────────┘ │
├─────────────────────────────────────────────────────────┤
│              Protocol Layer (跨平台接口)                  │
│  ┌────────────────────────────────────────────────────┐ │
│  │  CaptureProtocol | OCRProtocol | AnnotationProtocol │ │
│  │  HistoryProtocol | ScrollProtocol                   │ │
│  └────────────────────────────────────────────────────┘ │
├─────────────────────────────────────────────────────────┤
│              Core Logic (跨平台共享)                      │
│  ┌────────────────────────────────────────────────────┐ │
│  │  图像预处理 | OCR 后处理 | 标注数据模型              │ │
│  │  拼接算法 | 历史管理策略                            │ │
│  └────────────────────────────────────────────────────┘ │
├─────────────────────────────────────────────────────────┤
│              Platform Adapter (平台适配)                  │
│  ┌──────────────────────┐  ┌──────────────────────────┐ │
│  │  macOS: Vision       │  │  Windows: Media.Ocr      │ │
│  │  ScreenCaptureKit    │  │  Graphics.Capture        │ │
│  │  NSPasteboard        │  │  Clipboard API           │ │
│  └──────────────────────┘  └──────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
```

---

## 协议设计原则

每个 Core Package 暴露协议而非具体类，确保跨平台可替换性。

### 示例：OCRProtocol

```swift
public protocol OCRProtocol {
    associatedtype PlatformImageType

    /// 识别图像中的文本
    func recognize(
        image: PlatformImageType,
        languages: [String],
        options: OCROptions
    ) async throws -> OCRResult

    /// 返回当前引擎支持的语言列表
    func supportedLanguages() -> [String]

    /// 引擎标识
    var engineType: OCREngineType { get }

    /// 日志回调 (用于开发者模式调试)
    var logHandler: ((OCRLogEntry) -> Void)? { get set }
}

// 平台无关的枚举
public enum OCREngineType: Sendable {
    case vision
    case tesseract(languageDataPath: URL?)
    case windowsMediaOcr  // 预留给未来 Windows 版本
}

// 跨平台数据模型
public struct OCRResult: Sendable {
    public let text: String
    public let confidence: Float
    public let engineType: OCREngineType
    public let layoutPreserved: Bool
    public let observations: [OCRLine]
    public let processingTimeMs: Double
}
```

### 协议清单

| Protocol | Package | 平台适配 |
|----------|---------|----------|
| `CaptureProtocol` | CaptureCore | macOS: ScreenCaptureKit + CG |
| `OCRProtocol` | OCRCore | macOS: Vision + Tesseract |
| `BarcodeProtocol` | BarcodeCore | macOS: Vision barcode |
| `AnnotationProtocol` | AnnotationCore | macOS: Core Image |
| `HistoryProtocol` | HistoryCore | macOS: CryptoKit + App Support 本地密钥 |

---

## Actor 层级设计

为防止 actor 嵌套死锁，采用三层架构：

```
@MainActor (UI 层)
    MenuBarViewModel | EditorViewModel | HistoryVM
         │
         ▼
Actor (序列化访问)
    HistoryActor | ScrollStitchActor
         │
         ▼
Struct (无状态工具)
    CryptoService | PostProcessor | FrameDeduper
```

**设计原则：**
- **CryptoService 改为 struct**: 避免 actor 嵌套导致的死锁风险；密钥操作同步执行
- **HistoryActor 保持 actor**: 但内部调用 CryptoService 时使用同步方法
- **ScrollStitchActor**: 滚动截图拼接独立 actor，避免阻塞主线程

---

## 模块职责

| 模块 | 职责 | 关键依赖 |
|------|------|----------|
| **SharedKit** | 日志系统、图片编码、加密服务（CryptoKit AES-GCM）、本地密钥存取、统一错误类型 | CryptoKit, ImageIO |
| **CaptureCore** | 区域/窗口/全屏截图；多显示器 DPI 适配；SCK 主 + CG 兼容 | ScreenCaptureKit |
| **OCRCore** | Vision OCR 主引擎 + 运行时动态加载 Tesseract 降级；开发者模式双引擎对比；内存管理 | Vision, optional libtesseract |
| **BarcodeCore** | QR/Code128/EAN 等条码识别 | Vision |
| **AnnotationCore** | 标注工具集（箭头/矩形/文本/画笔/高亮/模糊/裁剪）；撤销/重做 | Core Image |
| **ScrollCore** | 半自动滚动截图拼接；SSIM 帧去重 | CaptureCore |
| **HistoryCore** | 加密环形缓存；自动清理策略；取色历史（单文件加密存储）；数据迁移 | CryptoKit |
| **AutomationCore** | 保留的 CLI / URL Scheme / App Intents 源码，不进入当前产品构建 | — |

---

## 未来 Windows 迁移路径

```
阶段 1 (当前): macOS Swift 原生 → 所有逻辑在 Swift
阶段 2: 抽取纯算法逻辑到独立模块，标记 @Sendable / Codable
阶段 3 (Windows 需要时): 用 C++/Rust 重写核心算法 + FFI 桥接
                        macOS: Swift → C ABI ← C++ Core
                        Windows: C# → C ABI ← C++ Core
```

---

## OCR Pipeline

```
输入: CGImage / NSImage
  │
  ▼
┌──────────────┐
│ 预处理        │ 裁剪 + 灰度 + 对比度 + 放大 + 二值化
│ (Preprocess)  │
└──────┬───────┘
       │
       ▼
┌──────────────────────────────────────────────┐
│           引擎选择                              │
│                                               │
│  default ──────▶ VisionOCREngine              │
│    │               │                          │
│    │          confidence < 0.7?               │
│    │               │                          │
│    │          ┌────▼────┐                     │
│    │          │ 降级提示 │ → 用户可选 Tesseract │
│    │          └─────────┘                     │
│    │                                          │
│  dev_mode ──▶ parallel(Vision, Tesseract)     │
│    │          → 对比结果 + 日志输出            │
└────┼──────────────────────────────────────────┘
     │
     ▼
┌──────────────┐
│ 后处理        │ 合并行 + 布局保留 + URL检测 + 词典替换
│ (PostProcess) │
└──────┬───────┘
       │
       ▼
输出: OCRResult (文本 + 置信度 + 引擎 + 日志)
```

**语言特定置信度阈值：**
- 中文：0.6
- 英文：0.8
- 日文：0.65

---

## 本地化

界面语言由设置中的「应用语言」决定（`PreferenceKeys.appLanguage`，默认 `system`），支持 `en` / `zh-Hans` / `ja` / `ko`。文案以 `.lproj/Localizable.strings` 存储于 `App/SnapGlass/Resources/`。

Cocoa 存在两条互不相通的解析路径，两条都必须覆盖：

| 路径 | 解析依据 | 适用场景 |
|------|----------|----------|
| SwiftUI `Text` / `LocalizedStringKey` | 视图环境 `\.locale` | 视图树内的文本，随应用语言即时切换 |
| `AppLocalization.string(_:)` | `AppLanguage.resourceIdentifier` 定位 `.lproj` | 视图环境之外的 Foundation 文本：toast、`NSAlert`、`NSMenu`、AppKit 面板、画布绘制 |

`App.swift` 逐窗口注入 `.environment(\.locale, locale)`；`Window` 场景标题与 `.commands` 菜单项不在视图环境内，因此额外使用 `.navigationTitle(Text(...))` 与 `AppLocalization`。

禁止在界面代码中直接使用 `NSLocalizedString` / `String(localized:)`——它们跟随系统语言而非应用语言，会导致设置窗口内语言不一致。界面代码中的文本应为字符串字面量（`LocalizedStringKey`）或经由 `AppLocalization`；`scripts/check-localization.sh` 会校验四语言键一致、占位符一致、无冲突重复键，且源码引用的键均已存在。

历史记录的 `captureMode`（`area` / `window` / `fullscreen` / `scroll`）是持久化数据标识而非界面文案，不参与本地化，以保证 CSV 导出与存储语义稳定。

---

## 激活策略生命周期（accessory ↔ regular）

`LSUIElement=true` 使应用默认以 `.accessory` 启动（无 Dock 图标、无应用菜单）。打开 Preferences / History / Editor / Permission 窗口时经 `AppWindowPresenter.present` 切到 `.regular` 以获得 Dock 图标与应用菜单；关闭最后一个窗口后须回退 `.accessory`。所有窗口打开路径均经 `present()`，因此降级门只依赖在途的 `pendingPresentations`。

关键约束（易回归点）：

| 约束 | 原因 |
|------|------|
| 降级门**不得**依赖 `registeredWindowIDs` | SwiftUI 关闭 `Window` 场景后仍保留其 `NSWindow`，`register()` 可能在 `willClose` 之后重登记，使集合永久非空而永久阻塞降级 |
| 降级时在 `setActivationPolicy(.accessory)` 成功后显式 `deactivate()` | 应用仍 active 时切换到 `.accessory` 常不能立即移除 Dock 图标（Apple 未文档化行为） |
| 重算触发面仅 `willClose` / `didBecomeKey` / `didMiniaturize` / `didDeminiaturize` | 不观察 `didOrderOffScreen` / `didHide` / `didResignActive`，避免隐藏、切 Space、全屏时误降级 |
| `willClose` 后延后一个 runloop tick（合并去抖）再重算 | `willClose` 触发时窗口仍 `isVisible`，需等 `orderOut` 完成 |
| `didBecomeKey` 补齐晋升 `.regular` | 与降级对称，避免应用卡在 accessory |

---

## 技术选型

| 域 | 选择 |
|----|------|
| 语言 | Swift 6+ |
| UI | SwiftUI + AppKit bridge |
| 状态管理 | Combine (UI) + Swift concurrency (workflow) |
| 截图 | ScreenCaptureKit (主) + CG 兼容 |
| OCR | Apple Vision (主) + Tesseract (降级) |
| 条码 | Vision barcode request |
| 热键 | KeyboardShortcuts |
| 项目生成 | XcodeGen + SPM |
| 加密 | CryptoKit AES-GCM + App Support 0600 密钥文件 |
| 崩溃 | macOS 系统日志与用户反馈（当前未集成第三方崩溃收集器） |
