# SnapGlass 测试指南

> 自动化测试是发版门槛；手动 GUI 检查是可选项，不是发版前置条件。

## 测试分层

| 层级 | 覆盖内容 | 命令 | 是否隔离运行实例 |
|---|---|---|---|
| Package 测试 | 图像、OCR、标注、历史、录制管线等纯逻辑 | `swift test --package-path Packages/<Name>` | 不需要 App |
| App Scheme 测试 | 编辑器状态、画布几何、离屏渲染、窗口生命周期、条码面板 | `xcodebuild test -project SnapGlass.xcodeproj -scheme <Scheme> -destination 'platform=macOS'` | 测试进程内，不触碰运行中的 App |
| 离屏画布渲染 | 真实 `EditableAnnotationCanvasNSView` 绘制、画布与导出对齐、透明棋盘格、描边 | `EditorInteractionTests/CanvasShareRenderTests` | 不启动 App、不需要屏幕/麦克风权限 |
| Agent 场景 | 真实录制/录屏/恢复/卡死路径，独立进程与独立数据根 | `scripts/agent-test.sh <scenario>` | `open -n` 第二实例，不触碰用户库 |

## 全量自动化

```bash
./scripts/test.sh
```

包含全部 Package 测试与三个 App scheme（`EditorInteractionTests`、`WindowLifecycleStateTests`、`BarcodePanelTests`）。任一失败即失败。

## 画布离屏渲染

`App/SnapGlass/EditorTests/CanvasShareRenderTests.swift` 直接创建真实的 `EditableAnnotationCanvasNSView`，通过 AppKit 的 display 路径渲染到 bitmap，并与 `MockupRenderer.render` 的导出结果对照：

- padding 区是模板背景色，内容区是图片；
- 透明背景在 padding 区显示棋盘格，而不是工作区深色；
- 描边画在内容边缘内侧；
- 画布与导出的 padding 颜色、内容位置一致。

这些测试不需要启动 App，也不会干扰用户正在运行的实例。

## Agent 后台临时测试

Agent 通道用于需要真实进程/真实录制管线的场景。它通过 `open -n` 启动第二个实例，使用独立的录制根与输出目录，正常启动路径完全不进入该通道。

```bash
# 场景文件见 scripts/agent-scenarios/
scripts/agent-test.sh scripts/agent-scenarios/audio-smoke.json --timeout 120
```

隔离与安全：

- `--agent-root <dir>`：录制根、会话索引、导出全部落在临时目录；
- `--agent-out <dir>`：`agent.pid`、`report.json`、失败取证；
- 不注册菜单栏、热键、登录项或 Sparkle；
- 不写用户 `UserDefaults`，不触碰 `~/Movies/SnapGlass`；
- 启动前比较测试构建与 `/Applications/SnapGlass.app` 的 bundle id 与 designated requirement；不一致会拒绝运行，避免触发第二次 TCC 授权；
- 脚本在运行前后对用户录制目录、应用支持目录和 `defaults` 做快照，失败时输出差异。

常用场景：

| 场景 | 用途 |
|---|---|
| `audio-smoke.json` | 3 秒录音冒烟，HUD 首现、发布、产物可播 |
| `audio-10s.json` | 10 秒录音稳定性 |
| `screen-10s.json` | 真实屏幕录制 |
| `stall-main.json` | 注入主线程阻塞，验证仍能落盘 |
| `recover-orphan.json` | 收编中断录制并导出 |

Agent 场景依赖真实屏幕/音频权限与已安装 App 的签名身份，因此**不放进** `scripts/test.sh`，在录制相关改动或发版前按需运行。失败时保留 `.build/agent-runs/<timestamp>/`，其中包含 `report.json`、`sample`、`spindump`、signpost 与用户目录差异。

## 菜单栏约束（远程 scene）

`MenuBarStatusLabel`（标签）与 `MenuBarView`（菜单内容）由 ControlCenter 的远程 scene 渲染，不是 App 自己的窗口。**标签必须保持静态**：禁止 `TimelineView`、定时器，禁止在录制开始时改变状态项宽度。实时计时器会让主线程卡在远程 scene 的 fence 上（2026-11-24 的 1.7.1 首秒卡死即此）。动态内容（录制时长等）放在菜单弹层里，打开菜单时按当前时间格式化。

`AgentMode` 不构造 SwiftUI scene（无 `MenuBarExtra`、无状态栏远程 scene），因此 agent 场景**覆盖不到**这条路径；涉及菜单栏的改版必须做一次真实入口冒烟。

## 卡死取证协议（beachball / 主线程冻结）

复现彩色转圈时**先不要强退**，按顺序取证，再终止进程：

```bash
# 1. 采样（5 秒，足以看出主线程栈）
sample SnapGlass 5 -file /tmp/snapglass-hang-$(date +%H%M%S).txt

# 2. 同窗口日志：把 --start / --end 换成卡死前 30 秒与卡死后 30 秒
log show --start '2026-11-24 14:40:55' --end '2026-11-24 14:42:00' \
  --predicate 'process == "SnapGlass" OR process == "ControlCenter"' \
  --info --debug > /tmp/snapglass-hang-window.log

# 3. 进程与会话现场（之后才强退）
ps -o pid,stat,%cpu,etime -p $(pgrep -x SnapGlass)
ls -l ~/Movies/SnapGlass/Recordings/.SnapGlassSessions/
```

| 栈顶特征 | 结论 |
|---|---|
| `NSHostingView.layout` / SwiftUI / `CA::Transaction::commit` / `_NSWindowTransformAnimation` | HUD 渲染或合成 |
| `NSHostingController.sizeThatFits` | HUD 测量 |
| `NSSceneFenceAction` / FrontBoard / `_waitForSceneUpdate` / `__waitForFence` | ControlCenter 远程 scene fence |
| `xpc_connection_send_message_with_reply_sync` / `mach_msg` 同步等待 | 同步 XPC 或框架调用 |
| `NSLock` / `os_unfair_lock` / `DispatchSemaphore`（非主线程持有） | 锁反转 |
| `mach_msg2_trap` 且上层是 `NSApplication` run loop | 只是空闲，需重抓并同时 spindump |

录制中主线程冻结超过 10 秒时，结算 supervisor 会自行停止并保存（见 `RecordingReadiness.recordingLivenessDeadline`）；因此取证时如果界面恢复，录制可能已经按“界面停止响应”文案结束，这是预期行为，不是二次故障。

## 发版门槛

1. `./scripts/test.sh` 全绿；
2. `./scripts/build.sh --sign` 成功（或由 release 流程完成）；
3. 如本次改动涉及录制/权限/**菜单栏**，额外跑相关 agent 场景，并做一次真实菜单栏冒烟：从 `MenuBarExtra` 开始一次录音，确认 1 秒内进入录音态、菜单栏与 HUD 均无卡死；
4. 本地化校验 `./scripts/check-localization.sh` 通过。

手动 GUI 检查（真实视觉、VoiceOver、透明 JPEG 导出、6K 缩放清晰度）保留为可选项：建议在发版后或用户验收时执行，不作为自动化发版的阻塞条件。

## 新增测试的落点

- 纯逻辑/算法：对应 `Packages/<Name>/Tests`；
- 编辑器状态/几何：`App/SnapGlass/EditorTests`；
- 真实 AppKit 绘制：`App/SnapGlass/EditorTests` 的离屏渲染用例；
- 真实录制路径/权限/主线程：新增 `scripts/agent-scenarios/*.json`，必要时扩展 `AgentScenario` 与 `AgentRunner`。

最后更新：2026-11-23
