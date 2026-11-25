# 录制功能开发交付记录

更新：2026-11-13。**源码开发与必要编译收尾已结束；这不是完整功能验收或可发布声明。**

## 1. 执行范围与当前结论

- 依原有 T1–T17 功能分工，执行者已交回音频、分段恢复、导出、App 接线与录屏多轨的实现报告。
- 用户随后明确停止重复基线、专项评测和独立复核。本轮遵照该要求，只保留改动所需的编译／类型检查，不重新创建旧 P0／FinalValidation 流程。
- 最新 Core 产品／测试源码和纯 App 模型 target 有编译 exit 0 记录；测试源码被编译，不代表测试被运行。
- 完整 SnapGlass App 此前阻塞在 Embed Sparkle。现已修正隔离 SourcePackages 路径选择，并窄修导出窗口的一处 SwiftUI `Text` 类型错误；完整无签名 Debug build **exit 0**。主会话已读取原最终日志的 `BUILD SUCCEEDED`，没有重复运行构建。
- 未提交、推送、签名安装或发布；没有启动真实录制、播放器或 GUI／TCC 验证。

## 2. 已交回的实现

| 任务 | 实现范围 | 验证口径 |
| --- | --- | --- |
| T1–T6 | 录制域、时钟、权限入口、音频来源／路由、混音重采样与 engine | 早期记录保留；不在本轮重复评测 |
| T7–T10 | CAF 检查点、分段协调、连续 AAC／Seal、journal／索引、预览租约、空间预算与低空间接线 | Core 编译记录；恢复与故障行为未据此认定通过 |
| T11–T14 | 菜单／设置／快捷键、真实双路 RMS、HUD／试听、退出收尾、录音窗口、截图共存与动态排除 | 纯模型及最终完整 App 编译通过；未运行 GUI／录制 |
| T15–T16 | 7170 秒范围规划、压缩视频直通导出、选段／裁剪／试听／导出界面、只读会话列表 | Core、纯模型及最终完整 App 编译通过；未实际导出或试听 |
| T17 | GOP 配置、视频 bridge、两级分段、单 SCK 音频复用、MP4 多音轨／ledger／App adapter | Core 与纯模型 target 仅 build；媒体性质未运行验证 |

这些是实现交接范围，不是逐项功能或媒体正确性的独立审计结果。

## 3. 必要编译与已知构建历史

- T15：`swift build --package-path Packages/CaptureCore --build-tests`，报告 exit 0。
- T16：Core 编译与 `WindowLifecycleStateTests` target build，最终均 exit 0；测试未运行。
- T17：Core `--build-tests` 与同一纯 App 模型 target build，均报告 exit 0；本次测试执行数量为 0。
- T11/T12 历史：Sparkle 产物解析、码率 helper 参数、progress 重名、SwiftUI frame 参数曾导致构建失败；已记录相应窄修。最后的完整 App 阻塞是 Embed Sparkle 路径问题，不能把之前局部编译成功改写为当时 App build 成功。
- T13 暴露的退出测试宏编译问题已由 T16 适配，后续纯模型 target build 通过；不因此宣称未编入该 target 的 SwiftUI 窗口已经检查。
- T18：`xcodegen generate` exit 0；首次完整编译暴露 `RecordingExportView.swift:321` 将 `Text` 再包装为 `Text` 的类型错误，已最小修正。修正后的完整无签名 SnapGlass Debug build **exit 0**，日志末尾为 `BUILD SUCCEEDED`。
- Sparkle 修复仅增加显式 `SPARKLE_FRAMEWORK_PATH`、隔离 clone 根查找与原默认路径回退；本次成功构建使用已锁定的现有框架产物及显式路径，未修改依赖版本、签名策略或更新行为。其他构建布局与 Release 签名未单独验证。

最终完整构建口径：`xcodebuild -project SnapGlass.xcodeproj -scheme SnapGlass -configuration Debug … -disableAutomaticPackageResolution SPARKLE_FRAMEWORK_PATH=… CODE_SIGNING_ALLOWED=NO build`。完整命令和两次真实退出码见执行报告 `reports/task-18-build-report.md`；最终原日志为 `$TMPDIR/opencode/snapglass-task18-attempt2-20261113.log`。

