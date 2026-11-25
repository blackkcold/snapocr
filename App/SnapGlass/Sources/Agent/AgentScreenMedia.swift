import CaptureCore
import Foundation

/// On-disk video facts for one screen session, used only by the agent report.
///
/// The values are sizes, counts, and URLs under the isolated agent root. Nothing
/// here reads frame content or window metadata.
struct AgentScreenChunkFacts {
    /// Every `chunk-*.mp4` under the agent root.
    var urls: [URL] = []
    /// How many of those files are exactly zero bytes.
    var zeroByteCount = 0
    /// The largest chunk size in bytes.
    var largestBytes: Int64 = 0
    /// The file behind ``largestBytes``, when any chunk exists.
    var largestURL: URL?

    /// Number of chunk files found.
    var count: Int { urls.count }
}

/// Reads the screen media a run left on disk and the ledger's published entries.
enum AgentScreenMedia {
    /// Scans the isolated root for `chunk-*.mp4` files and their sizes.
    ///
    /// - Parameter root: The agent recording root (`--agent-root`).
    /// - Returns: The chunk facts; empty when the session wrote nothing.
    static func chunkFacts(root: URL) -> AgentScreenChunkFacts {
        let sessions = root.appendingPathComponent(".SnapGlassSessions", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: sessions,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return AgentScreenChunkFacts() }
        var facts = AgentScreenChunkFacts()
        for case let url as URL in enumerator
        where url.lastPathComponent.hasPrefix("chunk-") && url.pathExtension.lowercased() == "mp4" {
            facts.urls.append(url)
            let size = fileSize(url)
            if size == 0 { facts.zeroByteCount += 1 }
            if size > facts.largestBytes {
                facts.largestBytes = size
                facts.largestURL = url
            }
        }
        return facts
    }

    /// Published screen video URLs, read from the same ledger the recordings window uses.
    ///
    /// - Parameter roots: The isolated pipeline roots.
    /// - Returns: Published URLs in index order, or `nil` when the ledger is unreadable.
    static func publishedVideoURLs(roots: RecordingPipelineRoots) async -> [URL]? {
        guard let sessions = try? await RecordingSessionLedger.publishedSessions(
            in: roots.sessionRoot,
            indexURL: roots.indexURL
        ) else { return nil }
        return sessions
            .filter { $0.kind == .screen }
            .flatMap { record in
                record.segments.filter { $0.state == .published }.compactMap(\.videoURL)
            }
    }

    /// Size of one file in bytes, or `0` when it cannot be read.
    ///
    /// - Parameter url: The file to measure.
    /// - Returns: Its size in bytes.
    static func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
            ?? 0
    }
}
