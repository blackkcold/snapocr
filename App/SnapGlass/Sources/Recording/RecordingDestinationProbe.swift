import CaptureCore
import Foundation
import SharedKit

/// Read-only outcome of a write destination capacity probe.
enum RecordingDestinationCapacity: Sendable, Equatable {
    /// Free bytes on the volume that actually receives the recording.
    ///
    /// `probedDirectory` is the exact target when it exists, or the nearest
    /// confirmed ancestor for a default folder that has not been created yet.
    case available(bytes: Int64, probedDirectory: URL, volume: RecordingVolumeIdentity?)
    /// The write location is missing, not a directory, or not writable.
    case locationUnavailable
    /// The write location exists but its free space cannot be read in time.
    case capacityUnreadable
}

/// Errors raised while validating a recording destination before start.
enum RecordingDestinationError: LocalizedError, Equatable, Sendable {
    case customDirectoryUnavailable
    case defaultDirectoryUnavailable
    case unavailableCapacity
    case timedOut
    case insufficientCapacity(available: Int64, required: Int64)
    case destinationCreationFailed(String)

    var errorDescription: String? {
        switch self {
        case .customDirectoryUnavailable:
            AppLocalization.string("The selected recording folder is unavailable. Choose it again in Preferences.")
        case .defaultDirectoryUnavailable:
            AppLocalization.string("The default recording folder is unavailable.")
        case .unavailableCapacity, .timedOut:
            AppLocalization.string("Could not check free space in the recording folder.")
        case let .insufficientCapacity(available, required):
            AppLocalization.string(
                "Not enough space: %@ available, %@ required.",
                RecordingStorage.formattedBytes(available),
                RecordingStorage.formattedBytes(required)
            )
        case let .destinationCreationFailed(message):
            message
        }
    }
}

/// Validates a recording destination and reads free space off the main actor.
///
/// Blocking `FileManager` calls run on a dedicated serial queue per destination
/// path. Identical concurrent probes share that one in-flight operation, so a
/// stalled network volume cannot create additional blocked workers. Each caller
/// still has its own deadline and a timeout is reported distinctly.
///
/// Only paths that actually receive bytes are inspected. A directory with no
/// writer is never part of these entry points.
struct RecordingDestinationProbe: Sendable {
    /// Deadline for one probe on a possibly slow external volume.
    static let defaultDeadline: Duration = .seconds(5)

    /// Validates or creates the destination and checks the 1 GiB start floor.
    ///
    /// Used by the screen-recording start path, whose existing start floor is
    /// 1 GiB. A custom directory must already exist; a default directory is
    /// created here. The recovery directory is not part of this check.
    ///
    /// - Parameters:
    ///   - directory: The write destination to validate or create.
    ///   - isCustom: Whether the user picked the directory.
    ///   - expectedVolumeUUID: Volume the destination must live on; `nil` skips
    ///     the identity check.
    ///   - deadline: The maximum time to wait for the filesystem.
    /// - Throws: ``RecordingDestinationError`` for an invalid, unreadable,
    ///   timed-out, or insufficient destination.
    static func prepare(
        directory: URL,
        isCustom: Bool,
        expectedVolumeUUID: String? = nil,
        deadline: Duration = defaultDeadline
    ) async throws {
        let outcome = await DestinationProbeEngine.shared.probe(
            directory: directory,
            request: isCustom ? .prepareCustom : .prepareDefault,
            expectedVolumeUUID: expectedVolumeUUID,
            deadline: deadline
        )
        switch outcome {
        case .timedOut:
            throw RecordingDestinationError.timedOut
        case let .result(result):
            switch result {
            case let .ready(bytes, _, _):
                guard bytes >= RecordingStorage.minimumStartFreeSpace else {
                    throw RecordingDestinationError.insufficientCapacity(
                        available: bytes,
                        required: RecordingStorage.minimumStartFreeSpace
                    )
                }
            case .locationUnavailable:
                throw isCustom
                    ? RecordingDestinationError.customDirectoryUnavailable
                    : RecordingDestinationError.defaultDirectoryUnavailable
            case .located, .capacityUnreadable:
                throw RecordingDestinationError.unavailableCapacity
            case let .creationFailed(message):
                throw RecordingDestinationError.destinationCreationFailed(message)
            }
        }
    }