警告仍存在。历史记录包含 AVFoundation 同步 API 弃用、未使用返回值、测试 target 警告，以及此前引入的格式／文件长度例外；本轮没有重跑 lint／formatter 或承诺零告警。

最终 App 日志还包含导出视图非 Sendable setter 传给 `@Sendable` 闭包、Sparkle delegate 可选方法近似匹配、无异步操作的 `await`、AppIntents metadata skip，以及 SwiftLint 不可用提示。它们未被隐去或写成已消除；尤其并发闭包的运行期行为没有验证。

## 4. 未运行的项目

- 用户停止评测之后，没有继续执行单测、全包回归、专项媒体 fixture／probe 或独立复核。
- 没有真实录音、录屏、系统声音／麦克风路由验证、TCC 操作、GUI／视觉／键盘／VoiceOver 验收或实际试听。
- 没有实际验证 300 秒检查点、59 分钟分段、7170 秒导出、2 小时／8 小时长跑、旧系统与硬件编码差异。
- 没有强杀、断电、真实盘满／慢盘、恢复重放或完整取消／发布验证。
- 没有执行最终四语言键／占位符脚本、视觉截断检查或性能测量。

上述项目是未验证，不是通过，也不由编译成功推定可靠。

## 5. 保留的质量债与风险

### T3 与文件系统边界

- 既有路径／symlink 防护不等于完全抵御恶意父目录并发替换的 TOCTOU 保证；私有暂存根及非敌对父目录仍是声明的边界。
- 本轮未用真实卷故障或并发文件系统攻击验证发布、fsync 或恢复行为。格式／长度例外保留，未以重排代码消除报告中的债务。

### T5 测试质量债

- 平台质量历史结论 `CHANGES_REQUIRED` 保留，不能因后续编译成功抹掉。
- P3 的强制 timeout／retained 证明、P4 的 System 重复拒绝对称证明、P5 admission fixture 调度债仍未追加验证。
- `legacyDirectoriesWaitForTheLegacyGrace` 与相关 fixture 的历史随机失败记录保留；本轮未运行，不能声称已消除或已复现。

### T6–T8 与后续接线

- 双路 RMS、progress 节流、新会话时钟及相关调度接线已有源码；真实电平、漂移、p99 和长期资源行为未运行验证。
- 历史风险涉及 generation 尾帧报告、慢 sink 下停止等待、诊断范围增长、缺源声道连续性与 scheduler 生命周期；本轮没有独立复核证明它们全部关闭。
- 多 role tick 屏障、batch journal 失败重试、根路径映射与 lease 生命周期已有接线，重入、崩溃恢复及回收正确性未实测；分块后缀 hostTime、旧 close／lastCommit 等历史说明继续保留。
- 码率已从配置传到 Seal／encoder，不再只是持久化设置；实际输出码率、priming／remainder、有效帧数、缺失静音、metadata remux 与平台支持仍未运行确认。

### 录屏与导出

- 单 SCK、两级边界、静态画面 tick、压缩视频直通与内嵌音轨均为已交回的生产接线；未实测首帧 sync、payload 一致性、PTS／DTS、轨道映射或音视频时间守恒。
- GUI 共存、窗口排除与截图声音没有真实操作证据；T13 未发现快门音效调用，不等于完成听测。
- 7170 秒执行前重验、取消保留 staging 与无覆盖发布虽已实现，实际媒体与故障路径没有运行期证据。

## 6. 文档与交付入口

- [简明状态记录](2026-11-11-recording-acceptance-matrix.md)
- [隐私说明](../../PRIVACY.md)：新增录音／录屏用途、恢复材料保留和未加密媒体边界。
- [未发布变更](../../../CHANGELOG.md)：仅记录开发变更，不标为发布或已验收。
- 执行报告位于 `.superpowers/sdd/2026-11-11-recording-full-delivery/reports/`；该目录被既有 gitignore 忽略，本文件是正式可见入口。

本轮以实现交接、必要完整 App 编译和文档收尾结束，不作“全验收通过”或“可发布”的结论。后续若要录制／媒体／权限／GUI／长跑验证，须另行明确范围与授权，不由本轮收尾自行恢复。
