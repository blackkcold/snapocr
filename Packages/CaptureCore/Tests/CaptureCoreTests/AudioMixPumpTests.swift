import Foundation
import Testing

@testable import CaptureCore

// swiftlint:disable:next type_body_length
struct AudioMixPumpTests {
    private let hostTicksPerSecond: UInt64 = 24_000_000
    private let sampleRate = 48_000

    private func clock() -> AudioSampleClock {
        AudioSampleClock(
            epochHostTime: 0,
            hostTicksPerSecond: hostTicksPerSecond,
            sampleRate: sampleRate
        )
    }

    private func hostTime(forSample sample: Int64) -> UInt64 {
        UInt64(sample) * hostTicksPerSecond / UInt64(sampleRate)
    }

    private func makeRing(
        role: RecordingTrackRole,
        format: AudioSourceFormat = AudioSourceFormat(sampleRate: 48_000, channelCount: 1),
        capacitySeconds: Double = 2.0
    ) throws -> AudioSourceRingBuffer {
        try AudioSourceRingBuffer(
            role: role,
            sampleRate: format.sampleRate,
            channelCount: format.channelCount,
            hostTicksPerSecond: hostTicksPerSecond,
            capacitySeconds: capacitySeconds
        )
    }

    private func write(
        _ channels: [[Float]],
        to ring: AudioSourceRingBuffer,
        hostTime: UInt64 = 0
    ) {
        let frames = channels.first?.count ?? 0
        if channels.count == 1 {
            channels[0].withUnsafeBufferPointer { first in
                _ = ring.write(planar: [first], frameCount: frames, hostTime: hostTime)
            }
        } else {
            channels[0].withUnsafeBufferPointer { first in
                channels[1].withUnsafeBufferPointer { second in
                    _ = ring.write(planar: [first, second], frameCount: frames, hostTime: hostTime)
                }
            }
        }
    }

    private func inputs(
        rings: [RecordingTrackRole: AudioSourceRingBuffer],
        formats: [RecordingTrackRole: AudioSourceFormat],
        active: Set<RecordingTrackRole>,
        everEnabled: Set<RecordingTrackRole>,
        generations: [RecordingTrackRole: UUID],
        boundary: Int64? = nil
    ) -> AudioPumpInputs {
        AudioPumpInputs(
            rings: rings,
            formatsByRole: formats,
            activeRoles: active,
            everEnabledRoles: everEnabled,
            generationIDs: generations,
            routeBoundarySample: boundary
        )
    }

    private func constant(_ value: Float, frames: Int = 480, channels: Int = 1) -> [[Float]] {
        (0..<channels).map { _ in [Float](repeating: value, count: frames) }
    }

    private func makePump(layout: AudioOutputLayout) -> AudioMixPump {
        AudioMixPump(
            clock: clock(),
            policy: AudioMixPolicy(sampleRate: sampleRate),
            layout: layout,
            blockFrames: 480
        )
    }

    @Test func singleTrackProducesOnlyMixedBlock() throws {
        let ring = try makeRing(role: .system, format: AudioSourceFormat(sampleRate: 48_000, channelCount: 2))
        write(constant(0.25, channels: 2), to: ring)
        let pump = makePump(layout: .mixed)
        pump.start()
        try pump.updateInputs(
            inputs(
                rings: [.system: ring],
                formats: [.system: AudioSourceFormat(sampleRate: 48_000, channelCount: 2)],
                active: [.system],
                everEnabled: [.system],
                generations: [.system: UUID()]
            )
        )

        let tick = try #require(try pump.nextTick(for: hostTime(forSample: 480)))

        #expect(Set(tick.blocks.keys) == [.mixed])
        #expect(tick.range == SampleRange(startSample: 0, sampleCount: 480))
        let mixed = try #require(tick.blocks[.mixed])
        #expect(mixed.frameCount == 480)
        #expect(mixed.sampleRate == 48_000)
        #expect(mixed.role == .mixed)
        #expect(abs(mixed.channels[0][10] - 0.25) < 0.000_1)
        #expect(tick.isSilence == false)
    }

