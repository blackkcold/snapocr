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
- 运行 `swift-format lint --recursive .`
- 运行 `swiftlint lint --strict`

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

1. 检出代码
2. 从 tag 名提取版本号
3. `xcodegen generate`
4. `xcodebuild -configuration Release build`（ad-hoc 签名）
5. 通过 `dmgbuild` 打包 `.app` → `.dmg`
6. 生成 `.sha256` 校验文件
7. 生成并校验 `SnapGlass-update.json` 静态更新清单
8. 创建 GitHub Release：
   - 标题：`vX.Y.Z`
   - Body：从 tag message 或 `CHANGELOG.md` 对应条目生成
   - 上传 `.dmg` + `.sha256` + `SnapGlass-update.json` 作为 Release assets
9. 发布后复核三个必需资产，缺少任意资产则工作流失败

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

---

## 本地复现 CI

```bash
# 等效 lint
swift-format lint --recursive . --configuration .swift-format
swiftlint lint --strict --config .swiftlint.yml

# 等效 build
xcodegen generate
xcodebuild -project SnapGlass.xcodeproj -scheme SnapGlass -configuration Release build CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO

# 等效 unit-test
./scripts/test.sh
```

---

*最后更新: 2026-09-03*
