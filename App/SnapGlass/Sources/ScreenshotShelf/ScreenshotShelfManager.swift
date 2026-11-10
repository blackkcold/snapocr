import AppKit
import CaptureCore
import HistoryCore
import QuartzCore
import SharedKit
import SwiftUI

@MainActor
final class ScreenshotShelfManager {
    private static let maximumThumbnailBytes = 16 * 1_024 * 1_024
    private static let maximumPendingAssetWrites = 2
    private static let collapseDelay: TimeInterval = 2.8
    private static let armExpansionDelay: TimeInterval = 0.6

    private let sessionStore: ScreenshotShelfSessionStore?
    private let defaults: UserDefaults
    private let createsPanel: Bool
    private let viewModel = ScreenshotShelfViewModel()
    var state: ScreenshotShelfState
    private var presentationState = ScreenshotShelfPresentationState()
    var cardsByID: [UUID: ScreenshotShelfCard] = [:]
    private var cachedThumbnailBytes = 0
    private var nextCompletionSequence: UInt64 = 0
    private var pendingAssetWrites = 0
    private var assetWorkTail: Task<Void, Never>?
    private var notificationObservers: [NSObjectProtocol] = []
    private var panel: ScreenshotShelfPanel?
    private lazy var dragOverlayController = ScreenshotShelfDragOverlayController(
        viewModel: viewModel,
        panel: { [weak self] in self?.panel },
        isShelfVisible: { [weak self] in self?.phase == .visible || self?.phase == .appearing }
    )
    let dragExportStore: ScreenshotShelfDragExportStore
    private lazy var dragOutController = ScreenshotShelfDragOutController(
        model: viewModel,
        exportStore: dragExportStore,
        dataProvider: { [weak self] captureID in
            try await self?.originalData(for: captureID)
        }
    )
    private var phase: ScreenshotShelfPhase = .hidden
    private var presentationGeneration: UInt64 = 0
    private var pendingLayout: ScreenshotShelfLayout?
    private var presentationUpdateScheduled = false
    private var globalMouseMonitor: Any?
    private var modeState = ScreenshotShelfModeState()
    private var collapseTask: Task<Void, Never>?
    private var armExpansionTask: Task<Void, Never>?
    private var isMenuTracking = false
    private var preferredDisplayID: CGDirectDisplayID?
    private var isEnabled: Bool
    private var cardHeight: CGFloat
    private var imageOpacity: Double
    private var anchor: ScreenshotShelfAnchor
    private var collapseToRail: Bool
    private var captureSuppressionCount = 0
    private var isRecordingActive = false
    private var isFullScreenSuppressed = false

    var onEdit: ((UUID) -> Void)?
    var onCopy: ((UUID) -> Void)?
    var onPin: ((UUID) -> Void)?
    var onStateChange: ((Bool, Bool, Bool, Bool) -> Void)?
    var onCacheFailure: ((String) -> Void)?

    private(set) var cards: [ScreenshotShelfCard] = []

    var orderedCaptureIDs: [UUID] { state.entries.map(\.captureID) }
    var historyIDsByCaptureID: [UUID: UUID] {
        Dictionary(uniqueKeysWithValues: state.entries.compactMap { entry in
            entry.historyID.map { (entry.captureID, $0) }
        })
    }
    var hasItems: Bool { !state.entries.isEmpty }
    var canToggle: Bool { isEnabled && hasItems && !isRecordingActive }
    var isVisible: Bool { phase == .visible || phase == .appearing }
    var shouldPresentPanel: Bool {
        isEnabled && hasItems && !isRecordingActive && presentationState.shouldPresentPanel
    }
    var displayScreen: NSScreen? {
        ScreenshotShelfScreenResolver.screen(for: preferredDisplayID)
            ?? ScreenshotShelfScreenResolver.screen(underMouse: NSEvent.mouseLocation)
    }

    convenience init(defaults: UserDefaults = .standard) {
        self.init(
            defaults: defaults,
            sessionStore: try? ScreenshotShelfSessionStore(),
            observesSystemEvents: true,
            createsPanel: true
        )
    }

