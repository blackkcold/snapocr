import AVFoundation
import Foundation

// MARK: Audio source inspection

/// One audio track found inside an export's audio sources.
struct PlannerAudioDescriptor: Sendable {
    enum MediaKind: Sendable, Equatable { case checkpoint, published }
    let role: RecordingTrackRole
    let url: URL
    let urls: [URL]
    let range: SampleRange
    let sampleRate: Int
    let channelCount: Int
    let mediaKind: MediaKind
}

extension RecordingExportPlanner {
    /// Validates a segment's audio source and returns its descriptors.
    static func requiredAudioDescriptors(
        source: ExportAudioSource?,
        segment: PublishedSegment,
        sessionLayout: AudioOutputLayout
    ) throws -> [PlannerAudioDescriptor] {
        guard let source, !source.urls.isEmpty,
              source.urls.allSatisfy({ $0.isFileURL && fileExists($0) })
        else { throw ExportError.missingSource }
        let descriptors = try inspectAudioSources(source, segment: segment, sessionLayout: sessionLayout)
        guard !descriptors.isEmpty else { throw ExportError.missingSource }
        return descriptors
    }

    private static func inspectAudioSources(
        _ source: ExportAudioSource,
        segment: PublishedSegment,
        sessionLayout: AudioOutputLayout
    ) throws -> [PlannerAudioDescriptor] {
        let mediaKind = mediaKind(for: source)
        var result: [PlannerAudioDescriptor] = []
        for url in uniqueURLs(source.urls) {
            switch source {
            case .checkpointPCM:
                result.append(try checkpointDescriptor(url: url, segment: segment, mediaKind: mediaKind))
            case .publishedMedia:
                result.append(contentsOf: try publishedDescriptors(
                    url: url, segment: segment, layout: sessionLayout, mediaKind: mediaKind
                ))
            case .recoveredMedia:
                // Recovered media is the recorder's original file, not a sealed
                // product: read the format from the file itself and report an
                // honest missing source when it cannot be decoded as audio.
                result.append(contentsOf: try recoveredDescriptors(
                    url: url, segment: segment, layout: sessionLayout, mediaKind: mediaKind
                ))
            }
        }
        guard !result.isEmpty else { throw ExportError.missingSource }
        return result
    }

    private static func mediaKind(
        for source: ExportAudioSource
    ) -> PlannerAudioDescriptor.MediaKind {
        switch source {
        case .checkpointPCM: .checkpoint
        case .publishedMedia, .recoveredMedia: .published
        }
    }

    /// One checkpoint PCM track, validated against its sidecar record.
    private static func checkpointDescriptor(
        url: URL,
        segment: PublishedSegment,
        mediaKind: PlannerAudioDescriptor.MediaKind
    ) throws -> PlannerAudioDescriptor {
        let match = try checkpointMatch(for: url)
        guard let (record, track) = match,
              record.segmentIndex == segment.index,
              record.sampleCount > 0, track.frameCount >= record.sampleCount,
              let role = recordingRole(track.role), track.sampleRate > 0,
              (1...2).contains(track.channelCount)
        else { throw ExportError.missingSource }
        return PlannerAudioDescriptor(
            role: role,
            url: url,
            urls: [url],
            range: SampleRange(startSample: record.startSample, sampleCount: record.sampleCount),
            sampleRate: track.sampleRate, channelCount: track.channelCount, mediaKind: mediaKind
        )
    }

    /// The first checkpoint sidecar in the file's directory that describes `url`.
    private static func checkpointMatch(
        for url: URL
    ) throws -> (record: RecordingCheckpointRecord, track: RecordingCheckpointRecord.Track)? {
        let sidecars = try FileManager.default.contentsOfDirectory(
            at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("checkpoint-") && $0.pathExtension == "json" }
        for sidecar in sidecars {
            guard let data = try? Data(contentsOf: sidecar),
                  let record = try? JSONDecoder().decode(RecordingCheckpointRecord.self, from: data),
                  let track = record.tracks.first(where: { $0.fileName == url.lastPathComponent })
            else { continue }
            return (record, track)
        }
        return nil
    }

    private static func publishedDescriptors(
        url: URL,
        segment: PublishedSegment,
        layout: AudioOutputLayout,
        mediaKind: PlannerAudioDescriptor.MediaKind
    ) throws -> [PlannerAudioDescriptor] {
        let roles = roles(for: url, segment: segment, layout: layout)
        guard !roles.isEmpty else { throw ExportError.missingSource }
        let audioInfo = inspectAudioFormat(url: url)
        return roles.map { role in
            plannerDescriptor(
                role: role, url: url, segment: segment, format: audioInfo, mediaKind: mediaKind
            )
        }
    }

    private static func recoveredDescriptors(
        url: URL,
        segment: PublishedSegment,
        layout: AudioOutputLayout,
        mediaKind: PlannerAudioDescriptor.MediaKind
    ) throws -> [PlannerAudioDescriptor] {
        let roles = roles(for: url, segment: segment, layout: layout)
        guard !roles.isEmpty, let audioInfo = readableAudioFormat(url: url) else {
            throw ExportError.missingSource
        }
        return roles.map { role in
            plannerDescriptor(
                role: role, url: url, segment: segment, format: audioInfo, mediaKind: mediaKind
            )
        }
    }

    private static func plannerDescriptor(
        role: RecordingTrackRole,
        url: URL,
        segment: PublishedSegment,
        format: (sampleRate: Int, channelCount: Int),
        mediaKind: PlannerAudioDescriptor.MediaKind
    ) -> PlannerAudioDescriptor {
        PlannerAudioDescriptor(
            role: role,
            url: url,
            urls: [url],
            range: SampleRange(startSample: segment.startSample, sampleCount: segment.sampleCount),
            sampleRate: format.sampleRate, channelCount: format.channelCount, mediaKind: mediaKind
        )
    }

    private static func inspectAudioFormat(url: URL) -> (sampleRate: Int, channelCount: Int) {
        DispatchQueue.global(qos: .utility).sync {
            guard let file = try? AVAudioFile(forReading: url) else {
                return (Int(sessionSampleRate), 2)
            }
            let rate = Int(file.processingFormat.sampleRate.rounded())
            let channels = Int(file.processingFormat.channelCount)
            return (rate > 0 ? rate : Int(sessionSampleRate), (1...2).contains(channels) ? channels : 2)
        }
    }

    /// Real format of a file that must be readable, or `nil` when it is not.
    ///
    /// Recovered media has no portable record to fall back on, so an unreadable
    /// file must be reported as a missing source instead of a guessed format.
    private static func readableAudioFormat(url: URL) -> (sampleRate: Int, channelCount: Int)? {
        DispatchQueue.global(qos: .utility).sync {
            guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }
            let rate = Int(file.processingFormat.sampleRate.rounded())
            let channels = Int(file.processingFormat.channelCount)
            guard rate > 0, (1...2).contains(channels) else { return nil }
            return (rate, channels)
        }
    }
}
