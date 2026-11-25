import Foundation

extension ScreenSegmentCoordinator {
    /// Number of frames dropped by completed and currently active video writers.
    public func droppedVideoFrameCount() -> Int64 {
        let active = currentVideoWriter?.droppedFrameCount ?? 0
        let (total, overflow) = completedVideoDropCount.addingReportingOverflow(active)
        return overflow ? Int64.max : total
    }

    /// Privacy-safe writer counters for the whole session.
    ///
    /// Combines every finished chunk with the live one, so a failure that closed a
    /// chunk is still visible while the next chunk writes.
    public func writerDiagnostics() -> ScreenWriterDiagnostics {
        completedWriterDiagnostics.combined(with: currentVideoWriter?.diagnostics ?? .idle)
    }

    /// Published screen MP4 URLs in segment order, read from the durable ledger.
    public func publishedVideoURLs() async throws -> [URL] {
        let snapshot = try await ledger.snapshot()
        return snapshot.segments
            .filter { $0.state == .published }
            .sorted { $0.index < $1.index }
            .compactMap(\.videoURL)
    }
}
