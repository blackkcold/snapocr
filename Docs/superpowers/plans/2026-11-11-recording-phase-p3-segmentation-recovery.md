# SnapGlass P3 — 分段与恢复 阶段实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Status:** `accepted for implementation after P2（2026-11-11 主会话复核；不代表实现完成）`。本文件只写接口、文件、测试与证据，**不实现产品、不跑 build/test/P0**；本轮已同步母计划 T7–10/接口表并追加 ledger 裁定，不改 spec。P0-4/5/7/10/11 是最终验收条件，不是开发前置。T3 实现 **DONE（327 tests）**；fix round1 限定复核 active（已报告 safety6/Core333/strictlint0），不写全完；P3 只按实际输出适配，不读/改其源码。

**Goal:** 在 CaptureCore 内交付可崩溃恢复的 PCM 检查点、每角色连续 AAC 编码、原子 Seal、账本/索引/预览租约与空间预算，并把真实 `AudioRecordingEngine` 接到 CAF→Seal→ledger 的唯一组合根。

**Architecture:** T7 写 CAF chunk 并只提交连续整数范围；T8 在段内保持每角色一个 AAC 上下文，产出 m4a/manifest 后整体发布；T9 以 journal 为事实源、index 为缓存，提供恢复扫描、幂等发布、预览租约和 `RecordingSessionPipeline` 组合根；T10 只做空间/backlog 决策并接到 T9 pipeline。T6 只认识 `AudioCheckpointSink`，P3 组合根反向依赖 T6，禁止前向循环。

**Tech Stack:** Swift 6、StrictConcurrency、Swift Testing、AVFoundation/CoreAudio、CryptoKit、Foundation；不新增 SPM 依赖、不改最低系统版本。

**Spec:** `Docs/superpowers/specs/2026-11-11-audio-and-segmented-recording-design.md`（修订 2.1）
**母计划:** `Docs/superpowers/plans/2026-11-11-recording-full-delivery.md`
**Workspace:** `.superpowers/sdd/2026-11-11-recording-full-delivery`

## 1. 范围、所有权与依赖方向

| 任务 | Owner 交付 | 明确不负责 |
|---|---|---|
| T7 | `RecordingCheckpointWriter`（实现 `AudioCheckpointSink`/`SegmentCheckpointSink`、真实 CAF 16-bit PCM、fsync、SHA-256 sidecar）；`SegmentedWriterCoordinator`（实际边界/plan、跨界拆分、多 sink 单提交排空、段关闭、coverage/stats） | AAC、Seal、ledger、App 接线 |
| T8 | `AudioTrackEncoder`（每角色段内单一连续 AAC 上下文、trim/priming/remainder）；`RecordingSealService`（stage、manifest、`beforePublish` 钩子、T3 publish、失败保留 staging） | 视频编码/解码；视频 chunk 仅 T17 直通注入点 |
| T9 | `RecordingSessionLedger`、journal/manifest、`RecordingIndexRecord`、`RecordingPreviewService`/`PreviewLease`、`RecordingPortableMetadata`；**`RecordingSessionPipeline` 是唯一真实组合根**；publishIntent/batch journal | 菜单/HUD/App 生命周期 |
| T10 | `RecordingSpaceBudget`、`RecordingBacklogPolicy`、`RecordingPipelineSpaceGate`（接到 T9 pipeline 的预检/低空间/Seal 准入/状态） | 实际删除/清理文件；改 T6 生产行为 |

- **T6 不依赖 P3 具体 writer**：`AudioRecordingEngine` 只接收 `any AudioCheckpointSink`，不得 import/命名 `RecordingCheckpointWriter`、`SegmentedWriterCoordinator`、`RecordingSessionLedger`。
- **唯一组合根**：T9 的 `RecordingSessionPipeline` 同时命名 T6 engine、T7 writer/coordinator、T8 seal、T9 ledger；engine→`LedgerCheckpointSink`→coordinator→writer，checkpoint 提交后再进 ledger。P2 尚未实现，开工前按实际 T6 产出适配；若缺确定性注入 seam，停并写入报告，不用 fake 冒充集成。
- 视频路径不在 P3 实现；T17 只复用本阶段接口，视频边界由实际帧/GOP 表提供，禁止 `i*3540`。

