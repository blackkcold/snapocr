# 录制 P5 — 拼接与导出 阶段计划
> **Status:** `Accepted for implementation after P4`；主会话已核对输出目标、assessment/validated plan、增益隔离、staging/lease 与测试 target 登记契约。开发优先，P0 全矩阵仅最终验收；本文件是已批准的实施输入，不代表 P5 已实现或通过测试。
> 母计划：`Docs/superpowers/plans/2026-11-11-recording-full-delivery.md`
> Spec：`Docs/superpowers/specs/2026-11-11-audio-and-segmented-recording-design.md`（修订 2.1）
> 顺序：**T15 → T16**；先纯逻辑/导出服务，再接 T14 `RecordingsWindow` 壳。
**Goal:** 在应用内完成选段、裁剪、增益、单/多轨导出；视频全程压缩样本直通，音频按需处理或从已发布媒体解码一次；上限 1:59:30，源文件不改。

**Architecture:** `RecordingExportPlanner` 纯逻辑生成 `ExportPlan`；`RecordingCompositionExporter` 后台 actor 执行并原子发布。T16 只做窗口/ViewModel/预览，不复制导出逻辑。

**Global Constraints**

- `maximumExportDuration = 7170s`；吸附后 `effectiveRanges` 再校验；UI 超限红/禁用并示超出量；执行前再验。
- 默认不选段；无会话/无选择双空态；missing 行不可选但可定位。
- 同 session 按时间顺序；不混不同 codec；格式不兼容明确失败，不偷偷重编码视频。
- 源文件/index 语义不改；新事务输出；用户目标路径只来自显式选择；测试临时根。
- 视频封装/拼接/裁剪不调用视频编码器；关键帧吸附可见；PTS/DTS/B 帧/边界时标守恒；音频跟随同一范围。
- 音频导出 gain 与试听 gain 分离；角色映射/缺失静音/trim 有算法与测试；原 CAF 可能已 GC，回退从已发布媒体解码一次并连续编码，不每 checkpoint 重复 priming。
- 取消/失败/外置卷不可用保留源与 owned staging；预览 lease 在窗口关闭/取消后释放。
- 真实播放器/听测/长时/真机最终验收，不阻塞开发。

---

## Task 15 — ExportPlanner + CompositionExporter

**Files**
- Create: `Packages/CaptureCore/Sources/Recording/RecordingExportPlanner.swift`
- Create: `Packages/CaptureCore/Sources/Recording/RecordingCompositionExporter.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/RecordingExportPlannerTests.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/RecordingCompositionExporterTests.swift`