    init(
        defaults: UserDefaults,
        sessionStore: ScreenshotShelfSessionStore?,
        observesSystemEvents: Bool,
        createsPanel: Bool,
        dragExportStore: ScreenshotShelfDragExportStore? = nil
    ) {
        self.defaults = defaults
        self.sessionStore = sessionStore
        self.createsPanel = createsPanel
        self.dragExportStore = dragExportStore ?? ScreenshotShelfDragExportStore()
        state = ScreenshotShelfState(limit: ScreenshotShelfPreferences.count(in: defaults))
        isEnabled = ScreenshotShelfPreferences.isEnabled(in: defaults)
        cardHeight = CGFloat(ScreenshotShelfPreferences.cardHeight(in: defaults))
        imageOpacity = ScreenshotShelfPreferences.imageOpacity(in: defaults)
        anchor = ScreenshotShelfPreferences.anchor(in: defaults)
        collapseToRail = ScreenshotShelfPreferences.collapseToRail(in: defaults)
        viewModel.delegate = self
        viewModel.onPointerInsideChanged = { [weak self] inside in
            self?.handlePointerInside(inside)
        }
        if observesSystemEvents {
            installObservers()
            refreshFullScreenSuppression()
            self.dragExportStore.sweepStale()
            schedulePrewarm()
        }
        refreshPresentation(immediate: true)
    }

    func publishCurrentState() {
        publishState()
    }

    @discardableResult
    func captureCompleted(
        _ image: CGImage,
        sourceDisplayID: CGDirectDisplayID? = nil,
        displayScale: CGFloat? = nil
    ) -> UUID? {
        refreshPreferences()
        guard isEnabled else { return nil }

        if modeState.mode == .collapsed {
            modeState.expand()
            cancelCollapseTasks()
        }

        nextCompletionSequence &+= 1
        let captureID = UUID()
        let evictedIDs = state.insert(
            captureID: captureID,
            completionSequence: nextCompletionSequence
        )
        removeCards(for: evictedIDs)
        scheduleAssetRemoval(for: evictedIDs)
        cardsByID[captureID] = ScreenshotShelfCard(
            captureID: captureID,
            historyID: nil,
            imagePixelSize: CGSize(width: image.width, height: image.height),
            displayScale: displayScale ?? 1,
            scaleSourcePixelWidth: displayScale == nil ? nil : CGFloat(image.width),
            thumbnailData: nil,
            decodedThumbnail: nil,
            errorMessage: nil,
            feedbackMessage: nil
        )
        presentationState.captureCompleted()
        preferredDisplayID = sourceDisplayID
        synchronizeCards()
        refreshPresentation()
        enqueuePreview(image, captureID: captureID)
        enqueueAssetWrite(image, captureID: captureID)
        return captureID
    }

    func toggle() {
        guard canToggle else { return }
        switch phase {
        case .visible, .appearing:
            hide()
        case .hidden, .disappearing:
            show()
        }
    }

    func show() {
        refreshPreferences()
        guard isEnabled, hasItems, !isRecordingActive else { return }
        cancelCollapseTasks()
        modeState.expand()
        presentationState.show()
        refreshPresentation()
    }

    func hide() {
        cancelCollapseTasks()
        presentationState.hide()
        refreshPresentation()
    }

    func beginCaptureSuppression() {
        captureSuppressionCount += 1
        guard captureSuppressionCount == 1 else {
            updateModeSuppression()
            return
        }
        presentationState.beginSuppression(.capture)
        updateModeSuppression()
        refreshPresentation(immediate: true)
    }

    func endCaptureSuppression() {
        guard captureSuppressionCount > 0 else { return }
        captureSuppressionCount -= 1
        guard captureSuppressionCount == 0 else {
            updateModeSuppression()
            return
        }
        presentationState.endSuppression(.capture)
        updateModeSuppression()
        refreshPresentation()
        scheduleCollapseIfNeeded()
    }

    func setRecordingActive(_ active: Bool) {
        guard isRecordingActive != active else { return }
        isRecordingActive = active
        if active {
            presentationState.beginSuppression(.recording)
        } else {
            presentationState.endSuppression(.recording)
        }
        updateModeSuppression()
        refreshPresentation(immediate: active)
        if !active { scheduleCollapseIfNeeded() }
    }

    func remove(captureID: UUID) {
        guard state.entries.contains(where: { $0.captureID == captureID }) else { return }
        state.remove(captureID: captureID)
        removeCards(for: [captureID])
        scheduleAssetRemoval(for: [captureID])
        synchronizeCards()
        schedulePresentationUpdate()
    }

    func clear() {
        let captureIDs = state.clear()
        removeCards(for: captureIDs)
        synchronizeCards()
        enqueueAssetClear()
        dragExportStore.removeAll()
        schedulePresentationUpdate()
    }

