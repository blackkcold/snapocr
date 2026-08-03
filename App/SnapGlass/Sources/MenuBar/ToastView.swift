import SwiftUI

/// A view that displays a toast notification.
///
/// Uses `.ultraThinMaterial` for a Liquid Glass effect.
public struct ToastView: View {
    /// The message to display.
    let message: ToastMessage
    
    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .foregroundColor(iconColor)
                .font(.system(size: 16, weight: .semibold))
            
            Text(message.message)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.primary)

            if let actionLabel = message.actionLabel, let action = message.action {
                Button(actionLabel) {
                    action()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 4)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.2), lineWidth: 0.5)
        }
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
    
    public func body(content: Content) -> some View {
        ZStack(alignment: .top) {
            content
            
            if let toast = toast {
                ToastView(message: toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 20)
                    .zIndex(100)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: toast != nil)
    }
}

public extension View {
    /// Adds a toast notification overlay to the view.
    ///
    /// - Parameter message: A binding to the toast message to display.
    /// - Returns: A view with the toast overlay.
    func toast(message: Binding<ToastMessage?>) -> some View {
        modifier(ToastModifier(toast: message))
    }
}