    @Test func multiTrackReturnsBothRolesOnTheSameRange() throws {
        let system = try makeRing(role: .system)
        let microphone = try makeRing(role: .microphone)
        write(constant(0.25), to: system)
        write(constant(-0.5), to: microphone)
        let pump = makePump(layout: .separateTracks)
        pump.start()
        try pump.updateInputs(
            inputs(
                rings: [.system: system, .microphone: microphone],
                formats: [
                    .system: AudioSourceFormat(sampleRate: 48_000, channelCount: 1),
                    .microphone: AudioSourceFormat(sampleRate: 48_000, channelCount: 1),
                ],
                active: [.system, .microphone],
                everEnabled: [.system, .microphone],
                generations: [.system: UUID(), .microphone: UUID()]
            )
        )

        let tick = try #require(try pump.nextTick(for: hostTime(forSample: 480)))

        #expect(Set(tick.blocks.keys) == [.system, .microphone])
        #expect(tick.range == SampleRange(startSample: 0, sampleCount: 480))
        let systemBlock = try #require(tick.blocks[.system])
        let microphoneBlock = try #require(tick.blocks[.microphone])
        #expect(systemBlock.range == tick.range)
        #expect(microphoneBlock.range == tick.range)
        #expect(abs(systemBlock.channels[0][0] - 0.25) < 0.000_1)
        #expect(abs(microphoneBlock.channels[0][0] + 0.5) < 0.000_1)
    }

    @Test func missingEverEnabledRoleGetsEqualLengthSilence() throws {
        let system = try makeRing(role: .system)
        write(constant(0.4), to: system)
        let pump = makePump(layout: .separateTracks)
        pump.start()
        try pump.updateInputs(
            inputs(
                rings: [.system: system],
                formats: [.system: AudioSourceFormat(sampleRate: 48_000, channelCount: 1)],
                active: [.system],
                everEnabled: [.system, .microphone],
                generations: [.system: UUID()]
            )
        )

        let tick = try #require(try pump.nextTick(for: hostTime(forSample: 480)))

        let microphoneBlock = try #require(tick.blocks[.microphone])
        #expect(microphoneBlock.range == tick.range)
        #expect(microphoneBlock.isSilence)
        #expect(tick.gapFramesByRole[.microphone] == 480)
        #expect(tick.isSilence == false)
    }

    @Test func neverEnabledRoleCreatesNoTrack() throws {
        let system = try makeRing(role: .system)
        write(constant(0.2), to: system)
        let pump = makePump(layout: .separateTracks)
        pump.start()
        try pump.updateInputs(
            inputs(
                rings: [.system: system],
                formats: [.system: AudioSourceFormat(sampleRate: 48_000, channelCount: 1)],
                active: [.system],
                everEnabled: [.system],
                generations: [.system: UUID()]
            )
        )

        let tick = try #require(try pump.nextTick(for: hostTime(forSample: 480)))

        #expect(Set(tick.blocks.keys) == [.system])
    }

    @Test func repeatedHostTimeDoesNotAdvanceTheSessionGrid() throws {
        let ring = try makeRing(role: .system)
        write(constant(0.1, frames: 1_440), to: ring)
        let pump = makePump(layout: .mixed)
        pump.start()
        try pump.updateInputs(
            inputs(
                rings: [.system: ring],
                formats: [.system: AudioSourceFormat(sampleRate: 48_000, channelCount: 1)],
                active: [.system],
                everEnabled: [.system],
                generations: [.system: UUID()]
            )
        )

        let first = try #require(try pump.nextTick(for: hostTime(forSample: 480)))
        let duplicate = try pump.nextTick(for: hostTime(forSample: 480))
        let beforeDue = try pump.nextTick(for: hostTime(forSample: 959))

        #expect(first.range.startSample == 0)
        #expect(duplicate == nil)
        #expect(beforeDue == nil)
        let second = try #require(try pump.nextTick(for: hostTime(forSample: 960)))
        #expect(second.range.startSample == 480)
    }

