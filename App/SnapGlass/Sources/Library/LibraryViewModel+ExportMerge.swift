import AppKit
import Foundation
import LibraryCore

@MainActor
extension LibraryViewModel {
    // MARK: - Export

    func exportSelection(options: LibraryExportOptions) async {
        let items = selectionItems.isEmpty ? filteredItems : selectionItems
        guard !items.isEmpty else {
            showToast(AppLocalization.string("Choose at least one item to export."), type: .error)
            return
        }
        isBusy = true
        exportProgress = 0
        exportMessage = AppLocalization.string("Preparing export…")
        defer {
            isBusy = false
            exportProgress = nil
            exportMessage = nil
        }

        do {
            let result = try await exportService.export(
                items: items,
                options: options,
                progress: { [weak self] progress in
                    Task { @MainActor in
                        self?.exportProgress = progress.fraction
                        self?.exportMessage = progress.message
                    }
                }
            )
            lastOutputURLs = result.outputURLs
            if let first = result.outputURLs.first {
                let message =
                    result.warnings.first
                    ?? AppLocalization.string(
                        "Exported %@ file(s)",
                        String(result.outputURLs.count)
                    )
                showToast(
                    message,
                    type: result.warnings.isEmpty ? .success : .info,
                    actionLabel: AppLocalization.string("Show in Finder"),
                    action: {
                        NSWorkspace.shared.activateFileViewerSelecting([first])
                    }
                )
            } else {
                showToast(
                    result.failures.first ?? AppLocalization.string("Nothing was exported."),
                    type: .error
                )
            }
        } catch is CancellationError {
            showToast(AppLocalization.string("Export cancelled"), type: .info)
        } catch {
            showToast(error.localizedDescription, type: .error)
        }
    }

    // MARK: - Merge planning

    var mergeGroups: [LibraryRecordingGroup] {
        let selectedGroups =
            selectionItems
            .compactMap(\.recordingGroup)
            .filter { $0.state == .complete && $0.segmentCount > 1 }
        if !selectedGroups.isEmpty {
            return selectedGroups.sorted { $0.startedAt < $1.startedAt }
        }
        if let selected = selectedRecordingGroup,
            selected.state == .complete,
            selected.segmentCount > 1
        {
            return [selected]
        }
        return []
    }

    var canMergeSelection: Bool {
        let groups = mergeGroups
        guard let first = groups.first else { return false }
        if !selectionItems.isEmpty,
            selectionItems.contains(where: { $0.recordingGroup == nil })
        {
            return false
        }
        return groups.allSatisfy { $0.kind == first.kind }
    }

    var canGroupSelection: Bool {
        let groups =
            selectionItems
            .compactMap(\.recordingGroup)
            .filter { !$0.isManualGroup }
        guard groups.count >= 2, let first = groups.first else { return false }
        return groups.allSatisfy { $0.kind == first.kind }
    }

    private func expandedMergeGroups(
        _ groups: [LibraryRecordingGroup]
    ) -> [LibraryRecordingGroup] {
        groups.flatMap { group in
            guard group.isManualGroup, !group.memberSessionIDs.isEmpty else {
                return [group]
            }
            let memberIDs = Set(group.memberSessionIDs)
            let members = sessionGroups.filter { memberIDs.contains($0.sessionID) }
            return members.isEmpty ? [group] : members
        }
    }

    // MARK: - Grouping

    func groupSelection() async {
        let groups =
            selectionItems
            .compactMap(\.recordingGroup)
            .filter { !$0.isManualGroup }
        guard groups.count >= 2, let first = groups.first,
            groups.allSatisfy({ $0.kind == first.kind })
        else { return }

        _ = await metadataStore.createGroup(
            title: nil,
            sessionIDs: groups.map(\.sessionID)
        )
        cancelSelection()
        await load()
        showToast(
            AppLocalization.string(
                "Grouped %@ recordings",
                String(groups.count)
            )
        )
    }

    func ungroup(_ group: LibraryRecordingGroup) async {
        guard let manualGroupID = group.manualGroupID else { return }
        await metadataStore.removeGroup(id: manualGroupID)
        selectedItemID = nil
        isInspectorPresented = false
        await load()
        showToast(AppLocalization.string("Ungrouped recordings"))
    }

    // MARK: - Merge

    func mergeSelected(destination: URL, outputTitle: String) async {
        let groups = expandedMergeGroups(mergeGroups)
        guard !groups.isEmpty else {
            showToast(AppLocalization.string("Choose one recording to merge."), type: .error)
            return
        }
        guard canMergeSelection else {
            showToast(AppLocalization.string("Only recordings of the same type can be merged together."), type: .error)
            return
        }
        isBusy = true
        mergeProgress = 0
        mergeMessage = AppLocalization.string("Preparing merge…")
        defer {
            isBusy = false
            mergeProgress = nil
            mergeMessage = nil
        }

        if groups.count > 1,
            await mergeCombinedGroups(
                groups,
                destination: destination,
                outputTitle: outputTitle
            )
        {
            return
        }

        let outcome = await mergeGroupsIndividually(
            groups,
            destination: destination,
            outputTitle: outputTitle
        )
        lastOutputURLs = outcome.outputs
        presentMergeResult(outputs: outcome.outputs, failures: outcome.failures)
    }

