import Foundation
import SharedKit

/// Process-wide activation of the headless agent test channel.
///
/// The channel exists so recording scenarios can be exercised without clicking
/// the menu bar, without touching the user's running instance, and without
/// writing to the user's recording library. Normal launches only pay for one
/// static `Bool` read.
enum AgentMode {
    /// Parsed agent arguments. Every path is isolated from the user's data.
    struct Configuration: Equatable, Sendable {
        /// Scenario JSON to run.
        let scenarioURL: URL
        /// Isolated recording root; also the export root while the agent runs.
        let rootURL: URL
        /// Directory receiving `agent.pid` and `report.json`.
        let outputURL: URL
        /// Optional override for the first-audio-sample deadline.
        let deadlineSeconds: Double?
        /// Optional fixed HUD corner (for example `bottomLeading`).
        let hudCorner: String?
    }

    /// Why the channel could not be activated even though arguments were present.
    enum ParseFailure: Error, Equatable, Sendable {
        case missingScenarioPath
        case missingValue(String)
        case invalidValue(flag: String, value: String)
        case unsafeRoot(String)
    }

    /// Three-state activation: inactive, ready, or refused-but-still-short-circuited.
    enum Activation: Equatable, Sendable {
        case inactive
        case active(Configuration)
        case invalid(String)
    }

    /// Result of parsing the process arguments.
    static let activation: Activation = {
        do {
            let configuration = try parse(arguments: CommandLine.arguments)
            return configuration.map(Activation.active) ?? .inactive
        } catch {
            return .invalid(describe(error))
        }
    }()

    /// Whether the process must skip menu bar, hot keys, updater, and login items.
    static let isActive: Bool = {
        switch activation {
        case .inactive: false
        case .active, .invalid: true
        }
    }()

    /// The parsed configuration, or `nil` when the channel is inactive or invalid.
    static var configuration: Configuration? {
        if case let .active(configuration) = activation { return configuration }
        return nil
    }

    /// Arguments understood by the channel.
    static let knownFlags: Set<String> = [
        "--agent-run",
        "--agent-root",
        "--agent-out",
        "--agent-deadline",
        "--agent-hud-corner",
    ]

    /// Parses agent arguments from a full argument vector.
    ///
    /// - Parameters:
    ///   - arguments: Usually `CommandLine.arguments`; index 0 is ignored.
    ///   - fileManager: File manager used for default temporary paths.
    ///   - homeDirectory: Overrides the home directory that root and output paths
    ///     must stay inside; `nil` uses the file manager's home directory.
    /// - Returns: `nil` when no agent flag is present.
    /// - Throws: A ``ParseFailure`` when a flag is present but unusable.
    static func parse(  // swiftlint:disable:this cyclomatic_complexity
        arguments: [String],
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil
    ) throws -> Configuration? {
        let arguments = Array(arguments.dropFirst())
        guard arguments.contains(where: { $0.hasPrefix("--agent-") }) else { return nil }

        var scenario: String?
        var root: String?
        var output: String?
        var deadline: String?
        var corner: String?

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            func value() throws -> String {
                guard index + 1 < arguments.count else { throw ParseFailure.missingValue(argument) }
                index += 1
                return arguments[index]
            }
            switch argument {
            case "--agent-run":
                scenario = try value()
            case "--agent-root":
                root = try value()
            case "--agent-out":
                output = try value()
            case "--agent-deadline":
                deadline = try value()
            case "--agent-hud-corner":
                corner = try value()
            default:
                break
            }
            index += 1
        }

        guard let scenario, !scenario.isEmpty else { throw ParseFailure.missingScenarioPath }

        let base = AgentMode.defaultBaseDirectory(fileManager: fileManager)
        let rootURL = root.map { URL(fileURLWithPath: $0) } ?? base.appendingPathComponent("root")
        let outputURL = output.map { URL(fileURLWithPath: $0) } ?? base.appendingPathComponent("out")

        let home = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
        try validateIsolatedRoot(rootURL, home: home)
        try validateIsolatedRoot(outputURL, home: home)

        var deadlineSeconds: Double?
        if let deadline {
            guard let parsed = Double(deadline), parsed.isFinite, parsed > 0 else {
                throw ParseFailure.invalidValue(flag: "--agent-deadline", value: deadline)
            }
            deadlineSeconds = parsed
        }

        var hudCorner: String?
        if let corner {
            guard RecordingHUDAgentCorners.all.contains(corner) else {
                throw ParseFailure.invalidValue(flag: "--agent-hud-corner", value: corner)
            }
            hudCorner = corner
        }

