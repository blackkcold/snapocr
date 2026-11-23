import AnnotationCore
import AppKit
import CaptureCore
import Foundation
import HistoryCore
import SharedKit
import SwiftUI

// MARK: - EditorViewModel Share Appearance

/// Owns the editor's share-appearance state, preview rendering and metadata
/// write-back.
///
/// The style is presentation metadata, not document content: it never enters
/// the annotation undo stack and never marks the editor dirty. Linked history
/// entries receive a debounced update so their cards stay in sync; unlinked
/// editors remember the last enabled style for the next time the toggle is
/// turned on.
extension EditorViewModel {
    /// Writes only the presentation metadata for an existing history entry.
    static let defaultHistoryStyleUpdater: @Sendable (UUID, String?) async throws -> Void = { id, json in
        let history = try HistoryActor.sharedResult().get()
        try await history.updateMockupStyle(id: id, styleJSON: json)
    }

    var isShareAppearanceEnabled: Bool {
        mockupStyle != nil
    }

    /// Context-specific explanation shown under the share controls.
    var shareAppearanceContextNote: LocalizedStringKey? {
        switch captureMode {
        case "window":
            return "Window captures use the float look by default; changes update this history entry"
        case "scroll":
            return "Scrolling captures have no share appearance by default"
        default:
            return nil
        }
    }

    /// Adopts a style from a reused editor tab without scheduling a write.
    func adoptMockupStyle(_ style: MockupStyle?) {
        mockupStyle = style
        if let style {
            lastEnabledMockupStyle = style
        }
        baselineMockupStyle = style
        lastCommittedMockupStyle = style
        selectedMockupPreset = Self.preset(matching: style)
        sharePreviewTask?.cancel()
        sharePreview = nil
        sharePreviewState = .idle
        if inspectorTab == .share, document != nil {
            scheduleSharePreview()
        }
    }

    /// Turns the share appearance on or off for this editor session.
    func setShareAppearanceEnabled(_ enabled: Bool) {
        if enabled {
            guard mockupStyle == nil else { return }
            let style = lastEnabledMockupStyle
                ?? baselineMockupStyle
                ?? MockupPolicy.style(
                    for: UserDefaults.standard.string(forKey: PreferenceKeys.captureMockupPreset)
                        ?? PreferenceDefaults.captureMockupPreset
                )
            mockupStyle = style
            selectedMockupPreset = Self.preset(matching: style)
        } else {
            guard mockupStyle != nil else { return }
            lastEnabledMockupStyle = mockupStyle
            mockupStyle = nil
            selectedMockupPreset = nil
        }
        scheduleSharePreview()
        scheduleShareStyleCommit()
    }

    /// Applies one of the built-in templates.
    func applyMockupPreset(_ preset: MockupPreset) {
        if mockupStyle == nil {
            setShareAppearanceEnabled(true)
        }
        let style = preset.style
        mockupStyle = style
        lastEnabledMockupStyle = style
        selectedMockupPreset = preset
        scheduleSharePreview()
        scheduleShareStyleCommit()
    }

    /// Mutates the current style and marks it custom.
    func updateMockupStyle(_ mutate: (inout MockupStyle) -> Void) {
        guard var style = mockupStyle else { return }
        mutate(&style)
        mockupStyle = style
        lastEnabledMockupStyle = style
        selectedMockupPreset = Self.preset(matching: style)
        scheduleSharePreview()
        scheduleShareStyleCommit()
    }

    /// Restores the style the editor opened with (or the last used style when
    /// the editor opened without one).
    func resetMockupStyle() {
        let style = baselineMockupStyle ?? lastEnabledMockupStyle ?? MockupPreset.light.style
        mockupStyle = style
        lastEnabledMockupStyle = style
        selectedMockupPreset = Self.preset(matching: style)
        scheduleSharePreview()
        scheduleShareStyleCommit()
    }

