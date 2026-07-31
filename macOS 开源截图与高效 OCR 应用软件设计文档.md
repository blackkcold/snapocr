# SnapGlass 软件设计文档

**文档类型**: SDD
**项目代号**: SnapGlass
**版本**: 2.1 (风险补全 + 性能修正版)
**策略**: 标准方案首发 + 完整方案分阶段构建，macOS 优先、预留跨平台架构
**假设**: 最低支持 macOS 13+；技术栈 Swift + SwiftUI + Combine + AppKit bridge；OCR 引擎 Apple Vision 主线 + Tesseract 降级；开源、离线优先、面向 agent 协作开发。

---

## 执行摘要

SnapGlass 是一个面向高频知识工作流的本地截图 + OCR 基础设施。首版交付**标准方案**（截图 + 标注 + OCR + 条码 + 快捷键 + CLI + 历史），后续通过分阶段迭代扩展为完整方案（滚动截图、Shortcuts、高级标注）。架构采用 **macOS 原生优先 + 协议导向分层** 设计，核心能力通过 protocol 抽象，为未来 Windows/跨平台扩展预留接口。

---

## 一、风险审计与缓解

### 🔴 高风险项 (首版必须解决)

| # | 风险 | 影响 | 缓解措施 | 首版落地 |
|---|------|------|----------|----------|
| **R1** | 跨平台架构缺失 → 未来 Windows 需重写 | 全量返工 | 首版即采用 protocol-oriented 设计，Core 层接口与平台实现分离；未来 Windows 只需实现对应协议 | ✅ 架构已纳入 |
| **R2** | 滚动截图跨应用差异大 → 拼接不稳 | 用户体验差 | 首版做白名单策略（Safari/Chrome 优先）；失败时展示"拼接失败，请手动截图"引导；明确 MVS 承诺"可用"不承诺"全自动" | ✅ 半自动方案 |
| **R3** | Apple Vision 低置信度场景 OCR 不准 | 识别结果不可用 | 定义 0.7 置信度阈值；低于阈值自动展示降级提示；Tesseract 作为二级引擎 fallback（开发者模式可手动对比） | ✅ Tesseract 已集成 |
| **R4** | 权限被拒绝后功能完全不可用 | 体验断裂 | 实现完整权限状态机；拒绝后展示引导卡片 + "打开系统设置"按钮；缺失权限仅禁用对应功能 | ✅ 权限服务已设计 |
| **R5** | `CGPreflightScreenCaptureAccess()` 在 Sequoia+ 对临时签名返回 false | 开发调试卡死 | 明确 CI 签名策略；本地开发用条件编译跳过屏幕录制权限要求；自托管 runner 做 UI 集成 | ✅ CI 设计已覆盖 |

### 🟡 中风险项

| # | 风险 | 影响 | 缓解措施 |
|---|------|------|----------|
| **R6** | macOS Sequoia/Tahoe 旧 CG API 废弃、TCC 更严格 | 截图可能被系统拦截 | 必须用 ScreenCaptureKit；macOS 15+ 要求 Developer ID 签名；需要 Info.plist 中有 `NSScreenCaptureUsageDescription` |
| **R7** | Liquid Glass (macOS 26) 适配需要维护两套 UI | 增加 UI 维护成本 | 通过 `#available(macOS 26, *)` 分支；13-25 统一用 `.ultraThinMaterial` 退化；单独维护 glass-degradation 测试 |
| **R8** | CLI 与 GUI 并发访问 HistoryStore | 数据竞争 | HistoryCore 使用 `actor` 序列化所有写操作；必要文件操作使用 `NSFileCoordinator` |
| **R9** | OCR 文本历史含敏感信息（密码、身份证号等） | 隐私泄露 | 历史数据使用 CryptoKit AES-GCM 加密存储；提供"敏感文本不持久化"模式；导出支持脱敏选项；`PrivacyInfo.xcprivacy` 声明屏幕录制使用 |
| **R10** | KeyboardShortcuts 依赖外部库 | 维护风险 | 固定在特定版本；提供 `HotKey` 作为备选评估位 |
| **R11** | 多个参考项目导致设计摇摆 | 架构不一致 | 明确定义参照优先级：架构 → Capso、体验 → capcap、OCR → TRex、测试 → NormCap |
| **R20** | CLI 与 GUI 热键冲突 | KeyboardShortcuts 可能与终端快捷键冲突 | CLI 模式自动禁用全局热键；提供 `--no-hotkey` 参数 |
| **R21** | OCR 结果本地化缺失 | 错误提示硬编码英文 | 从 Phase 1 开始使用 `String(localized:)` + `Localizable.strings` |
| **R22** | CryptoKit 密钥轮换缺失 | 长期使用同一密钥有安全风险 | 实现 `KeyRotationPolicy` + 透明重加密（Phase 2） |
| **R23** | Accessibility 权限 opt-in 引导不足 | 用户不知道为什么需要辅助功能权限 | 添加权限用途说明弹窗 + "了解详情"链接 |

### 🟢 低风险项（监控即可）

| # | 风险 | 缓解措施 |
|---|------|----------|
| **R12** | Tesseract 打包导致 App 体积增加 | 首版仅作为可选组件，通过 developer flag 启用；不加载语言包则无额外体积 |
| **R13** | macOS 15+ 每月重新授权提示 | 对频繁使用场景影响小；首版不做 App Store 分发则无 sandbox 限制 |

### 🔴 高风险补充项 (v2.1 新增)

| # | 风险 | 影响 | 缓解措施 | 首版落地 |
|---|------|------|----------|----------|
| **R14** | 多个 Actor 交互死锁：HistoryCore(actor) + CryptoService(actor) + DevModeService(actor) 三个 actor 相互调用 | UI 卡死、数据丢失 | 将 CryptoService 改为 struct + 同步方法，避免 actor 嵌套；HistoryCore 内部加密操作使用 `nonisolated` 包装 | ✅ 架构调整 |
| **R15** | OCR 大图片内存暴涨：Vision 框架内部缓存 + CGImage 持有 | 峰值 > 500MB，超出 120MB 目标 | 添加图片尺寸预检，> 4K 分辨率自动降采样至 2048px 宽；OCR 完成后立即释放原始 CGImage | ✅ 预检逻辑 |
| **R16** | Tesseract 语言数据下载机制缺失：文档说"按需下载"但无网络层设计 | 用户无法获取中文支持 | 实现 `LanguagePackDownloader` + 进度 UI + 离线降级提示；语言包缓存到 `~/Library/Application Support/SnapGlass/tessdata/` | ✅ 下载器设计 |
| **R17** | 数据迁移策略空白：HistoryCore 没有版本号管理 | 升级后历史数据丢失或损坏 | 添加 `SchemaVersion` 枚举 + 自动迁移链 + 迁移失败回滚机制 | ✅ 迁移框架 |
| **R18** | 滚动截图内存失控：多帧拼接时所有帧同时持有 | 10 帧 4K = 约 120MB 内存 | 流式拼接（逐帧处理并释放已处理帧）+ 内存压力监控 | ✅ 流式处理 |
| **R19** | Liquid Glass 降级测试缺失：`#available` 分支无测试覆盖 | macOS 26+ 发布后 UI 崩溃 | 添加 `GlassDegradationTests` target，覆盖所有 `#available(macOS 26, *)` 分支 | ✅ 测试覆盖 |

