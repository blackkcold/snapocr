# 录制 P0 — 交付阶段（最终源码 → 本地实验 DMG）方案

> **Status:** `Executed`，2026-11-18。已按本方案完成 CHANGELOG 补充、一次本地化校验、Release 通用签名构建与 DMG 核验（详见 §8）。未安装、未启动、未公证、未发布、未提交；真机与运行期行为仍未验证。
> Worktree：`/Users/11169285/.local/share/opencode/worktree/5d0345d699d913b55a21fac44cccbd69a3acb4ec/recording-p0`
> Branch：`fix/recording-p0`（base `84e4a6a`）

## 0. 边界（本轮与下轮都必须守）

| 不做 | 具体含义 |
|---|---|
| 不安装 | 不把 App 拷进 `/Applications`，不双击 DMG，不覆盖本机已装版本 |
| 不发布 | 不发 GitHub Release，不生成/上传 appcast，不联网分发 |
| 不覆盖旧包 | 不删、不移动、不重命名 `release/exp-v1.6.0-20261118T062756Z-be637c/`；不写 `--release-dir` 指向任何已有目录 |
| 不改权限 | 不 `chmod`/`chown`/`chflags`，不动 TCC 数据库、不重置权限、不 `tccutil` |
| 不公证 | 不 `notarytool`、不 `stapler`、不提交 Apple |
| 不 bump/tag | 不改 `version.txt`（1.6.0）、`build.txt`（3）、`.release.json`；不 `git tag`、不 commit、不 push |

**旧包红线：** `release/exp-v1.6.0-20261118T062756Z-be637c` 是上一轮的产物，**绝不可当本次包**。判别不靠记忆，靠三件事实：真实目录路径、目录/文件名里的 UTC 时间戳、本次构建打印的 SHA256。本方案**不读取旧包内容、不计算旧包哈希**，以免把旧件误当证据。

## 1. 启动闸门（全部满足才构建）

1. A、B、性能三条修改已集齐并合入当前工作树；构建前 `git status --porcelain` 的改动集合与交付清单一致，无意外文件。
2. `version.txt` = `1.6.0`，`build.txt` = `3`（不 bump，仅为读值确认）。
3. 签名材料在位：`~/.config/snapglass/signing/SnapGlass.p12` 与 `.password` 存在（只判存在，不读取、不打印内容）。
4. `release/` 下**没有**与本次时间戳相同的目录（本次目录名由构建时 UTC 时刻生成，理论不会撞名）。
5. §2 已执行完毕：`CHANGELOG.md` 的 `[Unreleased]` 只据已落地行为更新，四语言键与占位一致，`check-localization.sh` exit 0。

任一不满足 → 停止并报告，不改用 `--no-sign` 绕过。

## 2. 交付前文案与 CHANGELOG（源码完工后、打包前）

顺序固定：A/B/性能改动全部落地 → 只改 `CHANGELOG.md` 的 `## [Unreleased]` → 跑**一次**本地化校验 → 再构建。文案与 CHANGELOG 属于源码完工的一部分，不是打包动作。

- **CHANGELOG 只据已落地行为写**：`Docs/AGENTS.md` 的 Always 要求更新 `CHANGELOG.md`。只在 `[Unreleased]` 段内补充本轮**可从代码读出**的用户可见行为、边界与有意取舍，沿用现有 `### Fixed` / `### Changed` / `### Verification status` 结构；不预先写入尚未实现的能力，不写性能结论，不搬用 1.6.0 的验收结论。
- **未验证不得写成已验证**：`### Verification status` 只陈述真实做过的检查（编译、静态本地化校验），测试、GUI、TCC、真实录制、长录、性能一律写明「未运行」。无运行期证据时，禁止出现「已验证」「修复生效」等措辞。
- **四语言键**：`Docs/AGENTS.md` 的 Never 要求「新增界面文案必须补四语言键」。本次新增文案必须在 `App/SnapGlass/Resources/{en,zh-Hans,ja,ko}.lproj/Localizable.strings` 四份中同时存在且键名完全一致，`en` 为参照语言。
- **占位一致**：每个键的 `%d` / `%s` / `%@` / `%f` 等占位符种类与数量须与 en 相同；缺占位或多占位即不合格（参数顺序不同可接受）。
- **只跑一次**：`bash scripts/check-localization.sh`，仅一次，放在源码完工后、构建前，可与 `xcodegen generate`/编译并行或紧邻，不为此新增评审轮次。脚本覆盖重复键同值、四语言缺键/多键、占位符对齐、源码引用键存在、视图层不绕过应用语言。exit 0 才继续；非 0 只改文案，不改脚本、不加白名单。
- 本节是**下一轮**的步骤：此刻不改 `CHANGELOG.md`、不改源码。

## 3. 构建命令（唯一一条）

```bash
bash scripts/build.sh --version 1.6.0 --experimental --dmg --sign
```