## 2. P3 不变量（继承母计划，逐条有测试）

- 正常段 `≤3540s`；检查点目标 `300s`、约 290s 启动轮转；`48000 Hz`、`480 frames = 10ms`；所有区间为整数样本半开区间 `[start,end)`。
- 纯音频单轨只产 `mixed` CAF/m4a；多轨只产 `system`/`microphone`；每角色一个 m4a；视频 MP4 才可多 audio input，视频来源音轨只内嵌 MP4、不产外置 m4a。视频后续拼接/导出只直通压缩样本，不解码、不重编码。
- 音源切换是同一 session 的 `RouteEvent`，不重开 session/段/视频；缺失区间原位补静音，时间轴不前移。角色停止/关闭后输出格式固定，coverage 必须显式记录缺失 range，不能因角色消失而让后续来源前移。
- 一个检查点只有 CAF 关闭、校验、fsync、sidecar 持久化且 ledger 标记 `committed` 后才算安全；任一轨失败不得登记部分提交。
- 时间守恒按两层证明：`writer committed = appended input + writer-synthesized silence`；`segment coverage length = committed + explicit missing ranges`。不得把补静音前的输入和当作全部输出。
- journal 为事实源，index 为可重建缓存；发布意图先于原子 rename；失败保留本事务 owned 材料，不覆盖 existing，不自动删未发布材料。
- 恢复扫描只限应用录制根/已登记外置根；不遍历用户磁盘，不跟随逃逸 symlink。
- 预览只读已关闭 chunk/segment；lease 未释放不得 GC；预览增益与导出增益不共享可变状态。
- Seal 并发默认 1；采集/checkpoint 优先于 Seal，Seal 优先于导出/缩略图；Seal 不阻塞下一段录制或可见 backlog 报告。

## 3. 任务

### Task 7 — 检查点 CAF 写入与分段协调器

**Files:**
- Create: `Packages/CaptureCore/Sources/Recording/RecordingCheckpointWriter.swift`（含 support types、`SystemRecordingDurabilityBarrier` 默认实现、内部 fault seam）
- Create: `Packages/CaptureCore/Sources/Recording/SegmentedWriterCoordinator.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/RecordingCheckpointWriterTests.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/SegmentedWriterCoordinatorTests.swift`

**Interfaces:**
- Consumes: `AudioPCMBlock`、`AudioCheckpointSink`、`CheckpointCommit`、`SegmentCheckpointSet`、`SegmentBoundary`、`RecordingSegmentPolicy`（T1）。
- T7 不依赖 T8/T9/P2/T6 实现，可先独立落地并用假 sink factory 测协调器；真实 engine→writer 接线只在 T9 组合根完成。
- Produces:

