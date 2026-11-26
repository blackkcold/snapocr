# SnapGlass Release Guide

> 发版流程与产物目录规范

---

## 版本号

遵循 [Semantic Versioning](https://semver.org/) `vX.Y.Z`：

- **MAJOR (X)**：不兼容变更 / 大重构
- **MINOR (Y)**：新功能
- **PATCH (Z)**：Bug 修复

版本号同步更新于四处：

| 文件 | 字段 |
|------|------|
| `version.txt` | 单行纯版本号（无 `v` 前缀） |
| `build.txt` | 单调整数构建号，写入 `CFBundleVersion`；Sparkle 用它判断新旧 |
| `project.yml` | `settings.base.MARKETING_VERSION` |
| `CHANGELOG.md` | `## [vX.Y.Z] - YYYY-MM-DD` |

`scripts/bump-version.sh` 会同时自增 `build.txt`。构建号只能增加：Sparkle 不做降级，回退会让这批用户永久收不到更新。

---

## 产物目录规范

所有发版产物统一归档到 `release/vX.Y.Z/`（版本子目录），**禁止**使用 `output/`、`release/latest/`、`release/manual-*/` 等临时或软链目录。

### 正式发版 vs 本地实验打包（重要区分）

| 维度 | 正式发版 | 本地实验打包 |
|------|----------|--------------|
| 触发方式 | `./scripts/build.sh`（默认） | `./scripts/build.sh --experimental`（别名 `--exp`） |
| 输出目录 | `release/vX.Y.Z/`（固定） | `release/exp-vX.Y.Z-<UTC时间戳>-<随机码>/`（每次唯一） |
| 是否覆盖 | 目录已存在则**拒绝**并报错 | **永不覆盖**，每次生成新目录 |
| 用途 | 正式发布、`release.sh`、CI、GitHub Release | 多轮构建对比测试、A/B 验证 |
| 是否入库 | 是（`.dmg`/`.sha256`/`BUILD_INFO.json`） | 否（`.gitignore` 忽略 `release/exp-*/`） |
| `BUILD_INFO.json` | `kind: "release"` | `kind: "experimental"`，含唯一 `buildId` |

> **⚠️ Agent 使用指引**：后续任何 agent 或脚本调用 `build.sh` 时，**必须**先明确意图——
> - 目标是**正式发版**（打 tag、上传 Release、CI 产物）→ 用默认模式，输出 `release/vX.Y.Z/`。
> - 目标是**本地对比测试**（多轮打包并存、验证不同改动）→ 用 `--experimental`，输出 `release/exp-*/`。
>
> 两者**互斥**，不可同时指定 `--experimental` 与 `--release-dir`。误用会导致产物目录混乱或正式发版目录被实验产物污染。

### `release/latest/` 快捷入口

每次打包成功后，`build.sh` 会在 `release/latest/SnapGlass.app` 创建（或更新）一个**相对路径软链**，始终指向**最近一次打包**的 app（无论正式发版还是实验打包）。用于快速定位最新产物，方便对比测试。

- 软链目标：`release/latest/SnapGlass.app -> ../<产物目录>/SnapGlass.app`（相对路径，可移植）。
- **不入库**：`.gitignore` 已忽略 `release/latest/`。
- 若被指向的产物目录被清理，软链会失效（属预期，重新打包即恢复）。

### 目录结构

```
release/
├── v0.1.5/                   # 历史版本归档（保留）
│   ├── SnapGlass-0.1.5.dmg
│   ├── SnapGlass-0.1.5.dmg.sha256
│   └── BUILD_INFO.json
├── v0.2.0/                   # 当前发版产物
│   ├── SnapGlass-0.2.0.dmg
│   ├── SnapGlass-0.2.0.dmg.sha256
│   ├── SnapGlass-update.json
│   └── BUILD_INFO.json
```

> **目录命名规则**：版本子目录一律使用 `v` 前缀（`release/vX.Y.Z/`），与 `build.sh`、`release.sh` 的默认行为保持一致，避免新旧命名并存造成混淆。

### 可提交产物

仅以下文件可提交到 Git：

- `release/vX.Y.Z/SnapGlass-vX.Y.Z.dmg`
- `release/vX.Y.Z/SnapGlass-vX.Y.Z.dmg.sha256`
- `release/vX.Y.Z/SnapGlass-update.json`
- `release/vX.Y.Z/appcast.xml`
- `release/vX.Y.Z/BUILD_INFO.json`

### 忽略产物（.gitignore）

```gitignore
output/
release/latest/
release/*/*.app/
release/.DS_Store
```

---

## 本地构建

```bash
# 使用 version.txt 中的版本号
./scripts/build.sh

# 指定版本号
./scripts/build.sh --version 0.2.0

# 指定输出目录（默认 release/vX.Y.Z/）
./scripts/build.sh --release-dir /tmp/snapglass-build

# 本地实验打包：每次生成唯一目录 release/exp-vX.Y.Z-<UTC时间戳>-<随机码>/，永不覆盖
./scripts/build.sh --experimental
./scripts/build.sh --exp --version 0.5.3

# 构建后打开 Finder
./scripts/build.sh --open

# 同时生成带背景和 Applications 拖放入口的 DMG，并用固定证书签名
python3 -m venv .build/dmg-tools
.build/dmg-tools/bin/python -m pip install dmgbuild
DMGBUILD_PYTHON=.build/dmg-tools/bin/python ./scripts/build.sh --dmg --sign
```

`--sign` 会打开临时钥匙串、按「内层先、容器后」重签 Sparkle 嵌套代码，然后比对 DR 与 `CFBundleVersion`。缺少证书时直接失败；`--no-sign` 仅供本地调试，产物无法自动更新。

构建脚本行为：

1. 读取版本号（`--version` 或 `version.txt`）
2. 校验版本号格式 `^[0-9]+\.[0-9]+\.[0-9]+$`
3. 取**一个** UTC 打包时刻（同一秒派生 `YYYY-MM-DDTHH:MM:SSZ` 与 `YYYYMMDDTHHMMSSZ`）
4. 确定输出目录：
   - 默认（正式发版）→ `release/vX.Y.Z/`，若已存在则拒绝覆盖
   - `--experimental` → `release/exp-vX.Y.Z-<UTC时间戳>-<随机码>/`，每次唯一，永不覆盖
   - `--release-dir PATH` → 指定目录（与 `--experimental` 互斥）
5. `xcodegen generate` → 分别构建 arm64 与 x86_64 Release
6. 使用 `lipo` 合并主程序并验证 Universal 架构
7. `ditto` 拷贝 `.app` 到产物目录
8. 向组装完成的 `SnapGlass.app/Contents/Info.plist` 写入 `SGBuildTimestamp`（`YYYY-MM-DDTHH:MM:SSZ`，即步骤 3 的同一时刻）；写入失败或回读不一致直接中止。此步必须在签名之前，值才会被封进签名
9. 用固定证书按「内层先、容器后」签名，并断言身份、DR 与 `CFBundleVersion`（`--no-sign` 时为 ad-hoc）
10. 使用 `--dmg` 时，通过 `dmgbuild` 生成品牌背景、Applications 拖放入口与 SHA-256；实验打包的 DMG 文件名含同一 UTC 时间戳
11. 更新 `release/latest/SnapGlass.app` 软链，指向最近一次打包的 app
12. 输出 `✅ App packaged: <产物目录>/SnapGlass.app`

### 打包时间戳（`SGBuildTimestamp`）

一次打包只取一个 UTC 时刻，下列四处必须一致：

| 位置 | 形态 | 示例 |
|------|------|------|
| 已签名 App 的 `Contents/Info.plist` → `SGBuildTimestamp` | ISO 8601 UTC | `2026-11-18T09:41:07Z` |
| `BUILD_INFO.json` → `buildDate` | 同上 | `2026-11-18T09:41:07Z` |
| 实验目录名 | 紧凑 UTC | `release/exp-v1.4.3-20261118T094107Z-a1b2c3/` |
| 实验 DMG 文件名 | 紧凑 UTC | `SnapGlass-v1.4.3-20261118T094107Z.dmg` |

正式发版的 DMG 名保持规范形式 `SnapGlass-vX.Y.Z.dmg`（1.4.x 客户端按此名降级下载），不带时间戳；App 与 `BUILD_INFO.json` 仍然带时间戳。

从已构建的 App 读回时间戳（不启动 App、不需要证书）：

```bash
# 推荐：单行输出，可直接进脚本或对比
plutil -extract SGBuildTimestamp raw release/exp-v1.4.3-*/SnapGlass.app/Contents/Info.plist

# 等价写法
/usr/libexec/PlistBuddy -c "Print :SGBuildTimestamp" release/vX.Y.Z/SnapGlass.app/Contents/Info.plist
```

用 `date -u` 核对：App 内的 ISO 形式与目录/DMG 名里的紧凑形式应当是同一秒（macOS 可直接换算 `date -j -u -f %Y-%m-%dT%H:%M:%SZ "2026-11-18T09:41:07Z" +%Y%m%dT%H%M%SZ`）。时间戳一律 UTC，不随构建机时区变化。

---

## 发版流程

### 方式一：云端 CI 构建（推荐）

1. 更新版本号（`version.txt` + `project.yml` + `CHANGELOG.md`）
2. 提交变更：`git commit -m "release: vX.Y.Z — 简要描述"`
3. 打 tag：`git tag -a vX.Y.Z -m "vX.Y.Z — 简要描述"`
4. 推送：`git push origin main && git push origin vX.Y.Z`
5. GitHub Actions `release.yml` 自动触发：
   - 导入签名证书与 EdDSA 私钥，构建并签名 Release
   - 校验签名身份、构建号递增、`CFBundleVersion`
   - 生成 `.dmg` + `.sha256`
   - 下载上一版 DMG 作为差分基准，生成相对上一版的差分包（`.delta`）
   - 生成签名 `appcast.xml`（含 `<sparkle:deltas>`），并用 App 内置公钥验证 DMG 的 EdDSA 签名
   - 创建 GitHub Release 并上传产物（含差分包）
6. CI 同时生成并上传固定名称的 `SnapGlass-update.json`，供 1.4.x 客户端过渡使用
7. 更新仓库 Social Preview 并校验（见下节）

### 方式二：本地构建 + 手动上传

1. 执行 `./scripts/build.sh --version X.Y.Z`
2. 创建隔离工具环境：`python3 -m venv .build/dmg-tools && .build/dmg-tools/bin/python -m pip install dmgbuild`
3. 打包 `.dmg`：`DMGBUILD_PYTHON=.build/dmg-tools/bin/python bash scripts/package-dmg.sh --app release/vX.Y.Z/SnapGlass.app --version X.Y.Z --output-dir release/vX.Y.Z`
4. 打 tag 并推送
5. `gh release create vX.Y.Z release/vX.Y.Z/SnapGlass-vX.Y.Z.dmg release/vX.Y.Z/SnapGlass-vX.Y.Z.dmg.sha256 --title "vX.Y.Z" --notes-file <release-note.md>`
6. 更新仓库 Social Preview 并校验（见下节）

### 仓库 Social Preview（发版后）

GitHub 仓库卡片使用专用社交卡片 `Docs/images/social-preview.png`（1280×640）；站点 Open Graph 使用 `site/assets/og.png`（1200×630）。两者设计同源但文件不同，任一素材更新后都要分别重新上传/部署。GitHub 未提供 Social Preview 上传 API，因此这是发版清单里的人工步骤。

1. **素材**：`Docs/images/social-preview.png`（1280×640）。仓库卡片是独立设置，不会随 `site/assets/og.png` 自动更新。图片刻意**不烘焙版本号**：版本号变更是发版常态，而卡片只承担仓库的第一印象；把版本写进图里，等于每次发版都多一步人工重传，还会在忘传时留下一个过期的版本号。只有设计变更（文案、配色、版式）才需要重新导出并上传。
2. **上传**：仓库 → Settings → Social preview → Edit → 选择 `Docs/images/social-preview.png` → Save。
3. **校验**（约 1 分钟内生效）：

   ```bash
   # 1) 卡片图应指向自定义预览（repository-images.githubusercontent.com），而不是默认卡片
   curl -s -H "Accept: text/html" https://github.com/blackkcold/snapocr \
     | grep -o 'og:image" content="[^"]*"'

   # 2) 下载该图并核对：仓库卡片应为 1280×640
   curl -sL "<上一步输出的 URL>" -o /tmp/social-preview.png
   sips -g pixelWidth -g pixelHeight /tmp/social-preview.png
   ```

4. **站点 OG 单独校验**：`site/index.html` / `site/en/index.html` 的 `og:image` 指向
   `https://blackkcold.github.io/snapocr/assets/og.png`（1200×630）。仓库卡片与站点 OG 可以共用设计，
   但不是同一个文件，必须分别更新和校验。

---

## 更新包与差分

**对外文档不记录安装包体积。** README、站点与发布说明都不写 MB 数字：体积随工具链与内嵌资源波动，写死之后每次发版都要重新核对，而用户真正关心的是「这次更新要下多少」——那由差分决定，不由完整包决定。已经写在别处的数字如有残留，直接删掉，不要更新。

**差分是发版的硬契约。** 每次发版都必须产出相对上一版的差分包；只有完整包视为发版失败（首个版本、或上一版资产确实取不到时除外，且必须在报告里写明原因）。

- 差分由 `generate_appcast` 在**同目录存在旧归档**时自动生成，文件名形如 `SnapGlass<新build>-<旧build>.delta`。
- `scripts/make-appcast.sh` 通过 `--previous-dmg` 接收旧包；不传就不会有差分。
- appcast 里必须出现 `<sparkle:deltas>`，且 `sparkle:deltaFrom` 等于上一版的 build。`scripts/verify-appcast.py --require-delta-from <build>` 会把这条变成硬校验。
- 差分包必须作为 Release 资产上传，否则 appcast 里的链接会 404，客户端静默退回完整包。

实测参考：v1.9.0 → v1.9.1 的差分约 1.1 MB，完整包 18.9 MB，约 5.9%。

---


本项目使用 **structured-cn**（结构化中文 emoji 分组）格式：

```markdown
vX.Y.Z — 简短描述

🐛 修复
- 修复点

✨ 新增
- 新增点

🔧 改进
- 改进点

---

**Full Changelog**: compare/{prev}...{version}
```

emoji 分组按 Conventional Commits 前缀映射，详见 [CONTRIBUTING.md](./CONTRIBUTING.md)。

---

## 静态更新清单

App 检查更新的流程（不调用受匿名 IP 配额限制的 GitHub REST API）：

1. 通过 `https://github.com/blackkcold/snapocr/releases/latest` 的 302 重定向发现最新稳定版本号；
2. 若本地版本不落后于最新版，直接判定为「已是最新」，不再请求清单；
3. 需要更新时，拉取版本化清单
   `https://github.com/blackkcold/snapocr/releases/download/v{版本}/SnapGlass-update.json`；
4. 清单缺失（404，例如无清单的旧版本）时，按 `SnapGlass-v{版本}.dmg` / `.dmg.sha256`
   命名约定确定性降级，下载时仍以 `.sha256` sidecar 做 SHA-256 校验。

每个 GitHub Release 必须包含固定名称的 `SnapGlass-update.json`。清单由
`scripts/generate-update-manifest.py` 生成，CI 与本地 `release.sh` 共用同一脚本。
清单包含版本、Release Notes、DMG/校验文件地址及 SHA-256；禁止手工维护或在清单中写入凭证。

---

*最后更新: 2026-11-25*