---

## 二、交叉核查

### 2.1 技术选型一致性

| 核查项 | 设计声明 | 实际验证 | 结论 |
|--------|----------|----------|------|
| ScreenCaptureKit | macOS 13+ 高性能截图 | macOS 15+ 官方废弃 CG 旧 API，SCK 已成唯一推荐路径 | ✅ 必须 SCK |
| Vision OCR | 离线零依赖 | Vision 是系统框架，不需要额外下载模型 | ✅ 正确 |
| KeyboardShortcuts | sandboxed & MAS compatible | 库声明支持；但首版不用 MAS 所以不影响 | ✅ 可用 |
| XcodeGen | agent 友好 | Capso 项目中已验证，text-based 无冲突 | ✅ 推荐 |
| App Intents | Shortcuts 集成 | macOS 13+ Apple 推荐此方案 | ✅ 可用 |
| Tesseract | SwiftWasm/TesseractKit 桥接 | 需手动打包语言数据，体积 50-200MB | ⚠️ 明确体积影响 |
| Sparkle 2.x | 自动更新 | 要求 HTTPS feed + EdDSA 签名 | 🔄 首版暂不做分发 |

### 2.2 架构完整性核查

| 模块 | 已定义 | 缺失补充 |
|------|--------|----------|
| CaptureCore | 区域/窗口/全屏截图 | 多显示器 DPI 差异处理、macOS 15+ `SCContentSharingPicker` 适配 |
| ScrollCore | 半自动拼接 | 帧去重阈值（相似度 > 0.95）、拼接失败回退 UI、白名单应用列表 |
| OCRCore | Vision 识别 + 后处理 | **置信度阈值** (`minConfidence`)、**降级触发条件**、Tesseract 接口 + 日志 |
| AnnotationCore | 标注对象模型 | 撤销/重做栈深度限制 (max 100)、大图标注内存控制 |
| HistoryCore | 环形缓存 | **并发安全** (actor serialization)、**加密存储** (CryptoKit)、数据迁移策略 |
| AutomationCore | CLI + URL Scheme + Shortcuts | 命令参数校验、错误码规范 (`exit(0..4)`) |
| PermissionService | 权限检查 | **完整状态机** (unknown → request → granted/denied → degraded) |

### 2.3 安全边界核查（已全部补充）

| 边界 | 状态 | 补充方案 |
|------|------|----------|
| 屏幕录制权限拒绝 | ✅ 已设计 | 权限状态机 + 降级 UI + 系统设置引导 |
| 辅助功能权限 (双击 Command) | ✅ 已设计 | 默认关闭，在高级选项中 opt-in；不用辅助功能也能正常使用 |
| Apple Events 权限 (Finder 集成) | 🔄 延后 | P1 功能，首版不涉及 |
| 沙盒限制 (App Store) | 🔄 暂不适用 | 首版只做 GitHub 直装版，不启用 sandbox |
| 网络请求边界 | ✅ 已设计 | 仅允许 GitHub API 域名；速率限制 (max 10 req/min)；所有请求需用户显式触发 |
| 数据加密 | ✅ 已设计 | CryptoKit AES-GCM at rest；密钥存储在 App Support 0600 本地文件 |
| 敏感文本保护 | ✅ 已设计 | 默认不持久化完整 OCR 文本；导出支持脱敏 |
| 崩溃日志安全 | ✅ 已设计 | 本地存储；用户手动导出；不自动上传 |
| 代码签名 (macOS 15+) | ✅ 已设计 | Developer ID 签名 + Hardened Runtime + notarytool 公证 |

### 2.4 性能目标可行性核查

| 指标 | 原始目标 | 实际可行性 | 风险 | 修正建议 |
|------|----------|------------|------|----------|
| 截图 < 150ms | SCK 区域截图 | ✅ 可行 | 多显示器场景可能超时 | 添加超时降级（200ms 后切换 CG 方案） |
| OCR < 800ms | Vision 识别 | ⚠️ **高风险** | 4K 图片中文混合识别通常 1.2-2s | 改为"中等图片 (≤2K) < 800ms"，大图添加尺寸预检 |
| 内存 < 120MB | 峰值 | ❌ **不现实** | 4K 图片 ~32MB + OCR 缓存 + 标注栈 | 修正为 250MB，或添加内存压力监控自动降级 |

### 2.5 架构完整性补充核查

| 模块 | 文档定义 | 实际缺失 | 补充 |
|------|----------|----------|------|
| CaptureCore | 多显示器处理 | **DPI 差异检测** | 添加 `NSScreen.backingScaleFactor` 适配逻辑 |
| ScrollCore | 帧去重阈值 0.95 | **去重算法未指定** | 使用 SSIM (Structural Similarity) 而非像素差异 |
| OCRCore | 置信度阈值 0.7 | **语言特定阈值** | 建议：中文 0.6、英文 0.8、日文 0.65 |
| HistoryCore | 加密存储 | **密钥轮换** | 添加 `KeyRotationPolicy`（Phase 2 实现） |
| AutomationCore | CLI 参数校验 | **Shell 补全** | 生成 `completions/zsh/_snapglass` 等文件 |

### 2.6 安全边界补充核查

| 边界 | 原始状态 | 补充发现 |
|------|----------|----------|
| 网络请求边界 | ✅ 仅 GitHub API | **新增白名单**: Tesseract 语言包下载域名 (`github.com/tesseract-ocr/tessdata`) |
| 数据加密 | ✅ CryptoKit | **新增**: 内存中敏感数据使用后清零 (`Data.zeroize()` 扩展) |
| 权限最小化 | ✅ 拒绝后降级 | **新增**: 辅助功能权限的明确用途说明弹窗 |
| 依赖安全 | 🔄 未覆盖 | **新增**: SPM 依赖审计 + 签名验证（Phase 4 安全审查） |

---

## 三、跨平台架构

### 3.1 总体策略

> **先 macOS 原生 → 协议抽象 → 平台扩展**

- 首版全部代码用 Swift 实现，不做跨平台编译
- 核心能力通过 `protocol` 定义接口，每个 package 暴露协议而非具体实现类
- 未来 Windows 版本用 C#/C++ 实现相同协议，通过 FFI 或独立进程与核心逻辑桥接

### 3.2 分层架构

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
│  │  HistoryProtocol | AutomationProtocol               │ │
│  └────────────────────────────────────────────────────┘ │
├─────────────────────────────────────────────────────────┤
│              Core Logic (跨平台共享)                      │
│  ┌────────────────────────────────────────────────────┐ │
│  │  图像预处理 | OCR 后处理 | 标注数据模型              │ │
│  │  拼接算法 | 历史管理策略 | 命令解析                  │ │
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

### 3.3 协议设计原则

```swift
// 每个 Core Package 暴露协议而非具体类
// 例如 OCRCore/Sources/OCRProtocol.swift:

public protocol OCRProtocol {
    associatedtype PlatformImageType

    /// 识别图像中的文本
    /// - Parameters:
    ///   - image: 平台原生图像对象
    ///   - languages: 语言优先级列表
    ///   - options: 识别选项
    /// - Returns: 统一的 OCR 结果
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

### 3.4 未来 Windows 迁移路径

```
阶段 1 (当前): macOS Swift 原生 → 所有逻辑在 Swift
阶段 2: 抽取纯算法逻辑到独立模块，标记 @Sendable / Codable
阶段 3 (Windows 需要时): 用 C++/Rust 重写核心算法 + FFI 桥接
                        macOS: Swift → C ABI ← C++ Core
                        Windows: C# → C ABI ← C++ Core