```swift
public protocol SegmentCheckpointSink: AudioCheckpointSink, Sendable {
    var segmentBoundary: SegmentBoundary { get }
    func finishSegment() async throws -> SegmentCheckpointSet
    func finishSegmentBundle() async throws -> RecordingSegmentCheckpointBundle
}
public protocol RecordingSegmentPlan: Sendable {
    func boundary(containing sample: Int64) throws -> SegmentBoundary
    func nextBoundary(after boundary: SegmentBoundary) throws -> SegmentBoundary
}
public struct AudioSegmentPlan: RecordingSegmentPlan { /* 3540s 增量扩展，不预生成无限表 */ }
public struct RecordingSampleRange: Codable, Sendable, Hashable {
    public let startSample: Int64; public let sampleCount: Int64
    public var endSample: Int64 { startSample + sampleCount }
}
public struct RecordingTrackCoverage: Codable, Sendable, Hashable {
    public let role: String; public let sampleRate: Int; public let channelCount: Int
    public let wasActive: Bool; public let firstSample: Int64?; public let lastSample: Int64?
    public let missingRanges: [RecordingSampleRange]
    public let writerSynthesizedSilenceFrames: Int64
}
public struct RecordingSegmentCoverage: Codable, Sendable, Hashable {
    public let segmentIndex: Int
    public let segmentStartSample: Int64; public let segmentEndSample: Int64
    public let tracks: [RecordingTrackCoverage]
}
public struct RecordingSegmentCheckpointBundle: Sendable, Hashable {
    public let checkpoints: SegmentCheckpointSet; public let coverage: RecordingSegmentCoverage
}
public struct RecordingCheckpointWriterStats: Sendable, Hashable {
    public let appendedFramesByRole: [RecordingTrackRole: Int64]
    public let writerSynthesizedSilenceFramesByRole: [RecordingTrackRole: Int64]
    public let committedFramesByRole: [RecordingTrackRole: Int64]
}
public actor RecordingCheckpointWriter: SegmentCheckpointSink {
    public init(directory: URL, sessionRoot: URL, segment: SegmentBoundary,
                sampleRate: Int, roles: Set<RecordingTrackRole>,
                durability: any RecordingDurabilityBarrier = SystemRecordingDurabilityBarrier(),
                now: @escaping @Sendable () -> Date = { Date() }) throws
    public nonisolated var segmentBoundary: SegmentBoundary { get }
    public func append(_ block: AudioPCMBlock) async throws
    public func commitCheckpoint() async throws -> CheckpointCommit
    public func finishSegment() async throws -> SegmentCheckpointSet
    public func finishSegmentBundle() async throws -> RecordingSegmentCheckpointBundle
    public func statistics() -> RecordingCheckpointWriterStats
}
public actor SegmentedWriterCoordinator: AudioCheckpointSink {
    public init(plan: any RecordingSegmentPlan,
                sinkFactory: @escaping @Sendable (SegmentBoundary) throws -> any SegmentCheckpointSink) throws
    public init(boundaries: [SegmentBoundary],
                sinkFactory: @escaping @Sendable (SegmentBoundary) throws -> any SegmentCheckpointSink) throws
    public func append(_ block: AudioPCMBlock) async throws
    public func append(_ block: AudioPCMBlock, at globalSample: Int64) async throws
    public func commitCheckpoint() async throws -> CheckpointCommit
    public func commitAvailableCheckpoints() async throws -> [CheckpointCommit]
    public func closeSegment(at index: Int, isFinal: Bool = false) async throws -> SegmentCheckpointSet
    public func closeSegmentBundle(at index: Int, isFinal: Bool = false) async throws -> RecordingSegmentCheckpointBundle
    public func makeClosedSegmentStream() -> AsyncStream<SegmentCheckpointSet>
}
```

