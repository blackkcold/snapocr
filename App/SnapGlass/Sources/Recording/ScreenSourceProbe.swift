import AppKit
import CaptureCore
import Foundation
@preconcurrency import ScreenCaptureKit

/// One attempt at enumerating the screen sources needed by the recording picker.
///
/// The result is deliberately not cached: a caller must hold an attempt identity
/// and discard this outcome if the user cancelled or started another attempt.
enum ScreenSourceProbeOutcome {
    /// Capture access is available and the enumerated content is ready to use.
    case ready(SCShareableContent)
    /// Capture access is not available; the caller shows the permission guide.
    case denied
    /// An already-authorized enumeration exceeded its bounded deadline.
    case timedOut
    /// Access may be available but enumeration failed for another reason.
    case failed(String)
}

/// Enumerates screen sources with one deliberate distinction:
///
/// - When screen-capture access is already granted, enumeration is bounded by
///   ``RecordingReadiness/sourceEnumerationDeadline`` so a stalled ScreenCaptureKit
///   call cannot leave the preparing UI spinning forever.
/// - When access is not yet granted, ScreenCaptureKit may be waiting on the system
///   authorization prompt. That wait is *not* bounded: expiring there would fail a
///   user who is still reading the prompt. It stays cancellable instead, and the
///   late result is discarded by the caller's attempt check.
@MainActor
enum ScreenSourceProbe {
    /// Loads the shareable content for one recording-source selection.
    ///
    /// - Returns: The enumeration outcome; never throws.
    static func load() async -> ScreenSourceProbeOutcome {
        let accessAlreadyGranted = CGPreflightScreenCaptureAccess()
        // The content never crosses an isolation boundary: the enumerating task
        // writes it into a main-actor box and the caller reads it there.
        let box = ScreenSourceProbeBox()
        let (signals, continuation) = AsyncStream<ScreenSourceProbeSignal>.makeStream()

        let enumerator = Task { @MainActor in
            defer { continuation.finish() }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    true,
                    onScreenWindowsOnly: true
                )
                guard !content.displays.isEmpty else {
                    continuation.yield(.denied)
                    return
                }
                box.content = content
                continuation.yield(.ready)
            } catch {
                if accessAlreadyGranted {
                    box.failureMessage = error.localizedDescription
                    continuation.yield(.failed)
                } else {
                    continuation.yield(.denied)
                }
            }
        }

        var timeout: Task<Void, Never>?
        if accessAlreadyGranted {
            timeout = Task { @MainActor in
                do {
                    try await Task.sleep(for: RecordingReadiness.sourceEnumerationDeadline)
                } catch {
                    return
                }
                continuation.yield(.timedOut)
                continuation.finish()
            }
        }

        // First signal wins: both producers yield at most once and the stream keeps
        // them in order, so a late enumeration result cannot overwrite a timeout.
        var signal: ScreenSourceProbeSignal?
        for await value in signals {
            signal = value
            break
        }
        enumerator.cancel()
        timeout?.cancel()

        switch signal {
        case .ready:
            guard let content = box.content else {
                return .failed(box.failureMessage ?? AppLocalization.string("Could not load recording sources."))
            }
            return .ready(content)
        case .denied:
            return .denied
        case .failed:
            return .failed(box.failureMessage ?? AppLocalization.string("Could not load recording sources."))
        case .timedOut, .none:
            return .timedOut
        }
    }
}

/// The only values that travel between the enumeration task and its caller.
private enum ScreenSourceProbeSignal: Sendable {
    case ready
    case denied
    case failed
    case timedOut
}

/// Main-actor storage for the enumerated content and its failure text.
@MainActor
private final class ScreenSourceProbeBox {
    var content: SCShareableContent?
    var failureMessage: String?
}
