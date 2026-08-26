# SnapGlass Release Guide

> 发版流程与产物目录规范

---

## 版本号

遵循 [Semantic Versioning](https://semver.org/) `vX.Y.Z`：

- **MAJOR (X)**：不兼容变更 / 大重构
- **MINOR (Y)**：新功能
- **PATCH (Z)**：Bug 修复

版本号同步更新于三处：

| 文件 | 字段 |
|------|------|
| `version.txt` | 单行纯版本号（无 `v` 前缀） |
| `project.yml` | `settings.base.MARKETING_VERSION` |
| `CHANGELOG.md` | `## [vX.Y.Z] - YYYY-MM-DD` |

---

## 产物目录规范

所有发版产物统一归档到 `release/vX.Y.Z/`（版本子目录），**禁止**使用 `output/`、`release/latest/`、`release/manual-*/` 等临时或软链目录。

### 正式发版 vs 本地实验打包（重要区分）

| 维度 | 正式发版 | 本地实验打包 |
|------|----------|--------------|
| 触发方式 | `./scripts/build.sh`（默认） | `./scripts/build.sh --experimental`（别名 `--exp`） |
| 输出目录 | `release/vX.Y.Z/`（固定） | `release/exp-vX.Y.Z-<时间戳>-<随机码>/`（每次唯一） |
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
│   └── BUILD_INFO.json
└── versions.json             # 版本索引（发版后回填）
```

> **目录命名规则**：版本子目录一律使用 `v` 前缀（`release/vX.Y.Z/`），与 `build.sh`、`release.sh` 的默认行为保持一致，避免新旧命名并存造成混淆。

### 可提交产物

仅以下文件可提交到 Git：

- `release/vX.Y.Z/SnapGlass-vX.Y.Z.dmg`
- `release/vX.Y.Z/SnapGlass-vX.Y.Z.dmg.sha256`
- `release/vX.Y.Z/BUILD_INFO.json`
- `release/versions.json`

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

# 本地实验打包：每次生成唯一目录 release/exp-vX.Y.Z-<时间戳>-<随机码>/，永不覆盖
./scripts/build.sh --experimental
./scripts/build.sh --exp --version 0.5.3

# 构建后打开 Finder
./scripts/build.sh --open

# 同时生成带背景和 Applications 拖放入口的 DMG
python3 -m venv .build/dmg-tools
.build/dmg-tools/bin/python -m pip install dmgbuild
DMGBUILD_PYTHON=.build/dmg-tools/bin/python ./scripts/build.sh --dmg
```

构建脚本行为：

1. 读取版本号（`--version` 或 `version.txt`）
2. 校验版本号格式 `^[0-9]+\.[0-9]+\.[0-9]+$`
3. 确定输出目录：
   - 默认（正式发版）→ `release/vX.Y.Z/`，若已存在则拒绝覆盖
   - `--experimental` → `release/exp-vX.Y.Z-<时间戳>-<随机码>/`，每次唯一，永不覆盖
   - `--release-dir PATH` → 指定目录（与 `--experimental` 互斥）
4. `xcodegen generate` → 分别构建 arm64 与 x86_64 Release
5. 使用 `lipo` 合并主程序并验证 Universal 架构
6. `ditto` 拷贝 `.app` 到产物目录
7. 本地 ad-hoc 签名 + 严格验证
8. 使用 `--dmg` 时，通过 `dmgbuild` 生成品牌背景、Applications 拖放入口与 SHA-256
9. 更新 `release/latest/SnapGlass.app` 软链，指向最近一次打包的 app
10. 输出 `✅ App packaged: <产物目录>/SnapGlass.app`

---

## 发版流程

### 方式一：云端 CI 构建（推荐）

1. 更新版本号（`version.txt` + `project.yml` + `CHANGELOG.md`）
2. 提交变更：`git commit -m "release: vX.Y.Z — 简要描述"`
3. 打 tag：`git tag -a vX.Y.Z -m "vX.Y.Z — 简要描述"`
4. 推送：`git push origin main && git push origin vX.Y.Z`
5. GitHub Actions `release.yml` 自动触发：
   - 构建 Release 配置
   - 生成 `.dmg` + `.sha256`
   - 创建 GitHub Release 并上传产物
6. 回填 `release/versions.json`（可选，由 CI 自动完成）

### 方式二：本地构建 + 手动上传

1. 执行 `./scripts/build.sh --version X.Y.Z`
2. 创建隔离工具环境：`python3 -m venv .build/dmg-tools && .build/dmg-tools/bin/python -m pip install dmgbuild`
3. 打包 `.dmg`：`DMGBUILD_PYTHON=.build/dmg-tools/bin/python bash scripts/package-dmg.sh --app release/vX.Y.Z/SnapGlass.app --version X.Y.Z --output-dir release/vX.Y.Z`
4. 打 tag 并推送
5. `gh release create vX.Y.Z release/vX.Y.Z/SnapGlass-vX.Y.Z.dmg release/vX.Y.Z/SnapGlass-vX.Y.Z.dmg.sha256 --title "vX.Y.Z" --notes-file <release-note.md>`

---

## Release Note 格式

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

## versions.json

`release/versions.json` 是版本索引，发版后更新：

```json
[
  {
    "version": "0.2.0",
    "date": "2026-07-31",
    "file": "SnapGlass-0.2.0.dmg",
    "sha256": "release/v0.2.0/SnapGlass-0.2.0.dmg.sha256"
  },
  {
    "version": "0.1.5",
    "date": "2026-07-08",
    "file": "SnapGlass-0.1.5.dmg"
  }
]
```

---

*最后更新: 2026-08-04*
