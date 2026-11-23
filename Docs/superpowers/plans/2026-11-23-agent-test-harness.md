# Agent 测试通道 — 独立进程 / 真实代码路径 / 无 GUI 点击

> **Status:** `Planned`，2026-11-23。排在 S1 之后、S2 之前实施（S2 的“主线程卡死仍能落盘”验收依赖它）。
> Worktree：`.../recording-p0-completion` · Branch：`fix/recording-p0-completion`

## 0. 为什么需要它

| 现状问题 | 后果 |
|---|---|
| SnapGlass 是 `LSUIElement` 菜单栏应用，Dock 无图标 | cua 只能点菜单栏图标，命中率低；窗口不激活时点击容易落空 |
| 只有一个实例，测试会占用用户正在用的 App | 无法并行；测试录音会写进用户真实库；崩溃会杀掉用户会话 |
| 权限按 bundle / 签名归属 | 每次换构建方式（未签名 Debug）都可能重新弹 TCC |
| 卡死类缺陷无法用 GUI 复现 | 主线程卡住时，点击、脚本、AppleScript 全部失效 |
| 没有客观指标 | “HUD 立即出现”“没有卡顿”只能靠肉眼判断 |

**目标：** 用一条命令跑完录音/录屏/恢复/卡死场景，产出机器可读报告；不点菜单栏、不抢用户实例、不写用户库、不复用未签名二进制。

## 1. 设计原则

1. **同一 bundle、同一签名身份**：测试实例用 `com.snapglass.app` + `DeckPet Stable Code Signing`，TCC 授权与用户已授予的主 App 共用，不产生第二次授权。
2. **独立进程、独立数据根**：`open -n` 起第二个实例，`--agent-root <temp>` 把录制根、索引、导出全部隔离；绝不触碰 `~/Movies/SnapGlass` 与用户 `UserDefaults`。
3. **走真实代码路径**：不是 mock。真实的 `RecordingSessionController`、`RecordingSessionPipeline`、HUD、导出。测试模式只做三件事：注入参数、屏蔽菜单栏/热键/更新器、输出报告。
4. **可注入失败**：主线程阻塞、首样本截止、writer 不 ready 都能由场景文件触发，用于验收 S2/S4/S5。
5. **无 GUI 依赖**：结果从 `report.json` 读，进程健康从 pid + `sample` 读；不需要点击、不需要读屏。
6. **默认关闭**：只有显式 `--agent-run` / `--agent-scan` / `--agent-recover` 才进入测试模式；正常启动行为零变化。

## 2. 组成

```
scripts/agent-test.sh                # 驱动：构建/签名 → 起实例 → 等报告 → 失败取证
App/SnapGlass/Sources/Agent/
  AgentMode.swift                    # 参数解析、单例开关
  AgentScenario.swift                # Decodable 场景定义
  AgentRunner.swift                  # 执行场景、写 report.json、退出
  AgentMainThreadProbe.swift         # 主线程停顿探针（50ms ping）
  AgentReport.swift                  # Codable 报告模型
Docs/superpowers/plans/…             # 本文件
```

### 2.1 入口

- `SnapGlassApp.body`：`AgentMode.isActive` 时只保留一个空 `Settings` 场景，不创建 `MenuBarExtra`、不注册热键、不启动 updater、不建菜单栏图标。
- `AppLifecycleDelegate.applicationDidFinishLaunching`：`AgentMode.isActive` 时立即写 `agent.pid`，`NSApp.setActivationPolicy(.accessory)`（HUD 仍需窗口，但不抢焦点），随后启动 `AgentRunner`。
- 正常模式：以上代码全部短路，行为与现在一致。

### 2.2 参数

| 参数 | 含义 |
|---|---|
| `--agent-run <scenario.json>` | 执行一次场景后退出 |
| `--agent-scan` | 只扫描录制根，输出可恢复项后退出（S3 用） |
| `--agent-recover <sessionID>` | 收编指定会话后退出（S3 用） |
| `--agent-root <dir>` | 隔离录制根；未指定时用临时目录，禁止落到用户库 |
| `--agent-out <dir>` | 报告与日志输出目录 |
| `--agent-deadline <seconds>` | 覆盖首样本截止（默认 15s，测试可 2–3s） |
| `--agent-hud-corner <corner>` | 固定 HUD 角落，避免遮挡用户工作区 |

### 2.3 场景文件

```json
{
  "name": "stall-main",
  "audioSeconds": 5,
  "screenSeconds": 0,
  "firstSampleDeadlineSeconds": 3,
  "simulateMainStallMs": 6000,
  "simulateStallAfterStart": true,
  "expect": {
    "artifactPlayable": true,
    "hudFirstVisibleUnderMs": 300,
    "sizeThatFitsBeforeFirstVisible": 0
  }
}
```

