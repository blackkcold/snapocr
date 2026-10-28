import SwiftUI
import SharedKit
import AppKit

/// The main application entry point for SnapGlass.
@main
struct SnapGlassApp: App {
    /// The view model managing capture state and coordination.
    @StateObject private var viewModel = CaptureViewModel()
    /// Coordinates the selected Settings section and window opening.
    @StateObject private var router = PreferencesRouter()
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
                .environment(\.locale, locale)
                .preferredColorScheme(preferredColorScheme)
        } label: {
            Label(
                "SnapGlass",
                systemImage: viewModel.isCapturing
                    ? "camera.viewfinder.circle.fill"
                    : "camera.viewfinder"
            )
                .background {
                    AppLifecycleBridge(viewModel: viewModel, router: router)
                }
        }

        Window("Preferences", id: "preferences") {
            PreferencesView()
                .navigationTitle(Text("Preferences"))
                .environmentObject(router)
                .toast(message: $viewModel.toastMessage, edge: .bottom)
                .environmentObject(viewModel)
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
    @State private var didInitialize = false

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                viewModel.openWindow = { id in
                    AppWindowPresenter.present(id: id) {
                        openWindow(id: id)
                    }
                }
                router.openWindow = viewModel.openWindow
                guard !didInitialize else { return }
                didInitialize = true
                viewModel.checkPermissionsOnLaunch()
            }
    }
}