```

### 3.5 Actor 层级优化设计

```
┌─────────────────────────────────────────────────────────┐
│                  Actor 层级 (优化后)                      │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  @MainActor (UI 层)                                      │
│  ┌────────────────────────────────────────────────────┐ │
│  │  MenuBarViewModel | EditorViewModel | HistoryVM     │ │
│  └────────────────────────────────────────────────────┘ │
│                         │                               │
│                         ▼                               │
│  Actor (序列化访问)                                       │
│  ┌────────────────────────────────────────────────────┐ │
│  │  HistoryActor | ScrollStitchActor                   │ │
│  └────────────────────────────────────────────────────┘ │
│                         │                               │
│                         ▼                               │
│  Struct (无状态工具)                                      │
│  ┌────────────────────────────────────────────────────┐ │
│  │  CryptoService | PostProcessor | FrameDeduper       │ │
│  └────────────────────────────────────────────────────┘ │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

**设计原则**:
- **CryptoService 改为 struct**: 避免 actor 嵌套导致的死锁风险；密钥操作同步执行
- **HistoryActor 保持 actor**: 但内部调用 CryptoService 时使用同步方法
- **ScrollStitchActor**: 滚动截图拼接独立 actor，避免阻塞主线程

---

## 四、产品范围：分阶段构建

### 阶段总览

```
Phase 0: 脚手架 (第 1 周)
  项目结构 + CI + 文档 + 权限服务

Phase 1: 核心功能 (第 2-4 周)  ← 标准方案开始
  截图 + OCR + 条码 + 快捷键 + 剪贴板

Phase 2: 交互完善 (第 5-6 周)  ← 标准方案完成
  标注工具 + 历史 + CLI + 编辑器

Phase 3: 扩展能力 (第 7-8 周)  ← 完整方案
  滚动截图 + Shortcuts + URL Scheme

Phase 4: 稳定与发布 (第 9-10 周)
  测试回归 + 性能优化 + 文档 + GitHub Release
```

### 需求矩阵

| 需求 | Phase | MVS? | 备注 |
|------|-------|------|------|
| 区域/窗口/全屏截图 | P0 | ✅ | ScreenCaptureKit |
| OCR 文本识别 (Vision) | P0 | ✅ | 语言配置 + Plain/Layout 输出 |
| 二维码/条形码识别 | P0 | ✅ | Vision barcode request |
| 全局快捷键 (KeyboardShortcuts) | P0 | ✅ | 用户可录制 |
| 识别语言配置 | P0 | ✅ | 预设 + per-call override |
| 剪贴板输出 | P0 | ✅ | NSPasteboard 只写不读 |
| Tesseract 降级引擎 | P0 | ✅ | 开发者模式开关 + 日志对比 |
| 标注工具集 (箭头/矩形/文本/画笔/高亮/模糊/裁剪) | P1 | ✅ | Core Image 渲染 |
| CLI (ocr/barcode file) | P1 | ✅ | 共享 core packages |
| 本地历史环形缓存 | P1 | ✅ | 加密存储 + 自动清理 |
| 半自动滚动截图 | P2 | ✅ | 白名单应用 + 失败回退 |
| Shortcuts (App Intents) | P2 | ✅ | 4 个 action |
| URL Scheme | P2 | ✅ | snapglass://capture?... |
| 偏好设置窗口 | P2 | ✅ | 语言/快捷键/历史策略 |
| AX 自动滚动增强 | P3 | 🔄 | P3 延后 |
| 视频录制 | P4 | 🔄 | 延后 |
| 云分享/翻译/AI 增强 | P4 | 🔄 | 延后 |

### Phase 0 详细清单

```
Phase 0: 脚手架初始化
├── 仓库结构
│   ├── project.yml (XcodeGen)
│   ├── Package.swift (SPM workspace)
│   ├── .swift-format (格式化配置)
│   ├── .swiftlint.yml (Lint 配置)
│   └── .gitignore (排除 .xcodeproj)
├── CI
│   └── .github/workflows/ci.yml (lint + build + test)
├── 文档
│   ├── AGENTS.md (Agent 协作指南)
│   ├── ARCHITECTURE.md (架构说明)
│   ├── CONTRIBUTING.md (贡献指南)
│   ├── SECURITY.md (安全策略)
│   └── PRIVACY.md (隐私声明)
├── 模块骨架
│   ├── App/SnapGlass/ (GUI App target)
│   ├── App/SnapGlassCLI/ (CLI target)
│   ├── Packages/SharedKit/ (共享工具)
│   ├── Packages/CaptureCore/ (截图)
│   ├── Packages/OCRCore/ (OCR)
│   ├── Packages/BarcodeCore/ (条码)
│   ├── Packages/AnnotationCore/ (标注)
│   ├── Packages/ScrollCore/ (滚动截图)
│   ├── Packages/HistoryCore/ (历史)
│   └── Packages/AutomationCore/ (CLI/URL/Shortcuts)
└── 权限服务
    └── PermissionService (状态机 + 降级 UI)
```

---

## 五、技术选型

| 域 | 选择 | 理由 |
|----|------|------|
| 语言 | Swift 6+ | Apple 原生栈一致性，async/await，actor 并发 |
| UI | SwiftUI + AppKit bridge | SwiftUI 快速开发 + AppKit 处理菜单栏/浮窗/覆盖层 |
| 状态管理 | Combine (UI) + Swift concurrency (workflow) | 各司其职 |
| 截图 | ScreenCaptureKit (主) + CG 兼容 | SCK 官方推荐，macOS 15+ CG API 废弃 |
| OCR | Apple Vision (主) + Tesseract (降级) | Vision 零依赖 + Tesseract 特殊场景补充 |
| 条码 | Vision barcode request | 原生支持、零额外依赖 |
| 热键 | KeyboardShortcuts | 自带录制 UI，声明 sandbox 兼容 |
| 项目生成 | XcodeGen + SPM | 文本化、无冲突、agent 友好 |
| 更新 | 首版不做自动更新 | Phase 4 再集成 Sparkle |
| 崩溃 | 本地 PLCrashReporter | 用户手动导出 |
| 加密 | CryptoKit AES-GCM + App Support 本地密钥 | 历史数据 at rest + 0600 文件权限 |

---

## 六、仓库结构

