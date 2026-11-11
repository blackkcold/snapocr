import AppKit
import CaptureCore
import HistoryCore
import ImageIO
import QuartzCore
import SharedKit
import SwiftUI

@MainActor
final class ScreenshotShelfManager {
    static let maximumThumbnailBytes = 16 * 1_024 * 1_024
    static let maximumPendingAssetWrites = 2
    /// Grace period after the pointer leaves the shelf before it folds back to the handle.
    static let pointerExitCollapseDelay: TimeInterval = 0.7
    /// Grace period after a drag, menu, or suppression ends before the shelf may fold.
    static let interactionResumeDelay: TimeInterval = 2.8
    static let armExpansionDelay: TimeInterval = 0.6
    /// Time the pointer must rest on the collapsed handle before the shelf expands.
    static let dwellDelay: TimeInterval = 0.25

    let sessionStore: ScreenshotShelfSessionStore?
    let defaults: UserDefaults
    let createsPanel: Bool
    let viewModel = ScreenshotShelfViewModel()
    var state: ScreenshotShelfState
    var presentationState = ScreenshotShelfPresentationState()
    var cardsByID: [UUID: ScreenshotShelfCard] = [:]
    var historyPresentationKeys: [UUID: String] = [:]
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
            try await self?.presentedData(for: captureID)
        }
    )
    lazy var keyboardController = ScreenshotShelfKeyboardController(
        model: viewModel,
        onCopy: { [weak self] in self?.onCopy?($0) },
        onOpen: { [weak self] in self?.onEdit?($0) },
        onSave: { [weak self] in self?.onSave?($0) },
        onOpenMockup: { [weak self] in self?.onInspectMockup?($0) },
        onToggleMockup: { [weak self] in self?.toggleMockup(captureID: $0) },
        onCycleMockup: { [weak self] in self?.cycleMockup(captureID: $0) },
        onRemove: { [weak self] in self?.remove(captureID: $0) }
    )
    var phase: ScreenshotShelfPhase = .hidden
    var presentationGeneration: UInt64 = 0
    var pendingLayout: ScreenshotShelfLayout?
    var presentationUpdateScheduled = false
    var globalMouseMonitor: Any?
    var modeState = ScreenshotShelfModeState()
    var collapseTask: Task<Void, Never>?
    var dwellTask: Task<Void, Never>?
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
    var isEditingSuppressed = false

    /// 全屏抑制判定缝。生产代码走 `ScreenshotShelfScreenResolver`；
    /// 测试进程里真实枚举取决于「谁恰好在最前」，因此允许注入可重复的判定。
    var frontmostAppCoversDisplay: ((CGDirectDisplayID?) -> Bool)?

    var onEdit: ((UUID) -> Void)?
    var onInspectMockup: ((UUID) -> Void)?
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
        viewModel.onPointerMoved = { [weak self] location in
            self?.handlePointerMoved(location)
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
        presentedImage: CGImage? = nil,
        mockupStyle: MockupStyle? = nil,
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
            feedbackMessage: nil,
            mockupStyle: mockupStyle
        )
        presentationState.captureCompleted()
        preferredDisplayID = sourceDisplayID
        synchronizeCards()
        // Re-align suppression before the panel can appear: an empty or disabled
        // shelf does not track full-screen changes, so the first visible card must
        // not inherit a stale suppression value.
        refreshFullScreenSuppression()
        refreshPresentation()
        let presented = presentedImage ?? image
        enqueuePreview(presented, captureID: captureID)
        enqueueAssetWrite(original: image, presented: presented, captureID: captureID)
        return captureID
    }

    private func currentMockupPreset() -> MockupPreset {
        let raw = defaults.string(forKey: PreferenceKeys.captureMockupPreset)
            ?? PreferenceDefaults.captureMockupPreset
        return MockupPolicy.preset(for: raw)
    }

    func setMockupStyle(_ style: MockupStyle?, captureID: UUID) {
        Task { await applyMockup(style: style, captureID: captureID) }
    }

    private func toggleMockup(captureID: UUID) {
        guard let card = cardsByID[captureID] else { return }
        let style = card.mockupStyle == nil ? currentMockupPreset().style : nil
        Task { await applyMockup(style: style, captureID: captureID) }
    }

    private func cycleMockup(captureID: UUID) {
        guard let card = cardsByID[captureID] else { return }
        let presets = MockupPreset.allCases
        let nextIndex: Int
        if let current = card.mockupStyle,
           let index = presets.firstIndex(where: { $0.style == current }) {
            nextIndex = (index + 1) % presets.count
        } else {
            nextIndex = presets.firstIndex(of: currentMockupPreset()) ?? 0
        }
        Task { await applyMockup(style: presets[nextIndex].style, captureID: captureID) }
    }

    /// Re-renders a shelf card from its raw capture. The session store keeps the
    /// original untouched; only the preview and drag artifact are replaced.
    private func applyMockup(style: MockupStyle?, captureID: UUID) async {
        guard let data = try? await originalData(for: captureID) else { return }
        // Decode, full-size render, and both encodes stay off the main actor:
        // a 6K window/fullscreen capture takes hundreds of milliseconds.
        guard let rendered = await Task.detached(priority: .userInitiated, operation: {
            () -> (assets: ScreenshotShelfEncodedAssets, preview: CGImage?)? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let rawImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { return nil }
            let presented = style.flatMap { MockupRenderer.render(rawImage, style: $0) } ?? rawImage
            guard let assets = ScreenshotShelfAssetEncoder.encode(presented) else {
                return nil
            }
            return (
                assets,
                ScreenshotShelfAssetEncoder.previewImage(from: presented)
            )
        }).value else { return }

        // Re-read after awaiting: `linkHistory` or `remove` may have changed the
        // card while the render was running. Never write back a stale snapshot.
        guard var card = cardsByID[captureID],
              state.entries.contains(where: { $0.captureID == captureID })
        else { return }

        cachedThumbnailBytes = max(0, cachedThumbnailBytes - (card.thumbnailData?.count ?? 0))
        card.mockupStyle = style
        card.thumbnailData = rendered.assets.thumbnailData
        card.decodedThumbnail = rendered.preview
        cardsByID[captureID] = card
        cachedThumbnailBytes += rendered.assets.thumbnailData.count
        await setThumbnail(rendered.assets.thumbnailData, for: captureID)

        dragExportStore.invalidate(captureID: captureID)
        await dragExportStore.prepare(
            captureID: captureID,
            data: rendered.assets.originalData,
            sourceTypeIdentifier: "public.png"
        )

        if let historyID = cardsByID[captureID]?.historyID,
           let history = HistoryActor.shared {
            let json = style.flatMap { try? JSONEncoder().encode($0) }.flatMap {
                String(data: $0, encoding: .utf8)
            }
            try? await history.updateMockupStyle(id: historyID, styleJSON: json)
        }
        synchronizeCards()
        refreshPresentation()
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
        guard isEnabled, hasItems, !isRecordingActive, !isEditingSuppressed else { return }
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

    /// Hides the shelf for as long as an editor window opened from it is on screen.
    ///
    /// Unlike `hide()`, this keeps the user's show intent, so closing the editor can
    /// restore the shelf instead of losing it until the next capture.
    func beginEditingSuppression() {
        guard !isEditingSuppressed else { return }
        isEditingSuppressed = true
        presentationState.beginSuppression(.editing)
        refreshPresentation(immediate: true)
    }

    /// Releases the editor suppression and restores the shelf if it was showing before.
    func endEditingSuppression() {
        guard isEditingSuppressed else { return }
        isEditingSuppressed = false
        presentationState.endSuppression(.editing)
        refreshPresentation()
        scheduleCollapseIfNeeded()
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

    /// Bytes the user sees and drags: the presented image when a mockup is
    /// applied, otherwise the raw capture. The session store keeps the raw
    /// original for history/re-edit.
    func presentedData(for captureID: UUID) async throws -> Data? {
        if let artifact = await dragExportStore.awaitArtifact(for: captureID) {
            return try Data(contentsOf: artifact.url)
        }
        if let style = cardsByID[captureID]?.mockupStyle,
           let rawData = try await originalData(for: captureID),
           let raw = NSImage(data: rawData)?.cgImage(
               forProposedRect: nil,
               context: nil,
               hints: nil
           ),
           let rendered = await Task.detached(priority: .userInitiated, operation: {
               MockupRenderer.render(raw, style: style)
           }).value,
           let assets = await Task.detached(priority: .utility, operation: {
               ScreenshotShelfAssetEncoder.encode(rendered)
           }).value {
            return assets.originalData
        }
        return try await originalData(for: captureID)
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
