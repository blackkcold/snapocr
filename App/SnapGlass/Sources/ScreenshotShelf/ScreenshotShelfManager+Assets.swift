import AppKit
import CaptureCore
import SharedKit

@MainActor
extension ScreenshotShelfManager {
    // MARK: - Assets

    func enqueuePreview(_ image: CGImage, captureID: UUID) {
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

    func enqueueAssetWrite(original: CGImage, presented: CGImage, captureID: UUID) {
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
            await self?.storeAssets(original: original, presented: presented, captureID: captureID)
        }
        assetWorkTail = task
    }

    func storeAssets(original: CGImage, presented: CGImage, captureID: UUID) async {
        defer { pendingAssetWrites -= 1 }
        guard state.entries.contains(where: { $0.captureID == captureID }),
              let sessionStore else { return }
        let assets = await Task.detached(priority: .utility) {
            (
                original: ScreenshotShelfAssetEncoder.encode(original),
                presented: ScreenshotShelfAssetEncoder.encode(presented)
            )
        }.value
        guard state.entries.contains(where: { $0.captureID == captureID }) else { return }
        guard let originalAssets = assets.original,
              let presentedAssets = assets.presented else {
            cacheFailed(captureID: captureID)
            return
        }

        // The shelf keeps the raw capture encrypted for history/re-edit, while
        // the plaintext drag artifact is the presented image the user sees.
        await dragExportStore.prepare(
            captureID: captureID,
            data: presentedAssets.originalData,
            sourceTypeIdentifier: "public.png"
        )

        do {
            let evictedIDs = try await sessionStore.store(
                originalData: originalAssets.originalData,
                thumbnailData: presentedAssets.thumbnailData,
                captureID: captureID
            )
            for evictedID in evictedIDs { state.remove(captureID: evictedID) }
            removeCards(for: evictedIDs)
            if state.entries.contains(where: { $0.captureID == captureID }) {
                await setThumbnail(presentedAssets.thumbnailData, for: captureID)
            } else {
                try? await sessionStore.remove(captureID: captureID)
            }
            synchronizeCards()
            schedulePresentationUpdate()
        } catch {
            cacheFailed(captureID: captureID)
        }
    }

    func cacheFailed(captureID: UUID) {
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

    func applyThumbnail(_ data: Data, decoded: CGImage, for captureID: UUID) {
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
            historyPresentationKeys.removeValue(forKey: captureID)
            if let card = cardsByID.removeValue(forKey: captureID) {
                cachedThumbnailBytes = max(0, cachedThumbnailBytes - (card.thumbnailData?.count ?? 0))
            }
        }
    }

    func synchronizeCards() {
        cards = state.entries.compactMap { cardsByID[$0.captureID] }
    }

    func attachControllers(to panel: ScreenshotShelfPanel) {
        dragOutController.attach(panel: panel)
        keyboardController.attach(panel: panel)
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

    func enqueueAssetClear() {
        guard let sessionStore else { return }
        let previous = assetWorkTail
        let task = Task { @MainActor in
            await previous?.value
            try? await sessionStore.clear()
        }
        assetWorkTail = task
    }

    // MARK: - Actions

    func handle(_ action: ScreenshotShelfAction) {
        switch action {
        case .edit(let captureID):
            // The editor suppresses the shelf for as long as its window is open;
            // hiding here would clear the show intent and lose the shelf for good.
            onEdit?(captureID)
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
        case .beginKeyboardMode:
            keyboardController.enter()
        case .expand:
            setMode(.expanded)
        case .beginInteraction:
            modeState.beginInteraction()
            cancelCollapseTask()
            cancelDwellTask()
        case .endInteraction:
            modeState.endInteraction(now: Date(), delay: Self.interactionResumeDelay)
            scheduleCollapseIfNeeded()
        case .move(let captureID, let destination):
            state.move(captureID: captureID, to: destination)
            synchronizeCards()
            refreshPresentation()
        }
    }

    func publishState() {
        onStateChange?(isVisible, hasItems, isEnabled, canToggle)
    }
}