    func linkHistory(captureID: UUID, historyID: UUID) {
        guard state.entries.contains(where: { $0.captureID == captureID }) else { return }
        state.linkHistory(captureID: captureID, historyID: historyID)
        if var card = cardsByID[captureID] {
            card.historyID = historyID
            cardsByID[captureID] = card
        }
        // The session original is removed next, so the plaintext copy must go too;
        // it is rebuilt from the history bytes once the card refresh completes.
        dragExportStore.invalidate(captureID: captureID)
        scheduleAssetRemoval(for: [captureID])
        synchronizeCards()
        schedulePresentationUpdate()
        Task { @MainActor [weak self] in
            await self?.refreshHistoryCard(captureID: captureID, historyID: historyID)
        }
    }

    func historyID(for captureID: UUID) -> UUID? {
        state.entries.first(where: { $0.captureID == captureID })?.historyID
    }

    func card(for captureID: UUID) -> ScreenshotShelfCard? {
        cardsByID[captureID]
    }

    static func displayScaleForPinning(
        displayScale: CGFloat,
        scaleSourcePixelWidth: CGFloat?,
        imagePixelWidth: CGFloat
    ) -> CGFloat {
        guard displayScale.isFinite, displayScale > 0,
              imagePixelWidth.isFinite, imagePixelWidth > 0,
              let scaleSourcePixelWidth,
              scaleSourcePixelWidth == imagePixelWidth else {
            return 1
        }
        return displayScale
    }

    func originalData(for captureID: UUID) async throws -> Data? {
        guard let entry = state.entries.first(where: { $0.captureID == captureID }) else { return nil }
        if let historyID = entry.historyID {
            guard let history = HistoryActor.shared else {
                throw ScreenshotShelfAssetError.historyUnavailable
            }
            return try await history.imageData(for: historyID)
        }
        guard let sessionStore else {
            throw ScreenshotShelfAssetError.sessionStorageUnavailable
        }
        return try await sessionStore.originalData(for: captureID)
    }

    func reportFeedback(captureID: UUID, message: ScreenshotShelfMessage, isError: Bool = false) {
        guard var card = cardsByID[captureID] else { return }
        card.feedbackMessage = message
        if isError { card.errorMessage = message }
        cardsByID[captureID] = card
        synchronizeCards()
        schedulePresentationUpdate()
    }

    // MARK: - Presentation