```
snapocr/
├── .github/
│   └── workflows/
│       └── ci.yml                          # lint + build + unit test
├── App/
│   ├── SnapGlass/                          # macOS GUI App
│   │   ├── App.swift                       # @main 入口
│   │   ├── Info.plist                      # 含 NSScreenCaptureUsageDescription
│   │   ├── SnapGlass.entitlements          # Hardened Runtime
│   │   └── Sources/
│   │       ├── MenuBar/                    # 菜单栏入口
│   │       ├── Windows/                    # 偏好设置、历史窗口
│   │       ├── Overlays/                   # 截图选区覆盖层
│   │       ├── Editor/                     # 标注编辑器
│   │       ├── Permissions/                # 权限引导卡片
│   │       └── Routing/                    # URL Scheme / App Intents
│   └── SnapGlassCLI/                       # CLI target
│       └── main.swift
├── Packages/
│   ├── SharedKit/
│   │   ├── Package.swift
│   │   ├── Sources/
│   │   │   ├── Extensions/                 # Foundation/AppKit 扩展
│   │   │   ├── Logging/                    # 日志系统
│   │   │   │   ├── Logger.swift            # 统一日志接口
│   │   │   │   └── LogLevel.swift
│   │   │   ├── Security/
│   │   │   │   ├── CryptoService.swift     # AES-GCM 加密
│   │   │   │   └── KeychainService.swift   # LocalKeyStore 实现（不访问 Keychain）
│   │   │   └── Errors/
│   │   │       └── AppError.swift          # 统一错误类型
│   │   └── Tests/
│   ├── CaptureCore/
│   │   ├── Package.swift
│   │   ├── Sources/
│   │   │   ├── CaptureProtocol.swift       # 跨平台截图协议
│   │   │   ├── CaptureOrchestrator.swift
│   │   │   ├── SCKAdapter.swift            # ScreenCaptureKit 适配
│   │   │   └── CGCompatAdapter.swift       # 旧 API 兼容
│   │   └── Tests/
│   ├── OCRCore/
│   │   ├── Package.swift
│   │   ├── Sources/
│   │   │   ├── OCRProtocol.swift           # 跨平台 OCR 协议
│   │   │   ├── OCRPipeline.swift           # 管道编排
│   │   │   ├── VisionOCREngine.swift       # Apple Vision 引擎
│   │   │   ├── TesseractOCREngine.swift    # Tesseract 降级引擎
│   │   │   ├── DevModeService.swift        # 开发者模式: 引擎对比 + 日志
│   │   │   ├── PostProcessor.swift         # 布局整理/URL检测
│   │   │   ├── OCROptions.swift            # 识别选项
│   │   │   └── OCRLogEntry.swift           # 日志条目
│   │   └── Tests/
│   ├── BarcodeCore/
│   │   ├── Package.swift
│   │   ├── Sources/
│   │   │   ├── BarcodeProtocol.swift
│   │   │   ├── VisionBarcodeEngine.swift
│   │   │   └── BarcodeResult.swift
│   │   └── Tests/
│   ├── AnnotationCore/
│   │   ├── Package.swift
│   │   ├── Sources/
│   │   │   ├── AnnotationProtocol.swift
│   │   │   ├── AnnotationDocument.swift    # 统一文档模型
│   │   │   ├── AnnotationNode.swift        # 归一化坐标节点
│   │   │   ├── Tools/                      # 各标注工具
│   │   │   │   ├── ArrowTool.swift
│   │   │   │   ├── RectTool.swift
│   │   │   │   ├── TextTool.swift
│   │   │   │   ├── PenTool.swift
│   │   │   │   ├── HighlightTool.swift
│   │   │   │   ├── BlurTool.swift
│   │   │   │   └── CropTool.swift
│   │   │   └── Renderer.swift              # 矢量层 + 背景位图渲染
│   │   └── Tests/
│   ├── ScrollCore/
│   │   ├── Package.swift
│   │   ├── Sources/
│   │   │   ├── ScrollProtocol.swift
│   │   │   ├── ScrollStitchEngine.swift    # 帧对齐 + 拼接
│   │   │   ├── OverlapDetector.swift       # 重叠带匹配
│   │   │   ├── FrameDeduper.swift          # 重复帧检测
│   │   │   └── ScrollError.swift           # 拼接错误类型
│   │   └── Tests/
│   ├── HistoryCore/
│   │   ├── Package.swift
│   │   ├── Sources/
│   │   │   ├── HistoryProtocol.swift
│   │   │   ├── HistoryActor.swift          # actor 序列化访问
│   │   │   ├── HistoryEntry.swift          # 加密存储条目
│   │   │   ├── CleanupPolicy.swift         # 清理策略
│   │   │   └── TextAnonymizer.swift        # 导出脱敏
│   │   └── Tests/
│   └── AutomationCore/
│       ├── Package.swift
│       ├── Sources/
│       │   ├── AutomationProtocol.swift
│       │   ├── AutomationCommand.swift     # 统一命令模型
│       │   ├── CLI/
│       │   │   ├── CommandParser.swift
│       │   │   └── CLIHandlers.swift
│       │   ├── URLScheme/
│       │   │   └── URLSchemeRouter.swift
│       │   └── Intents/
│       │       └── AppIntents.swift
│       └── Tests/
├── Docs/
│   ├── ARCHITECTURE.md
│   ├── AGENTS.md
│   ├── CONTRIBUTING.md
│   ├── SECURITY.md
│   ├── PRIVACY.md
│   └── QUALITY.md
├── Tests/
│   ├── Fixtures/                            # 测试样本图片
│   │   ├── ocr/                             # OCR 样张
│   │   ├── barcode/                         # 条码样张
│   │   └── scroll/                          # 滚动截图样张
│   └── GoldenDatasets/                      # OCR 回归基线
├── Scripts/
│   ├── generate-project.sh
│   └── setup-dev.sh
├── project.yml                              # XcodeGen 配置 (真源)
├── Package.swift                            # SPM workspace
├── .swift-format                            # 格式化配置
├── .swiftlint.yml                           # Lint 配置
├── README.md
├── LICENSE
└── CHANGELOG.md
```

---

## 七、关键子系统设计

### 7.1 OCR Pipeline (含 Tesseract + 开发者模式)

```
┌─────────────────────────────────────────────────────────┐
│                    OCRPipeline                          │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  输入: CGImage / NSImage                               │
│    │                                                    │
│    ▼                                                    │
│  ┌──────────────┐                                      │
│  │ 预处理        │ 裁剪 + 灰度 + 对比度 + 放大 + 二值化  │
│  │ (Preprocess)  │                                      │
│  └──────┬───────┘                                      │
│         │                                               │
│         ▼                                               │
│  ┌──────────────────────────────────────────────┐      │
│  │           引擎选择                              │      │
│  │                                               │      │
│  │  default ──────▶ VisionOCREngine              │      │
│  │    │               │                          │      │
│  │    │          confidence < 0.7?               │      │
│  │    │               │                          │      │
│  │    │          ┌────▼────┐                     │      │
│  │    │          │ 降级提示 │ → 用户可选 Tesseract │      │
│  │    │          └─────────┘                     │      │
│  │    │                                          │      │
│  │  dev_mode ──▶ parallel(Vision, Tesseract)     │      │
│  │    │          → 对比结果 + 日志输出            │      │
│  │    │          → 将差异写入 DevLog             │      │
│  └────┼──────────────────────────────────────────┘      │
│       │                                                 │
│       ▼                                                 │
│  ┌──────────────┐                                      │
│  │ 后处理        │ 合并行 + 布局保留 + URL检测 + 词典替换 │
│  │ (PostProcess) │                                      │
│  └──────┬───────┘                                      │
│         │                                               │
│         ▼                                               │
│  输出: OCRResult (文本 + 置信度 + 引擎 + 日志)           │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

#### 开发者模式 (DevModeService)

```swift
// OCRCore/Sources/DevModeService.swift
// 通过 UserDefaults key "snapglass.devMode.enabled" 控制
// 默认关闭，用户可在偏好设置或 CLI 中开启

