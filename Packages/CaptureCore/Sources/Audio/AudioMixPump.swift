// swiftlint:disable file_length
import Foundation

/// One immutable set of source rings and route metadata for a pump update.
public struct AudioPumpInputs: Sendable {
  /// Producer ring per source role.
  public let rings: [RecordingTrackRole: AudioSourceRingBuffer]
  /// Actual native format of each ring, copied from the T5 generation.
  public let formatsByRole: [RecordingTrackRole: AudioSourceFormat]
  /// Roles that are active from ``routeBoundarySample`` onward.
  public let activeRoles: Set<RecordingTrackRole>
  /// Roles that have been enabled at any point in this session.
  public let everEnabledRoles: Set<RecordingTrackRole>
  /// Generation identity per source ring for retirement checks.
  public let generationIDs: [RecordingTrackRole: UUID]
  /// First session sample at which these inputs become active.
  public let routeBoundarySample: Int64?

  /// Creates a pump input snapshot.
  ///
  /// - Parameters:
  ///   - rings: Producer ring per source role.
  ///   - formatsByRole: Actual native format of each ring.
  ///   - activeRoles: Roles active from the boundary onward.
  ///   - everEnabledRoles: Roles enabled at any point in the session.
  ///   - generationIDs: Generation identity per source ring.
  ///   - routeBoundarySample: First session sample for these inputs.
  public init(
    rings: [RecordingTrackRole: AudioSourceRingBuffer],
    formatsByRole: [RecordingTrackRole: AudioSourceFormat],
    activeRoles: Set<RecordingTrackRole>,
    everEnabledRoles: Set<RecordingTrackRole>,
    generationIDs: [RecordingTrackRole: UUID],
    routeBoundarySample: Int64? = nil
  ) {
    self.rings = rings
    self.formatsByRole = formatsByRole
    self.activeRoles = activeRoles
    self.everEnabledRoles = everEnabledRoles
    self.generationIDs = generationIDs
    self.routeBoundarySample = routeBoundarySample
  }
}

/// One pump output tick on the fixed 48 kHz session grid.
public struct AudioPumpTick: Sendable {
  /// Session range covered by every block in this tick.
  public let range: SampleRange
  /// Host time of the tick's first session sample.
  public let hostTime: UInt64
  /// `.mixed` for single-track layout, or `.system`/`.microphone` for separate tracks.
  public let blocks: [RecordingTrackRole: AudioPCMBlock]
  /// Session frames filled with silence because a role's source was missing or late.
  public let gapFramesByRole: [RecordingTrackRole: Int]
  /// Whether every block in the tick is digital silence.
  public let isSilence: Bool
  /// RMS level from the actual system-audio input PCM, clamped to `0...1`.
  public let systemLevel: Float
  /// RMS level from the actual microphone input PCM, clamped to `0...1`.
  public let micLevel: Float

  /// Creates a pump tick.
  ///
  /// - Parameters:
  ///   - range: Session range covered by every block.
  ///   - hostTime: Host time of the tick's first sample.
  ///   - blocks: Output blocks keyed by output role.
  ///   - gapFramesByRole: Session frames filled with silence per source role.
  ///   - isSilence: Whether every block is silence.
  public init(
    range: SampleRange,
    hostTime: UInt64,
    blocks: [RecordingTrackRole: AudioPCMBlock],
    gapFramesByRole: [RecordingTrackRole: Int],
    isSilence: Bool,
    systemLevel: Float = 0,
    micLevel: Float = 0
  ) {
    self.range = range
    self.hostTime = hostTime
    self.blocks = blocks
    self.gapFramesByRole = gapFramesByRole
    self.isSilence = isSilence
    self.systemLevel = Self.clampedLevel(systemLevel)
    self.micLevel = Self.clampedLevel(micLevel)
  }

  private static func clampedLevel(_ value: Float) -> Float {
    guard value.isFinite else { return 0 }
    return min(max(value, 0), 1)
  }
}