**Interfaces**
```swift
public enum ExportTrackSelection: Sendable, Equatable { case mixed, sourceSeparated }
public enum ExportAudioOperation: Sendable, Equatable {
    case passthrough, reencodeAudio, mixedFromPublished, missingSilence
}
public enum ExportAudioSource: Sendable {
    case checkpointPCM([URL])
    case publishedMedia([URL])
}
public struct ExportDestination: Sendable {
    public let directory: URL   // 显式用户选择
    public let stem: String     // 含日期基名，不含扩展名
}
public enum ExportOutputShape: Sendable {
    case singleFile(fileExtension: String) // m4a / mp4
    case directory                          // audio sourceSeparated
}
public struct ExportAudioFormat: Sendable {
    public let codec: String                // "aac"
    public let sampleRate: Int              // 48000
    public let channelCountByRole: [RecordingTrackRole: Int]
}
public struct ExportOutputSpec: Sendable {
    public let destination: ExportDestination
    public let shape: ExportOutputShape
    public let videoCodec: String?          // source H.264/HEVC; nil for audio-only
    public let audioFormat: ExportAudioFormat
}
public enum ExportTrackRole: String, Sendable, Codable { case mixed, system, microphone }
public struct ExportSampleRange: Sendable, Codable {
    public let startSample: Int64
    public let sampleCount: Int64
}
public struct ExportTimeRange: Sendable, Codable {
    public let startValue: Int64
    public let startTimescale: Int32
    public let durationValue: Int64
    public let durationTimescale: Int32
}
public struct ExportSourceRange: Sendable, Codable {
    public let segmentID: UUID
    public let segmentIndex: Int
    public let role: ExportTrackRole
    public let requested: ExportSampleRange
    public let effective: ExportSampleRange
    public let videoRange: ExportTimeRange?
    public let sourceFiles: [URL]
}
public struct ExportSelection: Sendable {
    public let segmentIDs: [UUID]        // planner sorts by segment index/time
    public let rangesBySegment: [UUID: SampleRange]
    public let trackSelection: ExportTrackSelection
    public let audioGainDB: Float        // 明确用户导出选择，写入 plan
    public let destination: ExportDestination
}
public struct ExportClip: Sendable {
    public let segmentID: UUID
    public let index: Int
    public let requestedRange: SampleRange
    public let effectiveRange: SampleRange
    public let videoRange: ExportTimeRange?
}
public struct ExportAssessment: Sendable {
    public let requestedRanges: [UUID: SampleRange]
    public let effectiveRanges: [UUID: SampleRange] // 吸附后
    public let requestedDuration: TimeInterval
    public let effectiveDuration: TimeInterval
    public let overageSeconds: TimeInterval
    public let disabledReason: ExportDisabledReason?
    public let outputSpec: ExportOutputSpec
    public let clips: [ExportClip]
    public let trackMap: [RecordingTrackRole: ExportAudioOperation]
    public let audioOperation: ExportAudioOperation
    public let videoPassthrough: Bool
    public let estimatedPeakBytes: Int64
}
public enum ExportDisabledReason: Sendable, Equatable {
    case emptySelection
    case overLimit(overageSeconds: TimeInterval)
    case incompatibleCodec
    case missingSource
    case destinationUnavailable
    case passthroughUnsupported
}
public struct ExportPlan: Sendable {
    public let sessionID: UUID
    public let outputSpec: ExportOutputSpec
    public let sourceRanges: [ExportSourceRange]
    public let clips: [ExportClip]
    public let requestedRanges: [UUID: SampleRange]
    public let effectiveRanges: [UUID: SampleRange]
    public let trackMap: [RecordingTrackRole: ExportAudioOperation]
    public let audioGainDB: Float
    public let audioSourcesBySegment: [UUID: ExportAudioSource]
    public let videoPassthrough: Bool
    public let audioOperation: ExportAudioOperation
    public let estimatedDuration: TimeInterval
    public let estimatedPeakBytes: Int64
}
public enum ExportError: Error, Equatable {
    case emptySelection, overLimit(overageSeconds: TimeInterval)
    case incompatibleCodec, missingSource, destinationUnavailable
    case passthroughUnsupported
    case cancelled(stagingURL: URL?)
    case publishFailed(stagingURL: URL?)
}
public struct ExportProgress: Sendable { public let fraction: Double; public let phase: String }
public struct ExportResult: Sendable {
    public let outputURL: URL
    public let actualDuration: TimeInterval
    public let videoPassthrough: Bool
    public let audioOperation: ExportAudioOperation
    public let trackCount: Int
}
public enum RecordingExportPlanner {
    public static let maximumExportDuration: TimeInterval = 7170
    public static func assess(session: RecordingSessionRecord,
                              selection: ExportSelection,
                              audioSourcesBySegment: [UUID: ExportAudioSource]) -> ExportAssessment
    public static func plan(session: RecordingSessionRecord,
                            selection: ExportSelection,
                            audioSourcesBySegment: [UUID: ExportAudioSource]) throws -> ExportPlan
    public static func revalidate(_ plan: ExportPlan,
                                  actualRanges: [UUID: SampleRange]) throws -> ExportPlan
}
public actor RecordingCompositionExporter {
    public init(fileManager: FileManager = .default)
    public func export(_ plan: ExportPlan,
                       progress: @Sendable (ExportProgress) -> Void) async throws -> ExportResult
}
```

**Rules**
- 视频：只 `AVAssetReaderTrackOutput`（`outputSettings:nil`）→ `AVAssetWriterInput`（`outputSettings:nil`、非空 `sourceFormatHint`）；不解码/滤镜/重编码。起点同步样本、末端合法解码边界；扫描实际 GOP/PTS/DTS，不承诺固定 ±1s；`videoPassthrough=true` 才允许导出。
- 音频：优先保留整轨 AAC 直通；需混音/增益/补静音/接缝不兼容时解码到有效 PCM 后**只重编码音频**。原 CAF 不存在时用 `publishedMedia` 解码一次并连续编码；不按 checkpoint 重复 AAC priming。
- 缺失区间：按 `missingRanges` 插等长静音；后续不前移；角色映射 `mixed/system/microphone` 保留；priming/trim 保存有效样本范围。
- 7170：`assess` 返回 requested/effective/overage/disabledReason 供 UI；`plan` 只返回已验证 `ExportPlan`，超限/格式不兼容 throws；exporter 按 actual ranges 再 `revalidate`，不信 UI 缓存。
- `ExportPlan` 必须携带 `outputSpec`（destination/stem/shape/videoCodec/audioFormat）与可序列化 `sourceRanges`；`audioSourcesBySegment` 不跨 async 持有临时媒体对象，只传 URL/lease 标识。
- `audioGainDB` 是用户导出选择，写入 plan；previewGain 独立，不写 plan。
- 源不变：输出路径不得等于任一段源；失败/取消**保留**本任务 owned staging 供恢复/清理；成功发布后才回收；不改 index/ledger。
- 进度 4Hz；取消停止 reader/writer；外置卷不可用 fail closed，保留源/staging。