    /// Reads a write destination without creating it.
    ///
    /// Used by both settings pages. For a default folder that does not exist
    /// yet, the nearest confirmed ancestor is probed instead; a custom folder is
    /// always checked at the exact path the user selected.
    static func inspect(
        directory: URL,
        isCustom: Bool,
        expectedVolumeUUID: String? = nil,
        deadline: Duration = defaultDeadline
    ) async -> RecordingDestinationCapacity {
        let outcome = await DestinationProbeEngine.shared.probe(
            directory: directory,
            request: isCustom ? .inspectCustom : .inspectDefault,
            expectedVolumeUUID: expectedVolumeUUID,
            deadline: deadline
        )
        switch outcome {
        case .timedOut:
            return .capacityUnreadable
        case let .result(result):
            switch result {
            case let .ready(bytes, probedDirectory, identity):
                return .available(
                    bytes: bytes,
                    probedDirectory: probedDirectory,
                    volume: identity
                )
            case .locationUnavailable, .creationFailed:
                return .locationUnavailable
            case .capacityUnreadable, .located:
                return .capacityUnreadable
            }
        }
    }

    /// Confirms that the write destination is a usable location.
    ///
    /// This performs no capacity read and never creates a directory. Audio start
    /// uses it before constructing the pipeline; the pipeline's `preflightStart`
    /// remains the single capacity decision.
    static func validateLocation(
        directory: URL,
        isCustom: Bool,
        expectedVolumeUUID: String? = nil,
        deadline: Duration = defaultDeadline
    ) async throws {
        let outcome = await DestinationProbeEngine.shared.probe(
            directory: directory,
            request: isCustom ? .validateCustom : .validateDefault,
            expectedVolumeUUID: expectedVolumeUUID,
            deadline: deadline
        )
        switch outcome {
        case .timedOut:
            throw isCustom
                ? RecordingDestinationError.customDirectoryUnavailable
                : RecordingDestinationError.defaultDirectoryUnavailable
        case let .result(result):
            switch result {
            case .located:
                return
            case .locationUnavailable:
                throw isCustom
                    ? RecordingDestinationError.customDirectoryUnavailable
                    : RecordingDestinationError.defaultDirectoryUnavailable
            case .capacityUnreadable, .ready, .creationFailed:
                throw isCustom
                    ? RecordingDestinationError.customDirectoryUnavailable
                    : RecordingDestinationError.defaultDirectoryUnavailable
            }
        }
    }

    /// Reads free space at an existing write directory without creating it.
    ///
    /// Used by the in-recording 512 MiB poll. A timeout is reported as
    /// ``RecordingDestinationCapacity/capacityUnreadable`` so the caller can skip
    /// that poll instead of claiming the volume disappeared.
    static func capacity(
        at directory: URL,
        expectedVolumeUUID: String? = nil,
        deadline: Duration = defaultDeadline
    ) async -> RecordingDestinationCapacity {
        let outcome = await DestinationProbeEngine.shared.probe(
            directory: directory,
            request: .capacity,
            expectedVolumeUUID: expectedVolumeUUID,
            deadline: deadline
        )
        switch outcome {
        case .timedOut:
            return .capacityUnreadable
        case let .result(result):
            switch result {
            case let .ready(bytes, probedDirectory, identity):
                return .available(
                    bytes: bytes,
                    probedDirectory: probedDirectory,
                    volume: identity
                )
            case .locationUnavailable, .creationFailed:
                return .locationUnavailable
            case .capacityUnreadable, .located:
                return .capacityUnreadable
            }
        }
    }
}

/// Runs blocking recording pipeline construction off the main actor.
///
/// Pipeline creation creates session directories and initializes the ledger. It
/// stays one synchronous `make` call (never split into two phases) but runs on a
/// dedicated serial queue, so a slow destination also cannot block the UI.
enum RecordingPipelineSetupQueue {
    private static let queue = DispatchQueue(
        label: "com.snapglass.recording.pipeline-setup",
        qos: .userInitiated
    )

    /// Runs one blocking construction on the setup queue.
    ///
    /// - Parameter operation: A sendable, synchronous pipeline factory call.
    /// - Returns: The constructed value.
    /// - Throws: Whatever the operation throws.
    static func run<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try operation() })
            }
        }
    }
}