    @Test func futureHostTimeConsumesOneDueTickAtATime() throws {
        let ring = try makeRing(role: .system)
        write(constant(0.1, frames: 4_800), to: ring)
        let pump = makePump(layout: .mixed)
        pump.start()
        try pump.updateInputs(
            inputs(
                rings: [.system: ring],
                formats: [.system: AudioSourceFormat(sampleRate: 48_000, channelCount: 1)],
                active: [.system],
                everEnabled: [.system],
                generations: [.system: UUID()]
            )
        )
        let farFuture = hostTime(forSample: 4_800)

        var starts: [Int64] = []
        for _ in 0..<3 {
            let tick = try #require(try pump.nextTick(for: farFuture))
            starts.append(tick.range.startSample)
        }

        #expect(starts == [0, 480, 960])
    }

    @Test func dueTickWithoutSourcesIsSilence() throws {
        let pump = makePump(layout: .mixed)
        pump.start()
        try pump.updateInputs(
            inputs(
                rings: [:],
                formats: [:],
                active: [.system],
                everEnabled: [.system],
                generations: [:]
            )
        )

        let tick = try #require(try pump.nextTick(for: hostTime(forSample: 480)))

        #expect(tick.range == SampleRange(startSample: 0, sampleCount: 480))
        #expect(tick.blocks.count == 1)
        #expect(tick.blocks[.mixed]?.isSilence == true)
        #expect(tick.isSilence)
        #expect(tick.gapFramesByRole[.system] == 480)
    }

    @Test func routeBoundaryCutsAShortTickAndNeverPremixesNewSource() throws {
        let system = try makeRing(role: .system)
        let microphone = try makeRing(role: .microphone)
        write(constant(0.2, frames: 1_200), to: system)
        write(constant(-0.4), to: microphone, hostTime: hostTime(forSample: 720))
        let pump = makePump(layout: .separateTracks)
        pump.start()
        try pump.updateInputs(
            inputs(
                rings: [.system: system],
                formats: [.system: AudioSourceFormat(sampleRate: 48_000, channelCount: 1)],
                active: [.system],
                everEnabled: [.system],
                generations: [.system: UUID()]
            )
        )
        _ = try #require(try pump.nextTick(for: hostTime(forSample: 480)))

        try pump.updateInputs(
            inputs(
                rings: [.system: system, .microphone: microphone],
                formats: [
                    .system: AudioSourceFormat(sampleRate: 48_000, channelCount: 1),
                    .microphone: AudioSourceFormat(sampleRate: 48_000, channelCount: 1),
                ],
                active: [.system, .microphone],
                everEnabled: [.system, .microphone],
                generations: [.system: UUID(), .microphone: UUID()],
                boundary: 720
            )
        )

        let shortTick = try #require(try pump.nextTick(for: hostTime(forSample: 720)))
        #expect(shortTick.range == SampleRange(startSample: 480, sampleCount: 240))
        #expect(Set(shortTick.blocks.keys) == [.system])
        #expect(shortTick.blocks[.microphone] == nil)

        let nextTick = try #require(try pump.nextTick(for: hostTime(forSample: 1_200)))
        #expect(nextTick.range == SampleRange(startSample: 720, sampleCount: 480))
        #expect(nextTick.blocks[.microphone] != nil)
        #expect(nextTick.blocks[.system] != nil)
    }

