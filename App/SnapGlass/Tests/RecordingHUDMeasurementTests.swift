import CaptureCore
import CoreGraphics
import Foundation
import Testing

@Suite("Recording HUD measurement")
struct RecordingHUDMeasurementTests {
    private let language = "en"

    @Test("Elapsed time and meter levels never change the signature")
    func signatureIgnoresLiveValues() {
        let early = RecordingHUDPresentation(
            mode: .systemAndMicrophone,
            duration: 4,
            systemLevel: 0.1,
            micLevel: 0.05,
            segmentIndex: 0,
            savedCount: 0,
            state: .recording
        )
        let late = RecordingHUDPresentation(
            mode: .systemAndMicrophone,
            duration: 3_723,
            systemLevel: 0.95,
            micLevel: 0.8,
            segmentIndex: 7,
            savedCount: 9,
            state: .recording
        )

        let first = RecordingHUDLayoutSignature(
            audio: early,
            expanded: false,
            silenceWarning: false,
            language: language
        )
        let second = RecordingHUDLayoutSignature(
            audio: late,
            expanded: false,
            silenceWarning: false,
            language: language
        )

        #expect(first == second)
        #expect(first.hashValue == second.hashValue)
    }

    @Test("Language, expansion, and silence warning each produce a different signature")
    func keyIncludesLanguageAndOptions() {
        let presentation = RecordingHUDPresentation(
            mode: .system,
            duration: 12,
            systemLevel: 0.4,
            micLevel: 0,
            segmentIndex: 1,
            savedCount: 2,
            state: .recording
        )
        let english = RecordingHUDLayoutSignature(
            audio: presentation,
            expanded: false,
            silenceWarning: false,
            language: "en"
        )
        let japanese = RecordingHUDLayoutSignature(
            audio: presentation,
            expanded: false,
            silenceWarning: false,
            language: "ja"
        )
        let expanded = RecordingHUDLayoutSignature(
            audio: presentation,
            expanded: true,
            silenceWarning: false,
            language: "en"
        )
        let silent = RecordingHUDLayoutSignature(
            audio: presentation,
            expanded: false,
            silenceWarning: true,
            language: "en"
        )

        #expect(english != japanese)
        #expect(english != expanded)
        #expect(english != silent)
        #expect(
            expanded
                == RecordingHUDLayoutSignature(
                    content: .audioRecording(mode: .system, expanded: true, silenceWarning: false),
                    language: "en"
                )
        )
    }

    @Test("The reserved duration is at least as wide as every rendered duration")
    func worstCaseDurationCoversRenderedDurations() {
        // The duration labels use monospaced digits, so the drawn width is a function of
        // the character count: reserving the widest string makes a ticking clock free.
        let samples: [TimeInterval] = [0, 9, 59, 60, 599, 3_599, 3_600, 35_999, 359_999]
        for elapsed in samples {
            let rendered = RecordingHUDTimeFormatter.string(elapsed: elapsed)
            #expect(rendered.count <= RecordingHUDWorstCaseText.duration.count)
        }
        #expect(RecordingHUDWorstCaseText.duration == "99:59:59")
    }

    @Test("The reserved counters are the widest form the HUD draws")
    func worstCaseCountersAreWidest() {
        #expect(RecordingHUDWorstCaseText.savedSegments == 999)
        #expect(RecordingHUDWorstCaseText.segmentNumber == 999)
        #expect(RecordingHUDWorstCaseText.countdownSeconds == 3)
    }

    @Test("A stored size is a hit and an unknown signature is a miss")
    func cacheCountsHitsAndMisses() {
        var cache = RecordingHUDSizeCache()
        let signature = RecordingHUDLayoutSignature(content: .recording, language: language)
        let unknown = RecordingHUDLayoutSignature(content: .notice(text: "No frames"), language: language)
        let size = CGSize(width: 210, height: 40)

        #expect(cache.isEmpty)
        #expect(cache.lookup(signature) == nil)
        #expect(cache.misses == 1)

        cache.store(size, for: signature)
        #expect(cache.count == 1)
        #expect(cache.lookup(signature) == size)
        #expect(cache.hits == 1)

        #expect(cache.lookup(unknown) == nil)
        #expect(cache.misses == 2)
        // A plain read never counts as a lookup.
        #expect(cache.size(for: unknown) == nil)
        #expect(cache.misses == 2)

        cache.removeAll()
        #expect(cache.isEmpty)
        #expect(cache.hits == 0)
        #expect(cache.misses == 0)
    }

    @Test("An unmeasured signature falls back to its family baseline")
    func unknownSignatureUsesFamilyBaseline() {
        let available = CGSize(width: 1_200, height: 800)
        let audio = RecordingHUDLayoutSignature(
            content: .audioRecording(mode: .system, expanded: false, silenceWarning: false),
            language: language
        )
        let starting = RecordingHUDLayoutSignature(
            content: .starting(kind: .audio, phase: .awaitingFirstAudioSample),
            language: language
        )
        let expandedFailure = RecordingHUDLayoutSignature(
            content: .failure(expanded: true, canRetry: true, reason: "Recording failed"),
            language: language
        )

        #expect(
            RecordingHUDMeasurementPolicy.fallbackSize(for: audio, available: available)
                == CGSize(
                    width: RecordingHUDMetrics.audioBounds.minWidth,
                    height: RecordingHUDMetrics.audioRecordingHeight
                )
        )
        #expect(
            RecordingHUDMeasurementPolicy.fallbackSize(for: starting, available: available)
                == CGSize(
                    width: RecordingHUDMetrics.recordingBounds.minWidth,
                    height: RecordingHUDMetrics.recordingBounds.minHeight
                )
        )
        #expect(
            RecordingHUDMeasurementPolicy.fallbackSize(
                for: expandedFailure,
                available: available
            ).width == RecordingHUDMetrics.failureBounds.minWidth
        )
    }

    @Test("The fallback is clamped by a narrow screen")
    func fallbackIsClampedByAvailableWidth() {
        let available = CGSize(width: 120, height: 600)
        let signature = RecordingHUDLayoutSignature(
            content: .preparing(kind: .screen, phase: .loadingSources),
            language: language
        )

        let size = RecordingHUDMeasurementPolicy.fallbackSize(for: signature, available: available)
        #expect(size.width == 120)
        #expect(size.height == RecordingHUDMetrics.recordingBounds.minHeight)
    }

    @Test("A measured size never exceeds the family bounds")
    func measuredSizesStayInsideBounds() {
        let signatures: [RecordingHUDLayoutSignature] = [
            .init(content: .countdown, language: language),
            .init(content: .recording, language: language),
            .init(
                content: .saving(kind: .audio, showsFileName: true, isBeforeQuit: false),
                language: language
            ),
            .init(content: .audioFinalizing(previewReady: true, previewPlaying: false), language: language),
            .init(
                content: .audioFinished(
                    showsPreview: true,
                    previewPlaying: false,
                    offersRecordingsList: true
                ),
                language: language
            ),
            .init(content: .notice(text: "No frames are arriving"), language: language),
        ]

        for signature in signatures {
            let bounds = RecordingHUDMetrics.bounds(for: signature.panelKind)
            let size = RecordingHUDMeasurementPolicy.fallbackSize(
                for: signature,
                available: CGSize(width: 1_200, height: 800)
            )
            #expect(size.width >= bounds.minWidth)
            #expect(size.width <= bounds.maxWidth)
            #expect(size.height >= bounds.minHeight)
            #expect(size.height <= bounds.maxHeight)
        }
    }
}
