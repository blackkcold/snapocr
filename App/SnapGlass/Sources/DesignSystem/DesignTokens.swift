// swiftlint:disable identifier_name type_name
import AppKit
import SharedKit
import SwiftUI

/// 设计系统的基础刻度。
///
/// 这里的数值先与迁移前的实现逐项对齐，再作为后续调整的唯一入口。
/// 画布（`NSView.draw`）和 AppKit 控件也能直接读取这些 CGFloat。
enum DS {
    enum Corner {
        static let c4: CGFloat = 4
        static let c6: CGFloat = 6
        static let c8: CGFloat = 8
        static let c10: CGFloat = 10
        static let c12: CGFloat = 12
        static let c14: CGFloat = 14
        static let c20: CGFloat = 20
    }

    enum Space {
        static let s2: CGFloat = 2
        static let s4: CGFloat = 4
        static let s6: CGFloat = 6
        static let s7: CGFloat = 7
        static let s8: CGFloat = 8
        static let s9: CGFloat = 9
        static let s10: CGFloat = 10
        static let s12: CGFloat = 12
        static let s14: CGFloat = 14
        static let s16: CGFloat = 16
        static let s18: CGFloat = 18
        static let s20: CGFloat = 20
        static let s24: CGFloat = 24
        static let s32: CGFloat = 32
    }

    /// 字号刻度与常用字体。
    ///
    /// 用 `Font` 常量而不是每次调用 `.system(size:)`，既统一了字号，
    /// 也让「迁移完成的文件里不再出现散落的数值字号」可以被 grep 检查。
    enum Typography {
        static let t10: CGFloat = 10
        static let t11: CGFloat = 11
        static let t12: CGFloat = 12
        static let t13: CGFloat = 13
        static let t14: CGFloat = 14
        static let t15: CGFloat = 15
        static let t16: CGFloat = 16
        static let t17: CGFloat = 17
        static let t20: CGFloat = 20
        static let t24: CGFloat = 24
        static let t34: CGFloat = 34

        static let caption = Font.system(size: t11)
        static let captionStrong = Font.system(size: t11, weight: .medium)
        static let label = Font.system(size: t12, weight: .medium)
        static let body = Font.system(size: t13)
        static let bodyStrong = Font.system(size: t13, weight: .medium)
        static let control = Font.system(size: t14, weight: .medium)
        static let toast = Font.system(size: t14, weight: .medium)
        static let icon = Font.system(size: t16, weight: .semibold)
        static let title = Font.system(size: t17, weight: .semibold)
        static let display = Font.system(size: t20, weight: .semibold)
        static let emptyStateIcon = Font.system(size: t24, weight: .light)
        static let headline = Font.system(size: t24, weight: .semibold)
    }

    enum Motion {
        static let fast: TimeInterval = 0.15
        static let base: TimeInterval = 0.2
        static let slow: TimeInterval = 0.3
    }

    /// 命中区域。视觉尺寸可以更小，但可点击范围不应低于这些值。
    enum Hit {
        static let small: CGFloat = 28
        static let medium: CGFloat = 32
        static let large: CGFloat = 34
        /// 画布缩放手柄的命中直径（视觉 8pt，命中 22pt）。
        static let handle: CGFloat = 22
    }

    enum Control {
        /// 工具条里分隔线的高度。
        static let dividerHeight: CGFloat = 22
        static let iconButton: CGFloat = 28
        static let colorWell: CGFloat = 26
        static let presetWidth: CGFloat = 108
        static let strokeWidthPicker: CGFloat = 62
        static let zoomButtonWidth: CGFloat = 22
        static let zoomButtonHeight: CGFloat = 24
        static let trimButtonHorizontal: CGFloat = 7
        /// 画布缩放手柄的视觉边长（命中范围见 `Hit.handle`）。
        static let handleVisualSize: CGFloat = 8
    }

    /// 浮起高度。数值越高，材质越实、投影越大。
    enum Elevation: Int {
        case raised = 1
        case floating = 2
        case overlay = 3

        var material: Material {
            switch self {
            case .raised: .ultraThin
            case .floating: .thin
            case .overlay: .regular
            }
        }

        var shadowRadius: CGFloat {
            switch self {
            case .raised: 8
            case .floating: 12
            case .overlay: 16
            }
        }

        var shadowY: CGFloat {
            switch self {
            case .raised: 2
            case .floating: 4
            case .overlay: 8
            }
        }

        var shadowOpacity: Double {
            switch self {
            case .raised: 0.10
            case .floating: 0.14
            case .overlay: 0.18
            }
        }

        var strokeOpacity: Double {
            switch self {
            case .raised: 0.14
            case .floating: 0.18
            case .overlay: 0.22
            }
        }
    }
}

/// 画布自绘用的固定颜色与透明度。
///
/// 这些值不放进 SwiftUI 环境，因为 `NSView.draw` 与 AppKit 控件直接读取它们。
enum Palette {
    static let maskAlpha: CGFloat = 0.32
    static let labelBackground: CGFloat = 0.75
    static let whiteStroke: CGFloat = 0.85
    static let whiteStrokeStrong: CGFloat = 0.9

    static let handleFill = NSColor.white
    static let handleStroke = NSColor.black.withAlphaComponent(0.72)
    static let handleHoverFill = NSColor.white
    static let handleHoverStroke = NSColor.controlAccentColor

    static let selectionStroke = NSColor.controlAccentColor
    static let defaultAnnotationColor = NSColor.systemRed.cgColor
}

// swiftlint:enable identifier_name type_name


extension Color {
    /// RGB 0–255 的采样色 → SwiftUI 颜色。
    init(sampled color: SampledColor) {
        self.init(
            red: Double(color.red) / 255,
            green: Double(color.green) / 255,
            blue: Double(color.blue) / 255
        )
    }
}