    /// Merges every selected group into one file. Returns `true` when the
    /// outcome is final, `false` when the selection is too long for one file
    /// and the caller should fall back to per-group export.
    private func mergeCombinedGroups(
        _ groups: [LibraryRecordingGroup],
        destination: URL,
        outputTitle: String
    ) async -> Bool {
        do {
            let result = try await mergeService.merge(
                groups: groups,
                destination: destination,
                outputTitle: outputTitle,
                progress: { [weak self] progress in
                    Task { @MainActor in
                        self?.mergeProgress = progress.fraction
                        self?.mergeMessage = progress.message
                    }
                }
            )
            lastOutputURLs = result.outputURLs
            showToast(
                AppLocalization.string(
                    "Merged into %@ file(s)",
                    String(result.outputURLs.count)
                ),
                actionLabel: AppLocalization.string("Show in Finder"),
                action: {
                    NSWorkspace.shared.activateFileViewerSelecting(result.outputURLs)
                }
            )
            return true
        } catch RecordingMergeError.overLimit {
            // Too long for one file: fall through to per-group export.
            return false
        } catch {
            showToast(error.localizedDescription, type: .error)
            return true
        }
    }

    private func mergeGroupsIndividually(
        _ groups: [LibraryRecordingGroup],
        destination: URL,
        outputTitle: String
    ) async -> (outputs: [URL], failures: [String]) {
        var outputs: [URL] = []
        var failures: [String] = []

        for (index, group) in groups.enumerated() {
            let groupTitle =
                groups.count > 1
                ? "\(outputTitle) \(index + 1)"
                : outputTitle
            do {
                let result = try await mergeService.merge(
                    group: group,
                    destination: destination,
                    outputTitle: groupTitle,
                    progress: { [weak self] progress in
                        Task { @MainActor in
                            let base = Double(index) / Double(groups.count)
                            self?.mergeProgress = min(
                                1,
                                base + progress.fraction / Double(groups.count)
                            )
                            self?.mergeMessage = progress.message
                        }
                    }
                )
                outputs.append(contentsOf: result.outputURLs)
            } catch {
                let title =
                    group.title.isEmpty
                    ? AppLocalization.string("Recording")
                    : group.title
                failures.append("\(title): \(error.localizedDescription)")
            }
        }
        return (outputs, failures)
    }

    private func presentMergeResult(outputs: [URL], failures: [String]) {
        if outputs.isEmpty {
            showToast(
                failures.first ?? AppLocalization.string("Merge failed."),
                type: .error
            )
        } else {
            let message =
                failures.isEmpty
                ? AppLocalization.string("Merged into %@ file(s)", String(outputs.count))
                : AppLocalization.string(
                    "Merged %@ file(s); %@ item(s) failed.",
                    String(outputs.count),
                    String(failures.count)
                )
            showToast(
                message,
                type: failures.isEmpty ? .success : .info,
                actionLabel: AppLocalization.string("Show in Finder"),
                action: {
                    NSWorkspace.shared.activateFileViewerSelecting(outputs)
                }
            )
        }
    }

    // MARK: - Retention

    var recordingSessionCount: Int {
        sessionGroups.isEmpty ? recordingGroups.count : sessionGroups.count
    }

    private var retentionSourceGroups: [LibraryRecordingGroup] {
        sessionGroups.isEmpty ? recordingGroups : sessionGroups
    }

    var recordingLibraryByteSize: Int64 {
        retentionSourceGroups.reduce(Int64(0)) { $0 + $1.byteSize }
    }

    func retentionCandidateCount(olderThanDays days: Int) -> Int {
        RecordingRetentionPlanner.eligibleGroups(
            retentionSourceGroups,
            olderThanDays: days
        ).count
    }

    func cleanupRecordings(olderThanDays days: Int) async {
        let candidates = RecordingRetentionPlanner.eligibleGroups(
            retentionSourceGroups,
            olderThanDays: days
        )
        guard !candidates.isEmpty else {
            showToast(AppLocalization.string("No recordings are older than this."), type: .info)
            return
        }

        isCleaningRecordings = true
        defer { isCleaningRecordings = false }

        var deletedIDs = Set<String>()
        var failures: [String] = []
        for group in candidates {
            let report = await deletionService.delete(group)
            if report.deletedSessionCount > 0 {
                deletedIDs.insert(group.id)
            }
            failures.append(contentsOf: report.failures)
        }

        recordingGroups.removeAll { deletedIDs.contains($0.id) }
        await load()
        if failures.isEmpty {
            showToast(
                AppLocalization.string(
                    "Moved %@ recording(s) to the Trash",
                    String(deletedIDs.count)
                )
            )
        } else {
            showToast(
                failures.first ?? AppLocalization.string("Cleanup completed with errors"),
                type: .error
            )
        }
        isShowingStorageSheet = false
    }
}
