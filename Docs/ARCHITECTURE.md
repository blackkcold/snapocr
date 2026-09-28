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

## 置顶面板（Pinned NSPanel）

区域截图选区确认阶段按 ⌘P（或点击操作条 pin 按钮）会创建置顶面板。面板同样受上述激活策略约束：

> 置顶快捷键（默认 ⌘P）可通过 `PinSelectionShortcut` 自定义。它复用 `KeyboardShortcuts.Shortcut` 仅作为数据类型，配置存于 `PreferenceKeys.pinSelectionShortcut`（应用自有 `UserDefaults`），**从不调用** `KeyboardShortcuts.setShortcut` / `Recorder` / `reset`，因此永远不会注册为全局热键。匹配分两条路径：带 ⌘/⌃/⌥ 的事件走 `performKeyEquivalent(with:)`（见下方约束表），其余走 `keyDown`；两阶段（`.adjusting` / `.choosingAction`）分别走 `onSelectionComplete` 与 `completeSelection`。录制侧拒绝与全局热键及操作条保留键冲突的组合。

| 属性 | 取值 | 原因 |
|------|------|------|
| 窗口类型 | `NSPanel`（`[.borderless, .nonactivatingPanel]`） | 无边框、不抢焦点；`hasVisibleUserFacingWindow` 显式排除 `NSPanel`，因此置顶不会把应用钉在 `.regular` |
| `level` | `.floating` | 保持在普通窗口之上 |
| `hidesOnDeactivate` | `false` | 应用失活时置顶内容不消失 |
| `sharingType` | `.none` | 置顶内容不进入录屏 / 系统截屏 / 后续 SnapGlass 截图 |
| `collectionBehavior` | `[.canJoinAllSpaces, .fullScreenAuxiliary]` | 跨 Space 与全屏辅助显示 |
| `canBecomeKey` / `canBecomeMain` | `true` / `false` | 可接收键盘（Esc / ⌘W），不成为主窗口 |

关键约束（易回归点）：

| 约束 | 原因 |
|------|------|
| ⌘W 必须 override `performKeyEquivalent(with:)` | Command 组合键在无边框面板中先走 key equivalent 分发，`keyDown` 不可靠 |
| `closeAll()` 只遍历管理器自有数组 | 选区面板与窗口选择面板同样是 `NSPanel`，扫描 `NSApp.windows` 按类型过滤会误关它们 |
| 面板需被强引用持有至 `willClose` | `NSPanel` 默认 `isReleasedWhenClosed`，否则会提前释放 |
| 缩放倍率取 `image.width / pinRect.width` | 混合缩放多显示器下各屏倍率不同，`backingScaleFactor` 不可靠 |
| 缩放倍率由面板 frame 宽度反推，不缓存可变副本 | `fitToScreen()` 与拖拽右下角手柄只改 frame，缓存倍率会与画面失同步（工具条读数随之失真、滚轮缩放跳变） |

### 悬浮工具条（PinnedToolbarWindow / PinnedToolbarView）

悬停置顶面板时显示编辑工具条（不透明度、缩放、1:1、适应屏幕）。位置**默认在面板底部外侧**，面板贴近屏幕底部（下方放不下）时**翻到面板上侧**，上下都放不下（面板几乎占满屏高）才回退到面板底部内侧——避免工具条压住截图内容。工具条是**独立无边框子窗口**而非面板内子视图，原因有二：

1. 面板可被拖拽缩放到 `minimumResizeWidth`（40pt），子视图会被窗口裁剪而装不下工具条；
2. 面板透明度由窗口级 `alphaValue` 实现，子视图在 20% 不透明度下会一并变淡而无法操作，独立窗口可完全避开该实现。

| 约束 | 原因 |
|------|------|
| 工具条窗口必须显式设置 `sharingType = .none` | `sharingType` 是**逐窗口**属性、不被父窗口继承；SnapGlass 自身截图不排除本应用窗口，漏设即会入镜 |
| 工具条窗口必须显式设置 `level` 与 `collectionBehavior` | 二者同样不继承；漏设会导致切换 Space 或进入全屏时工具条消失 |
| `orderFront` 之后需重新确认 `sharingType` | 排序操作可能重置该属性 |
| 工具条窗口必须保持 `.borderless`（不得为带标题的普通 `NSWindow`） | 否则会命中 `hasVisibleUserFacingWindow`，使应用被永久钉在 `.regular`（Dock 图标常驻） |
| 工具条由管理器自有字典持有，并在 `willClose` / `closeAll` 一并回收 | 与面板同源：禁止扫描 `NSApp.windows`，且须避免子窗口泄漏成幽灵窗口 |
| 显隐时序收敛到 `PinnedToolbarVisibility` 纯值类型 | 工具条与面板是两个窗口，鼠标移向工具条必然触发面板 `mouseExited`，隐藏必须延迟并由工具条进入事件取消；纯类型可在 CaptureCore 下单测 |
| 工具条尺寸由**内容测量**得出，不得硬编码高/宽 | 旧实现把高度写死为 40pt 且只测宽度，窗口比内容矮，控件被圆角裁切而显示不全 |
| 外边距约束**必须带符号**（`trailing` / `bottom` 为负），且高度下限 = 内容高 + 2×`marginVertical` | 二者同向时若给正值，约束退化为负高度，`fittingSize` 会吃掉上下边距（实测 `stack.frame.y = −marginV`），窗口比内容矮即被 `masksToBounds` 裁切——这正是「工具条高度不够、显示不全」的根因 |
| 宽度 = 档位固定件 + 两根滑杆，滑杆在档位区间内吸收剩余宽度 | 「响应式」的落点：同一档位内滑杆随可用宽度连续伸缩；宽度由 `toolbarLayout` / `toolbarWidth` / `clampedToolbarWidth` 纯函数算出（`PinnedToolbarLayout` 提供档位度量），窗口与内容恒等宽 |
| 两个滑杆用 `>=min` / `<=max` 区间约束，不用固定宽度 | 固定宽度不会随可用空间伸缩；下限用优先级 750，极端窄屏时允许静默让步而非约束冲突 |
| 布局分 `regular` / `compact` 两档，两档都可响应式伸缩 | 可用宽度不足 `regular` 最小宽度时降档：省略前导图标、收紧间距与控件尺寸、收窄滑杆区间；百分比读数两档都保留 |
| 图标按钮 `title = ""` + `imagePosition = .imageOnly`，语义交给 `toolTip` 与无障碍标签 | 中文标题使工具条过宽；图标化后仍可被 VoiceOver 读出 |
| 竖直候选必须**完整**放得下才采用，不得靠钳制硬挤 | 否则面板几乎占满屏高时工具条会被推到屏幕边缘、远离光标且仍遮住画面 |
| 外边距 ≥ 圆角半径，圆角取 8pt | `masksToBounds` 为圆角所必需，边距不足会把控件圆角区裁掉 |
| 工具条尺寸向上取整到整数点（`integralToolbarSize`） | 滑杆宽度常出现半点，取整消除亚像素错位且不会让内容超出窗口 |
| `controlSize` 改变后需 `needsLayout` 再读 `fittingSize` | 否则外部测到的是切换前的陈旧固有尺寸 |

置顶历史条目的 `isProtected` 语义：自动清理的四类路径（时限淘汰、数量上限、磁盘配额、分层剥图）均跳过受保护条目；但 `delete(id:)` / `clear()` 等用户显式操作不受影响。置顶路径不运行自动 OCR，故条目文本为空、不可被文本搜索命中——这是「置顶不静默改写剪贴板、OCR 仅在右键显式触发」这一隐私取舍的直接结果。

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
