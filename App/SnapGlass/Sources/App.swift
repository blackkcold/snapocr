import AppKit
import SharedKit
import SwiftUI

/// Process entry point.
///
/// The agent channel needs `NSApplication` without any SwiftUI scene, because
/// `SceneBuilder` cannot branch between scene types. Normal launches delegate to
/// the SwiftUI app exactly as before.
@main
@MainActor
enum SnapGlassLauncher {
    private static var agentDelegate: SnapGlassApplicationDelegate?

    static func main() {
        if AgentMode.isActive {
            let application = NSApplication.shared
            let delegate = SnapGlassApplicationDelegate()
            agentDelegate = delegate
            application.delegate = delegate
            application.setActivationPolicy(.accessory)
            application.run()
            return
        }
        SnapGlassApp.main()
    }
}

/// The SwiftUI application: menu bar item, windows, and commands.
struct SnapGlassApp: App {
    @NSApplicationDelegateAdaptor(SnapGlassApplicationDelegate.self)
    private var applicationDelegate

    var body: some Scene {
        SnapGlassMainScene(applicationDelegate: applicationDelegate)
    }
}

/// The normal menu bar application: menu item, windows, and commands.
///
/// Extracted from `SnapGlassApp` so an agent launch never initializes the view
/// model, updater, or menu bar infrastructure.
private struct SnapGlassMainScene: Scene {
    /// The application delegate shared with the menu bar lifecycle bridge.
    let applicationDelegate: SnapGlassApplicationDelegate
    /// The view model managing capture state and coordination.
    @StateObject private var viewModel = CaptureViewModel()
    /// Coordinates the selected Settings section and window opening.
    @StateObject private var router = PreferencesRouter()
    /// Owns Sparkle and the install-deferral state.
    @StateObject private var updater = UpdaterManager()
    @AppStorage(PreferenceKeys.appLanguage)
    private var appLanguage = PreferenceDefaults.appLanguage
    @AppStorage(PreferenceKeys.appearanceMode)
    private var appearanceMode = PreferenceDefaults.appearanceMode
    @AppStorage(PreferenceKeys.editorInspectorVisible)
    private var editorInspectorVisible = PreferenceDefaults.editorInspectorVisible

    private var locale: Locale {
        (AppLanguage(rawValue: appLanguage) ?? .system).locale
    }

    private var preferredColorScheme: ColorScheme? {
        switch AppearanceMode(rawValue: appearanceMode) ?? .system {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(viewModel)
                .environmentObject(router)
                .environmentObject(updater)
                .environment(\.locale, locale)
                .preferredColorScheme(preferredColorScheme)
        } label: {
            MenuBarStatusLabel(
                status: viewModel.recordingStatus,
                isCapturing: viewModel.isCapturing,
                recordingKind: viewModel.currentRecordingKind,
                hasFailure: viewModel.recordingFailure != nil,
                hasUpdate: updater.hasAvailableUpdate
            )
            .environment(\.locale, locale)
            .background {
                AppLifecycleBridge(
                    viewModel: viewModel,
                    router: router,
                    updater: updater,
                    applicationDelegate: applicationDelegate
                )
            }
        }

        Window("Preferences", id: "preferences") {
            PreferencesView()
                .navigationTitle(Text("Preferences"))
                .environmentObject(router)
                .toast(message: $viewModel.toastMessage, edge: .bottom)
                .environmentObject(viewModel)
                .environmentObject(updater)
                .environment(\.locale, locale)
                .preferredColorScheme(preferredColorScheme)
                .background(AppWindowRegistrationView(id: "preferences", appearanceMode: appearanceMode))
        }
        .defaultSize(width: PreferencesSpacing.idealWindowWidth, height: PreferencesSpacing.idealWindowHeight)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(AppLocalization.string("About SnapGlass")) {
                    router.presentAbout()
                }
            }

            CommandGroup(replacing: .appSettings) {
                Button(AppLocalization.string("Preferences...")) {
                    router.presentSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandGroup(after: .sidebar) {
                Button(AppLocalization.string("Toggle Inspector")) {
                    editorInspectorVisible.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
            }

            CommandGroup(after: .windowArrangement) {
                Button(AppLocalization.string("Close Window")) {
                    NSApp.keyWindow?.performClose(nil)
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            }
        }

        Window("History", id: "history") {
            HistoryView()
                .navigationTitle(Text("History"))
                .environmentObject(viewModel)
                // 历史窗口自己的 toast 在底部；截图级提示放顶部，两者不重叠。
                .toast(message: $viewModel.toastMessage, edge: .top)
                .environment(\.locale, locale)
                .preferredColorScheme(preferredColorScheme)
                .background(AppWindowRegistrationView(id: "history", appearanceMode: appearanceMode))
        }

        Window("Recordings", id: AppWindowPresenter.recordingsWindowID) {
            RecordingsWindow()
                .navigationTitle(Text("Recordings"))
                .environment(\.locale, locale)
                .preferredColorScheme(preferredColorScheme)
                .background(
                    AppWindowRegistrationView(
                        id: AppWindowPresenter.recordingsWindowID,
                        appearanceMode: appearanceMode
                    ))
        }
        .defaultSize(width: PreferencesSpacing.idealWindowWidth, height: PreferencesSpacing.idealWindowHeight)
        .windowResizability(.contentMinSize)

        Window("Annotation Editor", id: "editor") {
            EditorWorkspaceView(workspace: viewModel.editorWorkspace)
                // Capture-level toasts sit at the bottom so they cannot
                // overlap the editor's own toast at the top.
                .toast(message: $viewModel.toastMessage, edge: .bottom)
                .environment(\.locale, locale)
                .preferredColorScheme(preferredColorScheme)
                .navigationTitle(Text("Annotation Editor"))
                .background(AppWindowRegistrationView(id: "editor", appearanceMode: appearanceMode))
        }

        Window("Permission Required", id: "permission") {
            PermissionGuideView()
                .navigationTitle(Text("Permission Required"))
                .toast(message: $viewModel.toastMessage, edge: .bottom)
                .environment(\.locale, locale)
                .preferredColorScheme(preferredColorScheme)
                .background(AppWindowRegistrationView(id: "permission", appearanceMode: appearanceMode))
        }
        .windowResizability(.contentSize)
    }
}

/// Installs window routing as soon as the persistent menu bar label appears.
/// This keeps global shortcuts functional before the menu is opened for the first time.
private struct AppLifecycleBridge: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var viewModel: CaptureViewModel
    @ObservedObject var router: PreferencesRouter
    @ObservedObject var updater: UpdaterManager
    /// The application delegate that owns quit and reopen routing.
    let applicationDelegate: SnapGlassApplicationDelegate
    @State private var didInitialize = false

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                applicationDelegate.viewModel = viewModel
                applicationDelegate.updater = updater
                updater.attach(to: viewModel)
                updater.onInstallPostponed = { [weak viewModel] blocker in
                    viewModel?.showToast(
                        message: AppLocalization.string(blocker.message),
                        type: .info
                    )
                }
                viewModel.openWindow = { id in
                    AppWindowPresenter.present(id: id) {
                        openWindow(id: id)
                    }
                }
                router.openWindow = viewModel.openWindow
                guard !didInitialize else { return }
                didInitialize = true
                updater.start()
                viewModel.checkPermissionsOnLaunch()
                // Interrupted recordings are discovered once, off the main actor,
                // right after launch. Failure only logs; it never blocks startup.
                Task { await viewModel.scanRecoverableRecordingsAtLaunch() }
            }
    }
}
