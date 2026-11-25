import AudioToolbox
import Foundation
import Testing

@testable import CaptureCore

struct RecordingPipelineIntegrationTests {
    @Test func realEngineCheckpointCAFSealAndLedgerComposeEndToEnd() async throws {
        let root = TestTemporaryDirectory.root("Task09-Pipeline")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let sessionRoot = root.appendingPathComponent(".SnapGlassSessions", isDirectory: true)
            .appendingPathComponent(sessionID.uuidString.lowercased(), isDirectory: true)
        let outputRoot = root.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)

        let indexURL = root.appendingPathComponent("recording-index.json")
        let ledger = try RecordingSessionLedger(
            sessionRoot: sessionRoot, indexURL: indexURL, sessionID: sessionID
        )
        let configuration = AudioRecordingConfiguration(
            kind: .audio, mode: .system, layout: .mixed, sampleRate: 48_000,
            channelCountByRole: [.mixed: 1], bitRate: 96_000
        )
        let coordinator = try SegmentedWriterCoordinator(plan: AudioSegmentPlan()) { boundary in
            let directory = sessionRoot.appendingPathComponent(
                String(format: "segment-%08d", boundary.index), isDirectory: true
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            return try RecordingCheckpointWriter(
                directory: directory,
                sessionRoot: sessionRoot,
                segment: boundary,
                sampleRate: 48_000,
                roles: [.mixed]
            )
        }
        let sealService = RecordingSealService(publicationHooks: [LedgerPublicationHook(ledger: ledger)])
        let authorizer = IntegrationAuthorizer()
        let engineFactory:
            @Sendable (
                AudioRecordingConfiguration,
                any AudioCheckpointSink & Sendable,
                AudioSampleClock
            ) throws -> any AudioRecordingControlling & Sendable = { config, sink, clock in
                let source = try IntegrationPCMSource()
                let routeController = AudioRouteController(authorizer: authorizer, sources: [.system: source])
                let pump = AudioMixPump(
                    clock: clock, policy: AudioMixPolicy(sampleRate: config.sampleRate),
                    layout: config.layout, blockFrames: 480, channelCountByRole: config.channelCountByRole
                )
                return AudioRecordingEngine(
                    sink: sink, clock: clock, sources: [.system: source],
                    routeController: routeController, pump: pump,
                    scheduler: IntegrationScheduler()
                )
            }
        let pipeline = try RecordingSessionPipeline(
            roots: RecordingPipelineRoots(
                sessionRoot: root, indexURL: indexURL, outputDirectory: outputRoot
            ),
            ledger: ledger, coordinator: coordinator, sealService: sealService,
            engineFactory: engineFactory
        )

        try await pipeline.start(configuration)
        let result = await pipeline.stop()
        let snapshot = try await pipeline.snapshot()

        #expect(result.sessionID == sessionID)
        #expect(snapshot.segments.contains(where: { $0.state == .published }))
        #expect(snapshot.segments.first?.files["mixed"] != nil)
    }
}

private final class IntegrationAuthorizer: MicrophoneAuthorizing, @unchecked Sendable {
    func currentState() -> MicrophoneAuthorizationState { .authorized }
    func requestAccess() async -> MicrophoneAuthorizationState { .authorized }
}

private final class IntegrationPCMSource: AudioFrameSource, AudioSourceReconfigurationCancelling,
    @unchecked Sendable
{
    let role: RecordingTrackRole = .system
    private let hostTicksPerSecond = AudioSourceTimestampMapper.nativeHostTicksPerSecond()
    private let lock = NSLock()
    private var generation: AudioSourceGeneration
    private var running = false

    init() throws {
        generation = try AudioSourceGeneration(
            role: .system,
            format: AudioSourceFormat(sampleRate: 48_000, channelCount: 1),
            hostTicksPerSecond: hostTicksPerSecond
        )
    }

    func currentGeneration() async -> AudioSourceGeneration {
        lock.withLock { generation }
    }

    func start() async throws {
        let next = try AudioSourceGeneration(
            role: .system,
            format: AudioSourceFormat(sampleRate: 48_000, channelCount: 1),
            hostTicksPerSecond: hostTicksPerSecond
        )
        lock.withLock {
            generation = next
            running = true
        }

        let samples = [Float](repeating: 0.05, count: 4_800)
        samples.withUnsafeBufferPointer { buffer in
            _ = next.ringBuffer.write(
                planar: [buffer], frameCount: samples.count,
                hostTime: AudioGetCurrentHostTime()
            )
        }
    }

    func isRunning() async -> Bool {
        lock.withLock { running }
    }

    func stop() async {
        let ring = lock.withLock {
            running = false
            return generation.ringBuffer
        }
        ring.requestClose()
        _ = ring.finishProducing()
    }

    func isProducerJoined() async -> Bool { true }

    func prepareReconfiguration(_ event: AudioDeviceChangeEvent) async -> AudioSourcePreparation {
        .unchangedOnFailure(reason: "fixed synthetic test source")
    }

    func commitReconfiguration(_ generation: AudioSourceGeneration) async -> Bool {
        lock.withLock { self.generation.id == generation.id && running }
    }

    func cancelReconfiguration(_ generationID: UUID) async {}
}

private final class IntegrationScheduler: AudioTickScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable () async -> Void)?

    func start(_ handler: @escaping @Sendable () async -> Void) async {
        lock.withLock { self.handler = handler }
    }

    func stop() async {
        lock.withLock { handler = nil }
    }
}
