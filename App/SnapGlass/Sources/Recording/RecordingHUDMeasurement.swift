import CaptureCore
import CoreGraphics
import Foundation

/// The visible step of a recording that has not started capture yet.
///
/// Shown from the moment the user asks to record: permission checks and source
/// enumeration are part of the session, not a silent gap before it.
enum RecordingPreparationPhase: Hashable, Sendable {
    case checkingPermission
    case waitingForAuthorization
    case loadingSources
    case choosingSource
    case verifyingDestination
}

/// The widest rendered form of every HUD field whose value changes while recording.
///
/// A size is measured once against these values, so a ticking clock or a growing
/// counter redraws inside an unchanged window instead of resizing it. The fields
/// render with monospaced digits, which keeps the drawn width equal to the measured one.
enum RecordingHUDWorstCaseText {
    /// Wider than `mm:ss` and than the `h:mm:ss` a long recording reaches.
    static let duration = "99:59:59"
    /// Widest saved-segment count in the expanded audio capsule.
    static let savedSegments = 999
    /// Widest current-segment number in the audio capsule.
    static let segmentNumber = 999
    /// The start countdown never counts above its first value.
    static let countdownSeconds = 3
}

/// The structural inputs that decide one HUD size.
///
/// Elapsed time, meter levels, and counter values are deliberately absent: they
/// redraw inside an unchanged layout and must never resize the window. The language
/// is part of the key because the same state measures differently per translation.
struct RecordingHUDLayoutSignature: Hashable, Sendable {
    /// One HUD state reduced to the fields that change its size.
    enum Content: Hashable, Sendable {
        case preparing(kind: RecordingKind, phase: RecordingPreparationPhase)
        case countdown
        case starting(kind: RecordingKind, phase: RecordingStartPhase)
        case recording
        case saving(kind: RecordingKind, showsFileName: Bool, isBeforeQuit: Bool)
        case audioRecording(mode: AudioSourceMode, expanded: Bool, silenceWarning: Bool)
        case audioFinalizing(previewReady: Bool, previewPlaying: Bool)
        case audioFinished(showsPreview: Bool, previewPlaying: Bool, offersRecordingsList: Bool)
        case failure(expanded: Bool, canRetry: Bool, reason: String)
        case notice(text: String)
    }

    /// The state this size belongs to.
    let content: Content
    /// The language the visible text renders in.
    let language: String
}

extension RecordingHUDLayoutSignature {
    /// Builds the signature for one audio HUD presentation.
    ///
    /// Duration, levels, and counters are dropped on purpose: they are live values,
    /// not layout inputs of their own.
    ///
    /// - Parameters:
    ///   - presentation: The value snapshot the live capsule renders.
    ///   - expanded: Whether the capsule shows the saved-count row.
    ///   - silenceWarning: Whether the "no sound detected" label is visible.
    ///   - language: The identifier of the language the text renders in.
    init(
        audio presentation: RecordingHUDPresentation,
        expanded: Bool,
        silenceWarning: Bool,
        language: String
    ) {
        self.init(
            content: .audioRecording(
                mode: presentation.mode,
                expanded: expanded,
                silenceWarning: silenceWarning
            ),
            language: language
        )
    }

    /// The measured-size family this state belongs to.
    var panelKind: RecordingHUDPanelKind {
        switch content {
        case .countdown:
            .countdown
        case .preparing, .starting, .recording:
            .recording
        case .saving:
            .saving
        case .failure:
            .failure
        case .notice:
            .notice
        case .audioRecording, .audioFinalizing, .audioFinished:
            .audio
        }
    }

    /// Whether this state shows the tall, scrollable failure card.
    var isExpandedFailure: Bool {
        guard case let .failure(expanded, _, _) = content else { return false }
        return expanded
    }

    /// Whether the capsule is an audio state with a fixed height.
    var isAudio: Bool { panelKind == .audio }

    /// A privacy-safe name for logs: the state family, never its text.
    var logName: String {
        switch content {
        case .preparing: "preparing"
        case .countdown: "countdown"
        case .starting: "starting"
        case .recording: "recording"
        case .saving: "saving"
        case .audioRecording: "audioRecording"
        case .audioFinalizing: "audioFinalizing"
        case .audioFinished: "audioFinished"
        case .failure: "failure"
        case .notice: "notice"
        }
    }
}

/// How a HUD size is chosen when its signature has no measurement yet.
enum RecordingHUDMeasurementPolicy {
    /// A measurement slower than this is treated as a fault and never retried.
    static let faultThresholdMilliseconds = 50

    /// Animation used when a measured size replaces the conservative frame.
    static let correctionDuration: TimeInterval = 0.12

    /// The conservative size shown until a signature is measured.
    ///
    /// It is the family's baseline size (the same width these capsules used before
    /// their content was measured), so the first frame is never clipped and the
    /// measured correction only ever grows into the real width.
    ///
    /// - Parameters:
    ///   - signature: The state whose measurement is still missing.
    ///   - available: The usable content area of the panel's screen.
    /// - Returns: A size inside the family's bounds and the available area.
    static func fallbackSize(
        for signature: RecordingHUDLayoutSignature,
        available: CGSize
    ) -> CGSize {
        let bounds = RecordingHUDMetrics.bounds(for: signature.panelKind)
        let height = signature.isAudio ? RecordingHUDMetrics.audioRecordingHeight : bounds.minHeight
        return CGSize(
            width: bounds.clampedWidth(bounds.minWidth, availableWidth: available.width),
            height: bounds.clampedHeight(height, availableHeight: available.height)
        )
    }
}

/// One session's measured HUD sizes, keyed by layout signature.
///
/// A pure value type, so the cache policy is unit-tested without a window.
struct RecordingHUDSizeCache: Equatable {
    private var sizes: [RecordingHUDLayoutSignature: CGSize] = [:]

    /// Lookups that found a size.
    private(set) var hits = 0
    /// Lookups that found nothing.
    private(set) var misses = 0

    /// The stored size, without counting a lookup.
    ///
    /// - Parameter signature: The layout signature to read.
    /// - Returns: The measured size, or `nil` when this signature is still unknown.
    func size(for signature: RecordingHUDLayoutSignature) -> CGSize? {
        sizes[signature]
    }

    /// The stored size, counting a hit or a miss.
    ///
    /// - Parameter signature: The layout signature to resolve.
    /// - Returns: The measured size, or `nil` when the caller has to measure.
    @discardableResult
    mutating func lookup(_ signature: RecordingHUDLayoutSignature) -> CGSize? {
        guard let size = sizes[signature] else {
            misses += 1
            return nil
        }
        hits += 1
        return size
    }

    /// Records one measurement, replacing an earlier one for the same signature.
    ///
    /// - Parameters:
    ///   - size: The measured window size.
    ///   - signature: The layout signature the size was measured for.
    mutating func store(_ size: CGSize, for signature: RecordingHUDLayoutSignature) {
        sizes[signature] = size
    }

    /// The number of measured signatures.
    var count: Int { sizes.count }

    /// Whether nothing has been measured yet.
    var isEmpty: Bool { sizes.isEmpty }

    /// Drops every measurement and counter.
    mutating func removeAll() {
        sizes.removeAll(keepingCapacity: true)
        hits = 0
        misses = 0
    }
}
