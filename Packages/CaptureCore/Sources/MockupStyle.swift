import CoreGraphics
import Foundation

/// A share-ready screenshot treatment: background, padding, rounded corners,
/// shadow and border. All metrics are ratios of the image's reference edge so
/// a 6K fullscreen capture and a small region capture keep the same visual
/// weight.
public struct MockupStyle: Codable, Equatable, Sendable {
    /// One stop in a linear-gradient background.
    ///
    /// Components are sRGB values in `0...1` and `location` positions the stop
    /// along the gradient from start (`0`) to end (`1`).
    public struct ColorStop: Codable, Equatable, Sendable {
        /// Red component in the `0...1` sRGB range.
        public let red: CGFloat
        /// Green component in the `0...1` sRGB range.
        public let green: CGFloat
        /// Blue component in the `0...1` sRGB range.
        public let blue: CGFloat
        /// Position of the stop along the gradient, from `0` to `1`.
        public let location: CGFloat

        /// Creates a color stop from sRGB components and a gradient position.
        public init(red: CGFloat, green: CGFloat, blue: CGFloat, location: CGFloat) {
            self.red = red
            self.green = green
            self.blue = blue
            self.location = location
        }
    }

    /// The canvas fill behind the screenshot: transparent, solid, or a linear gradient.
    public enum Background: Codable, Equatable, Sendable {
        case transparent
        case solid(red: CGFloat, green: CGFloat, blue: CGFloat)
        case linear(stops: [ColorStop], angle: CGFloat)

        /// Whether the exported canvas keeps transparency outside the image.
        public var isTransparent: Bool {
            if case .transparent = self { return true }
            return false
        }
    }

    /// Border colour resolved against the image edge.
    ///
    /// `automatic` picks a light or dark hairline from the background
    /// luminance; the custom case is stored as sRGB components.
    public enum BorderColor: Codable, Equatable, Sendable {
        case automatic
        case custom(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)
    }

    /// Schema version for forward-compatible decoding.
    public var version: Int = 2
    /// The canvas fill behind the screenshot.
    public var background: Background
    /// Padding on each side as a fraction of the reference edge.
    public var paddingRatio: CGFloat
    /// Content corner radius as a fraction of the reference edge.
    ///
    /// The rendered radius is capped at half the image's shorter side.
    public var cornerRadiusRatio: CGFloat
    /// Shadow blur radius as a fraction of the reference edge.
    public var shadowBlurRatio: CGFloat
    /// Shadow opacity in `0...1`.
    public var shadowOpacity: CGFloat
    /// Vertical shadow offset as a fraction of the reference edge.
    public var shadowOffsetRatio: CGFloat
    /// Border stroke width as a ratio of the reference edge. Zero disables it.
    public var borderWidthRatio: CGFloat
    /// How the border color is chosen for the image edge.
    public var borderColor: BorderColor

    /// Creates a style from a background and treatment ratios.
    ///
    /// Ratios are multiplied by `MockupLayout.referenceSide(for:)`, so captures
    /// of different sizes keep the same visual weight.
    public init(
        background: Background,
        paddingRatio: CGFloat = 0.08,
        cornerRadiusRatio: CGFloat = 0.012,
        shadowBlurRatio: CGFloat = 0.03,
        shadowOpacity: CGFloat = 0.28,
        shadowOffsetRatio: CGFloat = 0.012,
        borderWidthRatio: CGFloat = 0,
        borderColor: BorderColor = .automatic
    ) {
        self.background = background
        self.paddingRatio = paddingRatio
        self.cornerRadiusRatio = cornerRadiusRatio
        self.shadowBlurRatio = shadowBlurRatio
        self.shadowOpacity = shadowOpacity
        self.shadowOffsetRatio = shadowOffsetRatio
        self.borderWidthRatio = borderWidthRatio
        self.borderColor = borderColor
    }

    /// Whether the style leaves any transparent pixels in the exported canvas.
    public var isTransparent: Bool {
        background.isTransparent
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case background
        case paddingRatio
        case cornerRadiusRatio
        case shadowBlurRatio
        case shadowOpacity
        case shadowOffsetRatio
        case borderWidthRatio
        case borderColor
    }

    /// Decodes older records that predate the border fields.
    ///
    /// Swift's synthesized decoder does not apply property defaults for
    /// missing keys, so adding a field without this initializer would make
    /// every historical style silently fail to decode and fall back to the
    /// raw image. Every field is therefore optional on the wire.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        version = max(decodedVersion, 2)
        background = try container.decodeIfPresent(Background.self, forKey: .background) ?? .transparent
        paddingRatio = try container.decodeIfPresent(CGFloat.self, forKey: .paddingRatio) ?? 0.08
        cornerRadiusRatio = try container.decodeIfPresent(CGFloat.self, forKey: .cornerRadiusRatio) ?? 0.012
        shadowBlurRatio = try container.decodeIfPresent(CGFloat.self, forKey: .shadowBlurRatio) ?? 0.03
        shadowOpacity = try container.decodeIfPresent(CGFloat.self, forKey: .shadowOpacity) ?? 0.28
        shadowOffsetRatio = try container.decodeIfPresent(CGFloat.self, forKey: .shadowOffsetRatio) ?? 0.012
        borderWidthRatio = try container.decodeIfPresent(CGFloat.self, forKey: .borderWidthRatio) ?? 0
        borderColor = try container.decodeIfPresent(BorderColor.self, forKey: .borderColor) ?? .automatic
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

    /// Human-readable preset name for menus and settings.
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

    /// The share treatment this preset applies.
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