/// A control-side snapshot of pump counters and resampler state.
public struct AudioPumpDiagnosticsSnapshot: Sendable {
  /// Number of emitted ticks.
  public let tickCount: Int64
  /// Ticks cut short by a route boundary.
  public let shortTickCount: Int64
  /// Ticks whose output was entirely silent.
  public let silenceTickCount: Int64
  /// Session frames filled with silence per source role.
  public let gapFramesByRole: [RecordingTrackRole: Int64]
  /// Source frames discarded when a generation retired or a ring overflowed.
  public let droppedFramesByRole: [RecordingTrackRole: Int64]
  /// Current resampler watermark per role.
  public let resamplerWatermarkSecondsByRole: [RecordingTrackRole: Double]
  /// Current bounded correction per role.
  public let correctionPPMByRole: [RecordingTrackRole: Double]
  /// Current generation identity per role.
  public let generationIDsByRole: [RecordingTrackRole: UUID]

  /// Creates a diagnostics snapshot.
  ///
  /// - Parameters:
  ///   - tickCount: Number of emitted ticks.
  ///   - shortTickCount: Ticks cut short by a route boundary.
  ///   - silenceTickCount: Entirely silent ticks.
  ///   - gapFramesByRole: Silence-filled session frames per role.
  ///   - droppedFramesByRole: Discarded source frames per role.
  ///   - resamplerWatermarkSecondsByRole: Current resampler watermark per role.
  ///   - correctionPPMByRole: Current correction per role.
  ///   - generationIDsByRole: Current generation identity per role.
  public init(
    tickCount: Int64,
    shortTickCount: Int64,
    silenceTickCount: Int64,
    gapFramesByRole: [RecordingTrackRole: Int64],
    droppedFramesByRole: [RecordingTrackRole: Int64],
    resamplerWatermarkSecondsByRole: [RecordingTrackRole: Double],
    correctionPPMByRole: [RecordingTrackRole: Double],
    generationIDsByRole: [RecordingTrackRole: UUID]
  ) {
    self.tickCount = tickCount
    self.shortTickCount = shortTickCount
    self.silenceTickCount = silenceTickCount
    self.gapFramesByRole = gapFramesByRole
    self.droppedFramesByRole = droppedFramesByRole
    self.resamplerWatermarkSecondsByRole = resamplerWatermarkSecondsByRole
    self.correctionPPMByRole = correctionPPMByRole
    self.generationIDsByRole = generationIDsByRole
  }
}

/// A pump configuration or input failure.
public enum AudioPumpError: Error, Equatable {
  /// The pump has not been started.
  case notStarted
  /// The block frame count is not positive.
  case invalidBlockFrames
  /// A role is not a source role.
  case invalidRole(RecordingTrackRole)
  /// A ring format cannot be used.
  case invalidFormat(RecordingTrackRole)
  /// A ring has no matching native format.
  case missingFormat(RecordingTrackRole)
  /// An active ring has no generation identity.
  case missingGeneration(RecordingTrackRole)
  /// A route boundary is negative or already in the past.
  case invalidRouteBoundary
}

/// Reads native source rings, resamples each role independently, and emits fixed 48 kHz ticks.
///
/// A tick is only produced when its host-time end has been reached. Repeating the
/// same host time never advances the session grid. Missing active sources and
/// short producer underruns become equal-length silence without stopping the clock.
public final class AudioMixPump: @unchecked Sendable {
  private struct QueuedAudio {
    var channels: [[Float]]
    var gapFrames: Int
  }

  private struct Pipeline {
    let role: RecordingTrackRole
    let generationID: UUID
    let ring: AudioSourceRingBuffer
    let format: AudioSourceFormat
    let activationSample: Int64
    var resampler: AudioDriftResampler
    var queue: [QueuedAudio] = []
    var queuedFrames = 0
    var pendingGapFrames = 0
    var sourceGapFrames: Int64 = 0
  }

  private struct PendingInputs {
    let inputs: AudioPumpInputs
    let boundary: Int64
  }

  private let clock: AudioSampleClock
  private let layout: AudioOutputLayout
  private let blockFrames: Int
  private let channelCountByRole: [RecordingTrackRole: Int]
  private let targetWatermarkSeconds: Double
  private let maxCorrectionPPM: Int
  private let initialPolicy: AudioMixPolicy
  private let lock = NSLock()