    @Test func sourceRangeGapBecomesSilenceWithoutSkippingSessionTime() throws {
        let ring = try makeRing(role: .system, capacitySeconds: 0.05)
        write(constant(0.1, frames: 2_400), to: ring)
        var overflow = constant(0.7)
        overflow[0].withUnsafeBufferPointer { pointer in
            _ = ring.write(planar: [pointer], frameCount: 480, hostTime: 0)
        }
        let pump = makePump(layout: .mixed)
        pump.start()
        try pump.updateInputs(
            inputs(
                rings: [.system: ring],
                formats: [.system: AudioSourceFormat(sampleRate: 48_000, channelCount: 1)],
                active: [.system],
                everEnabled: [.system],
                generations: [.system: UUID()]
            )
        )

        var ticks: [AudioPumpTick] = []
        for index in 0..<5 {
            let tick = try #require(try pump.nextTick(for: hostTime(forSample: Int64((index + 1) * 480))))
            ticks.append(tick)
        }
        write(constant(0.2), to: ring, hostTime: hostTime(forSample: 2_880))
        for index in 5..<7 {
            let tick = try #require(try pump.nextTick(for: hostTime(forSample: Int64((index + 1) * 480))))
            ticks.append(tick)
        }

        #expect(ticks[5].gapFramesByRole[.system] == 480)
        #expect(abs((ticks[5].blocks[.mixed]?.channels[0][100] ?? 1)) < 0.001)
        #expect(abs((ticks[6].blocks[.mixed]?.channels[0][100] ?? 0) - 0.2) < 0.001)
        for (index, tick) in ticks.enumerated() {
            #expect(tick.range.startSample == Int64(index * 480))
        }
    }

    @Test func generationReplacementKeepsSessionRangeAndDropsOldRoute() throws {
        let first = try makeRing(role: .system)
        let second = try makeRing(role: .system)
        write(constant(0.1), to: first)
        write(constant(0.9), to: second, hostTime: hostTime(forSample: 480))
        let pump = makePump(layout: .mixed)
        pump.start()
        let firstID = UUID()
        try pump.updateInputs(
            inputs(
                rings: [.system: first],
                formats: [.system: AudioSourceFormat(sampleRate: 48_000, channelCount: 1)],
                active: [.system],
                everEnabled: [.system],
                generations: [.system: firstID]
            )
        )
        _ = try #require(try pump.nextTick(for: hostTime(forSample: 480)))

        let secondID = UUID()
        try pump.updateInputs(
            inputs(
                rings: [.system: second],
                formats: [.system: AudioSourceFormat(sampleRate: 48_000, channelCount: 1)],
                active: [.system],
                everEnabled: [.system],
                generations: [.system: secondID],
                boundary: 480
            )
        )
        let tick = try #require(try pump.nextTick(for: hostTime(forSample: 960)))

        #expect(tick.range == SampleRange(startSample: 480, sampleCount: 480))
        #expect(abs((tick.blocks[.mixed]?.channels[0][0] ?? 0) - 0.9) < 0.000_1)
        #expect(pump.diagnostics.generationIDsByRole[.system] == secondID)
    }

    @Test func closedAndEmptyRingIsNotReused() throws {
        let ring = try makeRing(role: .system)
        ring.requestClose()
        _ = ring.finishProducing()
        let pump = makePump(layout: .mixed)
        pump.start()
        try pump.updateInputs(
            inputs(
                rings: [.system: ring],
                formats: [.system: AudioSourceFormat(sampleRate: 48_000, channelCount: 1)],
                active: [.system],
                everEnabled: [.system],
                generations: [.system: UUID()]
            )
        )

        let tick = try #require(try pump.nextTick(for: hostTime(forSample: 480)))

        #expect(tick.blocks[.mixed]?.isSilence == true)
        #expect(tick.isSilence)
    }