        return Configuration(
            scenarioURL: normalize(URL(fileURLWithPath: scenario)),
            rootURL: normalize(rootURL),
            outputURL: normalize(outputURL),
            deadlineSeconds: deadlineSeconds,
            hudCorner: hudCorner
        )
    }

    /// Collapses duplicate separators and trailing slashes in an absolute path.
    ///
    /// `RecordingLedgerFileSystem` rejects paths that differ from their
    /// standardized form, and `TMPDIR` commonly ends with a slash.
    private static func normalize(_ url: URL) -> URL {
        let components = url.standardizedFileURL.path.split(
            separator: "/",
            omittingEmptySubsequences: true
        )
        return URL(fileURLWithPath: "/" + components.joined(separator: "/"))
    }

    /// Default base directory for an agent run that did not pass explicit paths.
    ///
    /// `FileManager.temporaryDirectory` lives under `/var`, which is a symlink
    /// the recording ledger rejects; the caches directory is a real path.
    static func defaultBaseDirectory(fileManager: FileManager = .default) -> URL {
        let caches =
            fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        return
            caches
            .appendingPathComponent("com.snapglass.agent", isDirectory: true)
            .appendingPathComponent(String(ProcessInfo.processInfo.processIdentifier), isDirectory: true)
    }

    /// Preferences the agent run overrides in memory (never written to disk).
    ///
    /// - Parameter configuration: Parsed agent arguments.
    /// - Returns: Preference values that take precedence for this process only.
    static func preferenceOverrides(for configuration: Configuration) -> [String: Any] {
        var overrides: [String: Any] = [:]
        if let corner = configuration.hudCorner {
            overrides[PreferenceKeys.recordingHUDCorner] = corner
        }
        return overrides
    }

    /// Rejects roots that would write into the user's real recording library.
    ///
    /// The agent may only write below an explicit temporary or test directory; a
    /// root inside `~/Movies/SnapGlass`, the app support folder, or the home
    /// directory itself would defeat the isolation guarantee.
    static func validateIsolatedRoot(_ url: URL, home: URL) throws {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard !path.isEmpty, path != "/" else { throw ParseFailure.unsafeRoot(path) }

        let homePath = home.standardizedFileURL.resolvingSymlinksInPath().path
        guard path != homePath else { throw ParseFailure.unsafeRoot(path) }

        let protected = [
            home.appendingPathComponent("Movies/SnapGlass", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/SnapGlass", isDirectory: true),
            home.appendingPathComponent("Library/Preferences", isDirectory: true),
            home.appendingPathComponent("Library/Containers/com.snapglass.app", isDirectory: true),
        ]
        for base in protected {
            let basePath = base.standardizedFileURL.resolvingSymlinksInPath().path
            if path == basePath || path.hasPrefix(basePath + "/") {
                throw ParseFailure.unsafeRoot(path)
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case ParseFailure.missingScenarioPath:
            return "missing --agent-run <scenario.json>"
        case let ParseFailure.missingValue(flag):
            return "missing value for \(flag)"
        case let ParseFailure.invalidValue(flag, value):
            return "invalid value for \(flag): \(value)"
        case let ParseFailure.unsafeRoot(path):
            return "refusing to write inside the user library: \(path)"
        default:
            return String(describing: error)
        }
    }
}

/// HUD corners accepted by `--agent-hud-corner`.
enum RecordingHUDAgentCorners {
    /// Corner identifiers understood by `RecordingHUDPlacement`.
    static let all: Set<String> = [
        "topLeading",
        "topTrailing",
        "bottomLeading",
        "bottomTrailing",
    ]
}

/// In-memory UserDefaults used by the agent channel.
///
/// Every read is served from the dictionary below and every write stays in
/// memory, so an agent scenario can never change the user's preferences. The
/// backing store is a private, never-written suite so even a bypassed read
/// cannot see the user's real domain.
final class AgentPreferences: UserDefaults {
    private var storage: [String: Any]

    /// Creates an isolated preferences store, or `nil` when the private suite is unusable.
    init?(storage: [String: Any] = [:]) {
        self.storage = storage
        super.init(suiteName: "com.snapglass.agent.memory")
    }

    override func object(forKey defaultName: String) -> Any? {
        storage[defaultName]
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        if let value {
            storage[defaultName] = value
        } else {
            storage.removeValue(forKey: defaultName)
        }
    }

    override func removeObject(forKey defaultName: String) {
        storage.removeValue(forKey: defaultName)
    }

    override func string(forKey defaultName: String) -> String? {
        storage[defaultName] as? String
    }

    override func bool(forKey defaultName: String) -> Bool {
        (storage[defaultName] as? NSNumber)?.boolValue
            ?? (storage[defaultName] as? Bool)
            ?? false
    }

    override func integer(forKey defaultName: String) -> Int {
        (storage[defaultName] as? NSNumber)?.intValue ?? 0
    }

    override func double(forKey defaultName: String) -> Double {
        (storage[defaultName] as? NSNumber)?.doubleValue ?? 0
    }

    override func array(forKey defaultName: String) -> [Any]? {
        storage[defaultName] as? [Any]
    }

    override func dictionary(forKey defaultName: String) -> [String: Any]? {
        storage[defaultName] as? [String: Any]
    }

    override func data(forKey defaultName: String) -> Data? {
        storage[defaultName] as? Data
    }

    override func stringArray(forKey defaultName: String) -> [String]? {
        storage[defaultName] as? [String]
    }

    override func dictionaryRepresentation() -> [String: Any] {
        storage
    }

    override func synchronize() -> Bool {
        true
    }
}

/// Resolves the isolated recording root for any code that asks where recordings live.
enum AgentIsolation {
    /// Environment variable that carries the isolated recording root to helper code.
    static let rootEnvironmentKey = "SNAPGLASS_AGENT_ROOT"

    /// Returns the isolated root when the agent channel is active, otherwise `nil`.
    ///
    /// - Parameter environment: Process environment, injectable for tests.
    /// - Returns: The recording root that must replace the user's library.
    static func recordingRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if let value = environment[rootEnvironmentKey], !value.isEmpty {
            return URL(fileURLWithPath: value).standardizedFileURL
        }
        if let configuration = AgentMode.configuration {
            return configuration.rootURL
        }
        return nil
    }
}