  private var policy: AudioMixPolicy
  private var inputs: AudioPumpInputs?
  private var pendingInputs: PendingInputs?
  private var pipelines: [RecordingTrackRole: Pipeline] = [:]
  private var started = false
  private var nextSample: Int64 = 0
  private var tickCount: Int64 = 0
  private var shortTickCount: Int64 = 0
  private var silenceTickCount: Int64 = 0
  private var gapFramesByRole: [RecordingTrackRole: Int64] = [:]
  private var droppedFramesByRole: [RecordingTrackRole: Int64] = [:]
  private var capturedSourceFrames: Int64 = 0

  /// Creates a pump for one recording layout.
  ///
  /// - Parameters:
  ///   - clock: Session clock whose sample zero is the recording epoch.
  ///   - policy: Real Task 4 mix policy.
  ///   - layout: Mixed or separate-track output.
  ///   - blockFrames: Nominal session frames per tick; defaults to 480.
  ///   - channelCountByRole: Optional session channel count per output role.
  ///   - targetWatermarkSeconds: Resampler watermark target; defaults to one 480-frame tick (10ms).
  ///   - maxCorrectionPPM: Resampler correction bound.
  public init(
    clock: AudioSampleClock,
    policy: AudioMixPolicy,
    layout: AudioOutputLayout,
    blockFrames: Int = 480,
    channelCountByRole: [RecordingTrackRole: Int] = [:],
    targetWatermarkSeconds: Double = 0.01,
    maxCorrectionPPM: Int = 300
  ) {
    self.clock = clock
    self.policy = policy
    self.initialPolicy = policy
    self.layout = layout
    self.blockFrames = blockFrames
    self.channelCountByRole = channelCountByRole
    self.targetWatermarkSeconds = targetWatermarkSeconds
    self.maxCorrectionPPM = maxCorrectionPPM
  }

  /// Starts a fresh session grid at sample zero.
  public func start() {
    lock.lock()
    defer { lock.unlock() }
    inputs = nil
    pendingInputs = nil
    pipelines = [:]
    started = true
    nextSample = 0
    tickCount = 0
    shortTickCount = 0
    silenceTickCount = 0
    gapFramesByRole = [:]
    droppedFramesByRole = [:]
    capturedSourceFrames = 0
    policy = initialPolicy
  }

  /// Stops producing ticks; pipelines remain drainable through ``drainForStop(joinedGenerationIDs:)``.
  public func stop() {
    lock.lock()
    defer { lock.unlock() }
    started = false
    pendingInputs = nil
  }

  /// Replaces the source inputs, optionally at a future route boundary.
  ///
  /// - Parameter inputs: New rings, formats, roles, and generations.
  /// - Throws: ``AudioPumpError`` when the snapshot is inconsistent.
  public func updateInputs(_ inputs: AudioPumpInputs) throws {
    lock.lock()
    defer { lock.unlock() }
    guard started else {
      throw AudioPumpError.notStarted
    }
    try validate(inputs, nextSample: nextSample)
    if let boundary = inputs.routeBoundarySample, boundary > nextSample {
      pendingInputs = PendingInputs(inputs: inputs, boundary: boundary)
      return
    }
    applyInputsLocked(inputs, activationSample: nextSample)
  }

  /// Returns the next tick when its host-time end has been reached.
  ///
  /// - Parameter hostTime: Current monotonic host tick in the clock's domain.
  /// - Returns: One due tick, or `nil` before the next range is due.
  /// - Throws: ``AudioPumpError`` when buffered audio cannot be resampled.
  public func nextTick(for hostTime: UInt64) throws -> AudioPumpTick? {
    lock.lock()
    defer { lock.unlock() }
    guard started, inputs != nil else {
      return nil
    }
    guard let hostSample = clock.sampleIndex(forHostTime: hostTime) else {
      return nil
    }
    applyDuePendingInputsLocked()
    let frames = tickFramesLocked()
    guard hostSample >= nextSample + Int64(frames) else {
      return nil
    }
    let tickHostTime = clock.hostTime(forSample: nextSample) ?? hostTime
    let tick = try makeTickLocked(frames: frames, hostTime: tickHostTime, deliverable: nil)
    nextSample += Int64(frames)
    tickCount += 1
    if frames < blockFrames {
      shortTickCount += 1
    }
    if tick.isSilence {
      silenceTickCount += 1
    }
    for (role, gap) in tick.gapFramesByRole {
      gapFramesByRole[role, default: 0] += Int64(gap)
    }
    applyDuePendingInputsLocked()
    return tick
  }

