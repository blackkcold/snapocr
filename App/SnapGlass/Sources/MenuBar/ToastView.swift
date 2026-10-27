import SwiftUI

/// A view that displays a toast notification.
///
/// Uses `.ultraThinMaterial` for a Liquid Glass effect.
public struct ToastView: View {
    /// The message to display.
    let message: ToastMessage
    
    public var body: some View {
        HStack(spacing: DS.Space.s12) {
            Image(systemName: iconName)
                .foregroundColor(iconColor)
                .font(DS.Typography.icon)

            Text(message.message)
                .font(DS.Typography.toast)
                .foregroundColor(.primary)

            if let actionLabel = message.actionLabel, let action = message.action {
                Button(actionLabel) {
                    action()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, DS.Space.s16)
        .padding(.vertical, DS.Space.s12)
        .glassSurface(
            RoundedRectangle(cornerRadius: DS.Corner.c12, style: .continuous),
            elevation: .overlay
        )
    }
    
    /// The SF Symbol name for the toast type.
    private var iconName: String {
        switch message.type {
        case .success: return "checkmark.circle.fill"
        case .error: return "xmark.circle.fill"
        case .info: return "info.circle.fill"
        }
    }
    
    /// The color for the toast icon.
    private var iconColor: Color {
        switch message.type {
        case .success: return .green
        case .error: return .red
        case .info: return .blue
        }
    }
}

// MARK: - Toast Modifier

/// A view modifier that overlays a toast notification.
public struct ToastModifier: ViewModifier {
    /// The binding to the toast message.
    @Binding var toast: ToastMessage?
    /// The edge of the container where the toast appears.
    var edge: Edge = .top

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public func body(content: Content) -> some View {
        ZStack(alignment: edge == .top ? .top : .bottom) {
            content

            if let toast = toast {
                ToastView(message: toast)
                    .transition(.move(edge: edge).combined(with: .opacity))
                    .padding(Edge.Set(edge), DS.Space.s20)
                    .zIndex(100)
            }
        }
        .animation(
            reduceMotion ? nil : .spring(response: DS.Motion.slow, dampingFraction: 0.7),
            value: toast != nil
        )
    }
}

public extension View {
    /// Adds a toast notification overlay to the view.
    ///
    /// - Parameters:
    ///   - message: A binding to the toast message to display.
    ///   - edge: The edge of the container where the toast appears. Defaults to `.top`.
    /// - Returns: A view with the toast overlay.
    func toast(message: Binding<ToastMessage?>, edge: Edge = .top) -> some View {
        modifier(ToastModifier(toast: message, edge: edge))
    }
}
