import AppKit
import CaptureCore
import HistoryCore
import ImageIO
import SharedKit
import UniformTypeIdentifiers

struct ScreenshotShelfCard: Identifiable, Equatable {
    let captureID: UUID
    var historyID: UUID?
    var imagePixelSize: CGSize
    var thumbnailData: Data?
    var errorMessage: String?
    var feedbackMessage: String?

    var id: UUID { captureID }
}

private struct ScreenshotShelfEncodedAssets: Sendable {
    let originalData: Data
    let thumbnailData: Data
}

private enum ScreenshotShelfAssetEncoder {
    static func encode(_ image: CGImage) -> ScreenshotShelfEncodedAssets? {
        guard let originalData = imageData(image, type: .png) else { return nil }
        let scale = min(1, 768 / CGFloat(max(1, max(image.width, image.height))))
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let thumbnail = context.makeImage(),
              let thumbnailData = imageData(thumbnail, type: .jpeg, quality: 0.82) else { return nil }
        return ScreenshotShelfEncodedAssets(originalData: originalData, thumbnailData: thumbnailData)
    }

    static func displayThumbnail(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 768,
        ] as CFDictionary
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return imageData(thumbnail, type: .jpeg, quality: 0.82)
    }

    private static func imageData(_ image: CGImage, type: UTType, quality: Double? = nil) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            return nil
        }
        let properties = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

@MainActor
final class ScreenshotShelfManager {
    private static let maximumThumbnailBytes = 16 * 1_024 * 1_024
    private static let maximumPendingAssetWrites = 2

    private let sessionStore: ScreenshotShelfSessionStore?
    private let defaults: UserDefaults
    private let createsPanel: Bool
    private var state: ScreenshotShelfState
    private var presentationState = ScreenshotShelfPresentationState()
    private var cardsByID: [UUID: ScreenshotShelfCard] = [:]
    private var cachedThumbnailBytes = 0
    private var nextCompletionSequence: UInt64 = 0
    private var pendingAssetWrites = 0
    private var assetWorkTail: Task<Void, Never>?
    private var notificationObservers: [NSObjectProtocol] = []
    private var panel: ScreenshotShelfPanel?
    private var preferredDisplayID: CGDirectDisplayID?
    private var isEnabled: Bool
    private var cardHeight: CGFloat
    private var imageOpacity: Double
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
    var isVisible: Bool { panel?.isVisible == true && shouldPresentPanel }
    var shouldPresentPanel: Bool {
        isEnabled && hasItems && !isRecordingActive && presentationState.shouldPresentPanel
    }
    var displayScreen: NSScreen? {
        Self.screen(for: preferredDisplayID) ?? Self.screen(underMouse: NSEvent.mouseLocation)
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
        createsPanel: Bool
    ) {
        self.defaults = defaults
        self.sessionStore = sessionStore
        self.createsPanel = createsPanel
        state = ScreenshotShelfState(limit: ScreenshotShelfPreferences.count(in: defaults))
        isEnabled = ScreenshotShelfPreferences.isEnabled(in: defaults)
        cardHeight = CGFloat(ScreenshotShelfPreferences.cardHeight(in: defaults))
        imageOpacity = ScreenshotShelfPreferences.imageOpacity(in: defaults)
        if observesSystemEvents {
            installObservers()
            refreshFullScreenSuppression()
        }
        updatePanel()
    }

    func publishCurrentState() {
        publishState()
    }