  /// Drains joined ring tails after sources stop.
  ///
  /// - Parameter joinedGenerationIDs: Generations whose producers joined and rings may be finalized.
  /// - Returns: Short and full ticks continuing the session range.
  /// - Throws: ``AudioPumpError`` when a tail cannot be resampled.
  internal func drainForStop(joinedGenerationIDs: Set<UUID>) throws -> [AudioPumpTick] {
    lock.lock()
    defer { lock.unlock() }
    var deliverable: Set<RecordingTrackRole> = []
    for role in [RecordingTrackRole.system, .microphone] {
      guard var pipeline = pipelines[role],
        joinedGenerationIDs.contains(pipeline.generationID)
      else {
        continue
      }
      try drainPipelineLocked(&pipeline)
      if let tail = try? pipeline.resampler.flush() {
        appendBatchLocked(tail.blocks, gap: tail.gapFrames, to: &pipeline)
      }
      pipelines[role] = pipeline
      deliverable.insert(role)
    }
    var ticks: [AudioPumpTick] = []
    while true {
      let maximum = deliverable.compactMap { pipelines[$0]?.queuedFrames }.max() ?? 0
      guard maximum > 0 else {
        break
      }
      let frames = min(blockFrames, maximum)
      let tick = try makeTickLocked(
        frames: frames,
        hostTime: clock.hostTime(forSample: nextSample) ?? 0,
        deliverable: deliverable
      )
      nextSample += Int64(frames)
      tickCount += 1
      if frames < blockFrames {
        shortTickCount += 1
      }
      if tick.isSilence {
        silenceTickCount += 1
      }
      for (role, gap) in tick.gapFramesByRole {
        gapFramesByRole[role, default: 0] += Int64(gap)
      }
      ticks.append(tick)
    }
    return ticks
  }

  /// A control-side snapshot; fields are not required to describe one instant.
  public var diagnostics: AudioPumpDiagnosticsSnapshot {
    lock.lock()
    defer { lock.unlock() }
    var watermarks: [RecordingTrackRole: Double] = [:]
    var corrections: [RecordingTrackRole: Double] = [:]
    var generations: [RecordingTrackRole: UUID] = [:]
    for (role, pipeline) in pipelines {
      let values = pipeline.resampler.diagnosticValues
      watermarks[role] = values.watermarkSeconds
      corrections[role] = values.correctionPPM
      generations[role] = pipeline.generationID
    }
    if let inputs {
      for (role, id) in inputs.generationIDs where generations[role] == nil {
        generations[role] = id
      }
    }
    return AudioPumpDiagnosticsSnapshot(
      tickCount: tickCount,
      shortTickCount: shortTickCount,
      silenceTickCount: silenceTickCount,
      gapFramesByRole: gapFramesByRole,
      droppedFramesByRole: droppedFramesByRole,
      resamplerWatermarkSecondsByRole: watermarks,
      correctionPPMByRole: corrections,
      generationIDsByRole: generations
    )
  }

  /// The next session sample that will be emitted.
  internal var nextSampleIndex: Int64 {
    lock.lock()
    defer { lock.unlock() }
    return nextSample
  }

  /// Frames actually read from captured source buffers so far.
  ///
  /// Frames synthesized to fill a tick when a source has no data are excluded,
  /// as are clock-advanced ticks with no source frames. An all-zero captured
  /// sample still counts because it came from the source buffer.
  internal var capturedSourceFrameCount: Int64 {
    lock.lock()
    defer { lock.unlock() }
    return capturedSourceFrames
  }
}

extension AudioMixPump {
  private func validate(_ inputs: AudioPumpInputs, nextSample: Int64) throws {
    guard blockFrames > 0 else {
      throw AudioPumpError.invalidBlockFrames
    }
    try validateRoles(inputs)
    try validateFormats(inputs)
    if let boundary = inputs.routeBoundarySample {
      guard boundary >= nextSample else {
        throw AudioPumpError.invalidRouteBoundary
      }
    }
  }

  private func validateRoles(_ inputs: AudioPumpInputs) throws {
    for role in inputs.rings.keys {
      guard role == .system || role == .microphone else {
        throw AudioPumpError.invalidRole(role)
      }
    }
    for role in inputs.activeRoles.union(inputs.everEnabledRoles) {
      guard role == .system || role == .microphone else {
        throw AudioPumpError.invalidRole(role)
      }
    }
  }

