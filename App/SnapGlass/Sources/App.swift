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
    /// Owns the onboarding state machine and its windows.
    @StateObject private var onboarding = OnboardingRuntime()
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
                .environmentObject(onboarding)
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
                    onboarding: onboarding,
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
            Group {
                if LibraryFeature.isEnabled {
                    LibraryView()
                } else {
                    HistoryView()
                }
            }
            .navigationTitle(Text("History"))
            .environmentObject(viewModel)
            // 历史窗口自己的 toast 在底部；截图级提示放顶部，两者不重叠。
            .toast(message: $viewModel.toastMessage, edge: .top)
            .environment(\.locale, locale)
            .preferredColorScheme(preferredColorScheme)
            .background(AppWindowRegistrationView(id: "history", appearanceMode: appearanceMode))
        }
        .defaultSize(width: 1_040, height: 720)
        .windowResizability(.contentMinSize)

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

        // The guide is a `Window`, not a `WindowGroup`: it is a one-off, and a group
        // would let the app menu open a second copy. It must also stay an `NSWindow` —
        // `hasVisibleUserFacingWindow` ignores every `NSPanel`, so a panel-backed guide
        // would demote the app to `.accessory` and never show the Dock icon it exists
        // to advertise.
        Window("Welcome to SnapGlass", id: WelcomeWindowPresenter.windowID) {
            WelcomeView(
                page: onboarding.savedGuidePage,
                onFinish: { page in
                    onboarding.finishGuide(at: page)
                    Task { await onboarding.evaluate(welcomeJustDismissed: true) }
                },
                onDismiss: { page in
                    onboarding.dismissGuideWithoutCompleting(at: page)
                    Task { await onboarding.evaluate(welcomeJustDismissed: true) }
                },
                onTryCapture: { [viewModel] in
                    // Close the guide, then start the capture immediately. Evaluating
                    // onboarding first would let the coach panel and the selection
                    // overlay compete for the same frame: the overlay sits at
                    // `.screenSaver` level, so the coach would be invisible while
                    // still counting as shown. The capture marks itself as started,
                    // so the later evaluation returns no action until it finishes.
                    onboarding.finishGuide(at: .capture)
                    viewModel.captureArea()
                }
            )
            .navigationTitle(Text("Welcome to SnapGlass"))
            .environment(\.locale, locale)
            .preferredColorScheme(preferredColorScheme)
            .background(AppWindowRegistrationView(id: WelcomeWindowPresenter.windowID, appearanceMode: appearanceMode))
        }
        .defaultSize(width: WelcomeMetrics.width, height: WelcomeMetrics.height)
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
    /// Onboarding state machine and its guide window.
    @ObservedObject var onboarding: OnboardingRuntime
    /// The application delegate that owns quit and reopen routing.
    let applicationDelegate: SnapGlassApplicationDelegate
    @State private var didInitialize = false

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                applicationDelegate.viewModel = viewModel
                applicationDelegate.updater = updater
                applicationDelegate.onboarding = onboarding
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
                // `WelcomeWindowPresenter` wraps this opener in
                // `AppWindowPresenter.present` itself, so hand it the raw scene
                // action. Passing `viewModel.openWindow` here nests a second
                // presentation under the same id; the inner one is dropped as
                // in-flight and the guide window never opens.
                onboarding.presenter.openWindow = { id in openWindow(id: id) }
                guard !didInitialize else { return }
                didInitialize = true
                updater.start()
                // A first run must not open the permission window: the guide has a page
                // for it, and two windows appearing at once on launch is exactly the
                // "what is happening" confusion this work exists to remove. Returning
                // users keep the automatic prompt.
                if !onboarding.isFirstRun {
                    viewModel.checkPermissionsOnLaunch()
                }
                wireOnboardingProbes()
                // Interrupted recordings are discovered once, off the main actor,
                // right after launch. Failure only logs; it never blocks startup.
                Task { await viewModel.scanRecoverableRecordingsAtLaunch() }
                // Runs after the menu-bar label exists, so opening the guide here
                // cannot race the routing installation above.
                Task { await onboarding.start() }
            }
    }

    /// Installs the facts the onboarding policy reads.
    ///
    /// Each probe is a closure rather than a stored copy so it always reflects the
    /// current moment; a snapshot taken here would be stale by the next evaluation.
    private func wireOnboardingProbes() {
        onboarding.permissionProbe = {
            await PermissionService().checkScreenCapturePermission()
        }
        onboarding.captureStateProbe = { [weak viewModel] in
            guard let viewModel else { return true }
            return viewModel.isCapturing || viewModel.isRecordingBusy
        }
        onboarding.shelfStateProbe = { [weak viewModel] in
            viewModel?.isScreenshotShelfVisible ?? false
        }
        // The coach must not appear over the area-selection overlay: that overlay sits
        // at `.screenSaver` level, so the panel would be invisible while the "shown"
        // flag was already written — permanently lost.
        onboarding.coach.isCapturing = { [weak viewModel] in
            guard let viewModel else { return true }
            return viewModel.isCapturing || viewModel.isRecordingBusy
        }
        onboarding.coach.onShown = { [weak onboarding] in
            onboarding?.recordCoachShown()
        }
        onboarding.coach.onTryIt = { [weak viewModel] in
            viewModel?.captureArea()
        }
        // The tutorial is chained: the editor banner waits for a capture, and the
        // shelf hint waits for the shelf. Nothing else reports the first fact, so
        // without this hook the chain stops at "press the shortcut" forever.
        viewModel.onCapturePublished = { [weak onboarding] openedEditor in
            Task { @MainActor in
                await onboarding?.noteCapturePublished(openedEditor: openedEditor)
            }
        }
    }
}
