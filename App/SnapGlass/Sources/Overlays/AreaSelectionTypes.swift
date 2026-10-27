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
    private var watchdog: Task<Void, Never>?
    private var escapeMonitor: Any?

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
        session.installSafetyNets()
    }

    /// 选区遮罩不是 key window 时收不到 `keyDown`：系统弹窗、切换 Space、
    /// 合盖唤醒都会让 Esc 失效，而外层 `withCheckedContinuation` 只依赖
    /// 这一次回调，`isCapturing` 会永久停在 true，之后所有截图热键都被
    /// 静默吞掉。这里补两条兜底：失去 key 时的本地 Esc 监听，以及有界超时。
    ///
    /// 遮罩仍持有键盘时不动手，保留「关浮层 → 回调整 → 取消」的原有层级。
    private func installSafetyNets() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // `NSEvent` 不是 Sendable：只把 keyCode 带进主 actor 闭包，
            // 事件对象本身留在监听的调用线程上。
            let keyCode = event.keyCode
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, !self.didFinish, keyCode == 53 else { return false }
                if let keyWindow = NSApp.keyWindow,
                    self.panels.contains(where: { $0 === keyWindow }) {
                    return false
                }
                self.finish(with: nil)
                return true
            }
            return consumed ? nil : event
        }
        watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled, let self, !self.didFinish else { return }
            self.finish(with: nil)
        }
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
        watchdog?.cancel()
        watchdog = nil
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        let completion = onComplete
        let activePanels = panels
        panels.removeAll()
        capturedFrames.removeAll()
        for panel in activePanels { panel.dismissWithoutCompleting() }
        Self.retainedSessions.removeAll { $0 === self }
        Task { @MainActor in completion(result) }
    }

    /// Hands late pre-captured frames to any session still on screen.
    ///
    /// Live mode presents the overlay before the frames exist; color picking
    /// starts working as soon as this lands.
    static func updateCapturedFrames(_ frames: [CGDirectDisplayID: CGImage]) {
        guard !frames.isEmpty else { return }
        for session in retainedSessions {
            session.applyCapturedFrames(frames)
        }
    }

    private func applyCapturedFrames(_ frames: [CGDirectDisplayID: CGImage]) {
        guard !didFinish else { return }
        capturedFrames.merge(frames) { _, new in new }
        for panel in panels {
            panel.updateCapturedFrames(capturedFrames)
        }
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

    /// Supplies pre-captured frames that finished after the overlay appeared.
    static func updateCapturedFrames(_ frames: [CGDirectDisplayID: CGImage]) {
        AreaSelectionSession.updateCapturedFrames(frames)
    }

    fileprivate func updateCapturedFrames(_ frames: [CGDirectDisplayID: CGImage]) {
        trackingView.updateCapturedFrames(frames)
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