private enum DestinationProbeRequest: Sendable {
    case prepareCustom
    case prepareDefault
    case inspectCustom
    case inspectDefault
    case validateCustom
    case validateDefault
    case capacity

    var key: String {
        switch self {
        case .prepareCustom: "prepare-custom"
        case .prepareDefault: "prepare-default"
        case .inspectCustom: "inspect-custom"
        case .inspectDefault: "inspect-default"
        case .validateCustom: "validate-custom"
        case .validateDefault: "validate-default"
        case .capacity: "capacity"
        }
    }
}

private enum DestinationProbeResult: Sendable {
    case located
    case ready(bytes: Int64, probedDirectory: URL, identity: RecordingVolumeIdentity?)
    case locationUnavailable
    case capacityUnreadable
    case creationFailed(String)
}

private enum DestinationProbeOutcome: Sendable {
    case result(DestinationProbeResult)
    case timedOut
}

/// Single-flight probe engine with one serial queue per destination path.
private final class DestinationProbeEngine: @unchecked Sendable {
    static let shared = DestinationProbeEngine()

    private final class Flight: @unchecked Sendable {
        var waiters: [DestinationProbeWaiter] = []
        var leaderRunning = false
    }

    private let lock = NSLock()
    private var queues: [String: DispatchQueue] = [:]
    private var flights: [String: Flight] = [:]

    func probe(
        directory: URL,
        request: DestinationProbeRequest,
        expectedVolumeUUID: String?,
        deadline: Duration
    ) async -> DestinationProbeOutcome {
        let standardized = directory.standardizedFileURL
        let queueKey = standardized.path
        let requestKey = "\(queueKey)|\(request.key)|\(expectedVolumeUUID ?? "-")"
        let waiter = DestinationProbeWaiter()

        let (queue, startsLeader) = lock.withLock { () -> (DispatchQueue, Bool) in
            let queue: DispatchQueue
            if let existing = queues[queueKey] {
                queue = existing
            } else {
                let created = DispatchQueue(
                    label: "com.snapglass.recording.destination-probe",
                    qos: .userInitiated
                )
                queues[queueKey] = created
                queue = created
            }
            let flight = flights[requestKey] ?? Flight()
            flights[requestKey] = flight
            flight.waiters.append(waiter)
            let startsLeader = !flight.leaderRunning
            if startsLeader { flight.leaderRunning = true }
            return (queue, startsLeader)
        }

        if startsLeader {
            queue.async { [weak self] in
                let result = Self.perform(
                    request,
                    directory: standardized,
                    expectedVolumeUUID: expectedVolumeUUID
                )
                self?.complete(requestKey: requestKey, result: result)
            }
        }

        let timer = Task { [weak self] in
            do {
                try await Task.sleep(for: deadline)
            } catch {
                return
            }
            self?.timeOut(requestKey: requestKey, waiter: waiter)
        }
        let outcome = await waiter.value()
        timer.cancel()
        return outcome
    }

    /// Resolves every caller still waiting for this one in-flight operation.
    private func complete(requestKey: String, result: DestinationProbeResult) {
        let flight = lock.withLock { flights.removeValue(forKey: requestKey) }
        guard let flight else { return }
        for waiter in flight.waiters {
            waiter.resolve(.result(result))
        }
    }

    /// Resolves one caller without starting a second filesystem operation.
    private func timeOut(requestKey: String, waiter: DestinationProbeWaiter) {
        lock.withLock {
            if let flight = flights[requestKey] {
                flight.waiters.removeAll { $0 === waiter }
                if flight.waiters.isEmpty && !flight.leaderRunning {
                    flights[requestKey] = nil
                }
            }
        }
        waiter.resolve(.timedOut)
    }

