import AppKit
import CaptureCore
import SharedKit
import SwiftUI

@MainActor
extension ScreenshotShelfManager {
    // MARK: - Presentation

    func refreshPresentation(immediate: Bool = false) {
        guard createsPanel else {
            panel?.orderOut(nil)
            phase = .hidden
            removeGlobalMonitor()
            cancelCollapseTasks()
            publishState()
            return
        }

        guard shouldPresentPanel,
              let screen = displayScreen ?? NSScreen.screens.first else {
            switch phase {
            case .visible, .appearing:
                hidePanel(immediate: immediate)
            case .hidden, .disappearing:
                break
            }
            publishState()
            return
        }

        synchronizeCards()
        let layout = makeLayout(for: screen)
        guard layout.panelFrame.width > 0, layout.panelFrame.height > 0 else {
            hidePanel(immediate: true)
            publishState()
            return
        }

        let modeChanged = layout.mode != viewModel.layout.mode
        if phase == .visible, modeChanged {
            crossfade(to: layout)
            scheduleCollapseIfNeeded()
            publishState()
            return
        }
        if phase == .appearing {
            pendingLayout = layout
            if !modeChanged {
                viewModel.layout = layout
            }
            publishState()
            return
        }

        updateViewModel(layout)
        switch phase {
        case .hidden:
            showPanel(layout: layout, immediate: immediate)
        case .visible:
            applyFrame(layout.panelFrame)
        case .disappearing:
            finishHideImmediately()
            showPanel(layout: layout, immediate: immediate)
        case .appearing:
            break
        }
        publishState()
    }