  private func validateFormats(_ inputs: AudioPumpInputs) throws {
    for (role, format) in inputs.formatsByRole {
      guard role == .system || role == .microphone else {
        throw AudioPumpError.invalidRole(role)
      }
      guard format.sampleRate > 0, format.sampleRate <= 768_000,
        format.channelCount == 1 || format.channelCount == 2
      else {
        throw AudioPumpError.invalidFormat(role)
      }
    }
    for role in inputs.rings.keys {
      guard inputs.formatsByRole[role] != nil else {
        throw AudioPumpError.missingFormat(role)
      }
      guard inputs.generationIDs[role] != nil else {
        throw AudioPumpError.missingGeneration(role)
      }
    }
  }

  private func applyDuePendingInputsLocked() {
    guard let pending = pendingInputs, pending.boundary <= nextSample else {
      return
    }
    applyInputsLocked(pending.inputs, activationSample: pending.boundary)
    pendingInputs = nil
  }

  private func applyInputsLocked(_ newInputs: AudioPumpInputs, activationSample: Int64) {
    for role in Array(pipelines.keys) {
      guard let pipeline = pipelines[role] else {
        continue
      }
      let ring = newInputs.rings[role]
      let sameRing = ring === pipeline.ring
      let sameGeneration = newInputs.generationIDs[role] == pipeline.generationID
      if !sameRing || !sameGeneration {
        dropPipelineLocked(role)
      }
    }
    for (role, ring) in newInputs.rings {
      guard pipelines[role] == nil, let format = newInputs.formatsByRole[role],
        let generationID = newInputs.generationIDs[role],
        !ring.isClosedAndEmpty
      else {
        continue
      }
      pipelines[role] = Pipeline(
        role: role,
        generationID: generationID,
        ring: ring,
        format: format,
        activationSample: activationSample,
        resampler: AudioDriftResampler(
          inputSampleRate: format.sampleRate,
          targetWatermarkSeconds: targetWatermarkSeconds,
          maxCorrectionPPM: maxCorrectionPPM
        )
      )
    }
    inputs = newInputs
  }

  private func dropPipelineLocked(_ role: RecordingTrackRole) {
    guard let pipeline = pipelines.removeValue(forKey: role) else {
      return
    }
    var dropped = pipeline.queuedFrames + pipeline.pendingGapFrames
    if let tail = try? pipeline.resampler.flush() {
      dropped += tail.blocks.reduce(0) { $0 + $1.frameCount }
    }
    droppedFramesByRole[role, default: 0] += Int64(dropped + Int(pipeline.sourceGapFrames))
  }

  private func tickFramesLocked() -> Int {
    guard let pending = pendingInputs, pending.boundary > nextSample,
      pending.boundary < nextSample + Int64(blockFrames)
    else {
      return blockFrames
    }
    return max(1, Int(pending.boundary - nextSample))
  }

  private func readMoreLocked(_ pipeline: inout Pipeline, minimumOutputFrames: Int) throws {
    let inputRate = pipeline.format.sampleRate
    while pipeline.queuedFrames < minimumOutputFrames {
      let need = minimumOutputFrames - pipeline.queuedFrames
      let scaled = Double(need) * Double(inputRate) / 48_000 * 1.02
      let maximum = max(64, min(16_384, Int(scaled.rounded(.up)) + 8))
      let read = pipeline.ring.read(maxFrames: maximum)
      if let block = read.block {
        capturedSourceFrames += Int64(block.frameCount)
        if let trimmed = trimmedForActivation(block, pipeline: pipeline) {
          let batch = try pipeline.resampler.process(trimmed)
          appendBatchLocked(batch.blocks, gap: batch.sessionGapFrames, to: &pipeline)
          pipeline.sourceGapFrames += Int64(batch.sessionGapFrames)
        }
        continue
      }
      if read.gapFrames > 0, read.isClosedAndEmpty {
        let sessionGap = pipeline.resampler.sessionGapFrames(forInputFrames: read.gapFrames)
        let blocks = try pipeline.resampler.appendTerminalGap(read.gapFrames)
        appendBatchLocked(blocks, gap: sessionGap, to: &pipeline)
        pipeline.sourceGapFrames += Int64(sessionGap)
      }
      break
    }
  }