    private static func perform(
        _ request: DestinationProbeRequest,
        directory: URL,
        expectedVolumeUUID: String?
    ) -> DestinationProbeResult {
        let fileManager = FileManager.default
        switch request {
        case .prepareCustom:
            return prepareCustom(
                directory: directory,
                expectedVolumeUUID: expectedVolumeUUID,
                fileManager: fileManager
            )
        case .prepareDefault:
            return prepareDefault(directory: directory, fileManager: fileManager)
        case .inspectCustom:
            return inspectCustom(
                directory: directory,
                expectedVolumeUUID: expectedVolumeUUID,
                fileManager: fileManager
            )
        case .inspectDefault:
            return inspectDefault(directory: directory, fileManager: fileManager)
        case .validateCustom:
            return validateCustom(
                directory: directory,
                expectedVolumeUUID: expectedVolumeUUID,
                fileManager: fileManager
            )
        case .validateDefault:
            return validateDefault(directory: directory, fileManager: fileManager)
        case .capacity:
            return capacity(
                directory: directory,
                expectedVolumeUUID: expectedVolumeUUID,
                fileManager: fileManager
            )
        }
    }

    private static func prepareCustom(
        directory: URL,
        expectedVolumeUUID: String?,
        fileManager: FileManager
    ) -> DestinationProbeResult {
        guard
            customLocationIsUsable(
                directory: directory,
                expectedVolumeUUID: expectedVolumeUUID,
                fileManager: fileManager
            )
        else { return .locationUnavailable }
        return readCapacity(at: directory)
    }

    private static func prepareDefault(
        directory: URL,
        fileManager: FileManager
    ) -> DestinationProbeResult {
        if existsAsNonDirectory(directory, fileManager) {
            return .locationUnavailable
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .creationFailed(error.localizedDescription)
        }
        guard isWritableDirectory(directory, fileManager) else {
            return .locationUnavailable
        }
        return readCapacity(at: directory)
    }

    private static func inspectCustom(
        directory: URL,
        expectedVolumeUUID: String?,
        fileManager: FileManager
    ) -> DestinationProbeResult {
        guard
            customLocationIsUsable(
                directory: directory,
                expectedVolumeUUID: expectedVolumeUUID,
                fileManager: fileManager
            )
        else { return .locationUnavailable }
        return readCapacity(at: directory)
    }

    private static func inspectDefault(
        directory: URL,
        fileManager: FileManager
    ) -> DestinationProbeResult {
        if existsAsNonDirectory(directory, fileManager) {
            return .locationUnavailable
        }
        guard let probed = nearestExistingDirectory(for: directory, fileManager: fileManager),
            isWritableDirectory(probed, fileManager)
        else {
            return .locationUnavailable
        }
        return readCapacity(at: probed)
    }

    private static func validateCustom(
        directory: URL,
        expectedVolumeUUID: String?,
        fileManager: FileManager
    ) -> DestinationProbeResult {
        customLocationIsUsable(
            directory: directory,
            expectedVolumeUUID: expectedVolumeUUID,
            fileManager: fileManager
        ) ? .located : .locationUnavailable
    }

    private static func validateDefault(
        directory: URL,
        fileManager: FileManager
    ) -> DestinationProbeResult {
        if existsAsNonDirectory(directory, fileManager) {
            return .locationUnavailable
        }
        if fileManager.fileExists(atPath: directory.path) {
            return isWritableDirectory(directory, fileManager) ? .located : .locationUnavailable
        }
        guard let probed = nearestExistingDirectory(for: directory, fileManager: fileManager),
            isWritableDirectory(probed, fileManager)
        else {
            return .locationUnavailable
        }
        return .located
    }

    private static func capacity(
        directory: URL,
        expectedVolumeUUID: String?,
        fileManager: FileManager
    ) -> DestinationProbeResult {
        guard
            customLocationIsUsable(
                directory: directory,
                expectedVolumeUUID: expectedVolumeUUID,
                fileManager: fileManager
            )
        else { return .locationUnavailable }
        return readCapacity(at: directory)
    }

    private static func customLocationIsUsable(
        directory: URL,
        expectedVolumeUUID: String?,
        fileManager: FileManager
    ) -> Bool {
        isWritableDirectory(directory, fileManager)
            && customVolumeIsAcceptable(directory, expectedVolumeUUID: expectedVolumeUUID)
    }

    /// Accepts a custom write path only when its volume identity still matches.
    ///
    /// New selections carry a persistent `volumeUUIDString`. Existing settings
    /// have no stored UUID; for those, only the reserved `/Volumes/<Name>`
    /// namespace gets a compatibility guard: a real directory on the system
    /// volume is treated as a stale mount point, while a symbolic-link system
    /// alias or a real mounted volume is accepted.
    private static func customVolumeIsAcceptable(
        _ directory: URL,
        expectedVolumeUUID: String?
    ) -> Bool {
        if let expectedVolumeUUID {
            guard let current = RecordingVolumeIdentityPolicy.volumeUUIDString(for: directory) else {
                return false
            }
            return current == expectedVolumeUUID
        }
        return !RecordingVolumeIdentityPolicy.isStaleVolumesMountPoint(directory)
    }