    private func refreshPresentation(immediate: Bool = false) {
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

    private func handlePointerInside(_ inside: Bool) {
        if inside {
            cancelCollapseTask()
            modeState.pointerEntered()
            if phase == .visible, viewModel.layout.mode != modeState.mode {
                refreshPresentation()
            }
        } else if collapseToRail, phase == .visible {
            modeState.pointerExited(now: Date(), delay: Self.collapseDelay)
            scheduleCollapseIfNeeded()
        }
    }

    private func scheduleCollapseIfNeeded() {
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
            modeState.pointerExited(now: Date(), delay: Self.collapseDelay)
            delay = Self.collapseDelay
        }
        collapseTask?.cancel()
        collapseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.collapseIfIdle()
        }
    }

    private func collapseIfIdle() {
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

    private func scheduleArmExpansion() {
        armExpansionTask?.cancel()
        armExpansionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.armExpansionDelay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.modeState.armExpansion()
            if self.viewModel.isPointerInside,
               self.modeState.mode == .collapsed,
               self.phase == .visible {
                self.modeState.expand()
                self.refreshPresentation()
            }
        }
    }

    private func cancelCollapseTask() {
        collapseTask?.cancel()
        collapseTask = nil
    }

    private func cancelCollapseTasks() {
        cancelCollapseTask()
        armExpansionTask?.cancel()
        armExpansionTask = nil
    }

    private func setMode(_ mode: ScreenshotShelfMode) {
        guard modeState.mode != mode else { return }
        switch mode {
        case .expanded:
            modeState.expand()
        case .collapsed:
            modeState.collapse()
        }
        cancelCollapseTask()
        if mode == .collapsed {
            scheduleArmExpansion()
        }
        refreshPresentation()
    }

    private func updateModeSuppression() {
        let suppressed = captureSuppressionCount > 0 || isRecordingActive || isFullScreenSuppressed
        modeState.setSuppressed(suppressed, now: Date(), delay: Self.collapseDelay)
        if suppressed {
            cancelCollapseTask()
        }
    }

    /// Updates the SwiftUI model atomically. Content changes on a visible shelf animate; the
    /// first appearance stays static so the window slide is the only entry motion.
    private func updateViewModel(_ layout: ScreenshotShelfLayout) {
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
    private func crossfade(to layout: ScreenshotShelfLayout) {
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

    private func makeLayout(for screen: NSScreen) -> ScreenshotShelfLayout {
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

    private func showPanel(layout: ScreenshotShelfLayout, immediate: Bool) {
        let panel = self.panel ?? ScreenshotShelfPanel(contentRect: layout.panelFrame, model: viewModel)
        self.panel = panel
        attachDragOutController(to: panel)
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
                self.publishState()
            }
        }
    }

    private func hidePanel(immediate: Bool) {
        cancelCollapseTasks()
        modeState.cancelInteraction()
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

    private func finishHideImmediately() {
        presentationGeneration &+= 1
        cancelCollapseTasks()
        modeState.cancelInteraction()
        dragOverlayController.cancel()
        panel?.orderOut(nil)
        panel?.alphaValue = 1
        phase = .hidden
        pendingLayout = nil
        resetPointerState()
        removeGlobalMonitor()
        NSCursor.arrow.set()
    }

    private func resetPointerState() {
        viewModel.setPointerInside(false)
        viewModel.setPointerLocation(nil)
    }

    private func applyFrame(_ frame: CGRect) {
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

    private func offscreenFrame(for frame: CGRect) -> CGRect {
        let offset = frame.height + 12
        let dy = anchor.isTop ? offset : -offset
        return frame.offsetBy(dx: 0, dy: dy)
    }

    private func installClickDismissMonitorIfNeeded() {
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

    private func removeGlobalMonitor() {
        guard let monitor = globalMouseMonitor else { return }
        NSEvent.removeMonitor(monitor)
        globalMouseMonitor = nil
    }

    private func prewarm() {
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
        attachDragOutController(to: warmPanel)
        dragOverlayController.prewarm()
        warmPanel.orderFrontRegardless()
        warmPanel.assertSharingType()
        warmPanel.prepareForDisplay()
        warmPanel.orderOut(nil)
    }

    private func schedulePrewarm() {
        guard createsPanel else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self?.prewarm()
        }
    }

    // MARK: - Observers and preferences

    private func installObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        notificationObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshFullScreenSuppression() }
        })
        notificationObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshFullScreenSuppression() }
        })
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.finishHideImmediately()
                self?.refreshPresentation(immediate: true)
            }
        })
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshPreferences() }
        })
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: HistoryActor.imagesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.reconcileHistory() }
        })
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isMenuTracking = true
                self?.cancelCollapseTask()
            }
        })
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isMenuTracking = false
                self?.scheduleCollapseIfNeeded()
            }
        })

        let distributedCenter = DistributedNotificationCenter.default()
        notificationObservers.append(distributedCenter.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.setScreenLocked(true) }
        })
        notificationObservers.append(distributedCenter.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.setScreenLocked(false) }
        })
    }

    private func setScreenLocked(_ isLocked: Bool) {
        if isLocked {
            modeState.reset()
            presentationState.setScreenLocked(true)
            cancelCollapseTasks()
            finishHideImmediately()
            removeGlobalMonitor()
            publishState()
        } else {
            presentationState.setScreenLocked(false)
        }
    }

    private func refreshPreferences() {
        let enabled = ScreenshotShelfPreferences.isEnabled(in: defaults)
        if isEnabled && !enabled { presentationState.hide() }
        isEnabled = enabled
        cardHeight = CGFloat(ScreenshotShelfPreferences.cardHeight(in: defaults))
        imageOpacity = ScreenshotShelfPreferences.imageOpacity(in: defaults)
        let newAnchor = ScreenshotShelfPreferences.anchor(in: defaults)
        let anchorChanged = newAnchor != anchor
        anchor = newAnchor
        let newCollapseToRail = ScreenshotShelfPreferences.collapseToRail(in: defaults)
        let collapseChanged = newCollapseToRail != collapseToRail
        collapseToRail = newCollapseToRail
        if collapseToRail {
            removeGlobalMonitor()
        } else if collapseChanged, modeState.mode == .collapsed {
            modeState.expand()
            cancelCollapseTask()
        }
        let evictedIDs = state.setLimit(ScreenshotShelfPreferences.count(in: defaults))
        removeCards(for: evictedIDs)
        scheduleAssetRemoval(for: evictedIDs)
        synchronizeCards()
        if phase == .visible, (anchorChanged || collapseChanged) {
            if let screen = displayScreen ?? NSScreen.screens.first {
                let layout = makeLayout(for: screen)
                if layout.panelFrame.width > 0 {
                    if let panel, layout.panelFrame == panel.frame {
                        updateViewModel(layout)
                    } else {
                        crossfade(to: layout)
                    }
                }
            }
            installClickDismissMonitorIfNeeded()
        } else {
            schedulePresentationUpdate()
        }
        if collapseToRail {
            scheduleCollapseIfNeeded()
        }
    }

    private func refreshFullScreenSuppression() {
        let targetDisplayID = (displayScreen ?? NSScreen.main)
            .flatMap(ScreenshotShelfScreenResolver.displayID(for:))
        let isCovered = ScreenshotShelfScreenResolver.frontmostAppCoversDisplay(
            targetDisplayID: targetDisplayID
        )
        guard isCovered != isFullScreenSuppressed else { return }
        isFullScreenSuppressed = isCovered
        if isCovered {
            presentationState.beginSuppression(.fullScreen)
        } else {
            presentationState.endSuppression(.fullScreen)
        }
        updateModeSuppression()
        refreshPresentation(immediate: isCovered)
        if !isCovered {
            scheduleCollapseIfNeeded()
        }
    }

    // MARK: - Assets

    private func enqueuePreview(_ image: CGImage, captureID: UUID) {
        Task { @MainActor [weak self] in
            let preview = await Task.detached(priority: .userInitiated) {
                ScreenshotShelfAssetEncoder.previewImage(from: image)
            }.value
            guard let self, let preview,
                  self.state.entries.contains(where: { $0.captureID == captureID }),
                  var card = self.cardsByID[captureID],
                  card.decodedThumbnail == nil else { return }
            card.decodedThumbnail = preview
            self.cardsByID[captureID] = card
            self.synchronizeCards()
            self.schedulePresentationUpdate()
        }
    }

    private func enqueueAssetWrite(_ image: CGImage, captureID: UUID) {
        guard sessionStore != nil else {
            cacheFailed(captureID: captureID)
            return
        }
        guard pendingAssetWrites < Self.maximumPendingAssetWrites else {
            cacheFailed(captureID: captureID)
            return
        }
        pendingAssetWrites += 1
        let previous = assetWorkTail
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await self?.storeAssets(image, captureID: captureID)
        }
        assetWorkTail = task
    }

    private func storeAssets(_ image: CGImage, captureID: UUID) async {
        defer { pendingAssetWrites -= 1 }
        guard state.entries.contains(where: { $0.captureID == captureID }),
              let sessionStore else { return }
        let assets = await Task.detached(priority: .utility) {
            ScreenshotShelfAssetEncoder.encode(image)
        }.value
        guard state.entries.contains(where: { $0.captureID == captureID }) else { return }
        guard let assets else {
            cacheFailed(captureID: captureID)
            return
        }

        // Reuse the encoded PNG the session store is about to seal: dragging a
        // card out needs a plaintext file, and this is the only place the bytes
        // already exist without a second encode.
        await dragExportStore.prepare(
            captureID: captureID,
            data: assets.originalData,
            sourceTypeIdentifier: "public.png"
        )

        do {
            let evictedIDs = try await sessionStore.store(
                originalData: assets.originalData,
                thumbnailData: assets.thumbnailData,
                captureID: captureID
            )
            for evictedID in evictedIDs { state.remove(captureID: evictedID) }
            removeCards(for: evictedIDs)
            if state.entries.contains(where: { $0.captureID == captureID }) {
                await setThumbnail(assets.thumbnailData, for: captureID)
            } else {
                try? await sessionStore.remove(captureID: captureID)
            }
            synchronizeCards()
            schedulePresentationUpdate()
        } catch {
            cacheFailed(captureID: captureID)
        }
    }

    private func cacheFailed(captureID: UUID) {
        let message = ScreenshotShelfMessage.localizedKey("Screenshot preview unavailable")
        guard var card = cardsByID[captureID] else { return }
        card.errorMessage = message
        cardsByID[captureID] = card
        synchronizeCards()
        onCacheFailure?(message.resolved(using: { AppLocalization.string($0) }))
        schedulePresentationUpdate()
    }

    func setThumbnail(_ data: Data, for captureID: UUID) async {
        guard data.count <= Self.maximumThumbnailBytes,
              cardsByID[captureID] != nil else {
            cacheFailed(captureID: captureID)
            return
        }
        let decoded = await Task.detached(priority: .utility) {
            ScreenshotShelfAssetEncoder.decodeThumbnail(from: data)
        }.value
        guard let decoded else {
            cacheFailed(captureID: captureID)
            return
        }
        applyThumbnail(data, decoded: decoded, for: captureID)
    }

    private func applyThumbnail(_ data: Data, decoded: CGImage, for captureID: UUID) {
        guard var card = cardsByID[captureID] else { return }
        let oldCount = card.thumbnailData?.count ?? 0
        cachedThumbnailBytes = max(0, cachedThumbnailBytes - oldCount)
        card.thumbnailData = nil
        card.decodedThumbnail = nil
        cardsByID[captureID] = card

        for entry in state.entries.reversed() where cachedThumbnailBytes + data.count > Self.maximumThumbnailBytes {
            guard entry.captureID != captureID,
                  var otherCard = cardsByID[entry.captureID],
                  let oldThumbnail = otherCard.thumbnailData else { continue }
            cachedThumbnailBytes = max(0, cachedThumbnailBytes - oldThumbnail.count)
            otherCard.thumbnailData = nil
            otherCard.decodedThumbnail = nil
            otherCard.errorMessage = .localizedKey("Screenshot preview unavailable")
            cardsByID[entry.captureID] = otherCard
        }

        guard var updatedCard = cardsByID[captureID] else { return }
        updatedCard.thumbnailData = data
        updatedCard.decodedThumbnail = decoded
        updatedCard.errorMessage = nil
        cardsByID[captureID] = updatedCard
        cachedThumbnailBytes += data.count
        synchronizeCards()
        schedulePresentationUpdate()
    }

    func removeCards(for captureIDs: [UUID]) {
        for captureID in captureIDs {
            dragExportStore.invalidate(captureID: captureID)
            if let card = cardsByID.removeValue(forKey: captureID) {
                cachedThumbnailBytes = max(0, cachedThumbnailBytes - (card.thumbnailData?.count ?? 0))
            }
        }
    }

    func synchronizeCards() {
        cards = state.entries.compactMap { cardsByID[$0.captureID] }
    }

    private func attachDragOutController(to panel: ScreenshotShelfPanel) {
        dragOutController.attach(panel: panel)
        panel.dragOutController = dragOutController
    }

    /// Rebuilds the plaintext copy from the card's current bytes.
    func scheduleAssetRemoval(for captureIDs: [UUID]) {
        guard !captureIDs.isEmpty, let sessionStore else { return }
        let previous = assetWorkTail
        let task = Task { @MainActor in
            await previous?.value
            for captureID in captureIDs {
                try? await sessionStore.remove(captureID: captureID)
            }
        }
        assetWorkTail = task
    }

    private func enqueueAssetClear() {
        guard let sessionStore else { return }
        let previous = assetWorkTail
        let task = Task { @MainActor in
            await previous?.value
            try? await sessionStore.clear()
        }
        assetWorkTail = task
    }

    // MARK: - Actions

    private func handle(_ action: ScreenshotShelfAction) {
        switch action {
        case .edit(let captureID):
            onEdit?(captureID)
            hide()
        case .copy(let captureID):
            onCopy?(captureID)
        case .pin(let captureID):
            onPin?(captureID)
        case .remove(let captureID):
            remove(captureID: captureID)
        case .clear:
            clear()
        case .hide:
            hide()
        case .expand:
            setMode(.expanded)
        case .beginInteraction:
            modeState.beginInteraction()
            cancelCollapseTask()
        case .endInteraction:
            modeState.endInteraction(now: Date(), delay: Self.collapseDelay)
            scheduleCollapseIfNeeded()
        case .move(let captureID, let destination):
            state.move(captureID: captureID, to: destination)
            synchronizeCards()
            refreshPresentation()
        }
    }

    private func publishState() {
        onStateChange?(isVisible, hasItems, isEnabled, canToggle)
    }
}

extension ScreenshotShelfManager: ScreenshotShelfViewModelDelegate {
    func screenshotShelfViewModel(_ model: ScreenshotShelfViewModel, perform action: ScreenshotShelfAction) {
        handle(action)
    }
}
