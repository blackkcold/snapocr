import AppKit
import CaptureCore
import SharedKit
import SwiftUI

/// What the menu-bar coach says.
public enum MenuBarCoachContent: Equatable, Sendable {
    /// "SnapGlass is up here": shown after the guide closes.
    case location
    /// "You're set, press ⌘⇧1": shown when screen permission is granted.
    case tutorial(shortcut: String)
}

/// A borderless panel that points at the menu-bar icon.
///
/// The point of this panel is that the only on-screen evidence SnapGlass is running
/// is an 18pt icon which macOS may push into the overflow area. After the guide
/// closes, this is what turns "the window vanished" into "the app went up there".
@MainActor
final class MenuBarCoachPanel: NSPanel {
    /// How long the panel stays before dismissing itself.
    static let displayDuration: Duration = .seconds(6)

    private var dismissTask: Task<Void, Never>?
    private var onDismiss: (() -> Void)?
    /// What the panel says. The text decides how tall the panel has to be.
    private let content: MenuBarCoachContent
    /// The language chosen in Settings, injected into the hosting view.
    private let locale: Locale

    /// Creates a coach panel.
    ///
    /// - Parameters:
    ///   - content: What the panel says.
    ///   - layout: The form chosen for the available space.
    ///   - locale: The language chosen in Settings.
    ///   - onTryIt: Invoked by the tutorial variant's button.
    ///   - onOpenControlCenter: Invoked by the card variant's button.
    ///   - onDismiss: Invoked once the panel is gone, whatever the reason.
    init(
        content: MenuBarCoachContent,
        layout: CoachLayout,
        locale: Locale = AppLocalization.locale(),
        onTryIt: (() -> Void)? = nil,
        onOpenControlCenter: (() -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        let size = layout.designSize
        self.content = content
        self.locale = locale
        super.init(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.onDismiss = onDismiss
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        // `.fullScreenAuxiliary` matters: the coach follows a first run that may
        // begin in a full-screen space, and a panel that cannot join it would be
        // invisible exactly when the user needs the explanation.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        sharingType = ShowcaseMode.isEnabled ? .readOnly : .none
        isMovableByWindowBackground = false

        let view = MenuBarCoachView(
            content: content,
            layout: layout,
            onTryIt: onTryIt,
            onOpenControlCenter: onOpenControlCenter,
            onDismiss: { [weak self] in self?.dismiss() },
            locale: locale
        )
        let hosting = NSHostingView(rootView: view)
        hosting.focusRingType = .none
        // The panel owns its size. The default `sizingOptions` publishes the
        // content's minimum size as the window's `contentMinSize`, and that
        // minimum is computed at width zero — where each `.fixedSize(horizontal:
        // false, vertical: true)` text reports one line per character. The
        // 49-character subtitle measured 574pt, and AppKit stretched this 288×96
        // panel to 288×888 the first time it was ordered front.
        hosting.sizingOptions = []
        contentView = hosting
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The size this panel should take on a screen.
    ///
    /// - Parameters:
    ///   - layout: The chosen form.
    ///   - content: What the panel says; the rendered text sets the height.
    ///   - available: The screen's usable area below the menu bar.
    ///   - locale: The language the text is measured in.
    /// - Returns: A size that fits `available`.
    static func size(
        for layout: CoachLayout,
        content: MenuBarCoachContent,
        available: CGSize,
        locale: Locale = AppLocalization.locale()
    ) -> CGSize {
        guard layout != .announcement else { return layout.designSize }
        let design = layout.designSize
        // Measure at the width the panel will actually take. A centered card
        // shrinks to as little as 248pt on a narrow screen; measuring at the
        // 320pt design width wraps the text less, so the height came out short
        // and the bottom row was clipped.
        let width = CoachLayoutResolver.panelWidth(design: design, available: available)
        return CoachLayoutResolver.panelSize(
            design: design,
            measuredHeight: measuredHeight(
                content: content,
                layout: layout,
                width: width,
                locale: locale
            ),
            available: available
        )
    }

    /// Renders the content once, outside any window, to learn its height.
    ///
    /// `sizeThatFits` is the same technique the recording HUD uses for its cached
    /// layout: it lays out the real view without creating a window, touching the
    /// material, or running an implicit animation. The extra `.fixedSize` is a
    /// probe only: the view fills its window vertically, so without it the
    /// measurement just returns the proposed height instead of the content's.
    private static func measuredHeight(
        content: MenuBarCoachContent,
        layout: CoachLayout,
        width: CGFloat,
        locale: Locale
    ) -> CGFloat {
        let probe = MenuBarCoachView(
            content: content,
            layout: layout,
            onTryIt: nil,
            onOpenControlCenter: nil,
            onDismiss: {},
            locale: locale
        )
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
        let controller = NSHostingController(rootView: probe)
        return controller.sizeThatFits(in: CGSize(width: width, height: 10_000)).height
    }

    /// Shows the panel and schedules its automatic dismissal.
    func present(on screen: NSScreen, layout: CoachLayout) {
        // `effectiveVisibleFrame` reserves the menu bar even when it is set to
        // auto-hide, where `visibleFrame` reports the full display and the panel
        // would slide under the bar as soon as the pointer reached the top edge.
        let visible = ScreenshotShelfGeometry.effectiveVisibleFrame(
            visibleFrame: screen.visibleFrame,
            screenFrame: screen.frame
        )
        let size = Self.size(
            for: layout,
            content: content,
            available: visible.size,
            locale: locale
        )
        setFrame(
            CoachLayoutResolver.panelFrame(layout: layout, size: size, visible: visible),
            display: false
        )
        orderFrontRegardless()
        sharingType = ShowcaseMode.isEnabled ? .readOnly : .none
        RecordingWindowExclusionRegistry.shared.register(self)

        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.displayDuration)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    /// Hides the panel and reports the dismissal once.
    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        orderOut(nil)
        if windowNumber > 0 {
            RecordingWindowExclusionRegistry.shared.unregister(CGWindowID(windowNumber))
        }
        let callback = onDismiss
        onDismiss = nil
        callback?()
    }
}

/// Picks the display that hosts the coach.
///
/// A menu-bar app usually has no key window, so `NSScreen.main` falls back to
/// the display that owns the menu bar. On a multi-display desk the pointer is
/// the only reliable signal for the display the user just interacted with —
/// they clicked the status item, the guide's Done button, or the permission
/// window there.
enum CoachScreenSelector {
    /// The index of the first frame containing `point`.
    static func index(containing point: CGPoint, in frames: [CGRect]) -> Int? {
        frames.firstIndex { $0.contains(point) }
    }
}

/// The coach's content, in whichever form the layout allows.
struct MenuBarCoachView: View {
    /// What the panel says.
    let content: MenuBarCoachContent
    /// The form chosen for the available space.
    let layout: CoachLayout
    /// Invoked by the tutorial variant's button.
    let onTryIt: (() -> Void)?
    /// Invoked by the card variant's settings button.
    let onOpenControlCenter: (() -> Void)?
    /// Invoked by the card variant's close button.
    let onDismiss: () -> Void
    /// The language chosen in Settings.
    ///
    /// The panel is an AppKit window, so it sits outside the SwiftUI scene that
    /// injects `\.locale`; without this the coach follows the system language
    /// instead of the app language, and its measured height is wrong too.
    let locale: Locale

    init(
        content: MenuBarCoachContent,
        layout: CoachLayout,
        onTryIt: (() -> Void)?,
        onOpenControlCenter: (() -> Void)?,
        onDismiss: @escaping () -> Void,
        locale: Locale = AppLocalization.locale()
    ) {
        self.content = content
        self.layout = layout
        self.onTryIt = onTryIt
        self.onOpenControlCenter = onOpenControlCenter
        self.onDismiss = onDismiss
        self.locale = locale
    }

    var body: some View {
        Group {
            switch layout {
            case .full:
                fullBody
            case .compact:
                compactBody
            case .centeredCard:
                cardBody
            case .announcement:
                EmptyView()
            }
        }
        .environment(\.locale, locale)
    }

    /// L0: icon, message, and the triangle pointing at the menu bar.
    private var fullBody: some View {
        VStack(alignment: .leading, spacing: DS.Space.s8) {
            HStack(spacing: DS.Space.s8) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 22, height: 22)
                    .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: DS.Corner.c6))
                Text(LocalizedStringKey(headline))
                    .font(DS.Typography.bodyStrong)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            Text(LocalizedStringKey(subtitle))
                .font(DS.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 30)

            if case .tutorial = content {
                tryItButton
                    .padding(.leading, 30)
            }
        }
        .padding(DS.Space.s14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Corner.c12))
        .overlay(alignment: .top) {
            // The pointer sits above the panel, angled at the menu bar.
            Triangle()
                .fill(.regularMaterial)
                .frame(width: 12, height: 7)
                .offset(y: -6)
        }
        .padding(.top, 6)
    }

    /// L1: a single line, no triangle.
    private var compactBody: some View {
        HStack(spacing: DS.Space.s6) {
            Image(systemName: "camera.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text(LocalizedStringKey(headline))
                .font(DS.Typography.captionStrong)
                .lineLimit(1)
            Image(systemName: "arrow.up.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.s12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Corner.c10))
    }

    /// L2: a card in the middle of the screen, with no pointer.
    ///
    /// The card deliberately does not open the guide: the guide is already complete
    /// by the time the coach appears, so reopening it would contradict the state.
    private var cardBody: some View {
        VStack(alignment: .leading, spacing: DS.Space.s8) {
            Text(LocalizedStringKey("SnapGlass is in the menu bar, top right."))
                .font(DS.Typography.bodyStrong)
                .fixedSize(horizontal: false, vertical: true)
            Text(LocalizedStringKey("Your menu bar is crowded, so its icon may be hidden."))
                .font(DS.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.Space.s8) {
                Button(LocalizedStringKey("Open Control Center Settings")) {
                    onOpenControlCenter?()
                }
                .controlSize(.small)
                Spacer(minLength: 0)
                Button(LocalizedStringKey("Close")) {
                    onDismiss()
                }
                .controlSize(.small)
                .buttonStyle(.link)
            }
            .padding(.top, DS.Space.s2)
        }
        .padding(DS.Space.s14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Corner.c12))
    }

    private var tryItButton: some View {
        Button(LocalizedStringKey("Try it")) {
            onTryIt?()
        }
        .controlSize(.small)
        .buttonStyle(.borderedProminent)
    }

    /// Localization key for the panel's headline.
    private var headline: String {
        switch content {
        case .location: "SnapGlass is up here"
        case .tutorial: "You're set — try a capture"
        }
    }

    /// Localization key for the panel's subtitle.
    private var subtitle: String {
        switch content {
        case .location: "The camera icon in the menu bar opens everything."
        case .tutorial(let shortcut): "Press %@ anywhere to grab part of the screen."
        }
    }
}