    private static func readCapacity(at directory: URL) -> DestinationProbeResult {
        do {
            guard let snapshot = try URLVolumeCapacityProvider().volumeSnapshot(at: directory),
                snapshot.availableBytes >= 0
            else {
                return .capacityUnreadable
            }
            return .ready(
                bytes: snapshot.availableBytes,
                probedDirectory: directory,
                identity: snapshot.identity
            )
        } catch {
            return .capacityUnreadable
        }
    }

    /// Returns the target or its nearest existing directory, bounded to the Home.
    ///
    /// The walk only checks existence; it never reads capacity. The chosen
    /// ancestor must be a component-prefix of the target and must not cross a
    /// mount point on the way down, so a missing default folder cannot borrow
    /// another volume's free space.
    private static func nearestExistingDirectory(
        for directory: URL,
        fileManager: FileManager
    ) -> URL? {
        let target = directory.standardizedFileURL
        let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL
        let targetComponents = target.pathComponents
        let homeComponents = home.pathComponents

        guard targetComponents.count > homeComponents.count,
            Array(targetComponents.prefix(homeComponents.count)) == homeComponents
        else {
            return nil
        }

        var candidate = target
        while candidate.pathComponents.count > homeComponents.count {
            var isDirectory = ObjCBool(false)
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory) {
                guard isDirectory.boolValue else { return nil }
                guard !crossesMountPoint(from: candidate, to: target) else {
                    return nil
                }
                return candidate
            }
            if (try? fileManager.destinationOfSymbolicLink(atPath: candidate.path)) != nil {
                // A broken symlink means the expected volume is gone; do not
                // borrow the parent volume's free space.
                return nil
            }
            candidate.deleteLastPathComponent()
        }

        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: home.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return nil
        }
        return home
    }

    /// Rejects a candidate that would cross into another mounted volume while
    /// descending. A volume root (`isVolume`) is the mount point of a volume.
    private static func crossesMountPoint(
        from ancestor: URL,
        to target: URL
    ) -> Bool {
        let ancestorComponents = ancestor.pathComponents
        let targetComponents = target.pathComponents
        guard targetComponents.count >= ancestorComponents.count,
            Array(targetComponents.prefix(ancestorComponents.count)) == ancestorComponents
        else {
            return true
        }

        var current = ancestor
        for component
            in targetComponents
            .dropFirst(ancestorComponents.count)
            .dropLast()
        {
            current.appendPathComponent(component)
            if let values = try? current.resourceValues(forKeys: [.isVolumeKey]),
                values.isVolume == true
            {
                return true
            }
        }
        return false
    }

    private static func existsAsNonDirectory(
        _ url: URL,
        _ fileManager: FileManager
    ) -> Bool {
        var isDirectory = ObjCBool(false)
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    private static func isWritableDirectory(
        _ url: URL,
        _ fileManager: FileManager
    ) -> Bool {
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return false
        }
        return fileManager.isWritableFile(atPath: url.path)
    }
}

/// One-shot, thread-safe waiter shared by the probe engine.
private final class DestinationProbeWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: DestinationProbeOutcome?
    private var continuation: CheckedContinuation<DestinationProbeOutcome, Never>?

    func resolve(_ outcome: DestinationProbeOutcome) {
        let pending: CheckedContinuation<DestinationProbeOutcome, Never>? = lock.withLock {
            guard self.outcome == nil else { return nil }
            self.outcome = outcome
            let continuation = continuation
            self.continuation = nil
            return continuation
        }
        pending?.resume(returning: outcome)
    }

    func value() async -> DestinationProbeOutcome {
        await withCheckedContinuation { continuation in
            let resolved: DestinationProbeOutcome? = lock.withLock {
                if let outcome { return outcome }
                self.continuation = continuation
                return nil
            }
            if let resolved {
                continuation.resume(returning: resolved)
            }
        }
    }
}
