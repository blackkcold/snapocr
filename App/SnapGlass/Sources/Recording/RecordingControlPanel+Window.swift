import AppKit
import CaptureCore
import OSLog
import SharedKit
import SwiftUI

/// Floating capsule that reports and controls one screen recording.
///
/// The window is exactly the size of the capsule and relies on the system window shadow
/// (`hasShadow = true`), so the shadow is drawn outside the window and can never be clipped by the
/// frame. Its width follows the measured SwiftUI content, so long localizations and action rows
/// are not squeezed; a persistent failure may grow taller when its details are expanded.
/// Opacity applies to the surface only; text keeps full contrast.
@MainActor
final class RecordingControlPanel: NSPanel, NSWindowDelegate {
    private let actions: RecordingControlPanelActions
    private let model: RecordingControlPanelModel
    private let hostingView: NSHostingView<RecordingControlPanelView>
    /// Off-window hosting view used only for the static measure view.
    ///
    /// Created on the first measurement, so creating the panel performs no layout work
    /// and the first frame is ordered front without touching SwiftUI sizing at all.
    private lazy var measurementController = NSHostingController(
        rootView: RecordingControlPanelMeasureView(
            signature: RecordingHUDLayoutSignature(
                content: .countdown,
                language: AppLocalization.languageIdentifier
            ),
            sizing: .ideal,
            failureScrollHeight: nil
        )
    )

    /// Sizes already measured for this panel, keyed by layout signature.
    private var sizeCache = RecordingHUDSizeCache()
    /// Scroll heights measured for expanded failure cards, keyed by layout signature.
    private var failureScrollHeights: [RecordingHUDLayoutSignature: CGFloat] = [:]
    /// Guards `apply(state:)` against re-entry from a model change it caused.
    private var isApplying = false
    /// The last state family written to the persisted log, so per-tick updates of the
    /// same state do not spam it.
    private var lastLoggedStateName: String?
    /// Whether a deferred measurement pass is already queued for the next main-loop turn.
    private var isMeasurementScheduled = false
    /// The size this panel last asked for, so a status tick during the correction
    /// animation cannot snap the frame to its end.
    private var lastRequestedSize: CGSize?
    private var screenFrame: CGRect
    private var corner: RecordingHUDCorner
    private var isProgrammaticMove = false
    private var snapTask: Task<Void, Never>?
    /// Shape-accurate shadow drawn below the capsule; see `RecordingHUDShadowWindow`.
    private var shadowWindow: RecordingHUDShadowWindow?
    private let logger = Logger(subsystem: "com.snapglass", category: "recording.hud")

    var excludedWindowIDs: Set<CGWindowID> {
        var identifiers: Set<CGWindowID> = []
        if windowNumber > 0 { identifiers.insert(CGWindowID(windowNumber)) }
        if let shadowWindow, shadowWindow.windowNumber > 0 {
            identifiers.insert(CGWindowID(shadowWindow.windowNumber))
        }
        return identifiers
    }

    /// The HUD accepts focus for VoiceOver and keyboard travel without activating the app.
    override var canBecomeKey: Bool { true }

    /// The HUD is an accessory capsule, never a main window.
    override var canBecomeMain: Bool { false }

