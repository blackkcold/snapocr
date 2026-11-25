import AnnotationCore
import CaptureCore
import Foundation
import Testing

/// State-level coverage for the editor share appearance.
///
/// These tests deliberately avoid the real history store and the real
/// UserDefaults fallback: they assert transitions and the debounced write-back
/// contract, not persisted values.
@MainActor
@Suite(.serialized)
struct ShareAppearanceStateTests {
    private final class StyleWriteRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(id: UUID, json: String?)] = []

        func append(id: UUID, json: String?) {
            lock.lock()
            entries.append((id, json))
            lock.unlock()
        }

        var all: [(id: UUID, json: String?)] {
            lock.lock()
            defer { lock.unlock() }
            return entries
        }
    }

    private func makeViewModel(
        sourceID: UUID? = UUID()
    ) -> (EditorViewModel, StyleWriteRecorder) {
        let recorder = StyleWriteRecorder()
        let context = EditorCaptureContext(
            captureMode: "area",
            supportsVerticalTrim: false,
            startsInVerticalTrim: false,
            sourceEntryID: sourceID,
            mockupStyle: nil
        )
        let viewModel = EditorViewModel(
            context: context,
            historyStyleUpdater: { id, json in
                recorder.append(id: id, json: json)
            }
        )
        return (viewModel, recorder)
    }

    @Test func toggleOffKeepsTheLastEnabledStyle() {
        let (viewModel, _) = makeViewModel(sourceID: nil)

        viewModel.setShareAppearanceEnabled(true)
        #expect(viewModel.isShareAppearanceEnabled)
        let enabledStyle = viewModel.mockupStyle
        #expect(enabledStyle != nil)

        viewModel.setShareAppearanceEnabled(false)
        #expect(!viewModel.isShareAppearanceEnabled)
        #expect(viewModel.mockupStyle == nil)
        #expect(viewModel.lastEnabledMockupStyle == enabledStyle)

        viewModel.setShareAppearanceEnabled(true)
        #expect(viewModel.mockupStyle == enabledStyle)
    }

    @Test func presetSelectionBecomesCustomAfterEditing() {
        let (viewModel, _) = makeViewModel(sourceID: nil)
        viewModel.setShareAppearanceEnabled(true)

        viewModel.applyMockupPreset(.dark)
        #expect(viewModel.selectedMockupPreset == .dark)
        #expect(viewModel.mockupStyle == MockupPreset.dark.style)

        viewModel.updateMockupStyle { style in
            style.borderWidthRatio = 0.001
        }
        #expect(viewModel.selectedMockupPreset == nil)
        #expect(viewModel.mockupStyle?.borderWidthRatio == 0.001)
    }

    @Test func styleChangesWriteBackOnlyOnceAfterDebounce() async throws {
        let sourceID = UUID()
        let (viewModel, recorder) = makeViewModel(sourceID: sourceID)

        viewModel.setShareAppearanceEnabled(true)
        viewModel.applyMockupPreset(.paper)
        viewModel.updateMockupStyle { style in
            style.borderWidthRatio = 0.001
            style.borderColor = .custom(red: 0.2, green: 0.3, blue: 0.4, alpha: 0.5)
        }

        try await Task.sleep(for: .milliseconds(850))

        let writes = recorder.all
        #expect(writes.count == 1)
        #expect(writes.first?.id == sourceID)

        let json = try #require(writes.first?.json)
        let data = try #require(json.data(using: .utf8))
        let decoded = try JSONDecoder().decode(MockupStyle.self, from: data)
        #expect(decoded.borderWidthRatio == 0.001)
        #expect(decoded.borderColor == .custom(red: 0.2, green: 0.3, blue: 0.4, alpha: 0.5))
    }

    @Test func adoptingACachedStyleDoesNotWriteHistory() async throws {
        let sourceID = UUID()
        let (viewModel, recorder) = makeViewModel(sourceID: sourceID)
        viewModel.adoptMockupStyle(MockupPreset.midnight.style)

        try await Task.sleep(for: .milliseconds(700))

        #expect(recorder.all.isEmpty)
        #expect(viewModel.mockupStyle == MockupPreset.midnight.style)
        #expect(viewModel.selectedMockupPreset == .midnight)
    }

    @Test func versionOneStyleStillMatchesItsPreset() {
        var style = MockupPreset.dark.style
        style.version = 1

        #expect(EditorViewModel.preset(matching: style) == .dark)
    }
}
