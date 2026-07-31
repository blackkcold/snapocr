# SnapGlass Security Policy

> 安全策略与边界核查

---

## 安全边界

### 权限管理

| 边界 | 状态 | 说明 |
|------|------|------|
| 屏幕录制权限 | ✅ 已设计 | 权限状态机 + 降级 UI + 系统设置引导 |
| Apple Events 权限 (Finder 集成) | 🔄 延后 | P1 功能，首版不涉及 |
| 沙盒限制 (App Store) | ❌ 不适用 | 首版只做 GitHub 直装版，不启用 sandbox |

### 权限状态机

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

### 权限检查 (macOS 15+)

```swift
// 双重验证：CGPreflight + ScreenCaptureKit 实际验证
func checkScreenCapturePermission() async -> Bool {
    // 步骤1: 快速检查
    guard CGPreflightScreenCaptureAccess() else { return false }

    // 步骤2: 用 ScreenCaptureKit 实际验证
    do {
        let content = try await SCShareableContent.current
        _ = content.displays
        return true
    } catch {
        return false
    }
}

// 系统设置跳转
func openScreenCaptureSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
        NSWorkspace.shared.open(url)
    }
}
```

---

## 数据加密

### 存储加密方案

| 数据 | 存储位置 | 加密方式 | 生命周期 |
|------|----------|----------|----------|
| 截图原图 | `~/Library/Application Support/SnapGlass/History/v2/images/` | CryptoKit AES-256-GCM | 7天 / 100条 |
| OCR 文本 | `~/Library/Application Support/SnapGlass/History/v2/entries/` | CryptoKit AES-256-GCM | 30天 / 500条 |
| 缩略图 | `~/Library/Application Support/SnapGlass/History/v2/thumbs/` | 无加密 | 90天 / 1000条 |
| 历史密钥 | `~/Library/Application Support/SnapGlass/Security/history-v2.key` | 256-bit 随机密钥；目录 0700、文件 0600 | 持久 |
| 崩溃日志 | `~/Library/Logs/SnapGlass/` | 无加密 | 30天 |
| DevMode 日志 | `~/Library/Logs/SnapGlass/devmode/` | 无加密 (可选导出) | 手动管理 |
| 临时文件 | `NSTemporaryDirectory()` | 无加密 | 会话结束 |

### 加密实现

```swift
import CryptoKit

public struct CryptoService {
    private let key: SymmetricKey

    public init(keyURL: URL) throws {
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

> **注意**: CryptoService 使用 `struct` 而非 `actor`，避免 actor 嵌套导致的死锁风险。密钥操作同步执行。
>
> SnapGlass 不调用系统 Keychain。旧版 `History/entries|images|thumbs` 数据保持原样，v2 不读取或迁移。由于本地密钥与数据属于同一 macOS 用户安全域，本方案可防止直接查看加密文件，但不能抵御已控制当前用户账户的攻击者。

---

## 网络安全

| 边界 | 策略 |
|------|------|
| 网络请求范围 | 仅允许 Tesseract 官方 GitHub 语言数据域名 |
| Tesseract 语言包下载 | 白名单: `raw.githubusercontent.com/tesseract-ocr/tessdata_best` |
| 用户控制 | 所有网络请求需用户显式触发 |

---

## 敏感文本保护

- 默认不持久化完整 OCR 文本到历史记录
- 导出支持脱敏选项（通过 `TextAnonymizer`）
- 提供"敏感文本不持久化"模式
- `PrivacyInfo.xcprivacy` 声明屏幕录制使用（文件待创建）

```swift
// HistoryCore/Sources/TextAnonymizer.swift
public struct TextAnonymizer {
    /// 对文本进行脱敏处理，替换敏感信息
    public static func anonymize(_ text: String) -> String {
        // 替换邮箱、电话、身份证号等模式
    }
}
```

---

## 内存安全

- 内存中敏感数据使用后清零（`Data.zeroize()` 扩展）
- OCR 完成立即释放原始 `CGImage`，只保留结果
- 大图片（> 4K）自动降采样至 2048px 宽

---

## 崩溃与日志

- 崩溃日志本地存储，不自动上传
- 用户可通过 UI 手动导出日志
- DevMode 日志包含引擎对比信息，仅开发者模式启用

---

## 代码签名

| 要求 | 说明 |
|------|------|
| 签名类型 | Developer ID 签名 |
| 运行时 | Hardened Runtime |
| 公证 | `xcrun notarytool submit` |
| macOS 15+ | 必须 Developer ID 签名才能使用 ScreenCaptureKit |

---

## 依赖安全

- SPM 依赖固定版本
- `KeyboardShortcuts` 固定在特定版本；提供 `HotKey` 作为备选
- 未来（Phase 4）将实施 SPM 依赖审计 + 签名验证

---

## 敏感性信息保护 (R9 风险缓解)

OCR 文本历史可能包含敏感信息（密码、身份证号等），缓解措施：

1. 历史数据使用 CryptoKit AES-GCM 加密存储
2. 提供"敏感文本不持久化"模式
3. 导出支持脱敏选项
4. `PrivacyInfo.xcprivacy` 声明屏幕录制使用（文件待创建）

---

## 安全事件响应

如发现安全漏洞，请通过 GitHub Issues 报告，不要公开发布未修复的安全问题。
