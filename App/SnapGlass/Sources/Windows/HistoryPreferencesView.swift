import AppKit
import HistoryCore
import SharedKit
import SwiftUI

// MARK: - History Preferences

struct HistoryPreferencesView: View {
    @AppStorage(PreferenceKeys.historyRetentionDays)
    private var storedRetentionDays = PreferenceDefaults.historyRetentionDays
    @AppStorage(PreferenceKeys.historyMaxItems)
    private var storedMaxItems = PreferenceDefaults.historyMaxItems
    @AppStorage(PreferenceKeys.historyStorageSize)
    private var storedStorageSize = PreferenceDefaults.historyStorageSize
    @AppStorage(PreferenceKeys.historyAutoSave)
    private var autoSave = PreferenceDefaults.historyAutoSave
    @AppStorage(PreferenceKeys.historySaveFullText)
    private var saveFullText = PreferenceDefaults.historySaveFullText
    @AppStorage(PreferenceKeys.colorHistoryEnabled)
    private var colorHistoryEnabled = PreferenceDefaults.colorHistoryEnabled
    @AppStorage(PreferenceKeys.colorHistoryMaxItems)
    private var storedColorHistoryMaxItems = PreferenceDefaults.colorHistoryMaxItems

    @State private var maxItems = PreferenceDefaults.historyMaxItems
    @State private var retentionDays = PreferenceDefaults.historyRetentionDays
    @State private var keepIndefinitely = false
    @State private var lastFiniteRetentionDays = PreferenceDefaults.historyRetentionDays
    @State private var storageSize = PreferenceDefaults.historyStorageSize
    @State private var colorHistoryMaxItems = PreferenceDefaults.colorHistoryMaxItems
    @State private var isClearingColors = false
    @State private var pendingCleanupCount = 0
    @State private var showsCleanupConfirmation = false
    @State private var policyRequestGeneration = 0

    private let logger = Logger(category: "preferences")

    var body: some View {
        ScrollView {
            PreferencesCardGrid {
                dashboardCard

                retentionCard

                storageCard

                colorHistoryCard

                saveCard
            }
        }
        .onAppear {
            keepIndefinitely = storedRetentionDays == 0
            lastFiniteRetentionDays = storedRetentionDays == 0
                ? PreferenceDefaults.historyRetentionDays
                : storedRetentionDays
            retentionDays = lastFiniteRetentionDays
            maxItems = storedMaxItems
            storageSize =
                UserDefaults.standard.object(forKey: PreferenceKeys.historyStorageSize) == nil
                ? PreferenceDefaults.historyStorageSize
                : storedStorageSize
            colorHistoryMaxItems = storedColorHistoryMaxItems
        }
        .alert("Apply New Retention Limits?", isPresented: $showsCleanupConfirmation) {
            Button("Cancel", role: .cancel) {
                revertPendingPolicyChange()
            }
            Button("Delete and Apply", role: .destructive) {
                commitPolicyChange()
            }
        } message: {
            Text(
                "\(pendingCleanupCount) screenshots will be permanently deleted. Favourite screenshots are kept."
            )
        }
    }

    private var dashboardCard: some View {
        HistoryStorageDashboard(storageSizeGB: storageSize)
    }