    /// Refreshes the share preview if it is missing or stale.
    func refreshSharePreviewIfNeeded(force: Bool = false) {
        guard document != nil else {
            sharePreview = nil
            sharePreviewState = .idle
            return
        }
        if force || sharePreview == nil || sharePreviewState == .idle {
            scheduleSharePreview()
        }
    }

    // MARK: - Preview

    func scheduleSharePreview() {
        sharePreviewTask?.cancel()
        sharePreviewGeneration += 1
        let generation = sharePreviewGeneration

        guard let document else {
            sharePreview = nil
            sharePreviewState = .idle
            return
        }

        sharePreviewState = .rendering
        let style = mockupStyle
        sharePreviewTask = Task { [weak self] in
            // Coalesce slider ticks; the last value wins.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self else { return }

            let outcome: (CGImage?, String?) = await Task.detached(priority: .userInitiated) {
                do {
                    let annotated = try Renderer().render(
                        document,
                        maximumDimension: 1200,
                        baseImage: nil
                    )
                    guard let style else { return (annotated, nil) }
                    guard let preview = MockupRenderer.render(annotated, style: style) else {
                        return (nil, "Preview render failed")
                    }
                    return (preview, nil)
                } catch {
                    return (nil, error.localizedDescription)
                }
            }.value

            guard generation == self.sharePreviewGeneration else { return }
            if let image = outcome.0 {
                self.sharePreview = image
                self.sharePreviewState = .ready
            } else {
                self.sharePreviewState = .failed(outcome.1 ?? AppLocalization.string("Unable to render preview"))
            }
        }
    }

    // MARK: - History metadata

    func scheduleShareStyleCommit() {
        shareStyleCommitTask?.cancel()
        shareStyleCommitTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            await self.commitShareStyle()
        }
    }

    /// Flushes the pending metadata write before a tab or window closes.
    func flushShareStyleCommit() {
        shareStyleCommitTask?.cancel()
        Self.persistLastMockupStyle(lastEnabledMockupStyle ?? mockupStyle)

        // Turning the toggle off is a session preview choice, not a request to
        // erase the saved look from history. The history menu still offers an
        // explicit "Remove Share Appearance".
        guard let style = mockupStyle,
              let id = sourceEntryID,
              style != lastCommittedMockupStyle,
              let json = Self.styleJSON(style)
        else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.historyStyleUpdater(id, json)
                self.lastCommittedMockupStyle = style
            } catch {
                self.showToast(
                    message: AppLocalization.string(
                        "Style could not be written back to history: %@",
                        error.localizedDescription
                    ),
                    type: .error
                )
            }
        }
    }

    private func commitShareStyle() async {
        Self.persistLastMockupStyle(lastEnabledMockupStyle ?? mockupStyle)

        guard let style = mockupStyle,
              let id = sourceEntryID,
              style != lastCommittedMockupStyle,
              let json = Self.styleJSON(style)
        else { return }

        do {
            try await historyStyleUpdater(id, json)
            lastCommittedMockupStyle = style
        } catch {
            showToast(
                message: AppLocalization.string(
                    "Style could not be written back to history: %@",
                    error.localizedDescription
                ),
                type: .error
            )
        }
    }

    // MARK: - Persistence helpers

    static func preset(matching style: MockupStyle?) -> MockupPreset? {
        guard let style else { return nil }
        return MockupPreset.allCases.first { candidate in
            var candidateStyle = candidate.style
            // Older records decode with version 1; version is not visual.
            candidateStyle.version = style.version
            return candidateStyle == style
        }
    }

    static func styleJSON(_ style: MockupStyle) -> String? {
        guard let data = try? JSONEncoder().encode(style) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func lastPersistedMockupStyle() -> MockupStyle? {
        guard let json = UserDefaults.standard.string(
            forKey: PreferenceKeys.editorMockupLastStyleJSON
        ), let data = json.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(MockupStyle.self, from: data)
    }

    static func persistLastMockupStyle(_ style: MockupStyle?) {
        guard let style, let json = styleJSON(style) else { return }
        UserDefaults.standard.set(json, forKey: PreferenceKeys.editorMockupLastStyleJSON)
    }
}