**Tests**
- 7170 边界：assess 的 requested/effective/overage/disabledReason；plan 超限 throws；exporter actual ranges 再验。
- 空选择/默认不选；同 session 顺序；不同 codec 明确 disabled/throws；缺 source；目标路径冲突。
- 真实短合成 MP4：关键帧吸附、首尾 PTS/DTS、输出**视频压缩样本子集** SHA-256 一致、无视频重编码；track count 按输出矩阵预期（不全局恒定）；源文件哈希前后不变。
- 音频：多轨/单轨、mixed/sourceSeparated、缺失静音、trim/priming、角色映射、`audioGainDB` 写入 plan、previewGain 分离；CAF 不存在时 publishedMedia 只解码一次；取消/失败保留 staging。
- 进度 ≤4Hz；输出 spec destination/stem/shape 实际使用。

**Exit:** planner/exporter 测试 GREEN；真实播放器/听测/长时最终验收标 `blocked`。

---
## Task 16 — 导出窗口、预算与预览

**Files**
- Create: `App/SnapGlass/Sources/Windows/RecordingExportView.swift`
- Create: `App/SnapGlass/Sources/Recording/RecordingExportViewModel.swift`
- Create: `App/SnapGlass/Sources/Recording/RecordingExportSummary.swift`
- Modify: `App/SnapGlass/Sources/Windows/RecordingsWindow.swift`（T14 壳）
- Modify: `App/SnapGlass/Resources/{en,zh-Hans,ja,ko}.lproj/Localizable.strings`
- Modify: `project.yml`（把测试需要的 `RecordingExportSummary.swift`、`RecordingExportViewModel.swift` 精确加入 `WindowLifecycleStateTests` sources；CaptureCore dependency 已由 T2 添加，复用不重复；Tests 目录自动收测试；随后 `xcodegen generate`）
- Test: `App/SnapGlass/Tests/RecordingExportSummaryTests.swift`（新增）
- Test: `App/SnapGlass/Tests/RecordingExportViewModelTests.swift`（新增：selection/validation/cancel/lease 释放/default exporter 接线）

**Interfaces**
- Consumes: T14 `RecordingsWindow`、P3 `RecordingSessionRecord`/`PublishedSegment`（含 optional `videoURL`/`videoTrackIndex`）/`RecordingSessionLedger.publishedSessions/openExisting`/`RecordingPreviewService`/`PreviewLease`、T15 `ExportPlan`/planner/exporter。
- Produces: `RecordingExportSummary { selectedDuration, maximumDuration, overage, videoPassthroughLabel, audioOperationLabel, trackCount, missingState }`；窗口 Tab 顺序、空格勾选、⌘⏎ 导出、Esc 关闭；每行 `[裁剪]`/`[定位]`；试听音量与导出增益分离；VoiceOver/Reduce Motion/Reduce Transparency。
- 真实 `RecordingCompositionExporter` 接线（不是假按钮）；会话列表/段行来自 `RecordingSessionLedger.publishedSessions`，选中会话用 `openExisting` 的只读 ledger + `makePreviewService`；预览只通过 `PreviewLease` 读未发布材料；窗口关闭/取消 `release`；lease 持有期间确实阻止 GC，release 后才可按政策清理。不得 UI 重建第二个可写 ledger。

**Rules**
- 会话列表/片段行、预算条、输出矩阵按 spec §6.4；单轨不显示灰滑杆；多轨显示轨数；输出选项随会话类型收敛。
- 超限整条红、禁用导出、显示超出量；使用 `ExportAssessment.disabledReason/overage` 呈现；执行前由 `ExportPlan`/exporter 再验。
- 双空态：无会话“还没有录制内容 + 开始录制音频”；有会话无选择“请选择片段”；missing 灰显 + 定位。
- 键盘/可达性：Tab 顺序、空格、⌘⏎、Esc、28×28、WCAG AA、非仅颜色；四语言动态宽度。
- 取消/失败/外置卷不可用：源与 staging 保留、错误可行动；不把 fake exporter 当真实接线。

**Tests**
- Summary 1:58:00/1:59:30、超出 0:32、多轨轨数、单轨提示、missing 不可选可定位、裁剪入口、试听/导出增益分离。
- `RecordingExportViewModelTests`：默认不选段；assess 超限 disabled；plan 超限 throws；取消/失败保留 staging；关闭窗口 release lease；`publishedSessions` 列表完成记录/segment files/videoURL；`openExisting` 只读且 preview 用同一 ledger；默认真实 exporter 接线。
- App scheme `WindowLifecycleStateTests`；`check-localization.sh`；App build；不打开 GUI。
- 真实播放器/四语言截断/Reduce/键盘人工最终验收。

---

## P5 出口

- [ ] T15 合成媒体测试 GREEN；7170 双验、源不变、视频直通载荷一致。
- [ ] T16 真实 exporter 接线、双空态/missing/preview lease、四语言与键盘。
- [ ] 源/index 不改；失败/取消保留 staging；未跑播放器/听测/长时明确 `blocked`。