- **实际接口校准（2026-11-12，详见 `briefs/task-07-brief.md` §3/§4.1/§7）**：T1 的 `SampleRange` 不是 `Codable`，`RecordingSampleRange`/coverage/stats/record/error/default durability 均为 T7 自有支持类型；`AudioMixPump` 输出 48 kHz 会话全局网格，`AudioRecordingEngine` 原样 `append`，T7 不做源帧→48k 换算；writer 用**每 role 独立游标**，段级 `wasActive` 与 chunk 级参与集分开。T6 engine 只在 `stop()` 调一次 `commitCheckpoint()`，T9 负责 290s timer/运行期 batch，且传给 engine 的 sink 必须在单次 commit 时全量排空。T3 `.directory` 的 `partialURL` staging 目录 → T7 `directory`，`destinationDirectory` → `sessionRoot`；T7 不 rename/publish。
- **多 sink 单提交兼容**：跨边界时旧/新 sink 可同时 open。`commitCheckpoint()` 只提交**最旧未关闭 sink**的当前 chunk 并返回一个 commit，不触碰 younger sink；`commitAvailableCheckpoints()` 按段序提交所有 open sink 的当前 chunk，返回全部新 commit（无数据返回 `[]`，重复调用不重复返回）。T9 `LedgerCheckpointSink` 必须用 batch 并逐条 journal；不能只 journal 最后一个。`closeSegmentBundle` 返回该段全部 checkpoint + coverage；`SegmentCheckpointSet` 每个 role/chunk 恰好一次，stream 不重复。
- **Chunk/range/gap**：`open`→`closing`→`closed`；失败 `failed` 且永不产出 commit。每 chunk 每个**参与**角色一个连续整数范围/CAF；每 role 独立游标，首次出现可补 `[chunkStart, firstSample)` 前缀静音，之后必须等于该 role 已写尾端，前跳抛 `.nonContiguousRange`，不静默重基；回退/重叠抛错。段级 `wasActive` 与 chunk 级参与集分开。Coordinator/writer 单写者，并发/重入必须拒绝或排队。
- **活动角色/coverage**：角色以该段首次 append 为活动；从未活动不建轨、`wasActive=false`；中途首次出现补 `firstSample-chunkStart` 有限静音前缀；角色停止/关闭后 coverage 记录 `[lastSample, segmentEnd)` 等显式 missing ranges，Seal 按固定 sampleRate/channelCount 补静音；不活跃角色消失不得让后续来源前移。`firstSample`/`lastSample` 是已提交 CAF 边界（含 writer 前缀静音），`missingRanges` 只含 CAF 未覆盖区间，避免 Seal 二次补静音。
- **边界**：`< boundary.end` 旧、`>=` 新；跨界 block 精确拆分。协调器不因单个角色跨界自动 finalize 旧段；旧 sink 保持 open 到显式 `closeSegmentBundle`。非最终段旧段末必须等于 boundary.end，否则 `segmentIncomplete`；最终段 `isFinal:true` 允许短于 boundary.end。每次 close 的 set/bundle 只投递一次。
- **提交/时间守恒**：本 chunk 所有参与 roles 的 range/frameCount 一致（已停止 role 不进入后续 chunk）；关闭 CAF → fsync → SHA-256 → sidecar（schema 1、相对路径、帧数、字节数、校验和、每轨 writer silence）→ fsync 目录 → 返回。`stats` 断言 `committed = appended + writerSynthesizedSilence`；coverage 断言 `segment length = committed + missingRanges`。失败保留 owned 文件，writer failed 终态，重试用新 writer/新 checkpointID。
- **路径/故障**：`directory` 必须在 `sessionRoot` 内；拒绝绝对/`..`/NUL/符号链接逃逸。`SystemRecordingDurabilityBarrier` 与 support types 必须在 `RecordingCheckpointWriter.swift`，不新增 allowlist 文件。

**Tests:** writer：`checkpointWritesOneContiguousCAFPerRoleWithGlobalRange`；`checkpointCommitIsIdempotentWithoutNewSamples`；`appendRejectsForwardGapWithoutAdvancing`；`partialRoleWriteNeverReturnsCommit`；`finishSegmentIsIdempotentAndRejectsAppend`；`checksumAndSchemaRoundTrip`；`pathEscapingSessionRootFailsClosed`；`blockFormatMismatchFailsClosed`；`closedCAFReadsBackDeclaredRateFramesSamples`；`roleFirstAppearingMidChunkGetsPrefixSilenceAndSameRange`；`neverActiveRoleProducesNoTrackOrFile`；`statsCountInputPlusSynthesizedSilence`。coordinator：`boundaryUsesHalfOpenRule`；`crossingBlockSplitsExactlyAndConservesFrames`；`lateRolePrefixAfterCrossingStillLandsInOldSegment`；`customTableIsUsedNot3540Formula`；`commitCheckpointDoesNotDrainYoungerSink`；`commitAvailableCheckpointsReturnsAllOpenSinksInOrder`；`closeSegmentSetHasEveryCheckpointOnce`；`finalShortSegmentClosesWithActualEnd`；`roleStopsMidSegmentCoverageHasExplicitMissingRange`；`concurrentAppendIsRejectedOrSerialized`。

**Steps:** 失败测试 → 实现 writer/coordinator/support/durability seam → 重跑两过滤器 + `RecordingWriterLifecycleTests` → 记录 `T07`（`reports/task-07-report.md`、`review/task-07/`、`logs/T07.log`）；不提交。短表只是机制证据，真实 59 分钟/kill 留 P0-7。

### Task 8 — 每角色 AAC 编码与 Seal

**Files:**
- Create: `Packages/CaptureCore/Sources/Recording/AudioTrackEncoder.swift`
- Create: `Packages/CaptureCore/Sources/Recording/RecordingSealService.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/AudioTrackEncoderTests.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/RecordingSealServiceTests.swift`