public actor DevModeService {
    public static let shared = DevModeService()

    @UserDefault("snapglass.devMode.enabled", defaultValue: false)
    private var isEnabled: Bool

    /// 日志收集器
    private var logEntries: [OCRLogEntry] = []

    /// 开启后：每次 OCR 请求同时跑 Vision 和 Tesseract，记录对比结果
    public func compareEngines(image: CGImage, languages: [String]) async -> DevCompareResult {
        async let visionResult = VisionOCREngine().recognize(image: image, languages: languages)
        async let tesseractResult = TesseractOCREngine().recognize(image: image, languages: languages)

        let (vision, tesseract) = await (visionResult, tesseractResult)

        let entry = OCRLogEntry(
            timestamp: Date(),
            visionConfidence: vision.confidence,
            tesseractConfidence: tesseract.confidence,
            visionText: vision.text,
            tesseractText: tesseract.text,
            processingTimeMs: [.vision: vision.processingTimeMs, .tesseract: tesseract.processingTimeMs]
        )
        logEntries.append(entry)

        return DevCompareResult(vision: vision, tesseract: tesseract, log: entry)
    }

    public func exportLogs() -> Data {
        // 导出为 JSON，供开发者分析
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        return try! encoder.encode(logEntries)
    }
}
```

#### Tesseract 集成策略

- **集成方式**: 通过 SPM 依赖 `TesseractKit` 或直接使用 `libtesseract` C API
- **语言数据**: 首版仅打包英文 (eng)，中文 (chi_sim/chi_tra) 通过手动下载
- **首版可用性**: Developer Mode 开关控制；正常用户走 Vision
- **日志记录**: 每次 Tesseract 调用记录语言、置信度、耗时，写入本地日志文件
- **CLI 支持**: `snapglass-cli ocr file --engine tesseract --lang chi_sim`

### 7.1+ OCR 内存管理策略

```swift
// OCRCore/Sources/MemoryGuard.swift

import Foundation

/// OCR 内存守卫：防止大图片导致内存暴涨
public struct MemoryGuard {
    /// 最大允许处理的图片宽度（像素）
    static let maxImageWidth: CGFloat = 2048

    /// 内存压力阈值（字节）
    static let memoryPressureThreshold: UInt64 = 200 * 1024 * 1024 // 200MB

    /// 检查图片是否需要降采样
    public static func needsDownsample(_ image: CGImage) -> Bool {
        return CGFloat(image.width) > maxImageWidth
    }

    /// 降采样图片到目标宽度
    public static func downsample(_ image: CGImage, targetWidth: CGFloat) -> CGImage? {
        let aspectRatio = CGFloat(image.height) / CGFloat(image.width)
        let targetHeight = targetWidth * aspectRatio

        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let data = image.dataProvider?.data,
              let source = CGImageSourceCreateWithData(data, options) else {
            return nil
        }

        let downsampleOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(targetWidth, targetHeight),
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary

        return CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions)
    }

    /// 检查当前内存压力
    public static func isMemoryPressureHigh() -> Bool {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4

        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }

        guard result == KERN_SUCCESS else { return false }
        return info.resident_size > memoryPressureThreshold
    }
}
```

**OCR Pipeline 内存优化流程**:
1. 输入图片 → 检查尺寸 → 超过 2048px 自动降采样
2. OCR 处理中 → 监控内存压力 → 超过 200MB 触发降级
3. OCR 完成 → 立即释放原始 CGImage → 只保留结果

### 7.1++ Tesseract 语言包下载器

```swift
// OCRCore/Sources/LanguagePackDownloader.swift

import Foundation

/// Tesseract 语言包下载器
public actor LanguagePackDownloader {
    public enum DownloadState: Sendable {
        case idle
        case downloading(progress: Double)
        case completed(URL)
        case failed(Error)
    }

    /// GitHub 语言数据仓库
    private let tessdataRepo = "https://github.com/tesseract-ocr/tessdata_best"

    /// 已下载的语言包列表
    private var downloadedLanguages: Set<String> = []

    /// 下载状态
    private var state: DownloadState = .idle

    /// 检查语言包是否已下载
    public func isLanguageAvailable(_ lang: String) -> Bool {
        let path = languagePackPath(for: lang)
        return FileManager.default.fileExists(atPath: path.path)
    }

    /// 下载语言包
    public func downloadLanguage(_ lang: String) async throws -> URL {
        guard !isLanguageAvailable(lang) else {
            return languagePackPath(for: lang)
        }

        state = .downloading(progress: 0)

        let url = URL(string: "\(tessdataRepo)/raw/main/\(lang).traineddata")!
        let destination = languagePackPath(for: lang)

        // 使用 URLSession 下载并报告进度
        let (asyncBytes, response) = try await URLSession.shared.bytes(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw LanguagePackError.downloadFailed
        }

        let totalBytes = httpResponse.expectedContentLength
        var receivedBytes: Int64 = 0
        var data = Data()
        data.reserveCapacity(Int(totalBytes))

        for try await byte in asyncBytes {
            data.append(byte)
            receivedBytes += 1

            if receivedBytes % 10240 == 0 { // 每 10KB 更新进度
                state = .downloading(progress: Double(receivedBytes) / Double(totalBytes))
            }
        }

        // 写入文件
        try data.write(to: destination)

        state = .completed(destination)
        downloadedLanguages.insert(lang)

        return destination
    }

    /// 获取语言包路径
    private func languagePackPath(for lang: String) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent("SnapGlass")
            .appendingPathComponent("tessdata")
            .appendingPathComponent("\(lang).traineddata")
    }
}

public enum LanguagePackError: LocalizedError {
    case downloadFailed
    case unsupportedLanguage

    public var errorDescription: String? {
        switch self {
        case .downloadFailed:
            return String(localized: "语言包下载失败，请检查网络连接")
        case .unsupportedLanguage:
            return String(localized: "不支持的语言")
        }
    }
}
```

### 7.2 权限状态机

```
                    ┌──────────┐
         启动 ─────▶ │ Unknown  │
                    └────┬─────┘
                         │ checkPermission()
                         ▼
               ┌─────────────────┐
               │   Authorized?   │
               └────┬────────┬───┘
                    │ yes    │ no
                    ▼        ▼
              ┌─────────┐  ┌──────────────┐
              │ Granted │  │ 功能触发时    │
              └────┬────┘  │ requestPerm() │
                   │       └──────┬───────┘
                   │              │
                   │       ┌──────▼──────┐
                   │       │ 用户选择?    │
                   │       └──┬───────┬──┘
                   │          │ allow │ deny
                   │          ▼       ▼
                   │    ┌─────────┐  ┌──────────┐
                   │    │ Granted │  │  Denied  │
                   │    └────┬────┘  └────┬─────┘
                   │         │            │
                   ▼         ▼            ▼
              ┌──────────────────────────────────┐
              │        Degraded Mode             │
              │  ┌──────────────────────────────┐│
              │  │ PermissionCard               ││
              │  │ "SnapGlass 需要屏幕录制权限   ││
              │  │  才能截图和 OCR 识别"         ││
              │  │ [打开系统设置] [稍后再说]     ││
              │  └──────────────────────────────┘│
              │  仅禁用对应能力，其他功能正常     │
              └──────────────────────────────────┘