  private func trimmedForActivation(
    _ block: AudioPCMBlock,
    pipeline: Pipeline
  ) -> AudioPCMBlock? {
    guard pipeline.activationSample > 0,
      let startSession = clock.sampleIndex(forHostTime: block.hostTime)
    else {
      return block
    }
    let ahead = pipeline.activationSample - startSession
    guard ahead > 0 else {
      return block
    }
    let inputRate = pipeline.format.sampleRate
    let drop = Int((Double(ahead) * Double(inputRate) / 48_000).rounded(.up))
    guard drop < block.frameCount else {
      return nil
    }
    let remaining = block.frameCount - drop
    let channels = block.channels.map { Array($0.dropFirst(drop)) }
    return AudioPCMBlock(
      role: block.role,
      range: SampleRange(
        startSample: block.range.startSample + Int64(drop),
        sampleCount: Int64(remaining)
      ),
      sampleRate: block.sampleRate,
      channelCount: block.channelCount,
      frameCount: remaining,
      hostTime: block.hostTime,
      channels: channels,
      isSilence: channels.allSatisfy { $0.allSatisfy { $0 == 0 } }
    )
  }

  private func appendBatchLocked(
    _ blocks: [AudioPCMBlock],
    gap: Int,
    to pipeline: inout Pipeline
  ) {
    var pendingGap = pipeline.pendingGapFrames + gap
    for (index, block) in blocks.enumerated() {
      let entryGap = index == 0 ? pendingGap : 0
      pendingGap = 0
      pipeline.queue.append(QueuedAudio(channels: block.channels, gapFrames: entryGap))
    }
    pipeline.pendingGapFrames = pendingGap
    pipeline.queuedFrames = pipeline.queue.reduce(0) { $0 + $1.channels[0].count }
  }

  private func popFramesLocked(_ pipeline: inout Pipeline, count: Int) -> (channels: [[Float]], gap: Int) {
    let channelCount = pipeline.queue.first?.channels.count ?? pipeline.format.channelCount
    var channels = (0..<channelCount).map { _ in [Float]() }
    var gap = 0
    var remaining = count
    while remaining > 0, !pipeline.queue.isEmpty {
      var head = pipeline.queue[0]
      let available = head.channels[0].count
      let take = min(available, remaining)
      gap += head.gapFrames + pipeline.pendingGapFrames
      pipeline.pendingGapFrames = 0
      head.gapFrames = 0
      for channel in head.channels.indices {
        channels[channel].append(contentsOf: head.channels[channel].prefix(take))
      }
      if take == available {
        pipeline.queue.removeFirst()
      } else {
        head.channels = head.channels.map { Array($0.dropFirst(take)) }
        pipeline.queue[0] = head
      }
      remaining -= take
    }
    pipeline.queuedFrames -= (count - remaining)
    if remaining > 0 {
      let silence = Self.silenceChannels(channels: channelCount, frames: remaining)
      if channels.isEmpty {
        channels = silence
      } else {
        for channel in channels.indices {
          channels[channel].append(contentsOf: silence[min(channel, silence.count - 1)])
        }
      }
      gap += remaining
    }
    return (channels, gap)
  }

  private struct TickAssembly {
    let frames: Int
    let range: SampleRange
    let hostTime: UInt64
    let deliverable: Set<RecordingTrackRole>?
  }

  private func makeTickLocked(
    frames: Int,
    hostTime: UInt64,
    deliverable: Set<RecordingTrackRole>?
  ) throws -> AudioPumpTick {
    let range = SampleRange(startSample: nextSample, sampleCount: Int64(frames))
    let assembly = TickAssembly(
      frames: frames,
      range: range,
      hostTime: hostTime,
      deliverable: deliverable
    )
    var blocks: [RecordingTrackRole: AudioPCMBlock] = [:]
    var gaps: [RecordingTrackRole: Int] = [:]
    var inputLevels: [RecordingTrackRole: Float] = [:]
    switch layout {
    case .mixed:
      try makeMixedTickLocked(assembly, blocks: &blocks, gaps: &gaps, inputLevels: &inputLevels)
    case .separateTracks:
      try makeSeparateTickLocked(assembly, blocks: &blocks, gaps: &gaps, inputLevels: &inputLevels)
    }
    let isSilence = blocks.values.allSatisfy(\.isSilence)
    return AudioPumpTick(
      range: range,
      hostTime: hostTime,
      blocks: blocks,
      gapFramesByRole: gaps,
      isSilence: isSilence,
      systemLevel: inputLevels[.system] ?? 0,
      micLevel: inputLevels[.microphone] ?? 0
    )
  }

