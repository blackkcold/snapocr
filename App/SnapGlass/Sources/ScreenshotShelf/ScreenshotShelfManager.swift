import AppKit
import CaptureCore
import HistoryCore
import QuartzCore
import SharedKit
import SwiftUI

@MainActor
final class ScreenshotShelfManager {
    static let maximumThumbnailBytes = 16 * 1_024 * 1_024
    static let maximumPendingAssetWrites = 2
    static let collapseDelay: TimeInterval = 2.8
    static let armExpansionDelay: TimeInterval = 0.6

    let sessionStore: ScreenshotShelfSessionStore?
    let defaults: UserDefaults
    let createsPanel: Bool
    let viewModel = ScreenshotShelfViewModel()
    var state: ScreenshotShelfState
    var presentationState = ScreenshotShelfPresentationState()
    var cardsByID: [UUID: ScreenshotShelfCard] = [:]
    var cachedThumbnailBytes = 0
    var nextCompletionSequence: UInt64 = 0
    var pendingAssetWrites = 0
    var assetWorkTail: Task<Void, Never>?
    var notificationObservers: [NSObjectProtocol] = []
    var panel: ScreenshotShelfPanel?
    lazy var dragOverlayController = ScreenshotShelfDragOverlayController(
        viewModel: viewModel,
        panel: { [weak self] in self?.panel },
        isShelfVisible: { [weak self] in self?.phase == .visible || self?.phase == .appearing }
    )
    let dragExportStore: ScreenshotShelfDragExportStore
    lazy var dragOutController = ScreenshotShelfDragOutController(
        model: viewModel,
        exportStore: dragExportStore,
        dataProvider: { [weak self] captureID in
            try await self?.originalData(for: captureID)
        }
    )
    lazy var keyboardController = ScreenshotShelfKeyboardController(
        model: viewModel,
        onCopy: { [weak self] in self?.onCopy?($0) },
        onOpen: { [weak self] in
            self?.onEdit?($0)
            self?.hide()
        },
        onSave: { [weak self] in self?.onSave?($0) },
        onRemove: { [weak self] in self?.remove(captureID: $0) }
    )
    var phase: ScreenshotShelfPhase = .hidden
    var presentationGeneration: UInt64 = 0
    var pendingLayout: ScreenshotShelfLayout?
    var presentationUpdateScheduled = false
    var globalMouseMonitor: Any?
    var modeState = ScreenshotShelfModeState()
    var collapseTask: Task<Void, Never>?
    var armExpansionTask: Task<Void, Never>?
    var isMenuTracking = false
    var preferredDisplayID: CGDirectDisplayID?
    var isEnabled: Bool
    var cardHeight: CGFloat
    var imageOpacity: Double
    var anchor: ScreenshotShelfAnchor
    var collapseToRail: Bool
    var captureSuppressionCount = 0
    var isRecordingActive = false
    var isFullScreenSuppressed = false

    var onEdit: ((UUID) -> Void)?
    var onCopy: ((UUID) -> Void)?
    var onPin: ((UUID) -> Void)?
    var onSave: ((UUID) -> Void)?
    var onStateChange: ((Bool, Bool, Bool, Bool) -> Void)?
    var onCacheFailure: ((String) -> Void)?

    var cards: [ScreenshotShelfCard] = []

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
#if DEBUG
        if observesSystemEvents {
            ShowcaseShelfSeeder.schedule(manager: self)
        }
#endif
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

}

extension ScreenshotShelfManager: ScreenshotShelfViewModelDelegate {
    func screenshotShelfViewModel(_ model: ScreenshotShelfViewModel, perform action: ScreenshotShelfAction) {
        handle(action)
    }
}