    func schedulePresentationUpdate() {
        guard !presentationUpdateScheduled else { return }
        presentationUpdateScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.presentationUpdateScheduled = false
            self.refreshPresentation()
        }
    }

    // MARK: - Collapse timer and pointer

    func handlePointerInside(_ inside: Bool) {
        if inside {
            cancelCollapseTask()
            modeState.pointerEntered(
                at: viewModel.pointerLocation,
                now: Date(),
                dwell: Self.dwellDelay
            )
            scheduleDwellIfNeeded()
            if phase == .visible, viewModel.layout.mode != modeState.mode {
                refreshPresentation()
            }
        } else {
            cancelDwellTask()
            if collapseToRail, phase == .visible {
                modeState.pointerExited(now: Date(), delay: Self.pointerExitCollapseDelay)
                scheduleCollapseIfNeeded()
            }
        }
    }

    /// Restarts the dwell from the new pointer position when it travels across the handle.
    ///
    /// A pointer that arrives and settles still opens the shelf; one that sweeps across leaves
    /// the window before the dwell can elapse.
    func handlePointerMoved(_ location: CGPoint) {
        guard modeState.dwellDeadline != nil else { return }
        if modeState.pointerMoved(to: location, now: Date(), dwell: Self.dwellDelay) {
            scheduleDwellIfNeeded()
        }
    }

    /// Expands the shelf only after the pointer has rested on the collapsed handle.
    ///
    /// The handle is small and sits over other apps' title bars, so expanding on mere entry
    /// would make it easy to interrupt a click on a browser tab. The dwell makes expansion
    /// deliberate while still allowing a quick click on the handle to open it immediately.
    func scheduleDwellIfNeeded() {
        guard collapseToRail,
              phase == .visible,
              modeState.mode == .collapsed,
              viewModel.isPointerInside,
              !isMenuTracking,
              !modeState.isSuppressed,
              !modeState.isInteractionHeld,
              let deadline = modeState.dwellDeadline else { return }

        let delay = max(0.01, deadline.timeIntervalSinceNow)
        dwellTask?.cancel()
        dwellTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.expandIfPointerDwelled()
        }
    }

    func expandIfPointerDwelled() {
        guard collapseToRail,
              phase == .visible,
              modeState.mode == .collapsed,
              viewModel.isPointerInside,
              !isMenuTracking,
              !modeState.isSuppressed,
              !modeState.isInteractionHeld else { return }
        guard modeState.expandIfDwellElapsed(now: Date()) else { return }
        refreshPresentation()
    }

    func cancelDwellTask() {
        dwellTask?.cancel()
        dwellTask = nil
        modeState.cancelDwell()
    }

    func scheduleCollapseIfNeeded() {
        guard collapseToRail,
              phase == .visible,
              modeState.mode == .expanded,
              !isMenuTracking,
              !modeState.isSuppressed,
              !viewModel.isPointerInside else { return }
        let delay: TimeInterval
        if let deadline = modeState.idleDeadline {
            delay = max(0.05, deadline.timeIntervalSinceNow)
        } else {
            modeState.pointerExited(now: Date(), delay: Self.pointerExitCollapseDelay)
            delay = Self.pointerExitCollapseDelay
        }
        collapseTask?.cancel()
        collapseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.collapseIfIdle()
        }
    }

    func collapseIfIdle() {
        guard collapseToRail,
              phase == .visible,
              modeState.mode == .expanded,
              !isMenuTracking,
              !viewModel.isPointerInside,
              !modeState.isSuppressed else { return }
        guard modeState.collapseIfIdle(now: Date()) else { return }
        refreshPresentation()
        scheduleArmExpansion()
    }

    func scheduleArmExpansion() {
        armExpansionTask?.cancel()
        armExpansionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.armExpansionDelay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.modeState.armExpansion()
            // A pointer that returned during the cooldown must rest for a fresh dwell before the
            // shelf opens; the cooldown never expands it by itself.
            guard self.viewModel.isPointerInside,
                  self.modeState.mode == .collapsed,
                  self.phase == .visible else { return }
            self.modeState.pointerEntered(
                at: self.viewModel.pointerLocation,
                now: Date(),
                dwell: Self.dwellDelay
            )
            self.scheduleDwellIfNeeded()
        }
    }

    func cancelCollapseTask() {
        collapseTask?.cancel()
        collapseTask = nil
    }

    func cancelCollapseTasks() {
        cancelCollapseTask()
        cancelDwellTask()
        armExpansionTask?.cancel()
        armExpansionTask = nil
    }

    func setMode(_ mode: ScreenshotShelfMode) {
        guard modeState.mode != mode else { return }
        switch mode {
        case .expanded:
            modeState.expand()
        case .collapsed:
            modeState.collapse()
        }
        cancelCollapseTask()
        cancelDwellTask()
        if mode == .collapsed {
            scheduleArmExpansion()
        }
        refreshPresentation()
    }

    func updateModeSuppression() {
        let suppressed = captureSuppressionCount > 0 || isRecordingActive || isFullScreenSuppressed
        modeState.setSuppressed(suppressed, now: Date(), delay: Self.interactionResumeDelay)
        if suppressed {
            cancelCollapseTask()
            cancelDwellTask()
        }
    }

    /// Updates the SwiftUI model atomically. Content changes on a visible shelf animate; the
    /// first appearance stays static so the window slide is the only entry motion.
    func updateViewModel(_ layout: ScreenshotShelfLayout) {
        let oldIDs = viewModel.layout.cards.map(\.id)
        let newIDs = layout.cards.map(\.id)
        if phase == .visible, layout.mode == .expanded, oldIDs != newIDs {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                viewModel.layout = layout
            }
        } else {
            viewModel.layout = layout
        }
    }

    /// Crossfades a visible shelf to a new layout while the panel is transparent.
    ///
    /// AppKit window-frame animation and SwiftUI layout animation must never run together: the
    /// cards would be clipped by the shrinking window. Fading out first lets the frame and the
    /// model change atomically, then fades the new layout back in.
    func crossfade(to layout: ScreenshotShelfLayout) {
        guard phase == .visible, let panel else {
            updateViewModel(layout)
            applyFrame(layout.panelFrame)
            return
        }
        dragOverlayController.cancel()
        presentationGeneration &+= 1
        let generation = presentationGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.10
            panel.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor [weak self, weak panel] in
                guard let self, let panel,
                      self.phase == .visible,
                      generation == self.presentationGeneration else { return }
                panel.setFrame(layout.panelFrame, display: true)
                panel.assertSharingType()
                self.viewModel.layout = layout
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.12
                    panel.animator().alphaValue = 1
                }
            }
        }
    }

    func makeLayout(for screen: NSScreen) -> ScreenshotShelfLayout {
        let metrics = ScreenshotShelfMetrics()
        let naturalWidths = cards.map { card -> CGFloat in
            guard card.imagePixelSize.width > 0, card.imagePixelSize.height > 0 else {
                return cardHeight * 4 / 3
            }
            return cardHeight * card.imagePixelSize.width / card.imagePixelSize.height
        }
        let visible = ScreenshotShelfGeometry.effectiveVisibleFrame(
            visibleFrame: screen.visibleFrame,
            screenFrame: screen.frame
        )
        let fitted = ScreenshotShelfGeometry.fittedCardWidths(
            naturalWidths: naturalWidths,
            availableWidth: visible.width,
            metrics: metrics
        )
        let expandedFrame = ScreenshotShelfGeometry.panelFrame(
            visibleFrame: visible,
            cardWidths: fitted,
            cardHeight: cardHeight,
            anchor: anchor,
            metrics: metrics
        )
        let frame = modeState.mode == .collapsed
            ? ScreenshotShelfGeometry.collapsedFrame(expandedFrame: expandedFrame)
            : expandedFrame
        return ScreenshotShelfLayout(
            cards: cards,
            cardWidths: fitted,
            panelFrame: frame,
            cardHeight: cardHeight,
            imageOpacity: imageOpacity,
            locale: AppLocalization.locale(in: defaults),
            metrics: metrics,
            anchor: anchor,
            mode: modeState.mode
        )
    }

    func showPanel(layout: ScreenshotShelfLayout, immediate: Bool) {
        let panel = self.panel ?? ScreenshotShelfPanel(contentRect: layout.panelFrame, model: viewModel)
        self.panel = panel
        attachControllers(to: panel)
        panel.assertSharingType()
        dragOverlayController.cancel()
        dragOverlayController.prewarm()

        if immediate {
            presentationGeneration &+= 1
            panel.alphaValue = 1
            panel.setFrame(layout.panelFrame, display: true)
            panel.orderFrontRegardless()
            panel.assertSharingType()
            panel.prepareForDisplay()
            phase = .visible
            installClickDismissMonitorIfNeeded()
            scheduleCollapseIfNeeded()
            if modeState.mode == .collapsed {
                scheduleArmExpansion()
            }
            return
        }

        presentationGeneration &+= 1
        let generation = presentationGeneration
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let startFrame = reduceMotion ? layout.panelFrame : offscreenFrame(for: layout.panelFrame)
        panel.alphaValue = 0.01
        panel.setFrame(startFrame, display: false)
        panel.orderFrontRegardless()
        panel.assertSharingType()
        panel.prepareForDisplay()
        phase = .appearing
        installClickDismissMonitorIfNeeded()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.14 : 0.30
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            if !reduceMotion {
                panel.animator().setFrameOrigin(layout.panelFrame.origin)
            }
            panel.animator().alphaValue = 1
        } completionHandler: {
            Task { @MainActor [weak self, weak panel] in
                guard let self, let panel,
                      generation == self.presentationGeneration else { return }
                self.phase = .visible
                panel.alphaValue = 1
                panel.assertSharingType()
                if self.modeState.mode == .collapsed {
                    self.scheduleArmExpansion()
                }
                if let pending = self.pendingLayout {
                    self.pendingLayout = nil
                    if pending.mode != self.viewModel.layout.mode {
                        self.crossfade(to: pending)
                    } else {
                        self.applyFrame(pending.panelFrame)
                        self.viewModel.layout = pending
                    }
                }
                self.scheduleCollapseIfNeeded()
                if self.modeState.mode == .collapsed {
                    self.scheduleDwellIfNeeded()
                }
                self.publishState()
            }
        }
    }

    func hidePanel(immediate: Bool) {
        cancelCollapseTasks()
        modeState.cancelInteraction()
        keyboardController.exit()
        dragOverlayController.cancel()
        guard let panel else {
            phase = .hidden
            resetPointerState()
            removeGlobalMonitor()
            return
        }
        if !immediate, phase == .disappearing { return }

        presentationGeneration &+= 1
        let generation = presentationGeneration
        removeGlobalMonitor()
        NSCursor.arrow.set()

        if immediate {
            panel.orderOut(nil)
            panel.alphaValue = 1
            phase = .hidden
            pendingLayout = nil
            resetPointerState()
            return
        }

        phase = .disappearing
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let endFrame = offscreenFrame(for: panel.frame)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.12 : 0.20
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            if !reduceMotion {
                panel.animator().setFrameOrigin(endFrame.origin)
            }
            panel.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor [weak self, weak panel] in
                guard let self, let panel,
                      generation == self.presentationGeneration else { return }
                panel.orderOut(nil)
                panel.alphaValue = 1
                self.phase = .hidden
                self.pendingLayout = nil
                self.resetPointerState()
                self.publishState()
            }
        }
    }

    func finishHideImmediately() {
        presentationGeneration &+= 1
        cancelCollapseTasks()
        modeState.cancelInteraction()
        keyboardController.exit()
        dragOverlayController.cancel()
        panel?.orderOut(nil)
        panel?.alphaValue = 1
        phase = .hidden
        pendingLayout = nil
        resetPointerState()
        removeGlobalMonitor()
        NSCursor.arrow.set()
    }

    func resetPointerState() {
        viewModel.setPointerInside(false)
        viewModel.setPointerLocation(nil)
    }

    func applyFrame(_ frame: CGRect) {
        guard let panel, phase == .visible, panel.frame != frame else { return }
        if panel.frame.size != frame.size {
            panel.setFrame(frame, display: true)
        } else if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrame(frame, display: true)
        } else {
            panel.setFrame(frame, display: true, animate: true)
        }
        panel.assertSharingType()
    }

    func offscreenFrame(for frame: CGRect) -> CGRect {
        let offset = frame.height + 12
        return frame.offsetBy(dx: 0, dy: offset)
    }

    func installClickDismissMonitorIfNeeded() {
        guard !collapseToRail,
              globalMouseMonitor == nil,
              phase == .visible || phase == .appearing else { return }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.hide()
            }
        }
    }

    func removeGlobalMonitor() {
        guard let monitor = globalMouseMonitor else { return }
        NSEvent.removeMonitor(monitor)
        globalMouseMonitor = nil
    }

    func prewarm() {
        guard createsPanel, isEnabled, panel == nil,
              let screen = displayScreen ?? NSScreen.main else { return }

        let metrics = ScreenshotShelfMetrics()
        let frame = CGRect(
            x: screen.visibleFrame.maxX + 80,
            y: screen.visibleFrame.maxY + 80,
            width: 240,
            height: metrics.panelHeight(cardHeight: cardHeight)
        )
        viewModel.layout = ScreenshotShelfLayout(
            cards: [],
            cardWidths: [],
            panelFrame: frame,
            cardHeight: cardHeight,
            imageOpacity: imageOpacity,
            locale: AppLocalization.locale(in: defaults),
            metrics: metrics,
            anchor: anchor,
            mode: .expanded
        )
        let warmPanel = ScreenshotShelfPanel(contentRect: frame, model: viewModel)
        panel = warmPanel
        attachControllers(to: warmPanel)
        dragOverlayController.prewarm()
        warmPanel.orderFrontRegardless()
        warmPanel.assertSharingType()
        warmPanel.prepareForDisplay()
        warmPanel.orderOut(nil)
    }

    func schedulePrewarm() {
        guard createsPanel else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self?.prewarm()
        }
    }

}
