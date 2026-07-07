import SwiftUI
import SharedKit

/// 屏幕录制权限引导视图
///
/// 当权限未授权时展示，包含：
/// - 权限用途说明文案
/// - "打开系统设置"按钮（跳转系统偏好设置）
/// - "稍后再说"按钮（关闭引导）
///
/// 与设计文档 Section 7.2 权限状态机的 Degraded Mode 对应。
struct PermissionGuideView: View {
    @State private var permissionState: PermissionState = .unknown
    @State private var isChecking = false
    @Environment(\.dismiss) private var dismiss

    private let permissionService = PermissionService()

    var body: some View {
        Group {
            if permissionState.needsGuide {
                permissionCard
            } else {
                Text("Permission granted")
                    .onAppear {
                        dismiss()
                    }
            }
        }
        .onAppear {
            checkPermission()
        }
    }

    // MARK: - Permission Check

    private func checkPermission() {
        guard !isChecking else { return }
        isChecking = true

        Task {
            let state = await permissionService.currentState()
            await MainActor.run {
                permissionState = state
                isChecking = false
            }
        }
    }

    private func requestPermission() {
        guard !isChecking else { return }
        isChecking = true
        permissionState = .requesting

        Task {
            let granted = await permissionService.requestScreenCapturePermission()
            await MainActor.run {
                permissionState = granted ? .granted : .denied
                isChecking = false
                if granted {
                    dismiss()
                }
            }
        }
    }

    // MARK: - UI

    private var permissionCard: some View {
        VStack(spacing: 20) {
            Spacer()

            // 图标
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            // 标题
            Text("Screen Capture Required")
                .font(.title2)
                .fontWeight(.semibold)

            // 说明文案
            Text("SnapGlass needs screen recording permission to capture screenshots and perform OCR.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal, 24)

            // 状态指示
            switch permissionState {
            case .unknown, .degraded:
                actionButtons
            case .requesting:
                requestingIndicator
            case .denied:
                deniedView
            case .granted:
                grantedView
            }

            Spacer()
        }
        .padding(32)
        .frame(width: 400, height: 360)
        .background(.regularMaterial)
        .cornerRadius(16)
        .shadow(radius: 8)
    }

    /// 操作按钮组
    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button(action: {
                requestPermission()
            }) {
                Text("Open System Settings")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button(action: {
                dismiss()
            }) {
                Text("Remind Later")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .frame(maxWidth: 260)
    }

    /// 请求中指示器
    private var requestingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.8)
            Text("Requesting permission...")
                .foregroundColor(.secondary)
        }
    }

    /// 权限被拒绝后的引导
    private var deniedView: some View {
        VStack(spacing: 12) {
            Label("Permission Denied", systemImage: "xmark.circle.fill")
                .foregroundColor(.red)

            Text("Please manually enable screen recording permission in System Settings.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button(action: {
                permissionService.openScreenCaptureSettings()
            }) {
                Text("Open System Settings")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: 260)

            Button(action: {
                dismiss()
            }) {
                Text("Remind Later")
            }
            .buttonStyle(.borderless)
            .foregroundColor(.secondary)
        }
    }

    /// 权限已授权提示
    private var grantedView: some View {
        Label("Permission granted. You can now use screen capture.", systemImage: "checkmark.circle.fill")
            .foregroundColor(.green)
    }
}