- `--experimental`：输出到 `release/exp-v1.6.0-<UTC时间戳>-<6位随机码>/`，脚本自带「已存在即拒绝」保护，天然不覆盖。
- `--dmg`：同一 UTC 时刻用于目录名、DMG 文件名、`SGBuildTimestamp`、`BUILD_INFO.json.buildDate`。
- `--sign`：**显式要求证书签名**，缺证书直接失败退出；不会像默认 `auto` 那样静默退回 ad-hoc。
- 不使用 `--release-dir`、`--no-sign`、`--open`、`release.sh`、`package-dmg.sh` 单独调用。

脚本内部会先 `xcodegen generate`（工程文件被忽略，不改源码），再 arm64 / x86_64 各构建一次、`lipo` 合并、写入时间戳、签名、`verify-build.sh --require-ed-key`、生成 DMG 与 `.sha256`。

## 4. 必须记录的真实事实

按命令逐条记录**命令 / 退出码 / 原始输出关键行**，落到 `.context/recording-p0-delivery/`（gitignore 内）。

| 步骤 | 取什么 | 期望 |
|---|---|---|
| `bash scripts/check-localization.sh`（构建前，仅一次） | exit、末尾 `✅ Localization check passed` | 0 |
| `xcodegen generate` | exit | 0 |
| arm64 `xcodebuild` | exit、日志尾 `BUILD SUCCEEDED` | 0 |
| x86_64 `xcodebuild` | exit、日志尾 `BUILD SUCCEEDED` | 0 |
| `lipo -verify_arch arm64 x86_64` | exit | 0 |
| `scripts/verify-build.sh`（脚本内调用） | exit、`authority:`/`requirement:` 两行 | 0 |
| `scripts/package-dmg.sh` | exit、`✅ SHA-256:` 行 | 0 |
| `build.sh` 整体 | exit | 0 |

退出码用 `set -o pipefail; cmd; echo EXIT=$?` 或 `cmd >log 2>&1; echo EXIT=$? >>log` 记录；`build.sh` 是 `set -euo pipefail`，**首个失败即停**，后续步骤不会假成功。

新产物的真实路径从脚本输出抄，不手拼：

```text
✅ App packaged: release/exp-v1.6.0-<TS>-<hex>/SnapGlass.app
✅ Build info:   release/exp-v1.6.0-<TS>-<hex>/BUILD_INFO.json
✅ Latest shortcut: release/latest/SnapGlass.app -> ../exp-v1.6.0-<TS>-<hex>/SnapGlass.app
✅ SHA-256:      release/exp-v1.6.0-<TS>-<hex>/SnapGlass-v1.6.0-<TS>.dmg.sha256
```

**`latest` 软链接会变：** `build.sh` 末尾无条件 `rm -f` 再重建 `release/latest/SnapGlass.app`，指向本次新 app。这是既有行为，不修改、不回滚，但必须在报告里如实写「`latest` 已由旧包改指本次包」，并用 `readlink release/latest/SnapGlass.app` 留证。软链接变化不等于旧包被改动。

## 5. 构建后校验（只用新产物）

```bash
NEW=release/exp-v1.6.0-<TS>-<hex>          # 以上一步真实输出为准
bash scripts/verify-build.sh --app "$NEW/SnapGlass.app" \
  --version 1.6.0 --build 3 --require-ed-key   # 期望 exit 0
codesign --verify --deep --strict "$NEW/SnapGlass.app"   # 期望 exit 0
lipo -archs "$NEW/SnapGlass.app/Contents/MacOS/SnapGlass" # 期望 arm64 x86_64
shasum -a 256 "$NEW"/SnapGlass-v1.6.0-<TS>.dmg            # 与 sidecar 比对
( cd "$NEW" && shasum -a 256 -c SnapGlass-v1.6.0-<TS>.dmg.sha256 )  # 期望 OK
plutil -p "$NEW/BUILD_INFO.json"    # kind=experimental, buildId=<目录名>, buildDate=<TS>
```

判据：

- `verify-build.sh` 会校验 bundle id、版本/构建号、双架构、**证书非 ad-hoc**、designated requirement 与 `scripts/signing/identity.requirement.txt` 完全一致、`SUPublicEDKey` 与仓库公钥一致。任一项不符即 exit 非 0，**不得降级为 ad-hoc 蒙混**。
- SHA256 三方一致：`shasum` 实算值 = sidecar 文件内容 = 报告中抄录值。
- `BUILD_INFO.json` 的 `buildDate` 与目录名、DMG 文件名中的 `<TS>` 必须同一时刻，出现混用即判不合格。
- 旧包不参与比对：新旧区别以**新路径 + 新时间戳 + 新 SHA256** 陈述，不引用旧包哈希。

可选（只读挂载新 DMG 复核内容）：`hdiutil attach -readonly -nobrowse <新 DMG>` → 对挂载卷内 `SnapGlass.app` 重跑 `verify-build.sh` → `hdiutil detach`。做则必须记录 detach exit 0；不做不影响交付。

## 6. 报告口径与未验证项