    @discardableResult
    func captureCompleted(_ image: CGImage, sourceDisplayID: CGDirectDisplayID? = nil) -> UUID? {
        refreshPreferences()
        guard isEnabled else { return nil }

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
            thumbnailData: nil,
            errorMessage: nil,
            feedbackMessage: nil
        )
        presentationState.captureCompleted()
        preferredDisplayID = sourceDisplayID
        synchronizeCards()
        updatePanel()
        enqueueAssetWrite(image, captureID: captureID)
        return captureID
    }

    func toggle() {
        guard canToggle else { return }
        if panel?.isVisible == true {
            hide()
        } else {
            show()
        }
    }

    func show() {
        refreshPreferences()
        guard isEnabled, hasItems, !isRecordingActive else { return }
        presentationState.show()
        updatePanel()
    }

    func hide() {
        presentationState.hide()
        updatePanel()
    }

    func beginCaptureSuppression() {
        captureSuppressionCount += 1
        guard captureSuppressionCount == 1 else { return }
        presentationState.beginSuppression(.capture)
        updatePanel()
    }

    func endCaptureSuppression() {
        guard captureSuppressionCount > 0 else { return }
        captureSuppressionCount -= 1
        guard captureSuppressionCount == 0 else { return }
        presentationState.endSuppression(.capture)
        updatePanel()
    }

    func setRecordingActive(_ active: Bool) {
        guard isRecordingActive != active else { return }
        isRecordingActive = active
        if active {
            presentationState.beginSuppression(.recording)
        } else {
            presentationState.endSuppression(.recording)
        }
        updatePanel()
    }

    func remove(captureID: UUID) {
        guard state.entries.contains(where: { $0.captureID == captureID }) else { return }
        state.remove(captureID: captureID)
        removeCards(for: [captureID])
        scheduleAssetRemoval(for: [captureID])
        synchronizeCards()
        updatePanel()
    }

    func clear() {
        let captureIDs = state.clear()
        removeCards(for: captureIDs)
        synchronizeCards()
        enqueueAssetClear()
        updatePanel()
    }

    func linkHistory(captureID: UUID, historyID: UUID) {
        guard state.entries.contains(where: { $0.captureID == captureID }) else { return }
        state.linkHistory(captureID: captureID, historyID: historyID)
        if var card = cardsByID[captureID] {
            card.historyID = historyID
            cardsByID[captureID] = card
        }
        scheduleAssetRemoval(for: [captureID])
        synchronizeCards()
        updatePanel()
        Task { @MainActor [weak self] in
            await self?.refreshHistoryCard(captureID: captureID, historyID: historyID)
        }
    }

    func historyID(for captureID: UUID) -> UUID? {
        state.entries.first(where: { $0.captureID == captureID })?.historyID
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

    func reportFeedback(captureID: UUID, message: String, isError: Bool = false) {
        guard var card = cardsByID[captureID] else { return }
        card.feedbackMessage = message
        if isError { card.errorMessage = message }
        cardsByID[captureID] = card
        synchronizeCards()
        updatePanel()
    }

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
                self?.refreshFullScreenSuppression()
                self?.updatePanel()
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
        presentationState.setScreenLocked(isLocked)
        updatePanel()
    }

    private func refreshPreferences() {
        let enabled = ScreenshotShelfPreferences.isEnabled(in: defaults)
        if isEnabled && !enabled { presentationState.hide() }
        isEnabled = enabled
        cardHeight = CGFloat(ScreenshotShelfPreferences.cardHeight(in: defaults))
        imageOpacity = ScreenshotShelfPreferences.imageOpacity(in: defaults)
        let evictedIDs = state.setLimit(ScreenshotShelfPreferences.count(in: defaults))
        removeCards(for: evictedIDs)
        scheduleAssetRemoval(for: evictedIDs)
        synchronizeCards()
        updatePanel()
    }

    private func refreshFullScreenSuppression() {
        let isCovered = Self.frontmostAppCoversDisplay()
        guard isCovered != isFullScreenSuppressed else { return }
        isFullScreenSuppressed = isCovered
        if isCovered {
            presentationState.beginSuppression(.fullScreen)
        } else {
            presentationState.endSuppression(.fullScreen)
        }
        updatePanel()
    }

    private func reconcileHistory() async {
        guard let history = HistoryActor.shared else { return }
        let historyEntries = await history.allEntries()
        let entriesByID = Dictionary(uniqueKeysWithValues: historyEntries.map { ($0.id, $0) })
        let removedIDs = state.reconcileHistory(existingHistoryIDs: Set(entriesByID.keys))
        removeCards(for: removedIDs)
        scheduleAssetRemoval(for: removedIDs)

        for entry in state.entries {
            guard let historyID = entry.historyID,
                  let historyEntry = entriesByID[historyID] else { continue }
            updateHistoryCard(
                captureID: entry.captureID,
                historyID: historyID,
                pixelWidth: historyEntry.pixelWidth,
                pixelHeight: historyEntry.pixelHeight
            )
            await refreshHistoryThumbnail(captureID: entry.captureID, historyID: historyID, from: history)
        }
        synchronizeCards()
        updatePanel()
    }

    private func refreshHistoryCard(captureID: UUID, historyID: UUID) async {
        guard let history = HistoryActor.shared else { return }
        do {
            guard let historyEntry = try await history.load(id: historyID) else { return }
            updateHistoryCard(
                captureID: captureID,
                historyID: historyID,
                pixelWidth: historyEntry.pixelWidth,
                pixelHeight: historyEntry.pixelHeight
            )
            await refreshHistoryThumbnail(captureID: captureID, historyID: historyID, from: history)
            synchronizeCards()
            updatePanel()
        } catch {
            return
        }
    }

    private func updateHistoryCard(
        captureID: UUID,
        historyID: UUID,
        pixelWidth: Int?,
        pixelHeight: Int?
    ) {
        guard state.entries.contains(where: { $0.captureID == captureID && $0.historyID == historyID }),
              var card = cardsByID[captureID] else { return }
        if let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 {
            card.imagePixelSize = CGSize(width: pixelWidth, height: pixelHeight)
        }
        cardsByID[captureID] = card
    }

    private func refreshHistoryThumbnail(
        captureID: UUID,
        historyID: UUID,
        from history: HistoryActor
    ) async {
        guard state.entries.contains(where: { $0.captureID == captureID && $0.historyID == historyID }) else {
            return
        }
        do {
            guard let data = try await history.thumbnailData(for: historyID),
                  let thumbnailData = ScreenshotShelfAssetEncoder.displayThumbnail(from: data),
                  state.entries.contains(where: { $0.captureID == captureID && $0.historyID == historyID }) else {
                return
            }
            setThumbnail(thumbnailData, for: captureID)
        } catch {
            return
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

        do {
            let evictedIDs = try await sessionStore.store(
                originalData: assets.originalData,
                thumbnailData: assets.thumbnailData,
                captureID: captureID
            )
            for evictedID in evictedIDs { state.remove(captureID: evictedID) }
            removeCards(for: evictedIDs)
            if state.entries.contains(where: { $0.captureID == captureID }) {
                setThumbnail(assets.thumbnailData, for: captureID)
            } else {
                try? await sessionStore.remove(captureID: captureID)
            }
            synchronizeCards()
            updatePanel()
        } catch {
            cacheFailed(captureID: captureID)
        }
    }

    private func cacheFailed(captureID: UUID) {
        let message = AppLocalization.string("Screenshot preview unavailable")
        guard var card = cardsByID[captureID] else { return }
        card.errorMessage = message
        cardsByID[captureID] = card
        synchronizeCards()
        onCacheFailure?(message)
        updatePanel()
    }

    private func setThumbnail(_ data: Data, for captureID: UUID) {
        guard data.count <= Self.maximumThumbnailBytes,
              var card = cardsByID[captureID] else {
            cacheFailed(captureID: captureID)
            return
        }
        let oldCount = card.thumbnailData?.count ?? 0
        cachedThumbnailBytes = max(0, cachedThumbnailBytes - oldCount)
        card.thumbnailData = nil
        cardsByID[captureID] = card

        for entry in state.entries.reversed() where cachedThumbnailBytes + data.count > Self.maximumThumbnailBytes {
            guard entry.captureID != captureID,
                  var otherCard = cardsByID[entry.captureID],
                  let oldThumbnail = otherCard.thumbnailData else { continue }
            cachedThumbnailBytes = max(0, cachedThumbnailBytes - oldThumbnail.count)
            otherCard.thumbnailData = nil
            otherCard.errorMessage = AppLocalization.string("Screenshot preview unavailable")
            cardsByID[entry.captureID] = otherCard
        }

        guard var updatedCard = cardsByID[captureID] else { return }
        updatedCard.thumbnailData = data
        updatedCard.errorMessage = nil
        cardsByID[captureID] = updatedCard
        cachedThumbnailBytes += data.count
    }

    private func removeCards(for captureIDs: [UUID]) {
        for captureID in captureIDs {
            if let card = cardsByID.removeValue(forKey: captureID) {
                cachedThumbnailBytes = max(0, cachedThumbnailBytes - (card.thumbnailData?.count ?? 0))
            }
        }
    }

    private func synchronizeCards() {
        cards = state.entries.compactMap { cardsByID[$0.captureID] }
    }

    private func scheduleAssetRemoval(for captureIDs: [UUID]) {
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

    private func updatePanel() {
        guard createsPanel else {
            panel?.orderOut(nil)
            publishState()
            return
        }
        guard shouldPresentPanel,
              let screen = displayScreen ?? NSScreen.screens.first else {
            panel?.orderOut(nil)
            publishState()
            return
        }

        let widths = cards.map { card -> CGFloat in
            guard card.imagePixelSize.width > 0, card.imagePixelSize.height > 0 else {
                return cardHeight * 4 / 3
            }
            return cardHeight * card.imagePixelSize.width / card.imagePixelSize.height
        }
        let frame = ScreenshotShelfGeometry.panelFrame(
            visibleFrame: Self.safeVisibleFrame(for: screen),
            cardWidths: widths,
            cardHeight: cardHeight + 34,
            spacing: 12,
            horizontalInset: 14,
            topInset: 12,
            verticalInset: 10
        )
        guard !frame.isEmpty else {
            panel?.orderOut(nil)
            publishState()
            return
        }

        let rootView = ScreenshotShelfView(
            cards: cards,
            panelWidth: frame.width,
            panelHeight: frame.height,
            cardHeight: cardHeight,
            imageOpacity: imageOpacity,
            onEdit: { [weak self] in self?.onEdit?($0) },
            onCopy: { [weak self] in self?.onCopy?($0) },
            onPin: { [weak self] in self?.onPin?($0) },
            onRemove: { [weak self] in self?.remove(captureID: $0) },
            onClear: { [weak self] in self?.clear() },
            onHide: { [weak self] in self?.hide() }
        )
        if let panel {
            panel.update(rootView: rootView)
            panel.setFrame(frame, display: true)
        } else {
            panel = ScreenshotShelfPanel(contentRect: frame, rootView: rootView)
        }
        panel?.orderFrontRegardless()
        publishState()
    }

    private func publishState() {
        onStateChange?(isVisible, hasItems, isEnabled, canToggle)
    }

    private static func screen(for displayID: CGDirectDisplayID?) -> NSScreen? {
        guard let displayID else { return nil }
        return NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }
    }

    private static func screen(underMouse point: CGPoint) -> NSScreen? {
        NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
    }

    private static func safeVisibleFrame(for screen: NSScreen) -> CGRect {
        let visible = screen.visibleFrame
        let insets = screen.safeAreaInsets
        return CGRect(
            x: visible.minX + insets.left,
            y: visible.minY + insets.bottom,
            width: max(0, visible.width - insets.left - insets.right),
            height: max(0, visible.height - insets.top - insets.bottom)
        )
    }

    private static func frontmostAppCoversDisplay() -> Bool {
        guard let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              frontmostPID != ProcessInfo.processInfo.processIdentifier,
              let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
              ) as? [[String: Any]] else { return false }

        let displayFrames = NSScreen.screens.compactMap { screen -> CGRect? in
            guard let displayID = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? CGDirectDisplayID else { return nil }
            return CGDisplayBounds(displayID)
        }
        return windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == frontmostPID,
                  let windowFrame = windowFrame(from: window[kCGWindowBounds as String]) else { return false }
            return displayFrames.contains { windowFrame.insetBy(dx: -2, dy: -2).contains($0) }
        }
    }

    static func windowFrame(from value: Any?) -> CGRect? {
        guard let bounds = value as? [String: CGFloat] else { return nil }
        return CGRect(dictionaryRepresentation: bounds as CFDictionary)
    }
}

private enum ScreenshotShelfAssetError: Error {
    case historyUnavailable
    case sessionStorageUnavailable
}
