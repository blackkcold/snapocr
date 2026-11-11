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

/// Fixed geometry for the floating recording control panel.
///
/// The panel is a capsule: `height / 2` is its radius. Widths are the measured content widths
/// from the HUD spec, so the window and the card share one set of numbers.
public enum RecordingHUDMetrics {
    public static let countdownSize = CGSize(width: 236, height: 40)
    public static let recordingSize = CGSize(width: 176, height: 40)
    public static let pausedSize = CGSize(width: 176, height: 40)
    public static let savingSize = CGSize(width: 252, height: 40)
    public static let failureSize = CGSize(width: 344, height: 44)
    public static let noticeSize = CGSize(width: 296, height: 44)

    /// Inset from the screen's visible frame.
    public static let screenMargin: CGFloat = 16
    /// Capsule radius for the 40 pt states.
    public static let cornerRadius: CGFloat = 20
    /// Capsule radius for the 44 pt states.
    public static let tallCornerRadius: CGFloat = 22
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
        for corner in cornerOrder where
            !frame(for: corner, size: size, in: screenFrame).intersects(captured) {
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