    private var retentionCard: some View {
        PreferencesCard {
            PreferencesCardHeader(systemImage: "calendar", title: "Screenshot Retention") {
                Toggle("Keep indefinitely", isOn: $keepIndefinitely)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: keepIndefinitely) { forever in
                        if forever {
                            lastFiniteRetentionDays = retentionDays
                            requestPolicyChange()
                        } else {
                            retentionDays = max(lastFiniteRetentionDays, 1)
                            requestPolicyChange()
                        }
                    }
            }

            TriValueControl(
                title: "Maximum screenshots",
                unit: "items",
                presets: [50, 100, 200, 500, 1000],
                range: 10...5_000,
                value: maxItems
            ) { newValue in
                maxItems = newValue
                requestPolicyChange()
            }

            if !keepIndefinitely {
                TriValueControl(
                    title: "Retention period",
                    unit: "days",
                    presets: [7, 30, 90, 365],
                    range: 1...3_650,
                    value: retentionDays
                ) { newValue in
                    retentionDays = newValue
                    requestPolicyChange()
                }
            }

            PreferencesCardCaption(text: "Favourite screenshots are not removed by count or age limits.")
        }
    }

    private var storageCard: some View {
        PreferencesCard {
            PreferencesCardHeader(systemImage: "internaldrive", title: "Maximum storage")

            LabeledContent {
                HStack(spacing: 2) {
                    Text(storageSize, format: .number.precision(.fractionLength(1)))
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                    Text(" GB")
                        .foregroundColor(.secondary)
                }
            } label: {
                Text("Capacity")
            }

            Slider(
                value: $storageSize,
                in: 0.1...10.0,
                step: 0.1,
                onEditingChanged: { isDragging in
                    guard !isDragging else { return }
                    requestPolicyChange()
                }
            )
        }
    }

    private var saveCard: some View {
        PreferencesCard {
            Toggle("Auto-save captures to history", isOn: $autoSave)
                .help("Automatically save screenshots and thumbnails to local encrypted history")

            if autoSave {
                Toggle("Save full OCR text", isOn: $saveFullText)
                    .help("Store complete OCR text in encrypted history entries. Off stores an empty text field.")
            }
        }
    }

    private var colorHistoryCard: some View {
        PreferencesCard {
            PreferencesCardHeader(systemImage: "eyedropper", title: "Color History")

            Toggle("Record picked colors", isOn: $colorHistoryEnabled)
                .help("Record colors copied with the area or editor color picker")

            if colorHistoryEnabled {
                TriValueControl(
                    title: "Maximum color entries",
                    unit: "items",
                    presets: [50, 100, 200, 500],
                    range: 10...5_000,
                    value: colorHistoryMaxItems
                ) { newValue in
                    colorHistoryMaxItems = newValue
                    storedColorHistoryMaxItems = newValue
                }
            }

            Button(role: .destructive) {
                isClearingColors = true
            } label: {
                Label("Clear Colors", systemImage: "trash")
            }

            PreferencesCardCaption(
                text: "Colors are stored encrypted on this Mac only. Copying a color with the picker records it here."
            )
        }
        .alert("Clear Color History?", isPresented: $isClearingColors) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                Task { await clearColorHistory() }
            }
        } message: {
            Text("This will permanently delete all color entries.")
        }
    }

    private func clearColorHistory() async {
        guard let colorHistory = ColorHistoryStore.shared else { return }
        do {
            try await colorHistory.clear()
        } catch {
            logger.error("Failed to clear color history: \(error.localizedDescription)")
        }
    }

    /// Asks the history store how many records the pending limits would remove,
    /// and only writes the new limits after the user has decided. Limits that
    /// delete nothing are applied silently.
    private func requestPolicyChange() {
        policyRequestGeneration &+= 1
        let generation = policyRequestGeneration
        let pendingMaxItems = maxItems
        let pendingRetentionDays = keepIndefinitely ? 0 : retentionDays
        let pendingStorageSize = storageSize

        guard let history = HistoryActor.shared else { return }
        Task {
            let deletions = await history.entriesPendingDeletion(
                maxItems: pendingMaxItems,
                retentionDays: pendingRetentionDays == 0 ? Int.max : pendingRetentionDays,
                maxTotalSizeBytes: UInt64((pendingStorageSize * 1024 * 1024 * 1024).rounded())
            )
            guard generation == policyRequestGeneration else { return }
            if deletions > 0 {
                pendingCleanupCount = deletions
                showsCleanupConfirmation = true
            } else {
                commitPolicyChange()
            }
        }
    }

    /// Persists the limits currently shown and applies them.
    private func commitPolicyChange() {
        storedMaxItems = maxItems
        storedRetentionDays = keepIndefinitely ? 0 : retentionDays
        storedStorageSize = storageSize

        Task {
            do {
                try await HistoryActor.shared?.reloadConfiguredPolicyAndCleanup()
            } catch {
                logger.error("Failed to apply history retention policy: \(error.localizedDescription)")
            }
        }
    }

    /// Restores the limits that were in effect before the pending change.
    private func revertPendingPolicyChange() {
        policyRequestGeneration &+= 1
        keepIndefinitely = storedRetentionDays == 0
        retentionDays = storedRetentionDays == 0
            ? lastFiniteRetentionDays
            : storedRetentionDays
        maxItems = storedMaxItems
        storageSize = storedStorageSize
    }
}
