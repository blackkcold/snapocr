import CaptureCore
import Foundation

extension RecordingExportViewModel {
    func setPreviewGain(_ value: Double) {
        guard value.isFinite else { return }
        previewGain = min(1, max(0, value))
        previewPlayer?.setGain(Float(previewGain))
    }

    func togglePreview(for segmentID: UUID) {
        if previewSegmentID == segmentID {
            releasePreviewLease()
            return
        }
        guard let previewService,
              session?.segments.contains(where: { $0.id == segmentID && $0.state == .published }) == true else {
            message = .previewUnavailable
            return
        }

        releasePreviewLease()
        let generation = previewGeneration
        message = nil
        let task = Task { @MainActor [weak self] in
            defer {
                if self?.previewGeneration == generation { self?.previewTask = nil }
            }
            do {
                let lease = try await previewService.leasePreview(for: segmentID, duration: 24 * 60 * 60)
                guard let self else {
                    await previewService.release(lease)
                    return
                }
                guard !Task.isCancelled, self.previewGeneration == generation else {
                    await previewService.release(lease)
                    return
                }

                let player = RecordingExportAudioPreviewPlayer()
                self.previewLease = lease
                self.previewSegmentID = segmentID
                self.previewPlayer = player
                try player.play(urls: lease.mediaURLs, gain: Float(self.previewGain)) { [weak self] in
                    Task { @MainActor [weak self] in
                        guard self?.previewLease?.id == lease.id else { return }
                        self?.releasePreviewLease()
                    }
                }
            } catch {
                guard let self, self.previewGeneration == generation else { return }
                self.message = .previewFailed
                self.releasePreviewLease()
            }
        }
        previewTask = task
    }

    func releasePreviewLease() {
        previewGeneration += 1
        let generation = previewGeneration
        previewTask?.cancel()
        let task = previewTask
        previewTask = nil

        let player = previewPlayer
        previewPlayer = nil
        player?.stop()
        previewSegmentID = nil

        let lease = previewLease
        previewLease = nil
        if let lease, let previewService {
            enqueuePreviewRelease(lease, using: previewService)
        }
        let releaseTask = previewReleaseTask
        previewCleanupTask = Task { @MainActor in
            await task?.value
            await releaseTask?.value
            if self.previewGeneration == generation { self.previewCleanupTask = nil }
        }
    }

    func enqueuePreviewRelease(_ lease: PreviewLease, using service: RecordingPreviewService) {
        let previous = previewReleaseTask
        previewReleaseTask = Task { @MainActor in
            await previous?.value
            await service.release(lease)
        }
    }

    func releasePreviewLeaseAndWait() async {
        releasePreviewLease()
        let cleanup = previewCleanupTask
        await cleanup?.value
        let release = previewReleaseTask
        await release?.value
    }
}
