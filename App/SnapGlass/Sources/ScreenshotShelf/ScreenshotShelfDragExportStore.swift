import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Reads the uniform type identifier from encoded image bytes.
enum ScreenshotShelfImageTypeIdentifier {
    static func identifier(for data: Data) -> String? {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let type = CGImageSourceGetType(source)
        else { return nil }
        return type as String
    }
}


/// Keeps a plaintext copy of each shelf screenshot so a card can be dragged out
/// as a real file without waiting for a decrypt-and-encode step.
///
/// Originals in the shelf session store and the history database are encrypted,
/// so a `fileURL` drag needs a real file on disk. Files live in a per-process
/// directory under the caches folder, are readable only by the current user,
/// and are removed when the card leaves the shelf or when the next launch sweeps
/// abandoned sessions.
@MainActor
final class ScreenshotShelfDragExportStore {
    struct Artifact: Equatable, Sendable {
        let url: URL
        let byteCount: Int
    }

    private let rootDirectory: URL?
    private let sessionDirectory: URL?
    private let now: () -> Date
    private let timeZone: TimeZone

    private var artifacts: [UUID: Artifact] = [:]
    private var revisions: [UUID: String] = [:]
    private var tasks: [UUID: Task<Artifact?, Never>] = [:]
    private var invalidatedIDs: Set<UUID> = []
    private var invalidationGeneration = 0

    init(
        rootDirectory: URL? = nil,
        now: @escaping () -> Date = Date.init,
        timeZone: TimeZone = .current
    ) {
        let resolvedRoot = rootDirectory ?? Self.defaultRootDirectory()
        self.rootDirectory = resolvedRoot
        sessionDirectory = Self.makeSessionDirectory(in: resolvedRoot)
        self.now = now
        self.timeZone = timeZone
    }

    /// Writes the bytes once per capture and returns the same artifact afterwards.
    ///
    /// - Parameters:
    ///   - captureID: The shelf card that owns the bytes.
    ///   - data: The already-encoded image bytes. Callers reuse the bytes the
    ///     session store encoded, so no second image encode happens here.
    ///   - sourceTypeIdentifier: A uniform type identifier for `data`, used only
    ///     to pick a truthful file extension. Unknown values fall back to PNG.
    /// - Returns: The written artifact, or `nil` when the cache directory is
    ///   unavailable or the write failed.
    @discardableResult
    func prepare(
        captureID: UUID,
        data: Data,
        sourceTypeIdentifier: String?,
        revision: String? = nil
    ) async -> Artifact? {
        if let existing = artifact(for: captureID) {
            return existing
        }
        if let task = tasks[captureID] {
            return await task.value
        }
        guard let sessionDirectory else { return nil }

        invalidatedIDs.remove(captureID)
        let date = now()
        let timeZone = timeZone
        let identifier = sourceTypeIdentifier

        let generation = invalidationGeneration

        let task = Task { [weak self] () -> Artifact? in
            let artifact = await dragExportWriter.write(
                data: data,
                date: date,
                timeZone: timeZone,
                sourceTypeIdentifier: identifier,
                in: sessionDirectory
            )

            guard let self else { return artifact }
            self.tasks[captureID] = nil
            guard let artifact else { return nil }
            guard generation == self.invalidationGeneration,
                !self.invalidatedIDs.contains(captureID)
            else {
                try? FileManager.default.removeItem(at: artifact.url)
                return nil
            }
            self.artifacts[captureID] = artifact
            if let revision {
                self.revisions[captureID] = revision
            } else {
                self.revisions[captureID] = nil
            }
            return artifact
        }
        tasks[captureID] = task
        return await task.value
    }

    /// Returns the ready artifact, dropping the entry if the file disappeared.
    func artifact(for captureID: UUID) -> Artifact? {
        guard let artifact = artifacts[captureID] else { return nil }
        guard FileManager.default.fileExists(atPath: artifact.url.path) else {
            artifacts[captureID] = nil
            revisions[captureID] = nil
            return nil
        }
        return artifact
    }

    /// The history revision the current file was produced from, when known.
    func revision(for captureID: UUID) -> String? {
        revisions[captureID]
    }

