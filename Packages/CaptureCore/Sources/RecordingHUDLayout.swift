import CoreGraphics
import Foundation

/// Screen corners used by the floating recording control panel.
///
/// Corners are expressed in AppKit screen coordinates (origin bottom-left, Y up).
public enum RecordingHUDCorner: String, CaseIterable, Sendable {
    case topTrailing
    case topLeading
    case bottomTrailing
    case bottomLeading

    /// Whether the corner sits on the top edge of the screen.
    public var isTop: Bool { self == .topTrailing || self == .topLeading }

    /// Whether the corner sits on the trailing edge of the screen.
    public var isTrailing: Bool { self == .topTrailing || self == .bottomTrailing }
}

/// The content family whose measured size drives one HUD window resize.
public enum RecordingHUDPanelKind: Sendable, Equatable {
    /// Countdown before capture starts.
    case countdown
    /// Preparing, starting, or recording a screen capture.
    case recording
    /// Finalizing and saving a recording.
    case saving
    /// A persistent failure that can be retried, revealed, or expanded.
    case failure
    /// A transient notice.
    case notice
    /// Any audio-recording capsule (recording, finalizing, finished).
    case audio
}

/// Measured-size limits for one HUD content family.
///
/// The window follows the rendered SwiftUI content instead of a hard-coded width.
/// The former fixed widths are kept as minimums, so an English HUD never shrinks;
/// longer localizations (Japanese, Korean) may grow up to `maxWidth`, and a narrow
/// screen may still clamp the result to its visible frame.
public struct RecordingHUDPanelBounds: Sendable, Equatable {
    /// Smallest width the panel may use.
    public let minWidth: CGFloat
    /// Largest width the panel may use; also capped by the screen's visible width.
    public let maxWidth: CGFloat
    /// Smallest height the panel may use.
    public let minHeight: CGFloat
    /// Largest height the panel may use before the text has to scroll.
    public let maxHeight: CGFloat

    /// Creates one set of bounds, keeping width and height ordered.
    public init(minWidth: CGFloat, maxWidth: CGFloat, minHeight: CGFloat, maxHeight: CGFloat) {
        let minimumWidth = max(1, minWidth)
        let minimumHeight = max(1, minHeight)
        self.minWidth = minimumWidth
        self.maxWidth = max(minimumWidth, maxWidth)
        self.minHeight = minimumHeight
        self.maxHeight = max(minimumHeight, maxHeight)
    }

    /// Clamps a measured width, rounding up so text is never clipped by a fraction.
    public func clampedWidth(_ measured: CGFloat, availableWidth: CGFloat) -> CGFloat {
        let limit = max(1, min(maxWidth, availableWidth))
        let floor = min(minWidth, limit)
        return min(max(measured.rounded(.up), floor), limit)
    }

    /// Clamps a measured height, rounding up so text is never clipped by a fraction.
    public func clampedHeight(_ measured: CGFloat, availableHeight: CGFloat) -> CGFloat {
        let limit = max(1, min(maxHeight, availableHeight))
        let floor = min(minHeight, limit)
        return min(max(measured.rounded(.up), floor), limit)
    }

    /// Clamps a measured content size to these bounds and the visible frame.
    public func size(for measured: CGSize, available: CGSize) -> CGSize {
        CGSize(
            width: clampedWidth(measured.width, availableWidth: available.width),
            height: clampedHeight(measured.height, availableHeight: available.height)
        )
    }
}

/// Geometry for the floating recording control panel.
///
/// The panel is a capsule: `height / 2` is its radius. Widths are measured from the
/// rendered SwiftUI content (localized text plus its controls) and then clamped to
/// `RecordingHUDPanelBounds`, so the window and the card share one set of numbers.
public enum RecordingHUDMetrics {
    /// Fixed audio HUD height; its width is measured from localized content.
    public static let audioRecordingHeight: CGFloat = 44

    /// Bounds for the countdown capsule.
    public static let countdownBounds = RecordingHUDPanelBounds(
        minWidth: 236,
        maxWidth: 420,
        minHeight: 40,
        maxHeight: 40
    )
    /// Bounds for preparing, starting, and recording a screen capture.
    ///
    /// The height range only matters on narrow screens, where preparing and starting text
    /// may wrap; the recording capsule measures 40 pt and keeps that height.
    public static let recordingBounds = RecordingHUDPanelBounds(
        minWidth: 176,
        maxWidth: 480,
        minHeight: 40,
        maxHeight: 68
    )
    /// Bounds for the saving capsule.
    public static let savingBounds = RecordingHUDPanelBounds(
        minWidth: 252,
        maxWidth: 480,
        minHeight: 40,
        maxHeight: 40
    )
    /// Bounds for a failure capsule; expanding shows the full reason on several lines.
    public static let failureBounds = RecordingHUDPanelBounds(
        minWidth: 344,
        maxWidth: 520,
        minHeight: 44,
        maxHeight: 180
    )
    /// Height reserved inside an expanded failure for padding, spacing, and the actions row.
    ///
    /// The reason column scrolls only when its measured height leaves no room inside
    /// `failureBounds.maxHeight` after this chrome.
    public static let failureExpandedChromeHeight: CGFloat = 64
    /// Bounds for a transient notice capsule.
    public static let noticeBounds = RecordingHUDPanelBounds(
        minWidth: 296,
        maxWidth: 480,
        minHeight: 44,
        maxHeight: 44
    )
    /// Bounds for the audio capsules, including their action rows.
    public static let audioBounds = RecordingHUDPanelBounds(
        minWidth: 176,
        maxWidth: 640,
        minHeight: audioRecordingHeight,
        maxHeight: audioRecordingHeight
    )

