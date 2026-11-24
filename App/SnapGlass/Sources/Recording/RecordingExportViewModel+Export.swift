import CaptureCore
import Foundation

extension RecordingExportViewModel {
    func export() async throws -> ExportResult {
        let plan = try validatedPlan()
        guard let service = selectedSourceLeases?.service else { throw ExportError.missingSource }
        guard !isExporting else { throw ExportError.exportInProgress }

        isExporting = true
        exportProgress = 0
        message = nil
        succeededOutputURL = nil
        exportGeneration += 1
        let generation = exportGeneration
        let exportID = UUID()
        activeExportID = exportID
        await releasePreviewLeaseAndWait()
        guard generation == exportGeneration, !Task.isCancelled else {
            await finishExportReleasingLeases(using: service, exportID: exportID)
            let error = ExportError.cancelled(stagingURL: nil)
            message = .export(error)
            throw error
        }
        let exporter = self.exporter
        let task = Task<ExportResult, Error> { [weak self] in
            try await exporter.export(plan) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.activeExportID == exportID else { return }
                    self.exportProgress = progress.fraction
                }
            }
        }
        activeExportTask = task

        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            succeededOutputURL = result.outputURL
            exportProgress = 1
            await finishExportReleasingLeases(using: service, exportID: exportID)
            return result
        } catch {
            let exportError = error as? ExportError
                ?? (Task.isCancelled
                    ? ExportError.cancelled(stagingURL: nil)
                    : ExportError.publishFailed(stagingURL: nil))
            message = .export(exportError)
            await finishExportReleasingLeases(using: service, exportID: exportID)
            throw exportError
        }
    }

    func cancel() {
        assessmentGeneration += 1
        assessmentTask?.cancel()
        assessmentTask = nil
        isAssessing = false
        cachedPlan = nil
        validatedPlanGeneration = nil
        previewTask?.cancel()
        releasePreviewLease()
        exportGeneration += 1
        activeExportTask?.cancel()
        if !isExporting { releaseSelectedSourceLeases() }
    }

    func windowDidClose() {
        sessionGeneration += 1
        isOpeningSession = false
        cancel()
    }

    func finishExportReleasingLeases(
        using service: RecordingPreviewService,
        exportID: UUID
    ) async {
        let bundle = selectedSourceLeases
        selectedSourceLeases = nil
        if let bundle {
            await RecordingExportWork.release(bundle.leases, using: bundle.service)
        } else {
            _ = service
        }
        if activeExportID == exportID {
            activeExportTask = nil
            activeExportID = nil
            isExporting = false
        }
    }
}
