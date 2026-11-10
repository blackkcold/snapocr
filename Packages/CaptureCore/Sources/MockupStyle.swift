import CoreGraphics
import Foundation

/// A share-ready screenshot treatment: background, padding, rounded corners,
/// and a soft shadow. All metrics are ratios of the image's reference edge so
/// a 6K fullscreen capture and a small region capture keep the same visual
/// weight.
public struct MockupStyle: Codable, Equatable, Sendable {
    public struct ColorStop: Codable, Equatable, Sendable {
        public let red: CGFloat
        public let green: CGFloat
        public let blue: CGFloat
        public let location: CGFloat

        public init(red: CGFloat, green: CGFloat, blue: CGFloat, location: CGFloat) {
            self.red = red
            self.green = green
            self.blue = blue
            self.location = location
        }
    }

    public enum Background: Codable, Equatable, Sendable {
        case transparent
        case solid(red: CGFloat, green: CGFloat, blue: CGFloat)
        case linear(stops: [ColorStop], angle: CGFloat)
    }

    /// Schema version for forward-compatible decoding.
    public var version: Int = 1
    public var background: Background
    public var paddingRatio: CGFloat
    public var cornerRadiusRatio: CGFloat
    public var shadowBlurRatio: CGFloat
    public var shadowOpacity: CGFloat
    public var shadowOffsetRatio: CGFloat

    public init(
        background: Background,
        paddingRatio: CGFloat = 0.08,
        cornerRadiusRatio: CGFloat = 0.012,
        shadowBlurRatio: CGFloat = 0.03,
        shadowOpacity: CGFloat = 0.28,
        shadowOffsetRatio: CGFloat = 0.012
    ) {
        self.background = background
        self.paddingRatio = paddingRatio
        self.cornerRadiusRatio = cornerRadiusRatio
        self.shadowBlurRatio = shadowBlurRatio
        self.shadowOpacity = shadowOpacity
        self.shadowOffsetRatio = shadowOffsetRatio
    }
}

/// Built-in share treatments. Values are intentionally restrained; the
/// screenshot should remain the subject, not the background.
public enum MockupPreset: String, CaseIterable, Sendable {
    case float
    case light
    case dark
    case paper
    case sunset
    case ocean
    case midnight
    case transparent

    public var title: String {
        switch self {
        case .float: return "Float"
        case .light: return "Light"
        case .dark: return "Dark"
        case .paper: return "Paper"
        case .sunset: return "Sunset"
        case .ocean: return "Ocean"
        case .midnight: return "Midnight"
        case .transparent: return "Transparent"
        }
    }

    /// Localization key kept separate from the stable rawValue.
    public var localizedKey: String {
        switch self {
        case .float: return "Preset Float"
        case .light: return "Preset Light"
        case .dark: return "Preset Dark"
        case .paper: return "Preset Paper"
        case .sunset: return "Preset Sunset"
        case .ocean: return "Preset Ocean"
        case .midnight: return "Preset Midnight"
        case .transparent: return "Preset Transparent"
        }
    }

    public var style: MockupStyle {
        switch self {
        case .float:
            return MockupStyle(
                background: .transparent,
                paddingRatio: 0.06,
                cornerRadiusRatio: 0.012
            )
        case .light:
            return MockupStyle(background: .solid(red: 0.96, green: 0.96, blue: 0.97))
        case .dark:
            return MockupStyle(background: .solid(red: 0.11, green: 0.11, blue: 0.12))
        case .paper:
            return MockupStyle(
                background: .solid(red: 0.98, green: 0.976, blue: 0.965),
                paddingRatio: 0.10,
                cornerRadiusRatio: 0.010,
                shadowOpacity: 0.18
            )
        case .sunset:
            return MockupStyle(
                background: .linear(
                    stops: [
                        .init(red: 1.0, green: 0.494, blue: 0.373, location: 0),
                        .init(red: 0.996, green: 0.706, blue: 0.482, location: 1),
                    ],
                    angle: 135
                ),
                paddingRatio: 0.09,
                cornerRadiusRatio: 0.016
            )
        case .ocean:
            return MockupStyle(
                background: .linear(
                    stops: [
                        .init(red: 0.129, green: 0.576, blue: 0.690, location: 0),
                        .init(red: 0.427, green: 0.835, blue: 0.929, location: 1),
                    ],
                    angle: 135
                ),
                paddingRatio: 0.09,
                cornerRadiusRatio: 0.016
            )
        case .midnight:
            return MockupStyle(
                background: .linear(
                    stops: [
                        .init(red: 0.059, green: 0.125, blue: 0.153, location: 0),
                        .init(red: 0.125, green: 0.227, blue: 0.263, location: 0.55),
                        .init(red: 0.173, green: 0.325, blue: 0.392, location: 1),
                    ],
                    angle: 135
                ),
                paddingRatio: 0.09,
                cornerRadiusRatio: 0.014,
                shadowOpacity: 0.32
            )
        case .transparent:
            return MockupStyle(
                background: .transparent,
                paddingRatio: 0.08,
                cornerRadiusRatio: 0.012,
                shadowBlurRatio: 0,
                shadowOpacity: 0,
                shadowOffsetRatio: 0
            )
        }
    }
}
