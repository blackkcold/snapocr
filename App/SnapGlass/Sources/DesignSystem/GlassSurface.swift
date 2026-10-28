import SwiftUI

/// 统一的玻璃表面。
///
/// 三档：
/// 1. macOS 26 及以上：Liquid Glass。
/// 2. macOS 13–25：系统材质，按浮起高度选择厚度。
/// 3. 打开「降低透明度」：实色背景，完全不使用毛玻璃。
///
/// macOS 26 的 `glassEffect` 不可用时（更旧的 SDK）退回材质分支，
/// 因此调用点不需要自己写 `#available`。
struct GlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    let elevation: DS.Elevation
    /// 分栏面板贴在窗口内部，不应有「浮起」投影。
    var castsShadow: Bool = true
    /// 贴在窗口边缘的条/栏不需要四周高光。
    var showsStroke: Bool = true

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .background {
                surface
                    .modifier(ElevationShadow(elevation: elevation, isEnabled: castsShadow))
            }
            .overlay {
                if showsStroke {
                    shape.strokeBorder(
                        Color.white.opacity(elevation.strokeOpacity),
                        lineWidth: 0.5
                    )
                    .allowsHitTesting(false)
                }
            }
    }

    @ViewBuilder
    private var surface: some View {
        if reduceTransparency {
            shape.fill(Color(nsColor: .windowBackgroundColor))
        } else {
            // `glassEffect` 只存在于 macOS 26 SDK（Swift 6.2 起）。旧 SDK 上连符号
            // 都没有，只写 `#available` 会在编译期失败，因此编译期与运行时两层守卫都要有。
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                shape
                    .fill(.clear)
                    .glassEffect(.regular, in: shape)
            } else {
                shape.fill(elevation.material)
            }
            #else
            shape.fill(elevation.material)
            #endif
        }
    }
}

private struct ElevationShadow: ViewModifier {
    let elevation: DS.Elevation
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content.shadow(
                color: .black.opacity(elevation.shadowOpacity),
                radius: elevation.shadowRadius,
                x: 0,
                y: elevation.shadowY
            )
        } else {
            content
        }
    }
}

extension View {
    /// 把玻璃表面铺在视图背后，并加一圈高光描边。
    func glassSurface<S: InsettableShape>(
        _ shape: S,
        elevation: DS.Elevation,
        castsShadow: Bool = true,
        showsStroke: Bool = true
    ) -> some View {
        modifier(
            GlassSurface(
                shape: shape,
                elevation: elevation,
                castsShadow: castsShadow,
                showsStroke: showsStroke
            )
        )
    }
}