    /// Removes the plaintext copy after the card's bytes changed or the card left the shelf.
    func invalidate(captureID: UUID) {
        invalidatedIDs.insert(captureID)
        tasks[captureID]?.cancel()
        tasks[captureID] = nil
        revisions[captureID] = nil
        guard let artifact = artifacts.removeValue(forKey: captureID) else { return }
        try? FileManager.default.removeItem(at: artifact.url)
    }

    /// Removes every plaintext copy for this process session.
    func removeAll() {
        for task in tasks.values {
            task.cancel()
        }
        tasks.removeAll()
        artifacts.removeAll()
        revisions.removeAll()
        invalidatedIDs.removeAll()
        invalidationGeneration &+= 1
        guard let sessionDirectory else { return }
        try? FileManager.default.removeItem(at: sessionDirectory)
        try? FileManager.default.createDirectory(
            at: sessionDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    /// Deletes export directories left behind by earlier launches.
    ///
    /// Anything but this process's own session directory is dead by definition.
    /// The short grace window only protects a second instance that started
    /// moments ago from having its files deleted underneath it.
    func sweepStale(olderThan maxAge: TimeInterval = 60) {
        guard let rootDirectory, let sessionDirectory else { return }
        let fileManager = FileManager.default
        let cutoff = now().addingTimeInterval(-maxAge)
        let currentName = sessionDirectory.lastPathComponent
        guard
            let entries = try? fileManager.contentsOfDirectory(
                at: rootDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]
            )
        else { return }

        for entry in entries where entry.lastPathComponent.hasPrefix("session-") {
            guard entry.lastPathComponent != currentName else { continue }
            let values = try? entry.resourceValues(
                forKeys: [.contentModificationDateKey, .isDirectoryKey]
            )
            guard values?.isDirectory == true else { continue }
            let modified = values?.contentModificationDate ?? .distantPast
            guard modified < cutoff else { continue }
            try? fileManager.removeItem(at: entry)
        }
    }

    // MARK: - File system

    private nonisolated static func defaultRootDirectory() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SnapGlass", isDirectory: true)
            .appendingPathComponent("ScreenshotShelf", isDirectory: true)
            .appendingPathComponent("DragExport", isDirectory: true)
    }

    private nonisolated static func makeSessionDirectory(in root: URL?) -> URL? {
        guard let root else { return nil }
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            var directory = root
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? directory.setResourceValues(values)

            let session = root.appendingPathComponent(
                "session-\(UUID().uuidString)",
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: session,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            return session
        } catch {
            return nil
        }
    }

}

/// Serializes export writes so two cards finishing in the same second cannot
/// pick the same file name.
private actor ScreenshotShelfDragExportWriter {
    func write(
        data: Data,
        date: Date,
        timeZone: TimeZone,
        sourceTypeIdentifier: String?,
        in directory: URL
    ) -> ScreenshotShelfDragExportStore.Artifact? {
        let fileManager = FileManager.default
        let fileExtension = resolvedExtension(for: sourceTypeIdentifier)
        let baseName = baseName(for: date, timeZone: timeZone)

        var url = directory.appendingPathComponent("\(baseName).\(fileExtension)")
        var suffix = 2
        while fileManager.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(baseName)-\(suffix).\(fileExtension)")
            suffix += 1
        }

        do {
            try data.write(to: url, options: .atomic)
            return ScreenshotShelfDragExportStore.Artifact(url: url, byteCount: data.count)
        } catch {
            return nil
        }
    }

    private func baseName(for date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "SnapGlass_\(formatter.string(from: date))"
    }

    private func resolvedExtension(for identifier: String?) -> String {
        guard let identifier,
            let type = UTType(identifier),
            let preferred = type.preferredFilenameExtension
        else { return "png" }

        let sanitized = preferred.lowercased().filter { $0.isLetter || $0.isNumber }
        guard !sanitized.isEmpty else { return "png" }
        return sanitized == "jpeg" ? "jpg" : sanitized
    }
}

private let dragExportWriter = ScreenshotShelfDragExportWriter()