    init(
        on screen: NSScreen?,
        corner: RecordingHUDCorner,
        opacity: Double,
        hoverRestore: Bool,
        actions: RecordingControlPanelActions
    ) {
        let fallbackFrame = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let screenFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? fallbackFrame
        let model = RecordingControlPanelModel(
            state: .countdown(3),
            surfaceOpacity: opacity,
            hoverRestore: hoverRestore
        )
        let displayView = RecordingControlPanelView(
            model: model,
            actions: actions
        )
        let hostingView = NSHostingView(rootView: displayView)
        let size = RecordingHUDMetrics.countdownSize
        let origin = RecordingHUDPlacement.origin(for: corner, size: size, in: screenFrame)

        self.actions = actions
        self.model = model
        self.hostingView = hostingView
        self.screenFrame = screenFrame
        self.corner = corner

        super.init(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        // macOS 26 draws a window edge around the frame rectangle from the same
        // property that draws the window shadow. This frame is exactly the capsule,
        // so that edge showed as a square grey line across the capsule's round ends.
        // `RecordingHUDShadowWindow` draws the capsule shadow instead.
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        sharingType = ShowcaseMode.isEnabled ? .readOnly : .none
        delegate = self
        // A key panel must not draw AppKit's rectangular focus ring around the
        // hosting view: the ring follows the view's frame, not the capsule.
        hostingView.focusRingType = .none
        contentView = hostingView

        let shadowWindow = RecordingHUDShadowWindow()
        self.shadowWindow = shadowWindow
        shadowWindow.follow(
            panelFrame: frame,
            cornerRadius: RecordingHUDMetrics.cornerRadius,
            animated: false
        )

        model.onLayoutChange = { [weak self] in
            guard let self else { return }
            self.apply(state: self.model.state, presenting: false)
        }
    }

    override func orderFrontRegardless() {
        if AgentMode.isActive { AgentHUDMetrics.noteFirstVisible() }
        syncShadow(to: frame, animated: false)
        shadowWindow?.reveal()
        super.orderFrontRegardless()
        // `sharingType` is per-window and can be reset by ordering.
        sharingType = ShowcaseMode.isEnabled ? .readOnly : .none
        RecordingWindowExclusionRegistry.shared.register(self)
    }

    /// Borderless panels must keep their exact frame near screen edges.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// Shows the panel with `state` and orders it front without measuring.
    ///
    /// Ordering stays synchronous: callers read `isVisible` right after presenting.
    func present(state: RecordingControlPanelState) {
        apply(state: state, presenting: true)
    }

    /// Applies a status change without measuring.
    func update(state: RecordingControlPanelState) {
        apply(state: state, presenting: false)
    }

    /// Applies one state and its cached size; never calls `sizeThatFits`.
    ///
    /// A signature that has not been measured uses a conservative fallback for this
    /// frame and is measured after the status change has returned, so no state change
    /// waits on SwiftUI layout.
    private func apply(state: RecordingControlPanelState, presenting: Bool) {
        guard !isApplying else { return }
        isApplying = true
        defer { isApplying = false }
        if AgentMode.isActive { AgentHUDMetrics.noteApply() }

        if Self.failureReason(of: model.state) != Self.failureReason(of: state) {
            model.failureExpanded = false
            model.failureScrollHeight = nil
        }
        if model.state != state { model.state = state }

        let signature = currentSignature()
        if signature.logName != lastLoggedStateName {
            lastLoggedStateName = signature.logName
            // Persisted (unlike the per-tick debug lines), so a future freeze can be
            // traced to the last state the panel actually accepted.
            logger.notice(
                "HUD state accepted=\(signature.logName, privacy: .public) visible=\(self.isVisible, privacy: .public) cache=\(self.sizeCache.size(for: signature) != nil, privacy: .public)"
            )
        }
        if let cached = sizeCache.lookup(signature) {
            applyFailureScrollHeight(for: signature)
            setSize(cached, animated: false)
            logger.debug(
                "HUD apply state=\(signature.logName, privacy: .public) signature=\(Self.signatureCode(signature), privacy: .public) cache=hit"
            )
        } else {
            let fallback = fallbackSize(for: signature)
            setSize(fallback, animated: false)
            scheduleMeasurement()
            logger.debug(
                "HUD apply state=\(signature.logName, privacy: .public) signature=\(Self.signatureCode(signature), privacy: .public) cache=miss"
            )
        }

        if presenting, !isVisible { orderFrontRegardless() }
    }

    func updateAppearance(opacity: Double, hoverRestore: Bool) {
        model.surfaceOpacity = opacity
        model.hoverRestore = hoverRestore
    }

    func dismiss() {
        snapTask?.cancel()
        snapTask = nil
        shadowWindow?.orderOut(nil)
        orderOut(nil)
        if windowNumber > 0 {
            RecordingWindowExclusionRegistry.shared.unregister(CGWindowID(windowNumber))
        }
    }

    override func close() {
        shadowWindow?.orderOut(nil)
        super.close()
    }

    func windowDidMove(_ notification: Notification) {
        guard !isProgrammaticMove else { return }
        syncShadow(to: frame, animated: false)
        snapTask?.cancel()
        snapTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.snapToCorner()
        }
    }

    private func snapToCorner() {
        let newCorner = RecordingHUDPlacement.nearestCorner(
            to: frame.origin,
            size: frame.size,
            in: screenFrame
        )
        if newCorner != corner {
            corner = newCorner
            actions.onCornerChange(newCorner)
        }
        let origin = RecordingHUDPlacement.origin(for: corner, size: frame.size, in: screenFrame)
        guard origin != frame.origin else { return }
        isProgrammaticMove = true
        setFrameOrigin(origin)
        isProgrammaticMove = false
        syncShadow(to: frame, animated: false)
    }