交付报告只写已发生的事实：真实目录、DMG 文件名、字节大小、SHA256、各步退出码、验签输出、`latest` 新目标，以及 `[Unreleased]` 的更新依据与 `check-localization.sh` 的 exit。

以下**未验证**，必须显式标注，不得暗示：

- 真机安装与首次启动、Gatekeeper 放行、录制/屏幕/音频真实链路、TCC 提示、自更新升级、长录与性能数字。
- 因此状态最多到 `Compiled + Signed + SHA256-recorded`，**不是** `Validated`；真机项统一写「未验证」。

## 7. 失败处置

| 失败点 | 处置 |
|---|---|
| 缺证书 / `open_signing_keychain` 失败 | 停止，报告 exit 与提示原文；**不改 `--no-sign`**，不生成替代包 |
| `check-localization.sh` 非 0 | 先修文案（四语言键/占位），**不**改脚本、不加白名单、不跳过校验；修好后只重跑这一次校验 |
| 任一架构编译失败 | 保留日志，停止，不生成 DMG |
| `verify-build.sh` 失败 | 停止；包留在 `release/exp-*/` 作取证，不修补签名后重签冒充通过 |
| DMG 或哈希失败 | 停止；不手工补 `.sha256`，不手改 `BUILD_INFO.json` |
| 任何情况下 | 不删 `release/exp-v1.6.0-20261118T062756Z-be637c/`，不 `git checkout` 用户改动，不 commit |

## 8. 执行结果（2026-11-18）

### 8.1 CHANGELOG 与文案

- `CHANGELOG.md` 的 `[Unreleased]` 只补了已落地的 A（录屏生命周期）、B（目标卷预算/卷身份）与两处调用点收敛；`Verification status` 按实际构建与未验证边界重写。
- 四语言校验因四份 `Localizable.strings` 的最后修改（16:13）晚于旧日志（11:44），按闸门重跑**一次**：`bash scripts/check-localization.sh`，exit 0（键集、占位符、源码引用、视图层检查全部通过）。日志：`.context/recording-p0-delivery/check-localization-20261118T083932Z.log`。

### 8.2 构建（三次，前两次失败已修正）

| # | 日志 | exit | 诊断 |
|---|---|---|---|
| 1 | `build-20261118T084018Z.log` | 65 | `ScreenRecordingSessionCoordinator.swift:386`：`processingFailure ?? await …`，`??` 的 autoclosure 不支持 `await` |
| 2 | `build-retry-20261118T084042Z.log` | 65 | `RecordingControlPanel.swift:810` switch 未覆盖 `.preparing`；`RecordingSessionController+HUD.swift:442` 访问 private `screenPlatformStartPending` |
| 3 | `build-retry2-20261118T084129Z.log` | 0 | `** BUILD SUCCEEDED **`（arm64、x86_64），签名、验签、DMG 全部完成 |

最小修正（仅编译兼容，未改语义）：`if let` 替代 `??` 的 await；`.preparing` 归入非音频布局；`screenPlatformStartPending` 改为模块内可见（与同文件既有 HUD 共享属性一致）。

### 8.3 本次产物（唯一有效包）

```text
release/exp-v1.6.0-20261118T084129Z-68a696/
├── SnapGlass.app                                  (universal: x86_64 arm64)
├── SnapGlass-v1.6.0-20261118T084129Z.dmg          16,356,816 bytes
├── SnapGlass-v1.6.0-20261118T084129Z.dmg.sha256
└── BUILD_INFO.json
```

- SHA-256：`7cb634395fe74d506030ce8caa00b25fccaba03097bae8a5ac708d5c7444063e`（实算、sidecar、`shasum -c` 三方一致，exit 0）。
- 签名：`Authority=SnapGlass Code Signing`，`flags=0x0(none)`（无 Hardened Runtime），designated requirement 与 `scripts/signing/identity.requirement.txt` 完全一致；`verify-build.sh --require-ed-key` exit 0；`codesign --verify --deep --strict` exit 0。
- `BUILD_INFO.json`：`kind=experimental`、`buildId` 与目录名一致、`buildDate=2026-11-18T08:41:29Z` 与目录/DMG 时间戳同刻。
- `release/latest/SnapGlass.app` 已由旧包改指本次包（`../exp-v1.6.0-20261118T084129Z-68a696/SnapGlass.app`）；旧包目录仍为 `exp-v1.6.0-20261118T062756Z-be637c`（mtime 未变），未被覆盖，也未读取其内容或哈希。
- 构建 warning 共 129 条（96 SwiftLint 风格、18 AVFoundation 弃用、15 其他），无编译错误。

### 8.4 仍未验证

测试、GUI、TCC/权限提示、真实录音与录屏、长录、性能数字、DMG 挂载复核（可选步骤未做）、自更新与升级路径。状态为 `Compiled + Signed + SHA256-recorded`，不是 `Validated`；外置卷在最后一次检查与写入之间的卸载竞态未消除也未运行期验证。