  private func makeMixedTickLocked(
    _ assembly: TickAssembly,
    blocks: inout [RecordingTrackRole: AudioPCMBlock],
    gaps: inout [RecordingTrackRole: Int],
    inputLevels: inout [RecordingTrackRole: Float]
  ) throws {
    var systemBlock: AudioPCMBlock?
    var microphoneBlock: AudioPCMBlock?
    for role in [RecordingTrackRole.system, .microphone] where isActiveLocked(role) {
      let result = try sourceBlockLocked(role: role, assembly: assembly)
      inputLevels[role] = result.level
      if result.gap > 0 {
        gaps[role] = result.gap
      }
      if role == .system {
        systemBlock = result.block
      } else {
        microphoneBlock = result.block
      }
    }
    guard systemBlock != nil || microphoneBlock != nil else {
      if !everEnabledRolesLocked().isEmpty {
        let target = channelCountByRole[.mixed] ?? 1
        blocks[.mixed] = Self.silenceBlock(
          role: .mixed,
          range: assembly.range,
          hostTime: assembly.hostTime,
          channels: target
        )
      }
      return
    }
    let mixed = try policy.mix(
      system: systemBlock,
      microphone: microphoneBlock,
      systemGainDB: 0,
      microphoneGainDB: 0,
      masterGainDB: 0
    )
    let target = channelCountByRole[.mixed]
    blocks[.mixed] = Self.mapChannels(
      mixed.block,
      to: target,
      range: assembly.range,
      hostTime: assembly.hostTime
    )
  }

  private func makeSeparateTickLocked(
    _ assembly: TickAssembly,
    blocks: inout [RecordingTrackRole: AudioPCMBlock],
    gaps: inout [RecordingTrackRole: Int],
    inputLevels: inout [RecordingTrackRole: Float]
  ) throws {
    for role in [RecordingTrackRole.system, .microphone] where everEnabledRolesLocked().contains(role) {
      let result = try sourceBlockLocked(role: role, assembly: assembly)
      blocks[role] = result.block
      inputLevels[role] = result.level
      if result.gap > 0 {
        gaps[role] = result.gap
      }
    }
  }

  private func sourceBlockLocked(
    role: RecordingTrackRole,
    assembly: TickAssembly
  ) throws -> (block: AudioPCMBlock, gap: Int, level: Float) {
    let target: Int
    if let configured = channelCountByRole[role] {
      target = configured
    } else if let pipeline = pipelines[role] {
      target = pipeline.format.channelCount
    } else {
      target = 1
    }
    guard isActiveLocked(role),
      assembly.deliverable?.contains(role) ?? true,
      var pipeline = pipelines[role]
    else {
      return (
        Self.silenceBlock(
          role: role,
          range: assembly.range,
          hostTime: assembly.hostTime,
          channels: target
        ),
        assembly.frames,
        0
      )
    }
    try readMoreLocked(&pipeline, minimumOutputFrames: assembly.frames)
    let popped = popFramesLocked(&pipeline, count: assembly.frames)
    pipelines[role] = pipeline
    let level = Self.rmsLevel(popped.channels)
    let channels = Self.mapChannels(
      popped.channels,
      frameCount: assembly.frames,
      to: target,
      sourceChannels: pipeline.format.channelCount
    )
    let isSilence = channels.allSatisfy { $0.allSatisfy { $0 == 0 } }
    let block = AudioPCMBlock(
      role: role,
      range: assembly.range,
      sampleRate: 48_000,
      channelCount: channels.count,
      frameCount: assembly.frames,
      hostTime: assembly.hostTime,
      channels: channels,
      isSilence: isSilence
    )
    return (block, popped.gap, level)
  }

