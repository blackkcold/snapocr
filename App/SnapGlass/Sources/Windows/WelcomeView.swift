import SharedKit
import SwiftUI

/// The onboarding guide window's content.
///
/// Presented as a SwiftUI `Window` scene, which AppKit backs with an `NSWindow`.
/// That matters: `SystemApplicationActivationController.hasVisibleUserFacingWindow`
/// ignores every `NSPanel`, so hosting the guide in a panel would make the
/// coordinator believe no window is open, demote the app to `.accessory`, and
/// never show the Dock icon this window exists to advertise.
struct WelcomeView: View {
    /// Page currently shown.
    @State private var page: GuidePage
    /// Whether the Dock icon stays permanently.
    @State private var keepInDock: Bool
    /// Called with the page when the user finishes, skips, or closes.
    let onFinish: (GuidePage) -> Void
    /// Called when the user closes without finishing.
    let onDismiss: (GuidePage) -> Void
    /// Called when the user asks to try a capture from page 3.
    let onTryCapture: () -> Void

    /// Whether this appearance already reported its exit to the coordinator.
    ///
    /// The close button, ⌘W and Esc do not all end in the same callback, so both the
    /// escape handler and `onDisappear` fire for one close. Without a single guard the
    /// coordinator would be told twice and the coach would follow twice. The same flag
    /// covers the finishing paths, so completing the guide is never reported as an
    /// unfinished close.
    @State private var didReportExit = false

    /// Creates the guide.
    ///
    /// - Parameters:
    ///   - page: Page to open on, so an interrupted guide resumes.
    ///   - onFinish: Invoked when the guide completes.
    ///   - onDismiss: Invoked when the guide closes unfinished.
    ///   - onTryCapture: Invoked by the page 3 button.
    init(
        page: GuidePage,
        onFinish: @escaping (GuidePage) -> Void,
        onDismiss: @escaping (GuidePage) -> Void,
        onTryCapture: @escaping () -> Void
    ) {
        _page = State(initialValue: page)
        _keepInDock = State(initialValue: Self.readsKeepInDock())
        self.onFinish = onFinish
        self.onDismiss = onDismiss
        self.onTryCapture = onTryCapture
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, WelcomeMetrics.pagePadding)
                .padding(.top, WelcomeMetrics.pagePadding)

            footer
                .padding(.horizontal, WelcomeMetrics.pagePadding)
                .padding(.vertical, WelcomeMetrics.footerPadding)
        }
        .frame(width: WelcomeMetrics.width, height: WelcomeMetrics.height)
        .background(.background)
        // Single-parameter form: the two-parameter `onChange` needs macOS 14 and
        // the deployment target is 13.0.
        .onChange(of: keepInDock) { newValue in
            writeKeepInDock(newValue)
        }
        // Esc must be a close without completion, not a no-op. The system close
        // button and ⌘W land in `onDisappear`; both paths report exactly once.
        .onExitCommand {
            reportDismissal()
        }
        .onDisappear {
            reportDismissal()
        }
        .onAppear {
            // A reopened guide reuses this view instance, so the guard has to be
            // reset here or the second close would never be reported.
            didReportExit = false
        }
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .location:
            LocationPage(keepInDock: $keepInDock)
        case .shortcuts:
            ShortcutsPage()
        case .capture:
            CapturePage(onTryCapture: onTryCapture)
        case .record:
            RecordPage()
        }
    }

    private var footer: some View {
        HStack(spacing: DS.Space.s12) {
            Button("Skip guide") {
                finish()
            }
            .buttonStyle(.link)

            Spacer(minLength: 0)

            pageIndicator

            Spacer(minLength: 0)

            Button("Back") {
                if let previous = page.previous { page = previous }
            }
            .disabled(page.previous == nil)

            Button(page.next == nil ? "Done" : "Next") {
                if let next = page.next {
                    page = next
                } else {
                    finish()
                }
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Exit reporting

    /// Completes onboarding, marking the exit so `onDisappear` stays silent.
    private func finish() {
        didReportExit = true
        onFinish(page)
    }

    /// Reports a close without completion, at most once per appearance.
    ///
    /// Closing the window is the case the plan calls out: the user is exactly the
    /// person who now wonders where the app went, so this must reach the coordinator
    /// (which schedules the menu-bar coach) instead of being swallowed.
    private func reportDismissal() {
        guard !didReportExit else { return }
        didReportExit = true
        onDismiss(page)
    }

    /// Clickable page dots: the guide is four pages, so jumping is cheaper than
    /// clicking Next three times.
    private var pageIndicator: some View {
        HStack(spacing: DS.Space.s8) {
            ForEach(GuidePage.allCases) { candidate in
                Button {
                    page = candidate
                } label: {
                    Circle()
                        .fill(candidate == page ? Color.accentColor : Color.secondary.opacity(0.28))
                        .frame(width: 6, height: 6)
                        .contentShape(Rectangle().inset(by: -6))
                }
                .buttonStyle(.plain)
                // VoiceOver must hear the page's subject, not the enum case name:
                // "location" is an internal identifier, not something a user should meet.
                .accessibilityLabel(Text(LocalizedStringKey(Self.accessibilityTitle(for: candidate))))
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Localization key announcing a page dot.
    ///
    /// - Parameter page: The page the dot opens.
    /// - Returns: The key describing that page.
    private static func accessibilityTitle(for page: GuidePage) -> String {
        switch page {
        case .location: "Page 1: where SnapGlass lives"
        case .shortcuts: "Page 2: shortcuts"
        case .capture: "Page 3: after a capture"
        case .record: "Page 4: recording"
        }
    }

    // MARK: - Dock preference

    private static func readsKeepInDock() -> Bool {
        let raw = UserDefaults.standard.string(forKey: PreferenceKeys.dockIconMode)
        return DockIconMode(rawValue: raw ?? "") == .always
    }

    private func writeKeepInDock(_ keep: Bool) {
        // `always` is permanent; unchecking returns to the lifecycle default rather
        // than to `.never`, because hiding the Dock icon is a separate decision the
        // user makes in Preferences.
        let mode: DockIconMode = keep ? .always : .whileWindowsOpen
        UserDefaults.standard.set(mode.rawValue, forKey: PreferenceKeys.dockIconMode)
    }
}

/// Fixed dimensions for the guide window.
enum WelcomeMetrics {
    /// Window width; wide enough for the capture flow diagram on one line.
    static let width: CGFloat = 560
    /// Window height; fits the tallest page without scrolling.
    static let height: CGFloat = 520
    /// Inset around page content.
    static let pagePadding: CGFloat = 24
    /// Inset above and below the footer bar.
    static let footerPadding: CGFloat = 16
}