**Interfaces:**
- Consumes: `RecordingSegmentCheckpointBundle`、`RecordingSegmentCoverage`、`RecordingSampleRange`、`RecordingOutputTransaction`/`RecordingOutputRequest`（T3 DONE 327 tests；按实际输出适配，不修改）、`AudioPCMBlock`。
- Produces: `AudioTrackEncoder`（`beginSegment`/`append`/`finish() async throws -> AudioSealResult`）；`AudioSealResult { role, url, effectiveRange, primingFrames, remainderFrames, insertedSilenceFrames }`；`SegmentPortableRecord`（Codable，T8 owner；含 optional `videoURL`/`videoTrackIndex`，音频-only 为 nil；用 T7 `RecordingSampleRange`/raw string，不给 T1 加 Codable）；`RecordingSealContext`；`SealedSegment { segmentID, index, files: [RecordingTrackRole: URL], manifestURL: URL?, effectiveRange, videoBoundary, trackMap, videoURL: URL?, videoTrackIndex: Int? }`（`files` 仍只放音频角色，不伪造 video/mixed 角色）；`SegmentPublicationCandidate { segmentID, segmentIndex, stagingURL, reservedFinalURL, isDirectory, stagedFileURLs, contentHashes, manifestURL?, effectiveRange, coverage }`；`SegmentPublicationHooking.beforePublish(_:) async throws`；`RecordingSealService.seal(_ bundle:videoChunks:segmentID:context:publicationHooks:)`；`RecordingSealService.publishPrepared(_ candidate:)`（恢复用：验证 intent/staging/hash 后复用 T3 internal publisher，实际 URL 必须等于 reservedFinalURL）。
- **单/多轨 manifest**：单文件 `manifestURL == nil`，`SegmentPortableRecord` 嵌入 m4a metadata；多轨目录 `manifest.json` 必有且 `manifestURL` 指向实际文件。不得要求单文件存在外部 manifest。
- **段内连续 AAC**：同段同角色一个 `AVAssetWriter`/audio input/上下文；checkpoint 边界不重置；trim/priming/remainder/有效范围写入 metadata 和 manifest，可回读；T8 按 coverage 给停止/未活动区间补静音，保持固定格式。
- **发布钩子**：stage 全部写完并验证可读/时长/轨数/hash 后，向 T3 取实际 `reservedFinalURL`（碰撞 `_2` 必须由 T3 解析，不能猜）；构造 candidate 调用所有 `beforePublish`；T9 hook 在此 journal+fsync `publishIntent`。`publicationHooks` 默认空数组（T8 独立测试 no-op），T9 pipeline 必须注入真实 `LedgerPublicationHook`。hook 抛错：保留 staging/CAF，不 publish、不覆盖 existing。hook 成功后 T3.publish；实际返回 URL 必须等于 reservedFinalURL，否则 fail-closed 保留 final/stage、不标记 published。
- **publishPrepared 恢复复用（T3 internal，已由主会话点读确认存在）**：先验证持久化 intent 的 segmentID/hash/路径/非 symlink 及 reserved final，再直接复用同模块的 `AtomicRecordingOutputPublisher.init` 默认操作与 `publish(partialURL:finalURL:) throws -> RecordingOutputPublicationMethod`（单文件），或 `AtomicDirectoryOutputPublisher.init` 默认操作与 `publish(stagingURL:finalURL:) throws`（多轨目录）。不再要求 T3 新增 transaction adoption init，也不自行重写 rename/hardlink 算法。目标 final 已存在：只验证并采用与 segmentID/hash 匹配的产物；不匹配则 fail-closed 保留材料、不猜 `_2`。hardlink 成功后 source 清理由 owned lease/GC 政策决定，leased 材料不得误删。T3 source 不改；恢复未测，新增故障测试归 T8/T9。
- **失败/取消/盘满/并发**：保留 staged/source，不覆盖；single-flight gate 保证 max 1；Seal 不阻塞 capture/checkpoint；`videoChunks` 仅 T17 直通 seam，不做视频编解码。

