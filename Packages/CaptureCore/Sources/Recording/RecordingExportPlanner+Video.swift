import AVFoundation
import CoreMedia
import Foundation

// MARK: Video passthrough inspection

/// The video extent a passthrough export can reuse.
struct VideoRangeInspection: Sendable {
    let codec: String
    let range: ExportTimeRange
    let effective: SampleRange
}

extension RecordingExportPlanner {
    /// Timing facts gathered while scanning a video track's samples.
    private struct VideoPacketScan {
        var startKeyframe: CMTime?
        var endTime: CMTime?
        var codec: String?
        var sampleCount = 0
    }

    /// Track times for the requested sample range.
    private struct VideoRequestBounds {
        let start: CMTime
        let end: CMTime
        let trackEnd: CMTime
    }

    /// Shared reader and request bounds for one packet scan.
    private struct VideoScanContext {
        let reader: AVAssetReader
        let requestedStart: CMTime
        let requestedEnd: CMTime
    }

    /// Validated packet bounds for one requested range.
    private struct VideoScanResult {
        let codec: String
        let startKeyframe: CMTime
        let endTime: CMTime
    }

    static func inspectVideoRange(
        url: URL,
        trackIndex: Int,
        segmentStartSample: Int64,
        segmentSampleCount: Int64,
        requested: SampleRange
    ) throws -> VideoRangeInspection {
        try DispatchQueue.global(qos: .userInitiated).sync {
            let asset = AVURLAsset(url: url)
            let track = try videoTrack(of: asset, index: trackIndex)
            let bounds = try videoRequestBounds(
                track: track, segmentStartSample: segmentStartSample, requested: requested
            )
            let scan = try scanVideoPackets(asset: asset, track: track, bounds: bounds)
            return try videoInspection(
                scan: scan, track: track, segmentStartSample: segmentStartSample,
                segmentSampleCount: segmentSampleCount, requested: requested
            )
        }
    }

    private static func videoTrack(of asset: AVAsset, index: Int) throws -> AVAssetTrack {
        let tracks = asset.tracks(withMediaType: .video)
        guard index >= 0, index < tracks.count else { throw ExportError.passthroughUnsupported }
        let track = tracks[index]
        guard track.timeRange.isValid, track.timeRange.duration.isValid,
            track.timeRange.duration.seconds.isFinite, track.timeRange.duration.seconds > 0
        else { throw ExportError.passthroughUnsupported }
        return track
    }

    /// Translates the requested sample range into track time.
    private static func videoRequestBounds(
        track: AVAssetTrack,
        segmentStartSample: Int64,
        requested: SampleRange
    ) throws -> VideoRequestBounds {
        let requestedStart = CMTimeAdd(
            track.timeRange.start,
            CMTime(
                value: requested.startSample - segmentStartSample,
                timescale: CMTimeScale(sessionSampleRate)
            )
        )
        let requestedEnd = CMTimeAdd(
            track.timeRange.start,
            CMTime(
                value: requested.sampleCount + requested.startSample - segmentStartSample,
                timescale: CMTimeScale(sessionSampleRate)
            )
        )
        let trackEnd = CMTimeRangeGetEnd(track.timeRange)
        guard CMTimeCompare(requestedStart, track.timeRange.start) >= 0,
            CMTimeCompare(requestedEnd, trackEnd) <= 0
        else { throw ExportError.passthroughUnsupported }
        return VideoRequestBounds(start: requestedStart, end: requestedEnd, trackEnd: trackEnd)
    }

    /// Reads every sample packet once, collecting keyframe, end time, and codec.
    private static func scanVideoPackets(
        asset: AVAsset,
        track: AVAssetTrack,
        bounds: VideoRequestBounds
    ) throws -> VideoScanResult {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { throw ExportError.passthroughUnsupported }
        reader.add(output)
        guard reader.startReading() else { throw ExportError.passthroughUnsupported }
        let context = VideoScanContext(
            reader: reader, requestedStart: bounds.start, requestedEnd: bounds.end
        )
        var scan = VideoPacketScan()
        while let sample = output.copyNextSampleBuffer() {
            try consumeVideoSample(sample, context: context, scan: &scan)
        }
        guard reader.status == .completed, scan.sampleCount > 0,
            let startKeyframe = scan.startKeyframe, let endTime = scan.endTime,
            let codec = scan.codec,
            CMTimeCompare(endTime, bounds.end) >= 0,
            CMTimeCompare(endTime, bounds.trackEnd) <= 0
        else { throw ExportError.passthroughUnsupported }
        guard codec == "h264" || codec == "hevc" else { throw ExportError.passthroughUnsupported }
        return VideoScanResult(codec: codec, startKeyframe: startKeyframe, endTime: endTime)
    }