    /// Applies one size to the window, keeping the panel in its corner.
    ///
    /// The window is never displayed synchronously here. `display: true` draws the
    /// new SwiftUI content (Liquid Glass, meters, implicit animations) inside the
    /// caller's main-actor turn; a status change that lands while the app is also
    /// presenting or dismissing other windows can then block the main thread, and
    /// the status change that asked for this frame never completes. Leaving the
    /// draw to the next display cycle keeps the frame change itself cheap while
    /// looking identical to the user.
    ///
    /// - Parameters:
    ///   - size: The size from the cache or the conservative fallback.
    ///   - animated: Whether a measured correction eases into place.
    ///   - force: Whether a sub-pixel change is still applied.
    private func setSize(_ size: CGSize, animated: Bool, force: Bool = false) {
        guard size != lastRequestedSize, size != frame.size else { return }
        let largestChange = max(abs(size.width - frame.width), abs(size.height - frame.height))
        // Sub-pixel measurement noise must not make the capsule twitch; only a real
        // structural change earns a new frame.
        guard force || largestChange >= RecordingHUDMetrics.minimumSizeChange else { return }
        if AgentMode.isActive { AgentHUDMetrics.noteResize(from: frame.size, to: size) }
        let origin = RecordingHUDPlacement.origin(for: corner, size: size, in: screenFrame)
        let rect = CGRect(origin: origin, size: size)
        lastRequestedSize = size
        isProgrammaticMove = true
        guard animated else {
            setFrame(rect, display: false)
            hostingView.needsDisplay = true
            isProgrammaticMove = false
            syncShadow(to: rect, animated: false)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = RecordingHUDMeasurementPolicy.correctionDuration
            context.allowsImplicitAnimation = true
            animator().setFrame(rect, display: false)
            shadowWindow?.follow(
                panelFrame: rect,
                cornerRadius: shadowCornerRadius(for: size),
                animated: true
            )
        } completionHandler: { [weak self] in
            self?.isProgrammaticMove = false
        }
    }

    /// The radius the capsule is actually drawn with for one panel size.
    private func shadowCornerRadius(for size: CGSize) -> CGFloat {
        if case .failure = model.state, model.failureExpanded {
            return RecordingHUDMetrics.tallCornerRadius
        }
        return size.height / 2
    }

    /// Keeps the companion shadow on the capsule the panel is showing.
    private func syncShadow(to panelRect: CGRect, animated: Bool) {
        shadowWindow?.follow(
            panelFrame: panelRect,
            cornerRadius: shadowCornerRadius(for: panelRect.size),
            animated: animated
        )
    }

    /// The layout signature of what the panel shows right now.
    private func currentSignature() -> RecordingHUDLayoutSignature {
        RecordingHUDLayoutSignature(
            state: model.state,
            failureExpanded: model.failureExpanded,
            language: AppLocalization.languageIdentifier
        )
    }

    /// The usable content area of the panel's screen.
    private var contentAvailableSize: CGSize {
        CGSize(
            width: max(1, screenFrame.width - 2 * RecordingHUDMetrics.screenMargin),
            height: max(1, screenFrame.height - 2 * RecordingHUDMetrics.screenMargin)
        )
    }

    /// The size shown until a signature is measured.
    ///
    /// An expanded error reuses the collapsed card's measured height when there is one,
    /// so expanding it never drops to a clipped single line first.
    private func fallbackSize(for signature: RecordingHUDLayoutSignature) -> CGSize {
        var size = RecordingHUDMeasurementPolicy.fallbackSize(
            for: signature,
            available: contentAvailableSize
        )
        guard case let .failure(true, canRetry, reason) = signature.content else { return size }
        let collapsed = RecordingHUDLayoutSignature(
            content: .failure(expanded: false, canRetry: canRetry, reason: reason),
            language: signature.language
        )
        if let measured = sizeCache.size(for: collapsed) { size.height = measured.height }
        return size
    }

