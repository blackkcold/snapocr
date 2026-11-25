# 代码签名与更新密钥

SnapGlass 不使用 Developer ID：发布包由固定的自签名证书 `SnapGlass Code Signing` 签名，自动更新由 Sparkle 2 的 EdDSA 签名保证。这份文档记录材料在哪、为什么不能换、以及换机器时怎么恢复。

## 为什么自签名够用

macOS 用 **designated requirement（DR）** 判断「这是不是同一个 App」。ad-hoc 签名把 cdhash 写进 DR，每次构建都变，于是屏幕录制授权、通知、登录项全部重来。换成固定证书后，DR 变成：

```
identifier "com.snapglass.app" and certificate root = H"9077f02336cb662c4f982de4b4873c7e870483a1"
```

自签名根证书没有上级 CA，所以是 `certificate root`（不是某些文档写的 `certificate leaf`），效果相同：只要证书文件不变，DR 就逐字节不变。

Sparkle 校验更新包时，会用**旧 App 的 DR** 去验证新包。这既是身份稳定的收益，也是硬约束：一旦某一个版本用 ad-hoc 签发出去，它安装不了任何后续更新，用户只能手动重装。

## 冻结项

| 项目 | 值 | 改了会怎样 |
|---|---|---|
| Bundle ID | `com.snapglass.app` | 数据目录、UserDefaults、TCC、登录项全部换新 |
| 证书 CN | `SnapGlass Code Signing` | DR 变化；所有用户重新授权 |
| 证书 SHA-1 | `90:77:F0:23:36:CB:66:2C:4F:98:2D:E4:B4:87:3C:7E:87:04:83:A1` | 同上 |
| 证书有效期 | 2036-11-08 | 过期后新构建无法签名 |
| EdDSA 公钥 | `p42P65Q1D3b8IUFkUu6RMjiibnkR6n5X7dCwZb9BgDA=` | 已安装副本无法验证新包 |
| 构建号 | `build.txt`，单调递增 | Sparkle 认为没有新版本 |

这些值同时记录在 `scripts/signing/identity.requirement.txt`，CI 每次发布逐字节比对；不一致就阻断发布。

## 材料清单

| 材料 | 本机路径 | 备份 |
|---|---|---|
| 证书 + 私钥 | `~/.config/snapglass/signing/SnapGlass.p12` | 1Password（base64 存在 notes 中） |
| `.p12` 密码 | `~/.config/snapglass/signing/SnapGlass.p12.password` | 1Password 条目密码字段 |
| 证书 PEM | `~/.config/snapglass/signing/cert.pem` | 由 `.p12` 可重新导出 |
| EdDSA 私钥 | `~/.config/snapglass/signing/sparkle_ed25519.key` | 1Password + 离线副本 |
| EdDSA 公钥 | `scripts/signing/sparkle_ed25519.pub`（已提交） | 仓库本身 |

目录权限 `700`，文件 `600`。私钥不进入仓库、不出现在命令行参数、不打印到日志。

## 备份到 1Password

```bash
op signin
SIGNING_DIR="$HOME/.config/snapglass/signing" bash scripts/backup-signing-to-1password.sh
```

脚本会创建（或复用）`SnapGlass Release` 保险库，写入两个条目：

- `SnapGlass Code Signing`：`.p12` 的 base64、导出密码、SHA-1、有效期
- `Sparkle EdDSA private key`：32 字节 seed 的 base64 与对应公钥

EdDSA 私钥至少两份异地备份。自签路线没有「换钥回退包」——包必须是 Developer ID 签名才能触发 Sparkle 的换钥回退流程，所以私钥丢失等于老用户只能手动重装。

## 新机器恢复

```bash
mkdir -p ~/.config/snapglass/signing && chmod 700 ~/.config/snapglass/signing
cd ~/.config/snapglass/signing

# 1. 取回 .p12（1Password 条目 notes 里的 base64）
base64 -D > SnapGlass.p12
# 2. 写入密码（无换行）
printf '%s' '<1Password 中的密码>' > SnapGlass.p12.password
# 3. 取回 EdDSA 私钥（条目密码字段，单行 base64）
printf '%s' '<seed>' > sparkle_ed25519.key
# 4. 导出证书 PEM（用于核对指纹）
openssl pkcs12 -in SnapGlass.p12 -clcerts -nokeys \
  -passin "pass:$(cat SnapGlass.p12.password)" -out cert.pem

# 5. 断言身份没有变
security find-identity -v -p codesigning
openssl x509 -in cert.pem -noout -fingerprint -sha1
```

指纹必须仍是 `90:77:F0:...:A1`。然后跑一次：

```bash
bash scripts/build.sh --version 0.0.0 --release-dir .build/identity-check --sign
```

`verify-build.sh` 会比对 DR；不一致会直接失败。

## 从零重建（仅限证书彻底丢失时）

```bash
cd ~/.config/snapglass/signing
openssl req -x509 -newkey rsa:3072 -sha256 -days 3650 -nodes \
  -keyout key.pem -out cert.pem \
  -subj "/CN=SnapGlass Code Signing/O=SnapGlass/C=CN" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"
PASS="$(openssl rand -hex 16)"
printf '%s' "$PASS" > SnapGlass.p12.password
openssl pkcs12 -export -inkey key.pem -in cert.pem -out SnapGlass.p12 \
  -name "SnapGlass Code Signing" -passout "pass:$PASS"
chmod 600 SnapGlass.p12 SnapGlass.p12.password
```

重建后必须更新 `scripts/signing/identity.requirement.txt`，并在发布说明里告知用户：**屏幕录制授权会重置一次**。已安装的副本仍能通过 Sparkle 升级（EdDSA 不变即可），只是新版本的 DR 不同。

## 换成 Developer ID 时

1. 用 Developer ID 重新签名并公证，其余流程不变。
2. EdDSA 私钥保持不变，已安装的自签名副本就能自动升级到公证版本。
3. 用户的屏幕录制授权会重置一次（DR 从自签名根变成 Team ID），这是唯一一次可预期的重置。
4. 先发一版 Developer ID 构建，观察一个版本周期，再移除自签名证书相关脚本。

## CI 密钥

| Secret | 内容 |
|---|---|
| `SNAPGLASS_CERT_P12_BASE64` | `.p12` 的 base64（单行） |
| `SNAPGLASS_CERT_P12_PASSWORD` | `.p12` 导出密码 |
| `SPARKLE_ED_PRIVATE_KEY` | EdDSA seed 的 base64（单行） |

工作流把它们写到 `$RUNNER_TEMP/snapglass-signing/`（`600`），构建结束随 runner 销毁。发布前会做三件事：

1. `verify-build.sh`：非 ad-hoc、Authority 正确、无 Hardened Runtime、DR 与记录一致、`CFBundleVersion` 正确；
2. `make-appcast.sh`：生成签名 feed；
3. `verify-appcast.py`：用 App 内置的 `SUPublicEDKey` 对 DMG 做真实 Ed25519 校验。

第 3 步失败意味着这个包「永远收不到更新」，必须阻断发布。
