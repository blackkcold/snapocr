import AppKit
import Combine
import Sparkle

/// Owns Sparkle and turns its delegate callbacks into the app's presentation
/// state.
///
/// The standard user driver is used on purpose: it already ships 36
/// localizations (including ja, ko and zh_CN), download progress, release
/// notes, EdDSA verification, atomic bundle replacement and relaunch. The app
/// only adds a menu-bar reminder and defers installation while the editor has
/// unsaved work or a recording is in flight.
@MainActor
final class UpdaterManager: NSObject, ObservableObject {
    @Published private(set) var state: UpdateCheckState = .idle
    /// Set while Sparkle waits for the app to become idle.
    @Published private(set) var pendingBlocker: UpdateBlocker?
    /// True from the moment the install handler runs until the process exits.
    /// `applicationShouldTerminate` consults it so the relaunch cannot be
    /// intercepted by the unsaved-edits or recording prompts.
    @Published private(set) var isInstallingUpdate = false

    /// Called when Sparkle wanted to install but the app was busy.
    var onInstallPostponed: ((UpdateBlocker) -> Void)?

    private weak var viewModel: CaptureViewModel?
    private var controller: SPUStandardUpdaterController?
    private var userInitiatedCheck = false
    private var pendingInstallHandler: (() -> Void)?
    private var pendingWatch: Task<Void, Never>?
    private let activation = SystemApplicationActivationController()

    /// Sparkle aborts at startup with a configuration alert when the feed or
    /// the EdDSA key is missing. Test runners and `swift run` do not have them.
    static var isConfigured: Bool {
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        return !feed.isEmpty && !key.isEmpty
    }

    var availableUpdate: AvailableUpdate? { state.availableUpdate }
    var hasAvailableUpdate: Bool { availableUpdate != nil }

    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            controller?.updater.automaticallyChecksForUpdates = newValue
            objectWillChange.send()
        }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set {
            controller?.updater.automaticallyDownloadsUpdates = newValue
            objectWillChange.send()
        }
    }

    var allowsAutomaticUpdates: Bool {
        controller?.updater.allowsAutomaticUpdates ?? false
    }

    func attach(to viewModel: CaptureViewModel) {
        self.viewModel = viewModel
    }

    /// Starts Sparkle once. Safe to call from every launch path.
    func start() {
        guard Self.isConfigured, controller == nil else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        self.controller = controller
        controller.startUpdater()
    }

    /// User-initiated check. Errors are surfaced, and the window is brought to
    /// the front before Sparkle shows anything.
    func checkForUpdates() {
        guard Self.isConfigured else { return }
        start()
        guard let controller else { return }
        // Sparkle ignores a check while another one is in flight; without this
        // guard the panel would stay on "checking" forever.
        guard controller.updater.canCheckForUpdates else { return }
        userInitiatedCheck = true
        state = .checking
        beginExternalPresentation()
        controller.checkForUpdates(nil)
    }

    /// Entry point for the menu item and the settings panel. Re-presenting the
    /// already found update lets the user act on it again after dismissing
    /// Sparkle's first alert.
    func presentUpdate() {
        checkForUpdates()
    }

    /// Installs immediately when the blocker has been cleared.
    func installNowIfPossible() {
        guard pendingInstallHandler != nil, currentBlocker() == nil else { return }
        resumePendingInstall()
    }

    // MARK: - Installation deferral

    private func currentBlocker() -> UpdateBlocker? {
        guard let viewModel else { return nil }
        if viewModel.needsRecordingQuitConfirmation { return .recording }
        if viewModel.editorWorkspace.hasAnyUnsavedChanges { return .unsavedEdits }
        return nil
    }

    private func startPendingWatch() {
        pendingWatch?.cancel()
        pendingWatch = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard self.pendingInstallHandler != nil else { return }
                if self.currentBlocker() == nil {
                    self.resumePendingInstall()
                    return
                }
            }
        }
    }

    private func resumePendingInstall() {
        guard let handler = pendingInstallHandler else { return }
        pendingWatch?.cancel()
        pendingWatch = nil
        pendingInstallHandler = nil
        pendingBlocker = nil
        isInstallingUpdate = true
        handler()
    }

    // MARK: - Menu-bar activation

    private func beginExternalPresentation() {
        _ = activation.setActivationPolicy(.regular)
        activation.requestActivation()
    }

    private func endExternalPresentation() {
        guard !activation.hasVisibleUserFacingWindow else { return }
        _ = activation.setActivationPolicy(.accessory)
    }
}

// MARK: - SPUUpdaterDelegate

extension UpdaterManager: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        userInitiatedCheck = false
        state = .available(
            AvailableUpdate(
                displayVersion: item.displayVersionString,
                releaseNotesURL: item.releaseNotesURL
            )
        )
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        var update = availableUpdate
            ?? AvailableUpdate(
                displayVersion: item.displayVersionString,
                releaseNotesURL: item.releaseNotesURL
            )
        update.isDownloaded = true
        state = .available(update)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        state = userInitiatedCheck ? .upToDate(Self.currentVersion) : .idle
        userInitiatedCheck = false
    }

    /// Sparkle uses this variant when it can explain why no update was found.
    /// `noUpdateError` means "already current", not a failure.
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        let nsError = error as NSError
        let isCurrent = nsError.domain == SUSparkleErrorDomain
            && nsError.code == Int(SUError.noUpdateError.rawValue)
        if isCurrent {
            state = userInitiatedCheck ? .upToDate(Self.currentVersion) : .idle
        } else {
            state = userInitiatedCheck ? .failed(error.localizedDescription) : .idle
        }
        userInitiatedCheck = false
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        state = userInitiatedCheck ? .failed(error.localizedDescription) : .idle
        userInitiatedCheck = false
    }

    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvoking block: @escaping () -> Void
    ) -> Bool {
        guard let blocker = currentBlocker() else { return false }
        pendingInstallHandler = block
        pendingBlocker = blocker
        onInstallPostponed?(blocker)
        startPendingWatch()
        return true
    }

    func updater(
        _ updater: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate item: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        switch choice {
        case .skip:
            self.state = .idle
        case .dismiss, .install:
            break
        @unknown default:
            break
        }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
}

// MARK: - SPUStandardUserDriverDelegate

/// Sparkle does not annotate this protocol, so its witnesses must be
/// `nonisolated` even though Sparkle calls them on the main thread. The two
/// void callbacks hop back to the main actor explicitly.
extension UpdaterManager: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Scheduled checks only take over the screen when the system decides
        // the user is already idle. Otherwise the app shows its own badge.
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard handleShowingUpdate else { return }
        Task { @MainActor in
            self.beginExternalPresentation()
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in
            self.endExternalPresentation()
        }
    }
}