```

#### 权限检查关键点 (macOS 15+)

```swift
// 不要只依赖 CGPreflightScreenCaptureAccess()
// macOS Sequoia+ 该函数对临时签名(debug build)和 ad-hoc 签名始终返回 false
// 需要双重验证，且不依赖 CGPreflight 作为 guard 条件

func checkScreenCapturePermission() async -> Bool {
    let preflight = CGPreflightScreenCaptureAccess()

    // 主验证：SCShareableContent（不依赖 CGPreflight 的结果）
    do {
        let content = try await SCShareableContent.current
        if !content.displays.isEmpty {
            return true
        }
    } catch {
        // SCShareableContent 失败
    }

    // 辅助判断：如果 preflight 为 true 但 SCShareableContent 失败，重试一次
    if preflight {
        try? await Task.sleep(for: .milliseconds(500))
        do {
            let content = try await SCShareableContent.current
            if !content.displays.isEmpty {
                return true
            }
        } catch {
            // 重试失败
        }
    }

    return false
}

// 系统设置跳转
func openScreenCaptureSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
        NSWorkspace.shared.open(url)
    }
}
```

### 7.3 数据安全设计

#### 存储加密

| 数据 | 存储位置 | 加密方式 | 生命周期 |
|------|----------|----------|----------|
| 截图原图 | `~/Library/Application Support/SnapGlass/History/v2/images/` | CryptoKit AES-256-GCM | 7天 / 100条 |
| OCR 文本 | `~/Library/Application Support/SnapGlass/History/v2/entries/` | CryptoKit AES-256-GCM | 30天 / 500条 |
| 缩略图 | `~/Library/Application Support/SnapGlass/History/v2/thumbs/` | 无加密 | 90天 / 1000条 |
| 历史密钥 | `~/Library/Application Support/SnapGlass/Security/history-v2.key` | 本地 0600 权限文件 | 持久 |
| 崩溃日志 | `~/Library/Logs/SnapGlass/` | 无加密 | 30天 |
| DevMode 日志 | `~/Library/Logs/SnapGlass/devmode/` | 无加密 (可选导出) | 手动管理 |
| 临时文件 | `NSTemporaryDirectory()` | 无加密 | 会话结束 |

#### 加密实现

```swift
// SharedKit/Sources/Security/CryptoService.swift

import CryptoKit

public actor CryptoService {
    private let key: SymmetricKey

    public init() throws {
        self.key = try LocalKeyStore.loadOrCreateKey(at: keyURL)
    }

    public func encrypt(_ data: Data) throws -> Data {
        let sealedBox = try AES.GCM.seal(data, using: key)
        return sealedBox.combined!
    }

    public func decrypt(_ data: Data) throws -> Data {
        let sealedBox = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(sealedBox, using: key)
    }
}
```

### 7.4 Liquid Glass UI 首版适配

```swift
// App/SnapGlass/Sources/Overlays/CaptureToolbar.swift

import SwiftUI

