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

    /// Creates a coach panel.
    ///
    /// - Parameters:
    ///   - content: What the panel says.
    ///   - layout: The form chosen for the available space.
    ///   - onTryIt: Invoked by the tutorial variant's button.
    ///   - onOpenControlCenter: Invoked by the card variant's button.
    ///   - onDismiss: Invoked once the panel is gone, whatever the reason.
    init(
        content: MenuBarCoachContent,
        layout: CoachLayout,
        onTryIt: (() -> Void)? = nil,
        onOpenControlCenter: (() -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        let size = Self.size(for: layout)
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
            onDismiss: { [weak self] in self?.dismiss() }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.focusRingType = .none
        contentView = hosting
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Panel size for a layout, in points.
    ///
    /// - Parameter layout: The chosen form.
    /// - Returns: The content size that form needs.
    static func size(for layout: CoachLayout) -> CGSize {
        switch layout {
        case .full: CGSize(width: 288, height: 96)
        case .compact: CGSize(width: 240, height: 64)
        case .centeredCard: CGSize(width: 320, height: 120)
        case .announcement: CGSize(width: 1, height: 1)
        }
    }

    /// Places the panel on `screen` for its layout.
    ///
    /// - Parameters:
    ///   - layout: The chosen form.
    ///   - screen: The display to use.
    /// - Returns: The panel frame in screen coordinates.
    static func frame(for layout: CoachLayout, on screen: NSScreen) -> CGRect {
        let size = size(for: layout)
        // `effectiveVisibleFrame` reserves the menu bar even when it is set to
        // auto-hide, where `visibleFrame` reports the full display and the panel
        // would slide under the bar as soon as the pointer reached the top edge.
        let visible = ScreenshotShelfGeometry.effectiveVisibleFrame(
            visibleFrame: screen.visibleFrame,
            screenFrame: screen.frame
        )

        switch layout {
        case .full, .compact:
            // Right-aligned: new menu-bar items land near the right end, so that is
            // where the pointer and the copy both point.
            let originX = visible.maxX - size.width - Self.trailingInset
            let originY = visible.maxY - size.height - Self.topInset
            return CGRect(x: originX, y: originY, width: size.width, height: size.height)
        case .centeredCard:
            let originX = visible.midX - size.width / 2
            let originY = visible.midY - size.height / 2
            return CGRect(x: originX, y: originY, width: size.width, height: size.height)
        case .announcement:
            return .zero
        }
    }

    /// Gap between the panel and the right screen edge.
    static let trailingInset: CGFloat = 12
    /// Gap between the panel and the menu bar.
    static let topInset: CGFloat = 8

    /// Shows the panel and schedules its automatic dismissal.
    func present(on screen: NSScreen, layout: CoachLayout) {
        setFrame(Self.frame(for: layout, on: screen), display: false)
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
