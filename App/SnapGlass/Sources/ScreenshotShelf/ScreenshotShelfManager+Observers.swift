import AppKit
import CaptureCore
import HistoryCore
import SharedKit

@MainActor
extension ScreenshotShelfManager {
    // MARK: - Observers and preferences

    func installObservers() {
        installWorkspaceObservers()
        installAppObservers()
        installLockStateObservers()
    }

    private func installWorkspaceObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        notificationObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                // A Space switch changes the context under a parked pointer; do not let a
                // pending dwell pop the shelf open on the new Space.
                self?.cancelDwellTask()
                self?.refreshFullScreenSuppression()
            }
        })
        notificationObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cancelDwellTask()
                self?.refreshFullScreenSuppression()
            }
        })
    }

    private func installAppObservers() {
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let activeDisplayID = self.activeDisplayID,
                   ScreenshotShelfScreenResolver.screen(for: activeDisplayID) == nil {
                    self.activeDisplayID = ScreenshotShelfScreenResolver.displayID(
                        underMouse: NSEvent.mouseLocation
                    )
                }
                self.finishHideImmediately()
                self.refreshPresentation(immediate: true)
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
                self?.cancelDwellTask()
            }
        })
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isMenuTracking = false
                self.scheduleCollapseIfNeeded()
                // A pointer still resting on the handle resumes its dwell after the menu closes.
                if self.viewModel.isPointerInside,
                   self.modeState.mode == .collapsed,
                   self.phase == .visible {
                    self.modeState.pointerEntered(
                        at: self.viewModel.pointerLocation,
                        now: Date(),
                        dwell: Self.dwellDelay
                    )
                    self.scheduleDwellIfNeeded()
                }
            }
        })
    }

    private func installLockStateObservers() {
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

    func setScreenLocked(_ isLocked: Bool) {
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

    func refreshPreferences() {
        let wasEnabled = isEnabled
        let enabled = ScreenshotShelfPreferences.isEnabled(in: defaults)
        if isEnabled && !enabled { presentationState.hide() }
        isEnabled = enabled
        if !wasEnabled, enabled {
            // While disabled the shelf did not track full-screen changes; align
            // suppression before this method does any presentation work.
            refreshFullScreenSuppression()
        }
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
        if phase == .visible, anchorChanged || collapseChanged {
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

    func refreshFullScreenSuppression() {
        // The panel can only exist while the shelf is enabled and non-empty
        // (`shouldPresentPanel`). Outside that window there is nothing to hide,
        // so skip the WindowServer window-list enumeration. Both ways back into
        // the window re-align first: `refreshPreferences` (disabled → enabled)
        // and `captureCompleted` (0 → 1 card).
        guard isEnabled, hasItems else { return }

        let targetDisplayID = (displayScreen ?? NSScreen.main)
            .flatMap(ScreenshotShelfScreenResolver.displayID(for:))
        let isCovered = (frontmostAppCoversDisplay
            ?? ScreenshotShelfScreenResolver.frontmostAppCoversDisplay)(targetDisplayID)
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

}
