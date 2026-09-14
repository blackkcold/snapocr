import AppKit
import CaptureCore
import SharedKit

enum AreaCaptureAction {
    case copy
    case edit
}

struct AreaSelectionResult {
    let screenRect: CGRect
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
            onColorPicked: onColorPicked
        )
    }

    private init(onComplete: @escaping (AreaSelectionResult?) -> Void) {
        self.onComplete = onComplete
    }

    private func present(
        on screens: [NSScreen],
        style: CaptureSelectionStyle,
        overlayMode: CaptureOverlayMode,
        onColorPicked: ((SampledColor) -> Void)?
    ) {
        panels = screens.map { screen in
            AreaSelectionPanel(
                screen: screen,
                style: style,
                overlayMode: overlayMode,
                capturedFrames: capturedFrames,
                onColorPicked: onColorPicked
            ) { [weak self] result in
                self?.finish(with: result)
            }
        }
        for panel in panels { panel.orderFrontRegardless() }
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
        onComplete: @escaping (AreaSelectionResult?) -> Void
    ) {
        AreaSelectionSession.show(
            style: style,
            overlayMode: overlayMode,
            capturedFrames: capturedFrames,
            onColorPicked: onColorPicked,
            onComplete: onComplete
        )
    }

    fileprivate init(
        screen: NSScreen,
        style: CaptureSelectionStyle,
        overlayMode: CaptureOverlayMode,
        capturedFrames: [CGDirectDisplayID: CGImage],
        onColorPicked: ((SampledColor) -> Void)?,
        onComplete: @escaping (AreaSelectionResult?) -> Void
    ) {
        let contentSize = screen.frame.size
        let trackingView = AreaTrackingView(
            frame: CGRect(origin: .zero, size: contentSize),
            style: style,
            overlayMode: overlayMode,
            screen: screen,
            capturedFrames: capturedFrames,
            onColorPicked: onColorPicked
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
