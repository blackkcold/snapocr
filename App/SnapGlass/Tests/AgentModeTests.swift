import Foundation
import SharedKit
import Testing

@Suite("Agent mode arguments")
struct AgentModeTests {
    private let home = URL(fileURLWithPath: "/Users/tester")

    @Test("No agent flag leaves the app in normal mode")
    func inactiveWithoutFlags() throws {
        #expect(try AgentMode.parse(arguments: ["/Applications/SnapGlass.app/Contents/MacOS/SnapGlass"]) == nil)
    }

    @Test("Explicit paths and values are parsed")
    func parsesExplicitConfiguration() throws {
        let configuration = try AgentMode.parse(
            arguments: [
                "SnapGlass",
                "--agent-run", "/tmp/scenario.json",
                "--agent-root", "/tmp/agent-root",
                "--agent-out", "/tmp/agent-out",
                "--agent-deadline", "2.5",
                "--agent-hud-corner", "bottomLeading",
            ],
            homeDirectory: home
        )
        #expect(configuration?.scenarioURL.path == "/tmp/scenario.json")
        #expect(configuration?.rootURL.path == "/tmp/agent-root")
        #expect(configuration?.outputURL.path == "/tmp/agent-out")
        #expect(configuration?.deadlineSeconds == 2.5)
        #expect(configuration?.hudCorner == "bottomLeading")
    }

    @Test("Missing root and output fall back to an isolated caches directory")
    func defaultsToIsolatedDirectory() throws {
        let configuration = try AgentMode.parse(
            arguments: ["SnapGlass", "--agent-run", "/tmp/scenario.json"],
            homeDirectory: home
        )
        let root = try #require(configuration?.rootURL)
        #expect(root.path.contains("com.snapglass.agent"))
        #expect(root.path.hasSuffix("/root"))
        #expect(!root.path.contains("/Movies/SnapGlass"))
        let output = try #require(configuration?.outputURL)
        #expect(output.path.hasSuffix("/out"))
    }

    @Test("An invalid deadline is rejected")
    func rejectsInvalidDeadline() {
        #expect(throws: AgentMode.ParseFailure.self) {
            try AgentMode.parse(
                arguments: [
                    "SnapGlass",
                    "--agent-run", "/tmp/scenario.json",
                    "--agent-deadline", "zero",
                ],
                homeDirectory: home
            )
        }
    }

    @Test("An invalid HUD corner is rejected")
    func rejectsInvalidCorner() {
        #expect(throws: AgentMode.ParseFailure.self) {
            try AgentMode.parse(
                arguments: [
                    "SnapGlass",
                    "--agent-run", "/tmp/scenario.json",
                    "--agent-hud-corner", "middle",
                ],
                homeDirectory: home
            )
        }
    }

    @Test("The user's recording library is refused as a root")
    func rejectsUserRecordingLibrary() {
        for path in [
            "/Users/tester/Movies/SnapGlass",
            "/Users/tester/Movies/SnapGlass/Recordings",
            "/Users/tester/Library/Application Support/SnapGlass",
            "/Users/tester",
        ] {
            #expect(throws: AgentMode.ParseFailure.self) {
                try AgentMode.parse(
                    arguments: [
                        "SnapGlass",
                        "--agent-run", "/tmp/scenario.json",
                        "--agent-root", path,
                    ],
                    homeDirectory: home
                )
            }
        }
    }

    @Test("The user's library is also refused for the output directory")
    func rejectsUserLibraryOutput() {
        #expect(throws: AgentMode.ParseFailure.self) {
            try AgentMode.parse(
                arguments: [
                    "SnapGlass",
                    "--agent-run", "/tmp/scenario.json",
                    "--agent-out", "/Users/tester/Library/Preferences",
                ],
                homeDirectory: home
            )
        }
    }

    @Test("Agent isolation prefers the environment root")
    func environmentRootWins() throws {
        let root = try #require(
            AgentIsolation.recordingRoot(environment: [AgentIsolation.rootEnvironmentKey: "/tmp/isolated"])
        )
        #expect(root.path == "/tmp/isolated")
    }

    @Test("In-memory preferences never escape the process")
    func preferencesStayInMemory() throws {
        let defaults = try #require(AgentPreferences())
        defaults.set("hidden", forKey: "key")
        #expect(defaults.string(forKey: "key") == "hidden")
        defaults.removeObject(forKey: "key")
        #expect(defaults.object(forKey: "key") == nil)
        #expect(defaults.dictionaryRepresentation().isEmpty)
    }

    @Test("The HUD corner argument overrides preferences in memory")
    func hudCornerOverride() throws {
        let configuration = try #require(
            try AgentMode.parse(
                arguments: [
                    "SnapGlass",
                    "--agent-run", "/tmp/scenario.json",
                    "--agent-hud-corner", "bottomLeading",
                ],
                homeDirectory: home
            )
        )
        let defaults = try #require(
            AgentPreferences(storage: AgentMode.preferenceOverrides(for: configuration))
        )
        #expect(RecordingHUDPreferences.cornerIdentifier(in: defaults) == "bottomLeading")
    }
}