**Tests:** `threeCheckpointsOneM4APerRoleOneContext`；`singleTrackOnlyMixed`；`separateTracksOnlySystemAndMic`；`aacTrimMetadataRoundTrips`；`singleFileHasNoExternalManifest`；`multiTrackDirectoryRequiresManifest`；`coverageMissingRangeFilledWithSilence`；`neverActiveRoleOmittedFromTracks`；`beforePublishSeesReservedFinalURLAndHashes`；`beforePublishFailureRetainsStageAndDoesNotPublish`；`publishPreparedAdoptsVerifiedStageAfterCrash`；`publishPreparedRejectsSymlinkOrHashMismatch`；`publishPreparedExistingFinalVerifiesAndAdopts`；`publishPreparedHardlinkSourceNotDeletedWhileLeased`；`collisionUsesActualUnderscoreTwoPath`；`publisherURLMismatchFailsClosed`；`sealFailureRetainsStagingAndNeverOverwrites`；`cancelledSealKeepsSourcesAndPublishesNothing`；`videoChunksArePassthroughOnly`；`concurrentSealCallsRunOneAtATime`。

**Steps:** 失败测试 → encoder/seal/hook → 重跑两过滤器 → 记录 `T08`；P0-4 听测/真实 T17 标 `not-run`。

### Task 9 — 恢复账本、索引、预览租约与真实组合根

**Files:**
- Create: `Packages/CaptureCore/Sources/Recording/RecordingSessionLedger.swift`
- Create: `Packages/CaptureCore/Sources/Recording/RecordingIndexRecord.swift`
- Create: `Packages/CaptureCore/Sources/Recording/RecordingPreviewService.swift`
- Create: `Packages/CaptureCore/Sources/Recording/RecordingPortableMetadata.swift`
- Create: `Packages/CaptureCore/Sources/Recording/RecordingSessionPipeline.swift`（含 `LedgerCheckpointSink`、`LedgerPublicationHook`、`RecordingSpaceGating` 协议、`RecordingPipelineRoots`、`RecordingAudioPipelineFactory`）
- Test: `RecordingSessionLedgerTests.swift`、`RecordingPreviewServiceTests.swift`、`RecordingPipelineIntegrationTests.swift`（同目录）

**Interfaces:** `RecordingSessionRecord`、`PublishedSegment`（含 optional `videoURL`/`videoTrackIndex`，音频-only nil；`files`/`trackMap` 仍只放音频角色）、`PublishedSegmentState`、`RecoverableSession`；`RecordingSessionLedger`（单 session actor；`init(sessionRoot:indexURL:sessionID:readOnly:)`、register/commit/recordPublishIntent/markPublished/rebuildIndex、`snapshot()`、`makePreviewService()`、`static openExisting(...)`、`static publishedSessions(in:indexURL:)`、`static recoverableSessions(in:indexURL:)`）；`RecordingPublishIntent`；`PreviewLease`；`RecordingPortableMetadata.embed/read`；`RecordingSpaceGating`；`RecordingPipelineRoots`（`public init(sessionRoot:indexURL:outputDirectory:)`）；`RecordingAudioPipelineFactory.make(configuration:roots:spaceGate:) throws -> RecordingSessionPipeline`（T9 唯一生产工厂，startAudio 时构造）；`RecordingSessionPipeline`（init 显式接收同一个 `ledger` + coordinator/seal/spaceGate/engineFactory；公开只读 `ledger`/`snapshot`/`makePreviewService`；`resumePublish`）。
- **journal 全量**：`LedgerCheckpointSink.commitCheckpoint()` 调 coordinator `commitAvailableCheckpoints()`，按段序逐条 `ledger.commit`，返回最后一条（无新 commit 时返回缓存最后一条，否则 `.emptyCheckpoint`）；一次 checkpoint 不得只 journal 最后一个或漏旧段。journal append single-flight，记录 sequence/hash chain；index schema 2 仅缓存。
- **发布顺序**：stage 验证 → `publishIntent` journal+fsync → T3 rename → `published` journal+fsync → index 更新 → 仅本事务 owned+已替代材料 GC。`LedgerPublicationHook` 用 candidate 的 reservedFinalURL/staging/hashes 持久化；hook 失败 T8 不 publish。
- **恢复**：按 checkpointID/segmentID 去重；final 存在且 segmentID/hash 验证通过则直接补 `published`；只有同名 staging 时验证 segmentID/hash 后经 `resumePublish(segmentID:)` 调 T8 `publishPrepared` 重试（不自动 rename、不猜 `_2`）；碰撞 final 或 hash 不匹配不采用、不删除；两者都无/不匹配则 `failedRecoverable`；published 缺 index 只 rebuild；未知更高 schema 只读；路径逃逸/缺文件标 missing。
- **组合根/预览**：pipeline 用 batch journal，段关闭后 max 1 seal 后台执行，录制继续；start 先 `spaceGate.preflightStart`，拒绝则不 register/不建 media；stop 用 `isFinal:true` 关尾段；preview lease 可指向已关闭 checkpoint/已发布 segment，未释放/未过期 GC 不删；preview gain 局部，不写 ledger/manifest/export plan。
- **测试**：`batchCommitJournalsEveryOpenSegmentCommit`；`commitCheckpointDoesNotLoseOlderSegment`；`publishIntentBeforeRenameAndHookFailureKeepsStage`；`collisionRecoveryDoesNotClaimOtherFinal`；`stageOnlyRecoveryResumesViaPublishPrepared`；`recoveryIntentSymlinkOrHashMismatchFailsClosed`；`leasedSourceSurvivesHardlinkPublish`；`journalReplayIsIdempotent`；`publishCrashAfterRenameBeforeIndexAdoptsExisting`；`unknownNewerSchemaIsReadOnly`；`pathEscapeAndSymlinkRejected`；`missingFileKeepsRecord`；`previewLeaseBlocksGC`；`publishedSessionsListCompletedRecordAndPreviewWithSameLedger`；`readOnlyOpenDoesNotWriteJournalOrRepair`；`pipelineStopIsIdempotentAndSealsTail`；`checkpointCadenceCommitsBefore300s`；`pipelineIntegrationRealEngineToCAFToSealToLedger`（真实 CAF/AAC，非 TCC）。

