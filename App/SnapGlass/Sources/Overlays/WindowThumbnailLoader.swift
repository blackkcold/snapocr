import AppKit
import CaptureCore
import SharedKit
import SwiftUI

@preconcurrency import ScreenCaptureKit

/// Loads window-picker thumbnails with a small concurrency pool.
/// The pool bounds simultaneous SCStreams, which would stall the picker if unbounded.
actor WindowThumbnailLoader {
    static let shared = WindowThumbnailLoader()

    private let orchestrator = CaptureOrchestrator()
    private var cache: [CGWindowID: CGImage] = [:]

    /// Max concurrent SCStream captures.
    private static let maxConcurrentCaptures = 4
    private var activeCaptures = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func thumbnail(for windowID: CGWindowID, content: SCShareableContent) async -> CGImage? {
        if let cached = cache[windowID] {
            return cached
        }

        return await thumbnail(for: windowID, content: content, forceRefresh: false)
    }

    /// Fetches (or re-fetches) a window thumbnail. Pass `forceRefresh: true` to
    /// bypass the cache so the picker shows the window's *current* contents rather
    /// than a stale frame from an earlier session.
    func thumbnail(for windowID: CGWindowID, content: SCShareableContent, forceRefresh: Bool) async -> CGImage? {
        if !forceRefresh, let cached = cache[windowID] {
            return cached
        }

        await acquireSlot()

        let result: CGImage?
        do {
            let image = try await orchestrator.captureWindowThumbnail(
                windowID: windowID,
                maximumSize: CGSize(width: 240, height: 140),
                content: content
            )
            cache[windowID] = image
            result = image
        } catch {
            result = nil
        }

        await releaseSlot()
        return result
    }

    /// Invalidates every cached thumbnail so the next picker session re-captures
    /// fresh window contents.
    func clearCache() {
        cache.removeAll()
    }

    private func acquireSlot() async {
        guard activeCaptures >= Self.maxConcurrentCaptures else {
            activeCaptures += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func releaseSlot() {
        if waiters.isEmpty {
            activeCaptures -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
