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
  - SharedKit / CaptureCore / OCRCore / BarcodeCore / AnnotationCore / ScrollCore / HistoryCore
- 任一 Package 测试失败则 job 失败

### ui-smoke（仅 main push）
- 运行 UITests（需 self-hosted runner，有屏幕录制权限）
- 当前为可选 job，无 self-hosted runner 时自动跳过

---

## Release 工作流

`.github/workflows/release.yml` 在推送 `v*` tag 时触发：

1. 检出代码
2. 从 tag 名提取版本号
3. `xcodegen generate`
4. `xcodebuild -configuration Release build`（无签名）
5. 打包 `.app` → `.dmg`（`hdiutil`）
6. 生成 `.sha256` 校验文件
7. 创建 GitHub Release：
   - 标题：`vX.Y.Z`
   - Body：从 tag message 或 `CHANGELOG.md` 对应条目生成
   - 上传 `.dmg` + `.sha256` 作为 Release assets

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
| ui-smoke | `self-hosted` | 需屏幕录制权限（可选） |
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

*最后更新: 2026-07-31*