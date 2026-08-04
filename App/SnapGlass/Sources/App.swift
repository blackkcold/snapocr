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
                .environment(\.locale, locale)
                .preferredColorScheme(preferredColorScheme)
        } label: {
            Label("SnapGlass", systemImage: "camera.viewfinder")
                .background {
                    AppLifecycleBridge(viewModel: viewModel, router: router)
                }
        }

        Window("Preferences", id: "preferences") {
            PreferencesView()
                .environmentObject(router)
                .toast(message: $viewModel.toastMessage)
                .environmentObject(viewModel)
                .environment(\.locale, locale)
                .preferredColorScheme(preferredColorScheme)
                .background(AppWindowRegistrationView(id: "preferences"))
        }
        .defaultSize(width: PreferencesSpacing.idealWindowWidth, height: PreferencesSpacing.idealWindowHeight)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About SnapGlass") {
                    router.presentAbout()
                }
            }

            CommandGroup(replacing: .appSettings) {
                Button("Preferences...") {
                    router.presentSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }

        Window("History", id: "history") {
            HistoryView()
                .environmentObject(viewModel)
                .toast(message: $viewModel.toastMessage)
                .environment(\.locale, locale)
                .preferredColorScheme(preferredColorScheme)
                .background(AppWindowRegistrationView(id: "history"))
        }
        
        Window("Annotation Editor", id: "editor") {
            if let image = viewModel.editorImage {
                EditorView(image: image, context: viewModel.editorContext)
                    .id(viewModel.editorSessionID)
                    .frame(minWidth: 800, minHeight: 600)
                    .toast(message: $viewModel.toastMessage)
                    .environment(\.locale, locale)
                    .preferredColorScheme(preferredColorScheme)
                    .background(AppWindowRegistrationView(id: "editor"))
            }
        }
        
        Window("Permission Required", id: "permission") {
            PermissionGuideView()
                .toast(message: $viewModel.toastMessage)
                .environment(\.locale, locale)
                .preferredColorScheme(preferredColorScheme)
                .background(AppWindowRegistrationView(id: "permission"))
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
                NSApplication.shared.setActivationPolicy(.accessory)
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
