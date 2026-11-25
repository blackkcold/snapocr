import Foundation
import Testing

@Suite("Agent report")
struct AgentReportTests {
    private func makeReport() -> AgentReport {
        AgentReport(
            ok: true,
            scenario: "audio-smoke",
            app: AgentReport.AppFacts(
                pid: 4_242,
                bundleID: "com.snapglass.app",
                signedIdentity: "SnapGlass Code Signing",
                executablePath: "/tmp/SnapGlass.app/Contents/MacOS/SnapGlass"
            ),
            session: AgentReport.SessionFacts(
                id: "0f8fad5b-d9cb-469f-a165-70867728950e",
                kind: "audio",
                published: true,
                audioMode: "system"
            ),
            artifacts: [
                AgentReport.Artifact(
                    path: "/tmp/root/Recording.caf",
                    bytes: 1_024,
                    duration: 3.01
                )
            ],
            hud: AgentReport.HUDFacts(
                firstVisibleMs: 42,
                sizeThatFitsBeforeFirstVisible: 0,
                sizeThatFitsCount: 2,
                resizeCount: 1,
                applyCount: 6,
                resizeCountRecordingPhase: 1,
                resizes: [
                    AgentResizeRecord(
                        t: 120,
                        from: AgentSize(width: 320, height: 54),
                        to: AgentSize(width: 340, height: 54),
                        recordingPhase: true
                    )
                ],
                warmedUp: false
            ),
            mainThread: AgentReport.MainThreadFacts(maxStallMs: 6_002, probeSamples: 240),
            supervisor: AgentReport.SupervisorFacts(
                settledAtMs: 3_020,
                settlementDuringStall: false,
                reason: "requested",
                stopCalls: 1,
                mediaStarted: true
            ),
            readiness: AgentReport.ReadinessFacts(firstRealSampleAfterMs: 78, becameRecording: true),
            timeline: [
                AgentReport.TimelineEntry(t: 0, event: "launch"),
                AgentReport.TimelineEntry(t: 42, event: "hudVisible"),
            ],
            errors: []
        )
    }

    @Test("Reports round-trip through Codable")
    func roundTrips() throws {
        let original = makeReport()
        let data = try original.jsonData()
        let decoded = try JSONDecoder().decode(AgentReport.self, from: data)
        #expect(decoded == original)
    }

    @Test("Resize records keep their sizes, time, and phase")
    func resizeRecordsRoundTrip() throws {
        let original = makeReport()
        let data = try original.jsonData()
        let decoded = try JSONDecoder().decode(AgentReport.self, from: data)
        #expect(decoded.hud.resizes == original.hud.resizes)
        #expect(decoded.hud.resizeCountRecordingPhase == 1)
        #expect(decoded.hud.resizes.first?.recordingPhase == true)
        #expect(decoded.hud.resizes.first?.from.width == 320)
        #expect(decoded.hud.resizes.first?.to.width == 340)
    }

    @Test("Required keys are present in the encoded report")
    func encodesRequiredKeys() throws {
        let data = try makeReport().jsonData()
        let text = try #require(String(data: data, encoding: .utf8))
        for key in [
            "\"ok\"", "\"scenario\"", "\"app\"", "\"session\"", "\"artifacts\"",
            "\"hud\"", "\"mainThread\"", "\"readiness\"", "\"timeline\"", "\"errors\"",
            "\"firstVisibleMs\"", "\"sizeThatFitsBeforeFirstVisible\"", "\"maxStallMs\"",
            "\"probeSamples\"", "\"firstRealSampleAfterMs\"", "\"becameRecording\"",
            "\"resizeCountRecordingPhase\"", "\"resizes\"", "\"from\"", "\"to\"",
            "\"recordingPhase\"", "\"warmedUp\"",
            "\"supervisor\"", "\"settledAtMs\"", "\"settlementDuringStall\"",
            "\"stopCalls\"", "\"mediaStarted\"",
        ] {
            #expect(text.contains(key))
        }
    }

    @Test("A report without optional values still decodes")
    func decodesMinimalReport() throws {
        let json =
            """
            {
              "ok": false,
              "scenario": "failed",
              "app": {
                "pid": 1,
                "bundleID": "com.snapglass.app",
                "signedIdentity": "unknown",
                "executablePath": "/tmp/SnapGlass"
              },
              "session": {"id": null, "kind": "audio", "published": false, "audioMode": null},
              "artifacts": [],
              "hud": {
                "firstVisibleMs": null,
                "sizeThatFitsBeforeFirstVisible": 0,
                "sizeThatFitsCount": 0,
                "resizeCount": 0,
                "applyCount": 0,
                "resizeCountRecordingPhase": 0,
                "resizes": [],
                "warmedUp": false
              },
              "mainThread": {"maxStallMs": 0, "probeSamples": 0},
              "supervisor": {
                "settledAtMs": null,
                "settlementDuringStall": false,
                "reason": null,
                "stopCalls": 0,
                "mediaStarted": false
              },
              "readiness": {"firstRealSampleAfterMs": null, "becameRecording": false},
              "timeline": [],
              "errors": ["boom"]
            }
            """
        let report = try JSONDecoder().decode(AgentReport.self, from: Data(json.utf8))
        #expect(report.ok == false)
        #expect(report.hud.firstVisibleMs == nil)
        #expect(report.hud.resizeCountRecordingPhase == 0)
        #expect(report.hud.resizes.isEmpty)
        #expect(report.hud.warmedUp == false)
        #expect(report.errors == ["boom"])
    }

    @Test("Writing produces report.json in the output directory")
    func writesReportFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentReportTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try makeReport().write(to: directory)
        let file = directory.appendingPathComponent("report.json")
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}