    /// Baseline countdown size; the live window uses the measured content width.
    public static let countdownSize = CGSize(
        width: countdownBounds.minWidth,
        height: countdownBounds.minHeight
    )
    /// Baseline preparing/starting/recording size; the live window uses the measured width.
    public static let recordingSize = CGSize(
        width: recordingBounds.minWidth,
        height: recordingBounds.minHeight
    )
    /// Legacy alias for the 176 × 40 paused capsule.
    public static let pausedSize = recordingSize
    /// Baseline saving size; the live window uses the measured content width.
    public static let savingSize = CGSize(
        width: savingBounds.minWidth,
        height: savingBounds.minHeight
    )
    /// Baseline collapsed-failure size; the live window may be wider or taller.
    public static let failureSize = CGSize(
        width: failureBounds.minWidth,
        height: failureBounds.minHeight
    )
    /// Baseline notice size; the live window uses the measured content width.
    public static let noticeSize = CGSize(
        width: noticeBounds.minWidth,
        height: noticeBounds.minHeight
    )

    /// Smallest frame change worth applying; smaller deltas would jitter the window.
    public static let minimumSizeChange: CGFloat = 0.5

    /// Inset from the screen's visible frame.
    public static let screenMargin: CGFloat = 16
    /// Capsule radius for the 40 pt states.
    public static let cornerRadius: CGFloat = 20
    /// Corner radius for taller HUD surfaces, including an expanded failure card.
    public static let tallCornerRadius: CGFloat = 22

    /// Returns the measured-size bounds for one content family.
    public static func bounds(for kind: RecordingHUDPanelKind) -> RecordingHUDPanelBounds {
        switch kind {
        case .countdown: countdownBounds
        case .recording: recordingBounds
        case .saving: savingBounds
        case .failure: failureBounds
        case .notice: noticeBounds
        case .audio: audioBounds
        }
    }
}

/// Pure placement rules for the floating recording control panel.
///
/// The panel must never cover the captured area, so a region or window recording relocates it
/// to the nearest corner that lies outside the capture rectangle.
public enum RecordingHUDPlacement {
    /// Preference order when the stored corner is not usable.
    public static let cornerOrder: [RecordingHUDCorner] = [
        .topTrailing,
        .topLeading,
        .bottomTrailing,
        .bottomLeading,
    ]

    /// Returns the origin of the panel for one corner inside a screen's visible frame.
    public static func origin(
        for corner: RecordingHUDCorner,
        size: CGSize,
        in screenFrame: CGRect,
        margin: CGFloat = RecordingHUDMetrics.screenMargin
    ) -> CGPoint {
        let originX: CGFloat
        let originY: CGFloat
        if corner.isTrailing {
            originX = screenFrame.maxX - size.width - margin
        } else {
            originX = screenFrame.minX + margin
        }
        if corner.isTop {
            originY = screenFrame.maxY - size.height - margin
        } else {
            originY = screenFrame.minY + margin
        }
        return CGPoint(x: originX, y: originY)
    }

    /// Returns the panel frame for one corner inside a screen's visible frame.
    public static func frame(
        for corner: RecordingHUDCorner,
        size: CGSize,
        in screenFrame: CGRect,
        margin: CGFloat = RecordingHUDMetrics.screenMargin
    ) -> CGRect {
        CGRect(origin: origin(for: corner, size: size, in: screenFrame, margin: margin), size: size)
    }

    /// Chooses the corner that keeps the panel outside the captured rectangle.
    ///
    /// - Parameters:
    ///   - size: Current panel size.
    ///   - screenFrame: Visible frame of the screen being recorded.
    ///   - capturedRect: Captured area in the same coordinate space, or `nil` for a display capture.
    ///   - preferred: Stored/user corner. Kept when it does not intersect the capture rectangle.
    /// - Returns: A corner whose frame does not intersect `capturedRect` whenever one exists;
    ///   otherwise the preferred corner so the panel stays reachable.
    public static func preferredCorner(
        size: CGSize,
        screenFrame: CGRect,
        capturedRect: CGRect?,
        preferred: RecordingHUDCorner?
    ) -> RecordingHUDCorner {
        let fallback = preferred ?? .topTrailing
        guard let capturedRect, capturedRect.width > 0, capturedRect.height > 0 else {
            return fallback
        }
        let captured = capturedRect.standardized

        if !frame(for: fallback, size: size, in: screenFrame).intersects(captured) {
            return fallback
        }
        for corner in cornerOrder
        where
            !frame(for: corner, size: size, in: screenFrame).intersects(captured)
        {
            return corner
        }
        return fallback
    }

    /// Returns the corner whose panel center is closest to the dragged panel center.
    public static func nearestCorner(
        to origin: CGPoint,
        size: CGSize,
        in screenFrame: CGRect,
        margin: CGFloat = RecordingHUDMetrics.screenMargin
    ) -> RecordingHUDCorner {
        let center = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        var best = RecordingHUDCorner.topTrailing
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for corner in cornerOrder {
            let candidate = frame(for: corner, size: size, in: screenFrame, margin: margin)
            let deltaX = candidate.midX - center.x
            let deltaY = candidate.midY - center.y
            let distance = deltaX * deltaX + deltaY * deltaY
            if distance < bestDistance {
                bestDistance = distance
                best = corner
            }
        }
        return best
    }

    /// Parses a stored corner identifier, falling back to `topLeading`-safe defaults.
    public static func corner(rawValue: String, fallback: RecordingHUDCorner = .topTrailing) -> RecordingHUDCorner {
        RecordingHUDCorner(rawValue: rawValue) ?? fallback
    }
}