> **`suppressFirstSample`（S2 起）：** 采集照常运行，但把就绪观测注入为“永不就绪”，
> 用于在真实落盘路径上验证首样本截止。`simulateStallAfterStart: false` 时主线程阻塞
> 发生在就绪等待之前，因此截止会在阻塞期间触发。
>
> **`deadline-during-stall`：** 截止 2s + 阻塞 6s + `suppressFirstSample`；报告
> `supervisor.settlementDuringStall` 必须为 `true`（结算时刻落在 `timeline` 的
> `stallStart`/`stallEnd` 之间），`supervisor.stopCalls` 必须为 1，产物不得为 0 字节。

### 2.4 报告

`<out>/report.json`：

```json
{
  "ok": true,
  "scenario": "stall-main",
  "app": { "pid": 12345, "bundleID": "com.snapglass.app", "signedIdentity": "DeckPet Stable Code Signing" },
  "session": { "id": "…", "kind": "audio", "published": true },
  "artifacts": [{ "path": "…caf", "bytes": 4231936, "duration": 5.01 }],
  "hud": { "firstVisibleMs": 42, "sizeThatFitsCount": 0, "resizeCount": 1, "applyCount": 6 },
  "mainThread": { "maxStallMs": 6002, "probeSamples": 240 },
  "readiness": { "firstRealSampleAfterMs": 78, "becameRecording": true },
  "timeline": [{ "t": 0, "event": "start" }, { "t": 42, "event": "hudVisible" }],
  "errors": []
}
```

- `hud` 计数器由 `RecordingControlPanel` 在 agent 模式下累加（正常模式零开销：一个 static 计数 + 布尔判断）。
- `mainThread.maxStallMs` 是独立探针，不依赖被测代码。它是“UI 是否卡死”的客观证据。
- `timeline` 用单调时钟毫秒，便于对照 signpost。

## 3. 主线程停顿探针

```swift
final class AgentMainThreadProbe: @unchecked Sendable {
    // Task.detached 每 50ms 往 main queue 投一个带时间戳的块；
    // 主线程执行时计算延迟，记录 max 与直方图。
    // 不读 UI、不持锁、不阻塞主线程。
}
```
- 目的：S2 的“主线程阻塞时仍能落盘”必须由独立探针证明，而不是由被测代码自证。
- 报告里给出 `maxStallMs`；断言 `maxStallMs >= simulateMainStallMs * 0.8`（证明注入生效）且 `artifactPlayable == true`（证明兜底落盘生效）。

## 4. 数据隔离

- `RecordingExportRoots.current(in:)`：`SNAPGLASS_AGENT_ROOT` 存在时**只**返回该根；agent 模式结束不清理，由 wrapper 删除临时目录。
- `UserDefaults`：agent 模式禁止写入。HUD 角落、语言、设备选择全部走内存覆盖；实现时在 `AgentMode` 提供 `overrides`，相关读取点先查 overrides 再查 defaults。
- 单实例状态：不注册 `SMAppService`、不注册热键、不创建菜单栏项、不启动 Sparkle。
- 录音 HUD 会短暂出现（真实窗口），位置固定在指定角落，不激活 App。

## 5. 权限策略

- **构建必须签名**：`scripts/agent-test.sh` 优先使用 `scripts/build.sh --sign` 产物；若用 xcodebuild Debug，必须 `CODE_SIGN_IDENTITY="DeckPet Stable Code Signing"`，并对 App 与内嵌 framework 逐一 `codesign --force`，最后校验：
  - `codesign -dv` 显示同一身份；
  - `codesign -d -r-` 的 designated requirement 与已安装 App 一致（identifier + certificate leaf）。
- **一致性检查**：wrapper 在启动前比较构建产物与 `/Applications/SnapGlass.app` 的 `identifier` 与 leaf 证书哈希；不一致则拒绝运行并提示“会触发重复授权”。
- **一次性授权**：若系统从未给过该 bundle 麦克风/屏幕权限，第一次 agent 运行会弹一次；之后不再弹。文档中写明这是唯一一次。
- **不重置 TCC**：任何脚本都不执行 `tccutil reset`。

## 6. `scripts/agent-test.sh`

```
agent-test.sh <scenario.json> [--timeout 120] [--app <path>] [--keep]
```

