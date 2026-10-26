import AppKit
import CaptureCore
import SharedKit

enum AreaCaptureAction {
    case copy
    case edit
    case pin
}

struct AreaSelectionResult {
    let screenRect: CGRect
    let appKitRect: CGRect
    let normalizedPath: [CGPoint]?
    let action: AreaCaptureAction

    var isFreeform: Bool { normalizedPath != nil }
}

@MainActor
private final class AreaSelectionSession {
    private static var retainedSessions: [AreaSelectionSession] = []
    private let onComplete: (AreaSelectionResult?) -> Void
    private var panels: [AreaSelectionPanel] = []
    private var didFinish = false
    private var capturedFrames: [CGDirectDisplayID: CGImage] = [:]

    static func show(
        style: CaptureSelectionStyle,
        overlayMode: CaptureOverlayMode = .live,
        capturedFrames: [CGDirectDisplayID: CGImage] = [:],
        onColorPicked: ((SampledColor) -> Void)? = nil,
        onRecaptureRegion: (@MainActor (CGRect) async -> CGImage?)? = nil,
        onComplete: @escaping (AreaSelectionResult?) -> Void
    ) {
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            onComplete(nil)
            return
        }
        let session = AreaSelectionSession(onComplete: onComplete)
        session.capturedFrames = capturedFrames
        retainedSessions.append(session)
        session.present(
            on: screens,
            style: style,
            overlayMode: overlayMode,
            onColorPicked: onColorPicked,
            onRecaptureRegion: onRecaptureRegion
        )
    }

    private init(onComplete: @escaping (AreaSelectionResult?) -> Void) {
        self.onComplete = onComplete
    }

    private func present(
        on screens: [NSScreen],
        style: CaptureSelectionStyle,
        overlayMode: CaptureOverlayMode,
        onColorPicked: ((SampledColor) -> Void)?,
        onRecaptureRegion: (@MainActor (CGRect) async -> CGImage?)?
    ) {
        panels = screens.map { screen in
            AreaSelectionPanel(
                screen: screen,
                style: style,
                overlayMode: overlayMode,
                capturedFrames: capturedFrames,
                onColorPicked: onColorPicked,
                onRecaptureRegion: onRecaptureRegion
            ) { [weak self] result in
                self?.finish(with: result)
            }
        }
        for panel in panels {
            panel.orderFrontRegardless()
            panel.sharingType = .none
        }
        let mouseLocation = NSEvent.mouseLocation
        let initialPanel = panels.first { $0.frame.contains(mouseLocation) } ?? panels.first
        initialPanel?.makeKey()
    }

    private func finish(with result: AreaSelectionResult?) {
        guard !didFinish else { return }
        didFinish = true
        let completion = onComplete
        let activePanels = panels
        panels.removeAll()
        capturedFrames.removeAll()
        for panel in activePanels { panel.dismissWithoutCompleting() }
        Self.retainedSessions.removeAll { $0 === self }
        Task { @MainActor in completion(result) }
    }
}

final class AreaSelectionPanel: NSPanel {
    private let onComplete: (AreaSelectionResult?) -> Void
    private let trackingView: AreaTrackingView
    private var didFinish = false

    static func show(
        style: CaptureSelectionStyle,
        overlayMode: CaptureOverlayMode = .live,
        capturedFrames: [CGDirectDisplayID: CGImage] = [:],
        onColorPicked: ((SampledColor) -> Void)? = nil,
        onRecaptureRegion: (@MainActor (CGRect) async -> CGImage?)? = nil,
        onComplete: @escaping (AreaSelectionResult?) -> Void
    ) {
        AreaSelectionSession.show(
            style: style,
            overlayMode: overlayMode,
            capturedFrames: capturedFrames,
            onColorPicked: onColorPicked,
            onRecaptureRegion: onRecaptureRegion,
            onComplete: onComplete
        )
    }

    fileprivate init(
        screen: NSScreen,
        style: CaptureSelectionStyle,
        overlayMode: CaptureOverlayMode,
        capturedFrames: [CGDirectDisplayID: CGImage],
        onColorPicked: ((SampledColor) -> Void)?,
        onRecaptureRegion: (@MainActor (CGRect) async -> CGImage?)? = nil,
        onComplete: @escaping (AreaSelectionResult?) -> Void
    ) {
        let contentSize = screen.frame.size
        let trackingView = AreaTrackingView(
            frame: CGRect(origin: .zero, size: contentSize),
            style: style,
            overlayMode: overlayMode,
            screen: screen,
            capturedFrames: capturedFrames,
            onColorPicked: onColorPicked,
            onRecaptureRegion: onRecaptureRegion
        )
        self.trackingView = trackingView
        self.onComplete = onComplete
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // 决策 8 同族：遮罩面板不进入任何录屏、系统截屏或自己的截图。
        // `sharingType` 是逐窗口属性，排序后可能被重置，所以每次前置后重设。
        sharingType = .none
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isMovableByWindowBackground = false
        setFrame(screen.frame, display: true)
        trackingView.onSelectionComplete = { [weak self] rect in self?.finish(with: rect) }
        trackingView.autoresizingMask = [.width, .height]
        contentView?.addSubview(trackingView)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func orderFrontRegardless() {
        super.orderFrontRegardless()
        sharingType = .none
    }

    override func close() { finish(with: nil) }

    fileprivate func dismissWithoutCompleting() {
        guard !didFinish else { return }
        didFinish = true
        super.close()
    }

    private func finish(with result: AreaSelectionResult?) {
        guard !didFinish else { return }
        didFinish = true
        let completion = onComplete
        super.close()
        completion(result)
    }
}