struct CaptureToolbar: View {
    @Binding var mode: CaptureMode
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                glassToolbar   // Liquid Glass
            } else {
                materialToolbar // 退化方案
            }
        }
    }

    @available(macOS 26.0, *)
    private var glassToolbar: some View {
        GlassEffectContainer {
            toolbarContent
                .glassEffect()
        }
    }

    private var materialToolbar: some View {
        toolbarContent
            .background(
                reduceTransparency
                    ? Color(nsColor: .windowBackgroundColor)
                    : .ultraThinMaterial,
                in: Capsule()
            )
    }

    private var toolbarContent: some View {
        HStack(spacing: 12) {
            CaptureModeButton(.area, selection: $mode, icon: "rectangle.dashed")
            CaptureModeButton(.window, selection: $mode, icon: "macwindow")
            CaptureModeButton(.fullscreen, selection: $mode, icon: "rectangle.fill")
            CaptureModeButton(.scroll, selection: $mode, icon: "rectangle.stack")

            Divider().frame(height: 20)

            ActionButton("OCR", icon: "text.viewfinder") { /* trigger OCR */ }
            ActionButton("条码", icon: "qrcode") { /* trigger barcode */ }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
```

#### Liquid Glass 适配矩阵

| 组件 | macOS 26+ | macOS 13-25 | Reduce Transparency |
|------|-----------|-------------|---------------------|
| CaptureToolbar | `GlassEffectContainer` + `.glassEffect()` | `.ultraThinMaterial` + `Capsule()` | `Color.windowBackgroundColor` |
| InspectorPanel | `GlassEffectContainer` 侧栏 | `.regularMaterial` | 实色 |
| ResultToast | 微玻璃浮层 | `.ultraThinMaterial` | 不透明背景 |
| HistoryWindow | 不做玻璃 | 标准窗口 | 同 |
| SelectionOverlay | 不做玻璃 | 高对比边框 | 高对比边框 |
| AnnotationTopBar | `GlassEffectContainer` | `.ultraThinMaterial` | 实色 |

---

## 八、测试体系

### 8.1 测试分层

| 层 | 覆盖 | 工具 | 运行位置 |
|----|------|------|----------|
| 单元测试 | OCR 后处理、帧匹配、标注模型、历史清理、命令解析 | Swift Testing | GitHub Actions (macOS runner) |
| 集成测试 | CaptureCore ↔ OCRCore ↔ HistoryCore；CLI ↔ GUI handoff | XCTest | GitHub Actions |
| UI 冒烟 | 菜单栏、热键、权限引导、标注流程 | XCUITest | 自托管 Mac mini (权限需要) |
| 性能 | overlay 延迟、OCR 耗时、拼接内存 | XCTest metrics | GitHub Actions |
| OCR 回归 | 中英日韩混合、小字号、反白、表格 | 自建 golden dataset | GitHub Actions |
| UI 降级测试 | Liquid Glass 退化、Reduce Transparency、暗黑模式 | XCTest | GitHub Actions (macOS 26 runner) |

### 8.2 CI 矩阵

```yaml
# .github/workflows/ci.yml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  lint:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - run: brew install swiftlint
      - run: swift-format lint --recursive .
      - run: swiftlint lint --strict

  build:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - run: xcodegen generate
      - run: xcodebuild -project SnapGlass.xcodeproj -scheme SnapGlass -configuration Debug build CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO

  unit-test:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - run: xcodegen generate
      - run: swift test --package-path Packages/OCRCore
      - run: swift test --package-path Packages/CaptureCore
      - run: swift test --package-path Packages/ScrollCore
      - run: swift test --package-path Packages/HistoryCore

  ui-smoke:
    runs-on: self-hosted   # 需要屏幕录制权限
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    steps:
      - uses: actions/checkout@v4
      - run: xcodegen generate
      - run: xcodebuild -project SnapGlass.xcodeproj -scheme SnapGlassUITests test
```

### 8.3 测试用例样本

```
OCR 测试集 (至少 10 类):
  1. 菜单栏中文文本
  2. 小字号代码片段 (8pt monospace)
  3. 反色终端文本 (白字黑底)
  4. 浅灰底表格
  5. 混合中英日韩段落
  6. 手写体模糊截图
  7. 含 URL 的网页截图
  8. 含二维码的页面
  9. 含 Code128 条形码的物流单
  10. 低对比度水印文本

交互回归集:
  11. 小窗口 hover capture
  12. 多屏跨屏选区
  13. 启用 Reduce Transparency 环境
  14. 暗黑模式 vs 亮色模式
  15. 中文系统语言环境

Liquid Glass 降级测试集:
  16. macOS 13-25: CaptureToolbar 使用 .ultraThinMaterial
  17. macOS 26+: CaptureToolbar 使用 GlassEffectContainer
  18. Reduce Transparency 开启: 所有组件使用实色背景
  19. 暗黑模式: 标注颜色对比度足够
  20. 高对比模式: 边框可见性验证
```

---

## 九、代码规范

### 9.1 格式化与 Lint

| 工具 | 用途 | 配置 |
|------|------|------|
| `swift-format` | 自动格式化（缩进、空格、换行） | 项目根 `.swift-format` (JSON) |
| `SwiftLint` | 代码质量（安全、复杂度） | 项目根 `.swiftlint.yml` (YAML) |

**分工原则**: SwiftFormat 管格式（自动化修复），SwiftLint 管质量（代码审查把关）。两者规则不重叠。

#### .swift-format (推荐配置)

```json
{
  "version": 1,
  "lineLength": 120,
  "indentation": { "spaces": 2 },
  "maximumBlankLines": 1,
  "respectsExistingLineBreaks": true,
  "indentConditionalCompilationBlocks": true,
  "rules": {
    "AlwaysUseLowerCamelCase": true,
    "DoNotUseSemicolons": true,
    "NeverForceUnwrap": true,
    "NeverForceTry": true,
    "NeverUseImplicitlyUnwrappedOptionals": true,
    "OrderedImports": true,
    "UseTripleSlashForDocumentationComments": true,
    "ValidateDocumentationComments": true,
    "AllPublicDeclarationsHaveDocumentation": true
  }
}
```

#### .swiftlint.yml (推荐配置)

```yaml
opt_in_rules:
  - empty_count
  - force_unwrapping
  - implicitly_unwrapped_optional
  - unused_import
  - duplicate_imports
  - toggle_bool
  - private_action
  - private_outlet

disabled_rules:
  # 由 swift-format 处理的规则
  - trailing_whitespace
  - vertical_whitespace
  - colon
  - comma

line_length: 120
file_length:
  warning: 500
  error: 1200
type_body_length:
  warning: 400
identifier_name:
  min_length: 3
  excluded: [id, URL, key, tag]
```

### 9.2 命名约定

```swift
// 类型: UpperCamelCase
public struct CaptureOrchestrator { }
public protocol OCRProtocol { }
public enum OCREngineType { }

// 方法/属性: lowerCamelCase
func recognize(image: CGImage) async throws -> OCRResult
var isEnabled: Bool { get set }

// 常量: lowerCamelCase (不用 k 前缀)
let defaultConfidenceThreshold: Float = 0.7

// extension 中不缩写
extension String {
    var isNotEmpty: Bool { !isEmpty }
}
```

### 9.3 DocC 注释规范

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

### 9.4 Git 规范

- **Commit**: Conventional Commits (`feat:`, `fix:`, `docs:`, `test:`, `refactor:`)
- **分支**: `main` (保护) + `feat/xxx` + `fix/xxx`
- **版本**: SemVer `vX.Y.Z`
- **PR 要求**: 标题符合 Conventional Commits，包含测试证据、权限影响说明、CHANGELOG 更新

---

## 十、Agent 执行清单（分阶段任务）

### Phase 0: 脚手架（5-7 天）

| 任务 | 输入 | 验收标准 |
|------|------|----------|
| 仓库初始化 | 本文档 | `project.yml` 可生成工程；GUI + CLI target 可编译 |
| CI 基线 | 编译命令 | `swift build` 通过；lint gate 通过 |
| 文档搭建 | 模板 | AGENTS.md / ARCHITECTURE.md / CONTRIBUTING.md / SECURITY.md 就绪 |
| 权限服务骨架 | 权限矩阵 | PermissionService 可检查/请求屏幕录制权限状态 |

### Phase 1: 核心功能（10-14 天）标准方案开始

| 任务 | 依赖 | 验收标准 |
|------|------|----------|
| SharedKit 日志/加密 | Phase 0 | Logger 分级输出；CryptoService AES-GCM 加解密通过 |
| CaptureCore 基线 | SCK API | 多屏区域/窗口/全屏截图正确；复制到剪贴板可用 |
| OCRCore Vision 引擎 | Vision API | 中英混合文本正确输出；confidence 字段有效 |
| OCRCore Tesseract 引擎 | libtesseract | 通过 devMode 开关可手动对比两个引擎结果 |
| DevModeService | UserDefaults | 开发者模式开启后记录每次 OCR 的 Vision vs Tesseract 对比日志 |
| BarcodeCore | Vision barcode | QR/Code128/EAN 识别通过；payload + symbology 正确 |
| 全局快捷键 | KeyboardShortcuts | 热键录制/触发可用；快捷键不与系统冲突 |
| 菜单栏 App 骨架 | SwiftUI + AppKit | 菜单栏入口可用；基础 Toast 提示 |

### Phase 2: 交互完善（7-10 天）标准方案完成

| 任务 | 依赖 | 验收标准 |
|------|------|----------|
| AnnotationCore 基线 | Core Image | 箭头/矩形/文本/画笔/高亮/模糊/裁剪可用；撤销重做正常 |
| HistoryCore 加密存储 | CryptoService | 历史条目加密写入/读取正常；自动清理策略生效 |
| CLI 文件模式 | AutomationCore | `snapglass-cli ocr file ./test.png` 输出正确 |
| 编辑器窗口 | AnnotationCore + CaptureCore | 截图后可立即编辑标注 |

### Phase 3: 扩展能力（7-10 天）完整方案

| 任务 | 依赖 | 验收标准 |
|------|------|----------|
| ScrollCore 半自动拼接 | CaptureCore | 用户手动滚动后稳定拼接 (Safari/Chrome)；失败展示提示 |
| App Intents | AutomationCore | 4 个 Shortcuts action 可发现和触发 |
| URL Scheme 路由 | AutomationCore | `snapglass://capture?mode=area&ocr=1` 可用 |
| 偏好设置窗口 | SharedKit | 语言/快捷键/历史策略可配置 |

### Phase 4: 稳定与发布（5-7 天）

| 任务 | 依赖 | 验收标准 |
|------|------|----------|
| OCR 回归集 | OCRCore | PR 自动比对准确率和时延基线 |
| 性能测试 | 各 Core | 截图 < 150ms；OCR < 800ms (≤2K)；内存峰值 < 250MB |
| 文档完善 | Phase 0 文档 | README 含截图和 Quick Start |
| GitHub Release | CI | Tag 推送自动构建产物 |

---

## 十一、Tesseract 集成与开发者模式详解

### 11.1 集成决策

| 项目 | 决策 |
|------|------|
| 首版集成 | ✅ 是 |
| 默认引擎 | ❌ 否 (默认 Vision，Tesseract 通过 developer flag 启用) |
| 语言包 | 仅内置英文 (eng)，中文按需下载到 `~/Library/Application Support/SnapGlass/tessdata/` |
| 触发方式 | 偏好设置 → Developer Mode 开关 或 CLI `--engine tesseract` |
| 日志 | 每次调用记录引擎、语言、置信度、耗时 → 写入 `~/Library/Logs/SnapGlass/devmode/` |

### 11.2 DevMode 用户界面

```
偏好设置 → Developer 标签页:

  Developer Mode                     [OFF]
  ───────────────────────────────────────
  开启后，每次 OCR 将同时运行 Vision 和
  Tesseract，并在下方显示对比结果和日志。

  会增加 CPU 和内存使用。

  ── 引擎对比 ──────────────────────────
  [最新对比结果]
  Vision:   "你好世界" (confidence: 0.95)
  Tesseract: "你好世办" (confidence: 0.72)
  Vision: 124ms  Tesseract: 480ms

  [导出日志]  [清除日志]
```

### 11.3 CLI 开发者命令

```bash
# 强制使用 Tesseract
snapglass-cli ocr file ./sample.png --engine tesseract --lang chi_sim

# 开发者模式：同时跑两个引擎并输出对比
snapglass-cli ocr file ./sample.png --dev-compare

# 导出 DevMode 日志
snapglass-cli dev logs --format json --output ./ocr-compare.json
```

---

## 十二、Agent 协作指南 (AGENTS.md 核心内容)

将在仓库根目录创建 `AGENTS.md`，核心结构：

```markdown
# SnapGlass AGENTS.md

SwiftUI macOS 应用，最低部署 macOS 13，使用 Swift 6 和 Swift Testing。

## Commands
# 格式化和检查
swift-format lint -p Packages/OCRCore/Sources/OCRPipeline.swift --configuration .swift-format
swiftlint lint --config .swiftlint.yml

# 生成工程
xcodegen generate

# 编译
swift build

# 运行测试
swift test --package-path Packages/OCRCore
swift test --package-path Packages/HistoryCore

# 所有 package 测试
for pkg in Packages/*/; do swift test --package-path "$pkg" || break; done

## Code Style
- 遵循 `.swift-format` 和 `.swiftlint.yml`
- 所有 public API 必须有 DocC 注释 (///)
- ViewModel 使用 `@MainActor` 隔离 UI 状态
- 后台工作使用 Swift concurrency (async/await, Task, actor)
- 优先使用 struct + protocol，避免类继承

## Project Structure
- App/SnapGlass/ — GUI App (菜单栏、覆盖层、编辑器、权限)
- App/SnapGlassCLI/ — CLI 入口
- Packages/*/ — 各核心模块 (见仓库结构)

## Boundaries
- Always: 修改后跑对应 package 测试、更新 CHANGELOG、添加 DocC 注释
- Ask first: 添加新的 SPM 依赖、修改 Package.swift 协议定义、改动权限逻辑
- Never: 提交 secrets、修改 .build/ 或 DerivedData、force-unwrap (!)、直接 push main

## PR Checklist
- [ ] Title: type(scope): description (Conventional Commits)
- [ ] CHANGELOG.md 已更新
- [ ] 对应 package 测试通过
- [ ] lint 通过
- [ ] 涉及权限：在 PR 描述中说明权限影响
```

---

## 十三、发布（仅 GitHub，首版不做分发渠道）

首版不集成 Sparkle 自动更新、不做 Homebrew Cask、不做 App Store。

| 动作 | 命令/配置 |
|------|-----------|
| 打包 | `xcodebuild archive` → `.app` |
| 签名 | `codesign --deep --force --options runtime --sign "Developer ID Application: TEAMID"` |
| 公证 | `xcrun notarytool submit SnapGlass.dmg --keychain-profile AC_PROFILE --wait` |
| Release | GitHub Release 上传 `.dmg` + checksum |
| Tag | `git tag v0.1.0 && git push --tags` |

---

## 附录 A: 参考项目优先级

| 优先级 | 项目 | 借鉴点 |
|--------|------|--------|
| P0 | Capso | 仓库结构、XcodeGen、12 packages 模块化 |
| P0 | TRex | OCR 流程、CLI、URL Scheme、自动化 |
| P0 | capcap | 交互速度、权限引导、floating editor |
| P1 | ScreenCap | 标注工具、冲突规避快捷键 |
| P1 | NormCap | OCR 回退方案、测试 discipline、ADR |
| P2 | macshot | 高级编辑器、隐私文档（延后参考） |
| P2 | CopyShot/LuxShot | 轻量 UX 收敛边界 |

---

## 附录 B: 错误码规范

```
Exit Code | 含义
    0     | 成功
    1     | 通用错误
    2     | 参数错误 (CLI)
    3     | 权限不足 (屏幕录制/辅助功能未授权)
    4     | 引擎错误 (Vision/Tesseract 失败)
    5     | 文件错误 (路径不存在/格式不支持)
```

---

## 附录 C: 关键参考来源

| 来源 | URL |
|------|-----|
| Capso (架构样板) | github.com/stevapple/capso |
| TRex (OCR/自动化样板) | github.com/amebalabs/TRex |
| capcap (速度/权限样板) | github.com/kevinhermawan/capcap |
| ScreenCap (规格样板) | github.com/xlinesoft/ScreenCap |
| NormCap (测试/回退样板) | github.com/dynobo/normcap |
| Apple ScreenCaptureKit | developer.apple.com/documentation/screencapturekit |
| Apple Vision | developer.apple.com/documentation/vision |
| KeyboardShortcuts | github.com/sindresorhus/KeyboardShortcuts |
| XcodeGen | github.com/yonaskolb/XcodeGen |
| Sparkle 2.x | sparkle-project.org |
| macOS Code Signing | developer.apple.com/documentation/security |
| agents.md 规范 | agents.md |
| Swift Testing | developer.apple.com/xcode/swift-testing |
| CryptoKit | developer.apple.com/documentation/cryptokit |

---

## 附录 D: v2.1 优化变更记录

| 变更 | 原始 | 优化后 | 原因 |
|------|------|--------|------|
| CryptoService | actor | struct + 同步方法 | 避免 actor 嵌套死锁 |
| OCR 性能目标 | < 800ms 统一 | ≤2K < 800ms，大图预检降采样 | 4K 图片 Vision 识别通常 1.2-2s |
| 内存目标 | < 120MB | < 250MB + 压力监控 | 4K 图片 ~32MB + 缓存，120MB 不现实 |
| 帧去重算法 | 未指定 | SSIM (阈值 0.95) | SSIM 比像素差异更符合人眼感知 |
| OCR 置信度阈值 | 统一 0.7 | 语言特定：中 0.6 / 英 0.8 / 日 0.65 | 不同语言识别难度不同 |
| 数据迁移 | 无 | SchemaVersion + 自动迁移链 | 防止升级后数据丢失 |
| 语言包下载 | "按需下载"（无实现） | LanguagePackDownloader + 进度 UI | 用户需要明确的获取路径 |
| Liquid Glass 测试 | 无 | GlassDegradationTests target | 确保 #available 分支被测试覆盖 |

---

## 附录 E: 内存压力响应策略

| 内存压力级别 | 响应措施 |
|-------------|----------|
| 正常 (< 150MB) | 无限制运行 |
| 中等 (150-200MB) | 限制同时标注对象数量为 50；历史缓存缩减为 50 条 |
| 高 (> 200MB) | OCR 强制降采样到 1024px；滚动截图暂停新帧采集；提示用户关闭编辑器 |
| 临界 (> 300MB) | 自动释放所有非活跃缓存；显示内存不足警告 |

---

**最后更新**: 2026-06-09

> 本文档是项目唯一权威设计文档。所有重大架构决策必须通过 ADR 记录在 `Docs/ADR/` 目录中。
