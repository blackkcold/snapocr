import AppKit
import SharedKit
import SwiftUI

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

    /// Closes the guide. `dismiss` does not reliably close a `Window` scene, so
    /// prefer the registered NSWindow and keep `dismiss` only as a fallback.
    private func closeGuide() {
        if let window = AppWindowPresenter.window(id: "permission") {
            window.performClose(nil)
        } else {
            dismiss()
        }
    }

    var body: some View {
        // The card renders every state itself, including `.requesting` and
        // `.granted`. A separate "granted" branch here used to replace the card
        // and close the window on the next SwiftUI update, so the window vanished
        // right after it opened.
        permissionCard
            .onAppear {
                checkPermission()
            }
            // macOS posts no notification when the user flips the switch in
            // System Settings, so returning to the app is the only moment the
            // card can notice. `.denied` is the usual first state on macOS 15+
            // and its "Open System Settings" button only opens Settings: without
            // this the card kept saying "Access Unavailable" after the switch
            // was turned on, and the Done state never appeared.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
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
            Text("Screen Recording permission allows screenshots, OCR, and screen recording.")
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
                grantedSection
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
            Button(
                action: {
                    requestPermission()
                },
                label: {
                    Text("Open System Settings")
                        .frame(maxWidth: .infinity)
                }
            )
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button(
                action: {
                    closeGuide()
                },
                label: {
                    Text("Remind Later")
                        .frame(maxWidth: .infinity)
                }
            )
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

    /// 屏幕捕获访问不可用时的引导；状态检查也可能因临时或无显示器错误失败。
    private var deniedView: some View {
        VStack(spacing: 12) {
            Label("Screen Capture Access Unavailable", systemImage: "xmark.circle.fill")
                .foregroundColor(.red)

            Text(
                LocalizedStringKey(
                    "Screen capture access is unavailable. Allow SnapGlass to record the screen "
                        + "in System Settings, then quit and reopen SnapGlass."
                )
            )
            .font(.caption)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)

            Button(
                action: {
                    permissionService.openScreenCaptureSettings()
                },
                label: {
                    Text("Open System Settings")
                        .frame(maxWidth: .infinity)
                }
            )
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: 260)

            Button(
                action: {
                    closeGuide()
                },
                label: {
                    Text("Remind Later")
                }
            )
            .buttonStyle(.borderless)
            .foregroundColor(.secondary)
        }
    }

    /// 权限已授权提示
    ///
    /// 已授权也必须留下一个可见窗口和明确的关闭入口：过去这里在
    /// `onAppear` 里直接关窗，用户只看到 Dock 图标闪一下。
    private var grantedSection: some View {
        VStack(spacing: 16) {
            grantedView
            Button(
                action: {
                    closeGuide()
                },
                label: {
                    Text("Done")
                        .frame(maxWidth: .infinity)
                }
            )
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: 260)
        }
    }

    private var grantedView: some View {
        Label("Permission granted. You can now use screen capture.", systemImage: "checkmark.circle.fill")
            .foregroundColor(.green)
    }
}