    private static func consumeVideoSample(
        _ sample: CMSampleBuffer,
        context: VideoScanContext,
        scan: inout VideoPacketScan
    ) throws {
        if scan.codec == nil, let format = CMSampleBufferGetFormatDescription(sample) {
            scan.codec = videoCodecName(CMFormatDescriptionGetMediaSubType(format))
        }
        let count = CMSampleBufferGetNumSamples(sample)
        guard count > 0 else { return }
        var needed: CMItemCount = 0
        var timings = Array(
            repeating: CMSampleTimingInfo(
                duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid
            ),
            count: count
        )
        let timingStatus = CMSampleBufferGetSampleTimingInfoArray(
            sample, entryCount: count, arrayToFill: &timings, entriesNeededOut: &needed
        )
        guard timingStatus == noErr, needed == count else {
            context.reader.cancelReading()
            throw ExportError.passthroughUnsupported
        }
        let attachments =
            CMSampleBufferGetSampleAttachmentsArray(
                sample, createIfNecessary: false
            ) as? [[CFString: Any]]
        for index in 0..<count {
            try consumeVideoTiming(
                timings[index], attachments: attachments, index: index,
                context: context, scan: &scan
            )
        }
    }

    private static func consumeVideoTiming(
        _ timing: CMSampleTimingInfo,
        attachments: [[CFString: Any]]?,
        index: Int,
        context: VideoScanContext,
        scan: inout VideoPacketScan
    ) throws {
        guard timing.presentationTimeStamp.isValid, timing.decodeTimeStamp.isValid else {
            context.reader.cancelReading()
            throw ExportError.passthroughUnsupported
        }
        if !isNotSync(attachments: attachments, index: index),
            CMTimeCompare(timing.presentationTimeStamp, context.requestedStart) <= 0,
            scan.startKeyframe.map({ CMTimeCompare(timing.presentationTimeStamp, $0) > 0 }) ?? true
        {
            scan.startKeyframe = timing.presentationTimeStamp
        }
        if CMTimeCompare(timing.presentationTimeStamp, context.requestedEnd) < 0 {
            recordSampleEnd(timing, scan: &scan)
        }
        scan.sampleCount += 1
    }

    private static func isNotSync(attachments: [[CFString: Any]]?, index: Int) -> Bool {
        guard let attachments, attachments.indices.contains(index) else { return false }
        return attachments[index][kCMSampleAttachmentKey_NotSync] as? Bool ?? false
    }

    private static func recordSampleEnd(_ timing: CMSampleTimingInfo, scan: inout VideoPacketScan) {
        let duration = timing.duration.isValid && timing.duration.value > 0 ? timing.duration : .zero
        let sampleEnd = CMTimeAdd(timing.presentationTimeStamp, duration)
        guard sampleEnd.isValid,
            scan.endTime.map({ CMTimeCompare(sampleEnd, $0) > 0 }) ?? true
        else { return }
        scan.endTime = sampleEnd
    }

    /// Converts scanned packet times into the sample range the export may reuse.
    private static func videoInspection(
        scan: VideoScanResult,
        track: AVAssetTrack,
        segmentStartSample: Int64,
        segmentSampleCount: Int64,
        requested: SampleRange
    ) throws -> VideoRangeInspection {
        let startOffset = CMTimeSubtract(scan.startKeyframe, track.timeRange.start).seconds
        let endOffset = CMTimeSubtract(scan.endTime, track.timeRange.start).seconds
        guard startOffset.isFinite, endOffset.isFinite, endOffset > startOffset else {
            throw ExportError.passthroughUnsupported
        }
        let rawStart = segmentStartSample + Int64(floor(startOffset * Double(sessionSampleRate)))
        let rawEnd = segmentStartSample + Int64(ceil(endOffset * Double(sessionSampleRate)))
        let segmentEnd = segmentStartSample + segmentSampleCount
        let effectiveStart = max(segmentStartSample, rawStart)
        let effectiveEnd = min(segmentEnd, rawEnd)
        guard effectiveEnd > effectiveStart,
            effectiveStart <= requested.startSample,
            effectiveEnd >= requested.sampleCount + requested.startSample
        else { throw ExportError.passthroughUnsupported }
        let duration = CMTimeSubtract(scan.endTime, scan.startKeyframe)
        guard duration.isValid, duration.value > 0, duration.timescale > 0 else {
            throw ExportError.passthroughUnsupported
        }
        return VideoRangeInspection(
            codec: scan.codec,
            range: ExportTimeRange(
                startValue: scan.startKeyframe.value, startTimescale: scan.startKeyframe.timescale,
                durationValue: duration.value, durationTimescale: duration.timescale
            ),
            effective: SampleRange(startSample: effectiveStart, sampleCount: effectiveEnd - effectiveStart)
        )
    }

    private static func videoCodecName(_ subtype: FourCharCode) -> String? {
        switch subtype {
        case kCMVideoCodecType_H264: return "h264"
        case kCMVideoCodecType_HEVC: return "hevc"
        default: return nil
        }
    }
}