  private static func rmsLevel(_ channels: [[Float]]) -> Float {
    var sumSquares = 0.0
    var sampleCount = 0
    for channel in channels {
      for sample in channel {
        let value = sample.isFinite ? Double(sample) : 0
        sumSquares += value * value
        sampleCount += 1
      }
    }
    guard sampleCount > 0 else { return 0 }
    let rms = sqrt(sumSquares / Double(sampleCount))
    guard rms.isFinite else { return 0 }
    return Float(min(max(rms, 0), 1))
  }

  private func isActiveLocked(_ role: RecordingTrackRole) -> Bool {
    inputs?.activeRoles.contains(role) ?? false
  }

  private func everEnabledRolesLocked() -> Set<RecordingTrackRole> {
    guard let inputs else {
      return []
    }
    return inputs.everEnabledRoles.union(inputs.activeRoles)
  }

  private func drainPipelineLocked(_ pipeline: inout Pipeline) throws {
    var idleRounds = 0
    while !pipeline.ring.isClosedAndEmpty {
      let read = pipeline.ring.read(maxFrames: 4_096)
      if let block = read.block {
        capturedSourceFrames += Int64(block.frameCount)
        if let trimmed = trimmedForActivation(block, pipeline: pipeline) {
          let batch = try pipeline.resampler.process(trimmed)
          appendBatchLocked(batch.blocks, gap: batch.sessionGapFrames, to: &pipeline)
          pipeline.sourceGapFrames += Int64(batch.sessionGapFrames)
        }
        idleRounds = 0
        continue
      }
      if read.gapFrames > 0, read.isClosedAndEmpty {
        let sessionGap = pipeline.resampler.sessionGapFrames(forInputFrames: read.gapFrames)
        let blocks = try pipeline.resampler.appendTerminalGap(read.gapFrames)
        appendBatchLocked(blocks, gap: sessionGap, to: &pipeline)
        pipeline.sourceGapFrames += Int64(sessionGap)
        return
      }
      let finalized = pipeline.ring.finishProducing()
      if finalized.producerStillActive {
        return
      }
      if finalized.retainedStagingFrames > 0 {
        idleRounds += 1
        guard idleRounds <= 8 else {
          return
        }
        continue
      }
      if read.block == nil, finalized.flushedFrames == 0 {
        return
      }
    }
  }

  private static func silenceChannels(channels: Int, frames: Int) -> [[Float]] {
    (0..<max(1, channels)).map { _ in [Float](repeating: 0, count: frames) }
  }

  private static func silenceBlock(
    role: RecordingTrackRole,
    range: SampleRange,
    hostTime: UInt64,
    channels: Int
  ) -> AudioPCMBlock {
    let stored = silenceChannels(channels: channels, frames: Int(range.sampleCount))
    return AudioPCMBlock(
      role: role,
      range: range,
      sampleRate: 48_000,
      channelCount: stored.count,
      frameCount: Int(range.sampleCount),
      hostTime: hostTime,
      channels: stored,
      isSilence: true
    )
  }

  private static func mapChannels(
    _ block: AudioPCMBlock,
    to target: Int?,
    range: SampleRange,
    hostTime: UInt64
  ) -> AudioPCMBlock {
    let channels = mapChannels(
      block.channels,
      frameCount: block.frameCount,
      to: target,
      sourceChannels: block.channelCount
    )
    let isSilence = channels.allSatisfy { $0.allSatisfy { $0 == 0 } }
    return AudioPCMBlock(
      role: block.role,
      range: range,
      sampleRate: block.sampleRate,
      channelCount: channels.count,
      frameCount: block.frameCount,
      hostTime: hostTime,
      channels: channels,
      isSilence: isSilence
    )
  }

  private static func mapChannels(
    _ channels: [[Float]],
    frameCount: Int,
    to target: Int?,
    sourceChannels: Int
  ) -> [[Float]] {
    let fallback = channels.isEmpty ? sourceChannels : channels.count
    let desired = target ?? max(1, min(2, fallback))
    if channels.isEmpty {
      return silenceChannels(channels: desired, frames: frameCount)
    }
    if desired == channels.count {
      return channels
    }
    if desired == 2, channels.count == 1 {
      return [channels[0], channels[0]]
    }
    if desired == 1, channels.count >= 2 {
      return [
        (0..<frameCount).map { frame in
          (channels[0][frame] + channels[1][frame]) * 0.5
        },
      ]
    }
    return channels
  }
}
