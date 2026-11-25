import AVFoundation
import AudioToolbox
import CaptureCore
import Foundation

/// Value snapshot rendered by the audio recording HUD.
public struct RecordingHUDPresentation: Sendable, Equatable {
    public let mode: AudioSourceMode
    public let duration: TimeInterval
    public let systemLevel: Float
    public let micLevel: Float
    /// Zero-based index of the segment currently receiving samples.
    public let segmentIndex: Int
    /// Count of segments that P3 has fully published.
    public let savedCount: Int
    public let state: RecordingLifecycle
    public let reduceMotion: Bool
    public let reduceTransparency: Bool

    public init(
        mode: AudioSourceMode,
        duration: TimeInterval,
        systemLevel: Float,
        micLevel: Float,
        segmentIndex: Int,
        savedCount: Int,
        state: RecordingLifecycle,
        reduceMotion: Bool = false,
        reduceTransparency: Bool = false
    ) {
        self.mode = mode
        self.duration = duration.isFinite ? max(0, duration) : 0
        self.systemLevel = Self.clampedLevel(systemLevel)
        self.micLevel = Self.clampedLevel(micLevel)
        self.segmentIndex = max(0, segmentIndex)
        self.savedCount = max(0, savedCount)
        self.state = state
        self.reduceMotion = reduceMotion
        self.reduceTransparency = reduceTransparency
    }

    func resolvingAccessibility(reduceMotion: Bool, reduceTransparency: Bool) -> Self {
        Self(
            mode: mode,
            duration: duration,
            systemLevel: systemLevel,
            micLevel: micLevel,
            segmentIndex: segmentIndex,
            savedCount: savedCount,
            state: state,
            reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency
        )
    }

    private static func clampedLevel(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

/// Plays every leased track in sync and reports when the preview has ended.
@MainActor
final class RecordingAudioPreviewPlayer {
    private var engine: AVAudioEngine?
    private var nodes: [AVAudioPlayerNode] = []
    private var files: [AVAudioFile] = []
    private var unfinishedTracks = 0
    private var onFinished: (() -> Void)?

    var isPlaying: Bool { engine != nil }

    func play(urls: [URL], onFinished: @escaping () -> Void) throws {
        stop()
        guard !urls.isEmpty else { throw RecordingPreviewError.notPreviewable }

        let engine = AVAudioEngine()
        var files: [AVAudioFile] = []
        var nodes: [AVAudioPlayerNode] = []
        for url in urls {
            let file = try AVAudioFile(forReading: url)
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
            node.scheduleFile(file, at: nil) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.trackFinished()
                }
            }
            files.append(file)
            nodes.append(node)
        }

        try engine.start()
        self.engine = engine
        self.files = files
        self.nodes = nodes
        unfinishedTracks = nodes.count
        self.onFinished = onFinished

        let hostTime = AudioGetCurrentHostTime() + AVAudioTime.hostTime(forSeconds: 0.08)
        let startTime = AVAudioTime(hostTime: hostTime)
        nodes.forEach { $0.play(at: startTime) }
    }

    func stop() {
        let engine = self.engine
        let nodes = self.nodes
        self.engine = nil
        self.nodes = []
        files = []
        unfinishedTracks = 0
        onFinished = nil
        nodes.forEach { $0.stop() }
        engine?.stop()
    }

    private func trackFinished() {
        guard engine != nil else { return }
        unfinishedTracks -= 1
        guard unfinishedTracks == 0 else { return }
        let completion = onFinished
        stop()
        completion?()
    }
}