    /// Queues at most one measurement for a later main-loop turn.
    ///
    /// The deferral is a real runloop turn, not `Task.yield()`: a yield can resume
    /// inside the same main-queue drain that is still presenting the status change,
    /// which is exactly the shared turn this separation exists to avoid. Only the
    /// state that is current when the turn runs is measured: a signature that went
    /// stale in the meantime is dropped, never measured and never applied.
    private func scheduleMeasurement() {
        guard !isMeasurementScheduled else { return }
        isMeasurementScheduled = true
        Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(16))
            } catch {
                self?.isMeasurementScheduled = false
                return
            }
            guard let self else { return }
            guard !Task.isCancelled else {
                // Never leave the flag set: a later correction pass would then be
                // dropped forever.
                self.isMeasurementScheduled = false
                return
            }
            self.flushMeasurement()
        }
    }

    /// Measures the current signature once, then adopts its size if it is still current.
    private func flushMeasurement() {
        isMeasurementScheduled = false
        let signature = currentSignature()
        guard sizeCache.size(for: signature) == nil else {
            adoptMeasuredSize(for: signature)
            return
        }
        measure(signature)
        adoptMeasuredSize(for: signature)
    }

    /// Applies a measured size to the live window, once, with the correction animation.
    ///
    /// Nothing is applied when the state moved on while the measurement was queued: the
    /// result stays cached for the next time that state appears.
    private func adoptMeasuredSize(for signature: RecordingHUDLayoutSignature) {
        guard signature == currentSignature(), let measured = sizeCache.size(for: signature) else {
            return
        }
        applyFailureScrollHeight(for: signature)
        setSize(measured, animated: true, force: true)
        logger.debug(
            "HUD corrected state=\(signature.logName, privacy: .public) signature=\(Self.signatureCode(signature), privacy: .public) width=\(Int(measured.width)) height=\(Int(measured.height))"
        )
    }

    /// Measures one signature twice: ideal width, then height at the clamped width.
    ///
    /// The passes use the static measure view, so no glass render, implicit animation,
    /// or geometry pass runs. A pass that already spent the fault budget stops there:
    /// the conservative fallback is cached and that signature is never measured again.
    private func measure(_ signature: RecordingHUDLayoutSignature) {
        let bounds = RecordingHUDMetrics.bounds(for: signature.panelKind)
        let available = contentAvailableSize
        let clock = ContinuousClock()
        let start = clock.now

        let ideal: CGSize
        if signature.isExpandedFailure {
            ideal = .zero
        } else {
            ideal = measureSize(signature, sizing: .ideal, failureScrollHeight: nil)
        }
        let elapsed = Self.milliseconds(from: start, to: clock.now)
        guard elapsed <= RecordingHUDMeasurementPolicy.faultThresholdMilliseconds else {
            recordMeasurementFault(for: signature, since: start, clock: clock)
            return
        }

        var width = bounds.clampedWidth(ideal.width, availableWidth: available.width)
        if signature.isExpandedFailure {
            // Reading a multi-line error is worth the full column, not a tall narrow strip.
            width = bounds.clampedWidth(bounds.maxWidth, availableWidth: available.width)
        }

        var wrapped = measureSize(signature, sizing: .fixedWidth(width), failureScrollHeight: nil)
        var scrollHeight: CGFloat?
        if signature.isExpandedFailure {
            let maximumHeight = min(bounds.maxHeight, available.height)
            if wrapped.height > maximumHeight {
                scrollHeight = max(48, maximumHeight - RecordingHUDMetrics.failureExpandedChromeHeight)
                wrapped = measureSize(
                    signature,
                    sizing: .fixedWidth(width),
                    failureScrollHeight: scrollHeight
                )
            }
        }

        let contentHeight = signature.isExpandedFailure ? wrapped.height : max(ideal.height, wrapped.height)
        let size = CGSize(
            width: width,
            height: bounds.clampedHeight(contentHeight, availableHeight: available.height)
        )
        let millis = Self.milliseconds(from: start, to: clock.now)
        guard millis <= RecordingHUDMeasurementPolicy.faultThresholdMilliseconds else {
            recordMeasurementFault(for: signature, since: start, clock: clock, size: size)
            return
        }

        sizeCache.store(size, for: signature)
        failureScrollHeights[signature] = scrollHeight
        logger.debug(
            "HUD measured state=\(signature.logName, privacy: .public) signature=\(Self.signatureCode(signature), privacy: .public) ms=\(millis) cached=\(self.sizeCache.count)"
        )
    }

    /// Records an over-budget measurement, keeps the fallback, and stops retrying.
    private func recordMeasurementFault(
        for signature: RecordingHUDLayoutSignature,
        since start: ContinuousClock.Instant,
        clock: ContinuousClock,
        size: CGSize? = nil
    ) {
        let millis = Self.milliseconds(from: start, to: clock.now)
        logger.fault(
            "HUD measurement over budget state=\(signature.logName, privacy: .public) signature=\(Self.signatureCode(signature), privacy: .public) ms=\(millis)"
        )
        let fallback = RecordingHUDMeasurementPolicy.fallbackSize(
            for: signature,
            available: contentAvailableSize
        )
        sizeCache.store(size ?? fallback, for: signature)
    }

    /// Runs one measurement pass of the static view.
    private func measureSize(
        _ signature: RecordingHUDLayoutSignature,
        sizing: RecordingControlPanelMeasureSizing,
        failureScrollHeight: CGFloat?
    ) -> CGSize {
        measurementController.rootView = RecordingControlPanelMeasureView(
            signature: signature,
            sizing: sizing,
            failureScrollHeight: failureScrollHeight
        )
        let proposal: CGSize
        switch sizing {
        case .ideal:
            proposal = CGSize(width: 10_000, height: 10_000)
        case let .fixedWidth(width):
            proposal = CGSize(width: width, height: 10_000)
        }
        if AgentMode.isActive { AgentHUDMetrics.noteSizeThatFits() }
        return measurementController.sizeThatFits(in: proposal)
    }

    /// Keeps the live card's scroll column equal to what was measured for the signature.
    private func applyFailureScrollHeight(for signature: RecordingHUDLayoutSignature) {
        guard case .failure = signature.content else { return }
        let height = failureScrollHeights[signature]
        guard model.failureScrollHeight != height else { return }
        model.failureScrollHeight = height
    }

    /// Whole milliseconds between two instants.
    private static func milliseconds(
        from start: ContinuousClock.Instant,
        to end: ContinuousClock.Instant
    ) -> Int {
        let duration = start.duration(to: end)
        let components = duration.components
        let seconds = max(0, components.seconds)
        let attoseconds = max(0, components.attoseconds)
        return Int(clamping: seconds * 1_000 + attoseconds / 1_000_000_000_000_000)
    }

    /// A short, privacy-safe code for one signature in logs.
    private static func signatureCode(_ signature: RecordingHUDLayoutSignature) -> String {
        String(UInt(bitPattern: signature.hashValue), radix: 16)
    }

    private static func failureReason(of state: RecordingControlPanelState) -> String? {
        if case let .failure(failure) = state { return failure.reason }
        return nil
    }
}

