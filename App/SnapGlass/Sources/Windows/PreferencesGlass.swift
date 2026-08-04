import SwiftUI

enum GlassShape {
    case rect
    case rounded(CGFloat)
    case circle
    case capsule

    /// macOS 26 concentric corner — radii derive from the nearest container shape
    /// (the window), while never falling below `minimumRadius`.
    /// Falls back to a fixed `minimumRadius` rounded corner on macOS 13–25.
    case concentric(minimumRadius: CGFloat)
}

extension View {
    @ViewBuilder
    func glassSurface(
        in shape: GlassShape = .rounded(14),
        fallbackMaterial: Material = .ultraThinMaterial
    ) -> some View {
        if #available(macOS 26.0, *) {
            #if compiler(>=6.2)
            glassEffect(Glass.regular, in: shapePath(shape))
            #else
            background(fallbackMaterial, in: shapePath(shape))
            #endif
        } else {
            background(fallbackMaterial, in: shapePath(shape))
        }
    }

    @ViewBuilder
    func glassInteractive(
        in shape: GlassShape = .capsule,
        tinted: Bool = false
    ) -> some View {
        if #available(macOS 26.0, *) {
            #if compiler(>=6.2)
            if tinted {
                glassEffect(
                    Glass.regular.tint(.accentColor.opacity(0.35)).interactive(),
                    in: shapePath(shape)
                )
            } else {
                glassEffect(Glass.regular.interactive(), in: shapePath(shape))
            }
            #else
            background(.ultraThinMaterial, in: shapePath(shape))
            #endif
        } else {
            background(.ultraThinMaterial, in: shapePath(shape))
        }
    }

    private func shapePath(_ shape: GlassShape) -> AnyShape {
        switch shape {
        case .rect: return AnyShape(Rectangle())
        case .rounded(let r): return AnyShape(RoundedRectangle(cornerRadius: r))
        case .circle: return AnyShape(Circle())
        case .capsule: return AnyShape(Capsule())
        case .concentric(let minimumRadius):
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                return AnyShape(
                    ConcentricRectangle(
                        corners: .concentric(minimum: .fixed(minimumRadius)),
                        isUniform: true
                    )
                )
            }
            #endif
            return AnyShape(RoundedRectangle(cornerRadius: minimumRadius))
        }
    }
}

struct GlassGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            #if compiler(>=6.2)
            GlassEffectContainer {
                content
            }
            #else
            content
            #endif
        } else {
            content
        }
    }
}