### Task 10 — 空间预算、backlog 与真实 pipeline wiring

**Files:**
- Create: `Packages/CaptureCore/Sources/Recording/RecordingSpaceBudget.swift`
- Create: `Packages/CaptureCore/Sources/Recording/RecordingBacklogPolicy.swift`
- Create: `Packages/CaptureCore/Sources/Recording/RecordingPipelineSpaceGate.swift`（实现 T9 `RecordingSpaceGating`）
- Test: `RecordingSpaceBudgetTests.swift`、`RecordingPipelineSpaceGateTests.swift`（同目录）
- Read-only: `Packages/CaptureCore/Sources/Audio/AudioRecordingEngine.swift`（T6 合成注入 seam；不改生产行为，缺 seam 则停/报告）

**Interfaces:** `RecordingStorageConfiguration { kind, layout, channelCountByRole, bitRate, videoBitsPerSecond? }`；`RecordingSpaceBudget.requiredBytes(config:seconds:)`、`.preflight(recordingRoot:recoveryRoot:)`、`.shouldStop(...)`；`RecordingBacklogPolicy`（capture/checkpoint > seal > export/thumbnail、max 1 seal、高低水位滞回）；`RecordingPipelineSpaceGate`（真实 T9 gate：预检拒绝起录、checkpoint 后低空间安全 stop、Seal admission、状态流）。状态含 required/available/backlog/checkpointAge/state/reason；双卷检查，volume capacity 不可用 fail-closed；视频按 `videoBitsPerSecond/8×秒 + Seal 读+写峰值`，VBR 不当绝对上限。
- **真实 wiring**：T9 pipeline `start` 前调用 `preflightStart`，拒绝则不建 session/媒体；每次 checkpoint 后调用 `checkpointCommitted`，`.stopping` 触发安全 stop 并保留已提交尾；Seal 前 `admitSeal`，`defer` 只推迟 Seal、capture 继续，`stop` 安全停；状态流显示 backlog/低空间。max 1 由 pipeline/task 与 T8 gate 共同保证，不能只写常量。
- **T6 seam**：T10 测试用实际 T9 pipeline + T6 已有确定性合成注入 seam；若 T6 未提供，停并记录 interface request，不改 T6 生产行为。