extension RecordingHUDLayoutSignature {
    /// Reduces one panel state to the inputs that change its size.
    ///
    /// - Parameters:
    ///   - state: The state about to be shown.
    ///   - failureExpanded: Whether a failure currently shows its full reason.
    ///   - language: The identifier of the language the text renders in.
    init(state: RecordingControlPanelState, failureExpanded: Bool, language: String) {
        let content: Content
        switch state {
        case let .preparing(kind, phase):
            content = .preparing(kind: kind, phase: phase)
        case .countdown:
            content = .countdown
        case let .starting(kind, phase):
            content = .starting(kind: kind, phase: phase)
        case .recording:
            content = .recording
        case let .saving(kind, fileName, isBeforeQuit):
            content = .saving(kind: kind, showsFileName: fileName != nil, isBeforeQuit: isBeforeQuit)
        case let .audioRecording(presentation, expanded, silenceWarning):
            content = .audioRecording(
                mode: presentation.mode,
                expanded: expanded,
                silenceWarning: silenceWarning
            )
        case let .audioFinalizing(_, previewReady, previewPlaying):
            content = .audioFinalizing(previewReady: previewReady, previewPlaying: previewPlaying)
        case let .audioFinished(savedSegments, _, previewReady, previewPlaying):
            content = .audioFinished(
                showsPreview: previewReady,
                previewPlaying: previewPlaying,
                offersRecordingsList: savedSegments > 1
            )
        case let .failure(failure):
            content = .failure(
                expanded: failureExpanded,
                canRetry: failure.canRetry,
                reason: failure.reason
            )
        case let .notice(text):
            content = .notice(text: text)
        }
        self.init(content: content, language: language)
    }
}
