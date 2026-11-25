# SnapGlass CI/CD

> GitHub Actions 工作流说明

---

## 工作流概览

| 工作流 | 文件 | 触发条件 | 用途 |
|--------|------|----------|------|
| CI | `.github/workflows/ci.yml` | push 到 main / PR 到 main | Lint + Build + Test |
| Release | `.github/workflows/release.yml` | tag `v*` push | 构建 Release + 创建 GitHub Release |

---

## CI 工作流

`.github/workflows/ci.yml` 在每次 push 到 `main` 或 PR 时触发，包含以下 jobs：

### lint
- 安装 SwiftLint
- 校验 `swift-format` 版本：`xcrun swift-format --version` 必须命中 `.swift-format-version`，
  否则 job 失败并提示升级 runner 或改用已验证等价的构建（`scripts/check-swift-format-version.sh`）
- 运行 `xcrun swift-format lint --recursive .`
- 运行 `swiftlint lint --strict`

`swift-format` 不再由 Homebrew 安装：runner 镜像自带的 Xcode 工具链就是本地使用的同一二进制，
版本不符时失败而不是静默重排。`swift-format lint` 目前只报告警告、退出码为 0，
存量 698 条 DocC 警告（`AllPublicDeclarationsHaveDocumentation` / `ValidateDocumentationComments`）
留待单独重构；CI 失败与否由退出码与 SwiftLint 决定。

### build
- `xcodegen generate`
- `xcodebuild -configuration Release build`（无签名）
- 上传构建产物 artifact（`SnapGlass.app`）

### unit-test
- 对所有 Packages 执行 `swift test`：
  - SharedKit / CaptureCore / OCRCore / BarcodeCore / AnnotationCore / ScrollCore / HistoryCore / AutomationCore
- 任一 Package 测试失败则 job 失败
- job 与 step 均设置 `timeout-minutes`，避免单个 Package 挂起导致无限等待
- OCRCore 在 CI 上跳过依赖真实 Vision OCR 的集成测试（`VisionIntegrationTests` 与 `pipelineFallsBackToVisionWhenTesseractDataIsMissing`）：无头 CI runner 上 Vision 首次初始化可能挂起。本地仍完整运行这些测试（见 `scripts/test.sh`）

---

## Release 工作流

`.github/workflows/release.yml` 在推送 `v*` tag 时触发：

1. 检出代码（完整历史，用于校验构建号递增）
2. 从 tag 名提取版本号
3. 安装 XcodeGen、dmgbuild、cryptography
4. 从 secrets 导入签名证书与 EdDSA 私钥到临时目录（权限 `600`）
5. 本地化校验 + SharedKit 单测
6. `scripts/build.sh --sign`：双架构构建、lipo、按内层→外层用固定证书签名，并断言身份与构建号
7. 通过 `dmgbuild` 打包 `.app` → `.dmg`
8. 生成 `.sha256` 校验文件
9. 生成签名 `appcast.xml`，并用 App 内置 `SUPublicEDKey` 对 DMG 做 Ed25519 校验
10. 生成并校验 `SnapGlass-update.json`（1.4.x 兼容清单）
11. 创建 GitHub Release：
    - 标题：`vX.Y.Z`
    - Body：从 tag message 或 `CHANGELOG.md` 对应条目生成
    - 上传 `.dmg` + `.sha256` + `appcast.xml` + `release-notes.md` + `SnapGlass-update.json`
12. 发布后复核五个必需资产，缺少任意资产则工作流失败

### Release secrets

| Secret | 内容 |
|---|---|
| `SNAPGLASS_CERT_P12_BASE64` | 自签名证书 `.p12` 的 base64（单行） |
| `SNAPGLASS_CERT_P12_PASSWORD` | `.p12` 导出密码 |
| `SPARKLE_ED_PRIVATE_KEY` | Sparkle EdDSA seed 的 base64（单行） |

证书与密钥的生成、托管和恢复见 [`SIGNING.md`](SIGNING.md)。

### 触发方式

```bash
# 打 tag 并推送，自动触发 release workflow
git tag -a vX.Y.Z -m "vX.Y.Z — 简要描述"
git push origin vX.Y.Z
```

### 产物

GitHub Release 页面提供：

- `SnapGlass-vX.Y.Z.dmg` — 安装包
- `SnapGlass-vX.Y.Z.dmg.sha256` — SHA-256 校验文件
- `SnapGlass-update.json` — App 检查更新使用的固定名称静态清单

用户验证完整性：

```bash
shasum -a 256 SnapGlass-vX.Y.Z.dmg
# 对比 .sha256 文件内容
```

---

## Runner 要求

| Job | Runner | 说明 |
|-----|--------|------|
| lint / build / unit-test | `macos-latest` | GitHub 托管的 macOS runner |
| release | `macos-latest` | GitHub 托管 |

`macos-latest` 当前解析到 `macos-26-arm64`（Xcode 26.6）。镜像升级会同时改变工具链里的 `swift-format`，
届时 lint job 会因版本不符而失败——这是预期行为：先确认新版输出差异，再一次全量格式化并更新
`.swift-format-version`，不要直接放宽校验。若镜像不再提供该 Xcode 版本，可用 Homebrew 的等价构建：
`brew install swift-format` + `SNAPGLASS_SWIFT_FORMAT_BIN="$(brew --prefix)/bin/swift-format"`。

---

## 本地复现 CI

```bash
# 等效 lint（先确认格式器版本，再跑两条 lint）
bash scripts/check-swift-format-version.sh
xcrun swift-format lint --recursive . --configuration .swift-format
swiftlint lint --strict --config .swiftlint.yml

# 等效 build
xcodegen generate
xcodebuild -project SnapGlass.xcodeproj -scheme SnapGlass -configuration Release build CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO

# 等效 unit-test
./scripts/test.sh
```

测试分层、离屏画布渲染与 Agent 后台场景见 [`TESTING.md`](TESTING.md)。Agent 场景需要真实权限与已安装 App 的签名身份，不进入 CI 的 unit-test job。

---

*最后更新: 2026-11-25*
