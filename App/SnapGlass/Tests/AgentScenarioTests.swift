import CaptureCore
import Foundation
import Testing

@Suite("Agent scenarios")
struct AgentScenarioTests {
    private let url = URL(fileURLWithPath: "/tmp/scenario.json")

    private func decode(_ json: String) throws -> AgentScenario {
        try AgentScenario.load(from: url, data: Data(json.utf8))
    }

    @Test("Omitted fields use safe defaults")
    func appliesDefaults() throws {
        let scenario = try decode(#"{"name": "minimal"}"#)
        #expect(scenario.audioSeconds == 5)
        #expect(scenario.screenSeconds == 0)
        #expect(scenario.firstSampleDeadlineSeconds == 15)
        #expect(scenario.simulateMainStallMs == 0)
        #expect(scenario.simulateStallAfterStart == true)
        #expect(scenario.audioMode == "system")
        #expect(scenario.hudWarmup == false)
        #expect(scenario.expect.artifactPlayable == true)
        #expect(scenario.expect.hudFirstVisibleUnderMs == nil)
    }

    @Test("Every field is decoded")
    func decodesFullScenario() throws {
        let scenario = try decode(
            """
            {
              "name": "stall-main",
              "audioSeconds": 5,
              "screenSeconds": 0,
              "firstSampleDeadlineSeconds": 3,
              "simulateMainStallMs": 6000,
              "simulateStallAfterStart": true,
              "audioMode": "systemAndMicrophone",
              "hudWarmup": true,
              "expect": {
                "artifactPlayable": true,
                "hudFirstVisibleUnderMs": 300,
                "sizeThatFitsBeforeFirstVisible": 0,
                "becameRecording": true,
                "mainThreadMaxStallAtLeastMs": 4800,
                "maxResizeCount": 2,
                "maxRecordingResizeCount": 2
              }
            }
            """
        )
        #expect(scenario.name == "stall-main")
        #expect(scenario.audioSeconds == 5)
        #expect(scenario.firstSampleDeadlineSeconds == 3)
        #expect(scenario.simulateMainStallMs == 6000)
        #expect(scenario.audioMode == "systemAndMicrophone")
        #expect(scenario.hudWarmup == true)
        #expect(scenario.expect.hudFirstVisibleUnderMs == 300)
        #expect(scenario.expect.sizeThatFitsBeforeFirstVisible == 0)
        #expect(scenario.expect.becameRecording == true)
        #expect(scenario.expect.mainThreadMaxStallAtLeastMs == 4800)
        #expect(scenario.expect.maxResizeCount == 2)
        #expect(scenario.expect.maxRecordingResizeCount == 2)
    }

    @Test("An empty name is rejected")
    func rejectsEmptyName() {
        #expect(throws: AgentScenario.ValidationError.self) {
            try decode(#"{"name": "   "}"#)
        }
    }

    @Test("Non-positive audio duration is rejected")
    func rejectsInvalidDuration() {
        #expect(throws: AgentScenario.ValidationError.self) {
            try decode(#"{"name": "bad", "audioSeconds": 0}"#)
        }
    }

    @Test("Unknown audio mode is rejected")
    func rejectsUnknownAudioMode() {
        #expect(throws: AgentScenario.ValidationError.self) {
            try decode(#"{"name": "bad", "audioMode": "everything"}"#)
        }
    }

    @Test("A negative injected stall is rejected")
    func rejectsNegativeStall() {
        #expect(throws: AgentScenario.ValidationError.self) {
            try decode(#"{"name": "bad", "simulateMainStallMs": -1}"#)
        }
    }

    @Test("Scenarios round-trip through Codable")
    func roundTrips() throws {
        let original = AgentScenario(
            name: "round-trip",
            audioSeconds: 2,
            firstSampleDeadlineSeconds: 4,
            simulateMainStallMs: 100,
            audioMode: "microphone",
            hudWarmup: true,
            expect: AgentScenario.Expect(
                hudFirstVisibleUnderMs: 250,
                maxRecordingResizeCount: 2
            )
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try AgentScenario.load(from: url, data: data)
        #expect(decoded == original)
    }

    @Test("The agent audio configuration builds a real pipeline in an isolated root")
    func factoryAcceptsAgentConfiguration() throws {
        // The recording ledger rejects symlinked paths, so use a real caches path
        // rather than TMPDIR (which lives under /var).
        let caches = try #require(
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        )
        let root = caches
            .appendingPathComponent("com.snapglass.agent.tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let roots = RecordingPipelineRoots(
            sessionRoot: root,
            indexURL: root
                .appendingPathComponent(".SnapGlassSessions", isDirectory: true)
                .appendingPathComponent("recording-index.json"),
            outputDirectory: root
        )
        let configuration = AudioRecordingConfiguration(
            kind: .audio,
            mode: .system,
            layout: .mixed,
            sampleRate: 48_000,
            channelCountByRole: [.mixed: 2],
            bitRate: 128_000
        )
        _ = try RecordingAudioPipelineFactory.makeSpaceGated(
            configuration: configuration,
            roots: roots,
            expectedVolumeUUID: nil,
            backlog: RecordingBacklogPolicy(
                highWatermarkBytes: 512 * 1_024 * 1_024,
                lowWatermarkBytes: 128 * 1_024 * 1_024
            )
        )
    }
}