    @Test func fortyFourOneInputGapIsPublishedInSessionFrames() throws {
        let format = AudioSourceFormat(sampleRate: 44_100, channelCount: 1)
        let ring = try makeRing(role: .system, format: format, capacitySeconds: 0.05)
        write(constant(0.1, frames: 2_205), to: ring, hostTime: 0)
        var overflow = constant(0.7, frames: 441)
        overflow[0].withUnsafeBufferPointer { pointer in
            _ = ring.write(planar: [pointer], frameCount: 441, hostTime: 0)
        }
        let pump = makePump(layout: .mixed)
        pump.start()
        let generationID = UUID()
        try pump.updateInputs(
            inputs(
                rings: [.system: ring],
                formats: [.system: format],
                active: [.system],
                everEnabled: [.system],
                generations: [.system: generationID]
            )
        )

        var ticks: [AudioPumpTick] = []
        for index in 0..<5 {
            ticks.append(try #require(try pump.nextTick(for: hostTime(forSample: Int64((index + 1) * 480)))))
        }
        write(
            constant(0.2, frames: 441),
            to: ring,
            hostTime: hostTime(forSample: 2_880)
        )
        for index in 5..<7 {
            ticks.append(try #require(try pump.nextTick(for: hostTime(forSample: Int64((index + 1) * 480)))))
        }

        let gapTicks = ticks.filter { !$0.gapFramesByRole.isEmpty }
        #expect(gapTicks.count == 1)
        #expect(gapTicks.first?.gapFramesByRole[.system] == 480)
        #expect(gapTicks.first?.range.startSample == 2_400)
        #expect(pump.diagnostics.gapFramesByRole[.system] == 480)
    }

    @Test func terminal44kInputGapIsPublishedInSessionFrames() throws {
        let format = AudioSourceFormat(sampleRate: 44_100, channelCount: 1)
        let ring = try makeRing(role: .system, format: format, capacitySeconds: 0.05)
        write(constant(0.1, frames: 2_205), to: ring, hostTime: 0)
        var overflow = constant(0.7, frames: 441)
        overflow[0].withUnsafeBufferPointer { pointer in
            _ = ring.write(planar: [pointer], frameCount: 441, hostTime: 0)
        }
        ring.requestClose()
        _ = ring.finishProducing()
        let pump = makePump(layout: .mixed)
        pump.start()
        let generationID = UUID()
        try pump.updateInputs(
            inputs(
                rings: [.system: ring],
                formats: [.system: format],
                active: [.system],
                everEnabled: [.system],
                generations: [.system: generationID]
            )
        )
        for index in 0..<5 {
            _ = try #require(try pump.nextTick(for: hostTime(forSample: Int64((index + 1) * 480))))
        }
        pump.stop()
        let ticks = try pump.drainForStop(joinedGenerationIDs: [generationID])

        let gapTicks = ticks.filter { !$0.gapFramesByRole.isEmpty }
        #expect(gapTicks.count == 1)
        #expect(gapTicks.first?.gapFramesByRole[.system] == 480)
        #expect(pump.diagnostics.gapFramesByRole[.system] == 480)
    }

    @Test func large44kGapStaysOnFirstSessionTick() throws {
        let format = AudioSourceFormat(sampleRate: 44_100, channelCount: 1)
        let ring = try makeRing(role: .system, format: format, capacitySeconds: 0.05)
        write(constant(0.1, frames: 2_205), to: ring, hostTime: 0)
        var overflow = constant(0.7, frames: 882)
        overflow[0].withUnsafeBufferPointer { pointer in
            _ = ring.write(planar: [pointer], frameCount: 882, hostTime: 0)
        }
        let pump = makePump(layout: .mixed)
        pump.start()
        try pump.updateInputs(
            inputs(
                rings: [.system: ring],
                formats: [.system: format],
                active: [.system],
                everEnabled: [.system],
                generations: [.system: UUID()]
            )
        )
        for index in 0..<5 {
            _ = try #require(try pump.nextTick(for: hostTime(forSample: Int64((index + 1) * 480))))
        }
        write(constant(0.2, frames: 441), to: ring, hostTime: hostTime(forSample: 3_360))
        let first = try #require(try pump.nextTick(for: hostTime(forSample: 2_880)))
        let second = try #require(try pump.nextTick(for: hostTime(forSample: 3_360)))

        #expect(first.range.startSample == 2_400)
        #expect(first.gapFramesByRole[.system] == 960)
        #expect(second.gapFramesByRole.isEmpty)
        #expect(pump.diagnostics.gapFramesByRole[.system] == 960)
    }

    @Test func diagnosticsCountShortSilenceAndGapTicks() throws {
        let system = try makeRing(role: .system)
        write(constant(0.2, frames: 1_200), to: system)
        let pump = makePump(layout: .separateTracks)
        pump.start()
        try pump.updateInputs(
            inputs(
                rings: [.system: system],
                formats: [.system: AudioSourceFormat(sampleRate: 48_000, channelCount: 1)],
                active: [.system],
                everEnabled: [.system, .microphone],
                generations: [.system: UUID()]
            )
        )
        _ = try #require(try pump.nextTick(for: hostTime(forSample: 480)))
        try pump.updateInputs(
            inputs(
                rings: [.system: system],
                formats: [.system: AudioSourceFormat(sampleRate: 48_000, channelCount: 1)],
                active: [.system],
                everEnabled: [.system, .microphone],
                generations: [.system: UUID()],
                boundary: 600
            )
        )
        _ = try #require(try pump.nextTick(for: hostTime(forSample: 600)))

        let diagnostics = pump.diagnostics

        #expect(diagnostics.tickCount == 2)
        #expect(diagnostics.shortTickCount == 1)
        #expect(diagnostics.gapFramesByRole[.microphone] == 600)
        #expect(diagnostics.silenceTickCount == 0)
    }

    private struct HealthyRunResult {
        var firstFailures: [String] = []
        var nonSilentTicks = 0
        var totalGapFrames: Int64 = 0
    }

    private func runHealthyNominalInput(
        inputRate: Int,
        framesPerTick: Int,
        ticks: Int
    ) throws -> HealthyRunResult {
        let format = AudioSourceFormat(sampleRate: inputRate, channelCount: 1)
        let ring = try makeRing(role: .system, format: format)
        let pump = makePump(layout: .mixed)
        pump.start()
        try pump.updateInputs(
            inputs(
                rings: [.system: ring],
                formats: [.system: format],
                active: [.system],
                everEnabled: [.system],
                generations: [.system: UUID()]
            )
        )
        var result = HealthyRunResult()
        for index in 0..<ticks {
            write(
                constant(0.25, frames: framesPerTick),
                to: ring,
                hostTime: hostTime(forSample: Int64(index * 480))
            )
            let tick = try pump.nextTick(for: hostTime(forSample: Int64((index + 1) * 480)))
            guard let tick else {
                result.firstFailures.append("tick \(index): nil")
                break
            }
            let expectedRange = SampleRange(startSample: Int64(index * 480), sampleCount: 480)
            var reasons: [String] = []
            if tick.range != expectedRange {
                reasons.append("range \(tick.range)")
            }
            if !tick.gapFramesByRole.isEmpty {
                reasons.append("gap \(tick.gapFramesByRole)")
            }
            if tick.isSilence {
                reasons.append("silent")
            }
            if let block = tick.blocks[.mixed] {
                if block.isSilence {
                    reasons.append("silent block")
                }
                if block.frameCount != 480 || block.range != expectedRange {
                    reasons.append("block \(block.frameCount) \(block.range)")
                }
                if block.channels.first?.first.map({ $0.isFinite && abs($0) > 0.1 }) != true {
                    reasons.append("bad sample")
                }
                if !block.channels.allSatisfy({ $0.allSatisfy(\.isFinite) }) {
                    reasons.append("non-finite sample")
                }
            } else {
                reasons.append("missing mixed block")
            }
            if !reasons.isEmpty, result.firstFailures.count < 3 {
                result.firstFailures.append("tick \(index): \(reasons.joined(separator: ", "))")
            }
            if !tick.isSilence, tick.gapFramesByRole.isEmpty {
                result.nonSilentTicks += 1
            }
            result.totalGapFrames += tick.gapFramesByRole.values.reduce(0) { $0 + Int64($1) }
        }
        result.totalGapFrames += pump.diagnostics.gapFramesByRole.values.reduce(0, +)
        return result
    }

    @Test func healthy48kNominalInputHasNoFauxSilence() throws {
        let result = try runHealthyNominalInput(
            inputRate: 48_000,
            framesPerTick: 480,
            ticks: 6_000
        )
        #expect(result.firstFailures.isEmpty, "first failures: \(result.firstFailures)")
        #expect(result.nonSilentTicks == 6_000)
        #expect(result.totalGapFrames == 0)
    }

    @Test func healthy44kNominalInputHasNoFauxSilence() throws {
        let result = try runHealthyNominalInput(
            inputRate: 44_100,
            framesPerTick: 441,
            ticks: 6_000
        )
        #expect(result.firstFailures.isEmpty, "first failures: \(result.firstFailures)")
        #expect(result.nonSilentTicks == 6_000)
        #expect(result.totalGapFrames == 0)
    }

    /// S4: the readiness counter must move for microphone-only capture.
    @Test func capturedSourceFramesCountMicrophoneFramesNotClockSilence() throws {
        let microphone = try makeRing(role: .microphone)
        write(constant(0.1), to: microphone)
        let pump = makePump(layout: .mixed)
        pump.start()
        try pump.updateInputs(
            inputs(
                rings: [.microphone: microphone],
                formats: [.microphone: AudioSourceFormat(sampleRate: 48_000, channelCount: 1)],
                active: [.microphone],
                everEnabled: [.microphone],
                generations: [.microphone: UUID()]
            )
        )

        _ = try #require(try pump.nextTick(for: hostTime(forSample: 480)))
        #expect(pump.capturedSourceFrameCount == 480)

        // A later tick advances the clock but reads no source frames.
        _ = try #require(try pump.nextTick(for: hostTime(forSample: 960)))
        #expect(pump.nextSampleIndex > 480)
        #expect(pump.capturedSourceFrameCount == 480)
    }

    /// S4: the readiness counter must move for system-audio-only capture.
    @Test func capturedSourceFramesCountSystemFramesNotClockSilence() throws {
        let system = try makeRing(role: .system)
        write(constant(0.1), to: system)
        let pump = makePump(layout: .mixed)
        pump.start()
        try pump.updateInputs(
            inputs(
                rings: [.system: system],
                formats: [.system: AudioSourceFormat(sampleRate: 48_000, channelCount: 1)],
                active: [.system],
                everEnabled: [.system],
                generations: [.system: UUID()]
            )
        )

        _ = try #require(try pump.nextTick(for: hostTime(forSample: 480)))
        #expect(pump.capturedSourceFrameCount == 480)

        _ = try #require(try pump.nextTick(for: hostTime(forSample: 960)))
        #expect(pump.nextSampleIndex > 480)
        #expect(pump.capturedSourceFrameCount == 480)
    }

    /// S4: `systemAndMicrophone` counts frames from both roles.
    @Test func capturedSourceFramesCountBothRoles() throws {
        let system = try makeRing(role: .system)
        let microphone = try makeRing(role: .microphone)
        write(constant(0.1), to: system)
        write(constant(0.2), to: microphone)
        let pump = makePump(layout: .mixed)
        pump.start()
        try pump.updateInputs(
            inputs(
                rings: [.system: system, .microphone: microphone],
                formats: [
                    .system: AudioSourceFormat(sampleRate: 48_000, channelCount: 1),
                    .microphone: AudioSourceFormat(sampleRate: 48_000, channelCount: 1),
                ],
                active: [.system, .microphone],
                everEnabled: [.system, .microphone],
                generations: [.system: UUID(), .microphone: UUID()]
            )
        )

        _ = try #require(try pump.nextTick(for: hostTime(forSample: 480)))
        #expect(pump.capturedSourceFrameCount == 960)

        _ = try #require(try pump.nextTick(for: hostTime(forSample: 960)))
        #expect(pump.nextSampleIndex > 480)
        #expect(pump.capturedSourceFrameCount == 960)
    }
}