**Tests:** `requiredBytesMatchesDecimalGB`（单轨 0.6912 GB/h、0.67968 GB/59m；分轨 1.0368/1.01952）；`lowSpacePreflightDeniesStart`（假 volume provider + 实际 pipeline，无 media）；`lowSpaceAfterCheckpointStopsSafely`（保留 committed tail）；`sealAdmissionDefersSecondSealButCaptureContinues`；`normalMultiSegmentRecordingNotBlockedBySeal`（实际 pipeline，连续段，max 1）；`spaceStatusStreamReportsBacklog`；`hysteresisDoesNotFlap`；`diskFullCancelKeepsOwnedFilesAndNeverOverwrites`（与 T8/T9 联测）。

## 4. 测试、长跑与证据边界

- **合成真实框架**：用 AVAudioFile 写真实 CAF、AVAssetWriter/AVAssetReader 编解码真实 m4a，正弦/脉冲/扫频核对；不启动 SCK/麦克风，不需要 TCC/GUI/签名。
- **短边界模拟**：机制测试可用 8 kHz、短 boundary/checkpoint 覆盖拆分、守恒、恢复；这是机制证据，不是 59 分钟漂移/资源证据。
- **长跑/真机**：真正 59 分钟、2 小时、8 小时、历史 macOS、真实设备/断盘/断电未跑，标 `not-run`/`blocked`，留最终验收；不得作为 P3 开发前置，不得把短测写成已通过长跑。
- **crash 点**：T7 在 close/fsync/sidecar 前后；T9 在 journal append/fsync、publishIntent、rename、index、GC 前后注入抛错并重建；真实 kill/P0-7 另列。
- **证据**：每个 T07–T10 用母计划 §2.1，allowlist 只含本任务 Files；start/end 内容镜像 + SHA-256、tracked diff、未跟踪全文 `--no-index` diff、缺失/新增清单；报告/review/log 路径同 Task 7；不提交、不 push、不清理。T3 状态记录为 DONE/327 tests、fix round1 限定复核 active，不写全完、不读源码。

## 5. P3 出口门禁

- [ ] T7/T8/T9/T10 定向测试 GREEN；真实 CAF→AAC→Seal→ledger→preview 集成 GREEN；known-fail 按基线披露。
- [ ] batch journal 无“只记最后一个/漏旧段”；publishIntent 在 rename 前持久化；hook 失败无 publish；collision 使用 T3 实际 `_2` 路径。
- [ ] 单轨仅 mixed、多轨仅 system/mic、每角色一 m4a、单文件无外部 manifest、多轨 manifest 必有；视频 seam 不重编码。
- [ ] T10 实际 pipeline 预检拒绝/低空间 stop/Seal backlog/状态流有测试，normal 多段不被 Seal 堵住；max 1 非常量。
- [ ] coverage 显式 missing ranges；时间守恒按 input+writer silence 与 committed+missing 两层断言。
- [ ] 真实断电/强杀、59 分钟/2h/8h、历史 OS 未跑项明确 `not-run`/`blocked`；P0-4/5/7/10/11 通过前不声称最终验收。
- P0 映射：P0-4↔T8；P0-5↔T17；P0-7↔T7/T9；P0-10↔T8/T9；P0-11↔T10。

## 6. Review Focus（最易被真实输入击穿）

1. 多 sink 跨边界时只 journal 最后一个 commit，或旧段 commit 丢失/重复。
2. `beforePublish` 在 rename 后才执行，或 reserved `_2` 与实际发布路径不一致。
3. 角色停止后 coverage 缺 missing range，Seal 让后续来源前移。
4. T10 只算预算不接线：起录不拒绝、低空间不停、Seal backlog 堵 capture。
5. 单文件强制外部 manifest，或 AAC priming/remainder 与有效范围不一致。

## 7. 停止条件

- 需要改母计划/spec/T1 协议/`RecordingOutputTransaction.swift`/P2 源码，或 allowlist 外文件 → 停，写 `review/p3-preparation-notes.md` 或任务报告，交主会话裁定。
- 需要真实用户目录/真实盘/权限/GUI/签名/提交 → 停；P0 全矩阵未跑不构成开发阻塞。
- 出现 0 tests、known-fail 洗绿、fake 链路冒充真实 engine→CAF→Seal→ledger、未测长跑写成已通过 → 停。
