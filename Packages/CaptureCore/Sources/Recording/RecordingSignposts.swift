import Foundation
import os

/// A privacy-safe recording phase that can be emitted to the signpost log.
public enum RecordingPhase: String, Sendable {
    /// The session is validating configuration and preparing resources.
    case preparing
    /// Capture has been asked to start but no media has been accepted yet.
    case starting
    /// Real media (a writer-accepted frame or a real captured sample) has arrived.
    case recording
    /// Capture stopped and remaining media is being drained and published.
    case saving
    /// The session finished and its published media is durable.
    case finished
    /// The session failed but recoverable material may still be salvaged.
    case failed
    /// The user cancelled before any recording started.
    case cancelled
    /// Quit resolution completed for the session.
    case quitResolved
}

/// A privacy-safe failure class attached to a terminal recording phase.
///
/// Only the numeric class code leaves the process; the reason text never does.
public enum RecordingDiagnosticErrorClass: Int, Sendable {
    /// Capture permission was missing or was lost.
    case permission = 1
    /// The selected display, window, or region was unavailable.
    case source = 2
    /// The video writer failed or never accepted a frame.
    case writer = 3
    /// The destination directory was unavailable or too full.
    case destination = 4
    /// A bounded readiness or settlement wait expired.
    case timeout = 5
    /// The user cancelled before media was accepted.
    case cancelled = 6
    /// Any other failure.
    case unknown = 7
}

/// Emits one privacy-safe phase event.
///
/// Only a fixed pair of enum-derived event names is emitted. Never pass paths,
/// file names, device names, audio levels, session identifiers, or localized
/// text to this type. Metadata is restricted to integers: elapsed milliseconds
/// and a ``RecordingDiagnosticErrorClass`` raw value.
public enum RecordingSignposts {
    private static let signposter = OSSignposter(
        subsystem: "com.snapglass",
        category: "recording.phase"
    )

    /// Emits one point event for the given phase and recording kind.
    ///
    /// - Parameters:
    ///   - phase: The lifecycle phase that was reached.
    ///   - kind: The recording kind, which selects the static event-name prefix.
    ///   - elapsedMilliseconds: Optional duration since the previous phase.
    ///   - errorClass: Optional numeric failure class; never a message.
    public static func emit(
        _ phase: RecordingPhase,
        kind: RecordingKind,
        elapsedMilliseconds: Int? = nil,
        errorClass: RecordingDiagnosticErrorClass? = nil
    ) {
        let name = eventName(for: phase, kind: kind)
        switch (elapsedMilliseconds, errorClass) {
        case let (milliseconds?, failure?):
            signposter.emitEvent(
                name,
                id: .exclusive,
                "elapsed_ms=\(milliseconds) error_class=\(failure.rawValue)"
            )
        case let (milliseconds?, nil):
            signposter.emitEvent(name, id: .exclusive, "elapsed_ms=\(milliseconds)")
        case let (nil, failure?):
            signposter.emitEvent(name, id: .exclusive, "error_class=\(failure.rawValue)")
        case (nil, nil):
            signposter.emitEvent(name)
        }
    }

    /// Emits one point event for a start sub-stage.
    ///
    /// The stage is a fixed numeric code from `RecordingStartPhase`; no source
    /// name, path, file name, device name, or error text is ever attached.
    ///
    /// - Parameters:
    ///   - stage: The numeric start-stage code.
    ///   - kind: The recording kind, which selects the static event-name prefix.
    ///   - elapsedMilliseconds: Optional duration since the previous phase.
    public static func emitStartStage(
        _ stage: Int,
        kind: RecordingKind,
        elapsedMilliseconds: Int? = nil
    ) {
        let name: StaticString = kind == .audio ? "audio.start_stage" : "screen.start_stage"
        if let elapsedMilliseconds {
            signposter.emitEvent(name, id: .exclusive, "stage=\(stage) elapsed_ms=\(elapsedMilliseconds)")
        } else {
            signposter.emitEvent(name, id: .exclusive, "stage=\(stage)")
        }
    }

    private static let eventNames: [String: StaticString] = [
        "audio.preparing": "audio.preparing",
        "audio.starting": "audio.starting",
        "audio.recording": "audio.recording",
        "audio.saving": "audio.saving",
        "audio.finished": "audio.finished",
        "audio.failed": "audio.failed",
        "audio.cancelled": "audio.cancelled",
        "audio.quitResolved": "audio.quitResolved",
        "screen.preparing": "screen.preparing",
        "screen.starting": "screen.starting",
        "screen.recording": "screen.recording",
        "screen.saving": "screen.saving",
        "screen.finished": "screen.finished",
        "screen.failed": "screen.failed",
        "screen.cancelled": "screen.cancelled",
        "screen.quitResolved": "screen.quitResolved",
    ]

    private static func eventName(for phase: RecordingPhase, kind: RecordingKind) -> StaticString {
        let prefix = kind == .audio ? "audio" : "screen"
        return eventNames["\(prefix).\(phase.rawValue)"] ?? "unknown"
    }
}