流程：
1. 解析场景，创建 `out=$(mktemp -d)`。
2. 定位/构建签名 App；校验身份与 bundle id。
3. `open -n -a "$APP" --args --agent-run "$scenario" --agent-root "$out/root" --agent-out "$out" --agent-hud-corner bottomLeading`
4. 轮询 `$out/agent.pid` 与 `$out/report.json`，总超时 `--timeout`。
5. 超时或 `ok != true` 时自动取证：
   - `sample <pid> 5 -file "$out/sample.txt"`
   - `spindump <pid> -o "$out/spindump.txt"`（需要权限时跳过并记录）
   - `log show --last 3m --signpost --predicate 'subsystem == "com.snapglass"' > "$out/signposts.txt"`
   - 复制 `$out/root/.SnapGlassSessions/*/journal.ndjson` 与 `ls -l` 产物
6. 退出码：`ok == true` → 0；否则 1，并打印报告摘要与取证路径。
7. `--keep` 保留临时目录；默认成功即删、失败保留。

## 7. 场景清单（对应各阶段验收）

| 场景 | 用途 | 断言 |
|---|---|---|
| `audio-smoke` | 3s 录音 | HUD 首现 <300ms；首现前 `sizeThatFits == 0`；发布成功；产物可播 |
| `audio-10s` | 10s 录音 | 无周期性 resize；`resizeCount <= 2`；时长误差 <0.3s |
| `stall-main` | 注入 6s 主线程阻塞 + 3s 首样本截止 | `maxStallMs` 证明注入生效；仍产出可播文件；报告 `ok` |
| `deadline-no-media` | 不注入媒体（路由为空）+ 2s 截止 | 进入失败面板；不产生 0 字节发布；不永久等待 |
| `screen-10s` | 10s 录屏 | MP4 >0；可解码；列表可见 |
| `screen-writer-stall` | 注入 writer not-ready | 有界失败；0 字节文件被清理；文案分类正确 |
| `scan-orphans` | 复制今天的 4 个孤儿到隔离根 | 2 个 CAF 可恢复、2 个 0 字节 MP4 不列出 |
| `recover-orphan` | 对 22s CAF 执行 recover | index 可见；导出 m4a 可播；幂等 |

## 8. 实施顺序与文件

1. `AgentMode` + `AgentScenario` + `AgentReport`（纯类型，可单测）。
2. 入口接线：`App.swift` / `AppLifecycleDelegate.swift` 短路；`AgentRunner` 跑 `audio-smoke`。
3. 探针与 HUD 计数器。
4. `scripts/agent-test.sh` + 签名一致性校验。
5. `screen-*` 与 `scan/recover` 子命令（S3/S5 前补齐）。
6. `project.yml` 新文件入 App 与测试目标；`xcodegen generate`。

**测试：** `AgentScenarioTests`（参数解析、默认值、拒绝落用户库）、`AgentReportTests`（Codable 兼容）、`AgentRunnerTests`（用注入的 fake session 验证 ok/失败分支）。真实场景由 `agent-test.sh` 跑。

**非目标：** 不做远程控制、不做 socket 常驻服务、不替用户自动授权、不把测试模式暴露到正常 UI。

## 9. 验收

- `audio-smoke` 一次通过，报告含 `hud.firstVisibleMs`、`sizeThatFitsCount`、`mainThread.maxStallMs`。
- 用户正在使用主 App 时运行，用户会话不受影响、用户库无新增文件。
- 构建产物与已安装 App 身份一致，运行不触发新的 TCC 弹窗（首次除外）。
- `stall-main` 能证明：主线程确实被阻塞 6s，同时文件仍被落盘。
- 失败时自动产出 `sample.txt`，不再需要人工复现。

## 10. 已知限制

- **系统音频要求显示器处于唤醒状态**：`audioMode` 为 `system` 或 `systemAndMicrophone`
  时，ScreenCaptureKit 在显示器休眠时启动失败，错误为
  `source start failed: unavailable("no display available for audio stream")`。
  可用 `system_profiler SPDisplaysDataType` 查看 `Display Asleep`。harness 不会降级到
  `microphone`：报告 `errors` 同时写入原始错误与
  `display asleep / no display available`，场景如实失败。需要先唤醒显示器（例如
  `caffeinate -u -t 2`）再跑默认音源场景。`microphone` 场景不受此限制。
- **`hudWarmup` 是测速对比开关，不是冷启动证据**：字段默认 `false`；仅当场景显式设为
  `true` 时，harness 才在计时前创建并关闭一个真实 HUD 面板。冷启动首现必须用
  `hudWarmup: false` 测量。
- **agent 运行目录**：wrapper 把输出放在仓库内 `.build/agent-runs/<timestamp>-<pid>/`，
  因为录制 ledger 拒绝 `/var`、`/tmp` 这类符号链接路径。

