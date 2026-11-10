import AVFoundation
import AudioToolbox
import CoreGraphics
import Foundation

/// Video codecs supported by SnapGlass MP4 recordings.
public enum RecordingVideoCodec: String, CaseIterable, Hashable, Sendable {
    /// H.264 video encoding.
    case h264
    /// HEVC video encoding.
    case hevc
}

/// Errors raised when a recording configuration cannot be used.
public enum RecordingConfigurationError: Error, Equatable, Sendable {
    /// The requested codec is unavailable from the active encoder.
    case unsupportedCodec
    /// AAC system audio is unavailable for the requested recording.
    case unsupportedSystemAudioFormat
    /// A bitrate, frame rate, or output-size limit is invalid.
    case invalidConfiguration
}

/// Immutable settings captured when a recording session starts.
public struct RecordingConfiguration: Equatable, Sendable {
    /// Video codec written to the MP4 container.
    public let codec: RecordingVideoCodec
    /// Maximum encoded dimensions, in pixels.
    public let resolutionLimit: CGSize
    /// Maximum video frame rate, in frames per second.
    public let frameRateLimit: Int
    /// Target average video bitrate, in bits per second.
    public let averageVideoBitrate: Int
    /// Whether system audio is included in the recording.
    public let capturesSystemAudio: Bool

    /// Creates an immutable recording configuration.
    ///
    /// - Parameters:
    ///   - codec: Video codec; defaults to H.264.
    ///   - resolutionLimit: Maximum encoded pixel dimensions; defaults to 1920×1080.
    ///   - frameRateLimit: Maximum frames per second; defaults to 30.
    ///   - averageVideoBitrate: Target video bitrate; defaults to 8 Mbps.
    ///   - capturesSystemAudio: Whether to capture AAC system audio; defaults to `false`.
    public init(
        codec: RecordingVideoCodec = .h264,
        resolutionLimit: CGSize = CGSize(width: 1_920, height: 1_080),
        frameRateLimit: Int = 30,
        averageVideoBitrate: Int = 8_000_000,
        capturesSystemAudio: Bool = false
    ) {
        self.codec = codec
        self.resolutionLimit = resolutionLimit
        self.frameRateLimit = frameRateLimit
        self.averageVideoBitrate = averageVideoBitrate
        self.capturesSystemAudio = capturesSystemAudio
    }

    /// Fits source dimensions inside the configured limit without upscaling.
    ///
    /// Invalid or non-finite dimensions return `.zero`.
    public func outputDimensions(for sourceDimensions: CGSize) -> CGSize {
        guard sourceDimensions.width.isFinite,
              sourceDimensions.height.isFinite,
              resolutionLimit.width.isFinite,
              resolutionLimit.height.isFinite,
              sourceDimensions.width > 0,
              sourceDimensions.height > 0,
              resolutionLimit.width > 0,
              resolutionLimit.height > 0 else {
            return .zero
        }

        let scale = min(
            1,
            resolutionLimit.width / sourceDimensions.width,
            resolutionLimit.height / sourceDimensions.height
        )
        return CGSize(
            width: sourceDimensions.width * scale,
            height: sourceDimensions.height * scale
        )
    }

    func validatedEvenOutputDimensions(for sourceDimensions: CGSize) -> CGSize? {
        let fittedDimensions = outputDimensions(for: sourceDimensions)
        let width = (fittedDimensions.width / 2).rounded(.down) * 2
        let height = (fittedDimensions.height / 2).rounded(.down) * 2

        guard fittedDimensions.width.isFinite,
              fittedDimensions.height.isFinite,
              width.isFinite,
              height.isFinite,
              width >= 2,
              height >= 2,
              width < CGFloat(Int.max),
              height < CGFloat(Int.max),
              width <= sourceDimensions.width,
              height <= sourceDimensions.height,
              width <= resolutionLimit.width,
              height <= resolutionLimit.height else {
            return nil
        }

        return CGSize(width: width, height: height)
    }

    /// Validates the requested settings against the capabilities of an encoder.
    ///
    /// - Parameters:
    ///   - supportedCodecs: Video codecs accepted by the active MP4 encoder.
    ///   - supportsAACSystemAudio: Whether AAC system-audio output is available.
    /// - Throws: `RecordingConfigurationError` when a setting is unsupported or invalid.
    public func validate(
        supportedCodecs: Set<RecordingVideoCodec>,
        supportsAACSystemAudio: Bool = true
    ) throws {
        try validate(supportsAACSystemAudio: supportsAACSystemAudio)
        guard supportedCodecs.contains(codec) else {
            throw RecordingConfigurationError.unsupportedCodec
        }
    }

    /// Validates recording settings without assuming which video codecs the active encoder supports.
    ///
    /// - Parameter supportsAACSystemAudio: Whether AAC system-audio output is available.
    /// - Throws: `RecordingConfigurationError` when the settings are invalid or unsupported.
    public func validate(supportsAACSystemAudio: Bool = true) throws {
        guard resolutionLimit.width.isFinite,
              resolutionLimit.height.isFinite,
              resolutionLimit.width > 0,
              resolutionLimit.height > 0,
              frameRateLimit > 0,
              averageVideoBitrate > 0 else {
            throw RecordingConfigurationError.invalidConfiguration
        }
        guard !capturesSystemAudio || supportsAACSystemAudio else {
            throw RecordingConfigurationError.unsupportedSystemAudioFormat
        }
    }

    /// Recommends an average bitrate based on codec, pixel count, and frame rate.
    ///
    /// The H.264 baseline is 8 Mbps at 1920×1080 and 30 fps; HEVC uses half that
    /// baseline. Invalid inputs return zero.
    public static func recommendedAverageVideoBitrate(
        codec: RecordingVideoCodec,
        sourceDimensions: CGSize,
        frameRate: Int
    ) -> Int {
        guard sourceDimensions.width.isFinite,
              sourceDimensions.height.isFinite,
              sourceDimensions.width > 0,
              sourceDimensions.height > 0,
              frameRate > 0 else {
            return 0
        }

        let baseline: Double = codec == .h264 ? 8_000_000 : 4_000_000
        let pixelScale = Double(sourceDimensions.width * sourceDimensions.height) / Double(1_920 * 1_080)
        let frameRateScale = Double(frameRate) / 30
        let recommended = baseline * pixelScale * frameRateScale
        guard recommended.isFinite else { return Int.max }
        return Int(min(recommended.rounded(), Double(Int.max)))
    }
}

/// One display, one window, or one rectangle contained by one display.
public enum RecordingSource: Equatable, Sendable {
    /// Captures one display by its ScreenCaptureKit display identifier.
    case display(displayID: CGDirectDisplayID)
    /// Captures one window by its Core Graphics window identifier.
    case window(windowID: CGWindowID)
    /// Captures a display-local rectangle whose origin is at the display's top-left.
    case region(displayID: CGDirectDisplayID, sourceRect: CGRect)

    /// Converts a Quartz global rectangle into a source rectangle local to one display.
    ///
    /// Cross-display and out-of-bounds rectangles are rejected.
    ///
    /// - Parameters:
    ///   - displayID: Identifier of the display that owns the region.
    ///   - quartzRect: Region in Quartz global coordinates.
    ///   - displayFrame: Selected display bounds in the same Quartz coordinate space.
    /// - Returns: A display-local region source, or `nil` for an invalid rectangle.
    public static func makeRegion(
        displayID: CGDirectDisplayID,
        quartzRect: CGRect,
        displayFrame: CGRect
    ) -> RecordingSource? {
        guard isFinite(quartzRect), isFinite(displayFrame) else { return nil }
        let region = quartzRect.standardized
        let display = displayFrame.standardized
        guard region.width > 0,
              region.height > 0,
              display.width > 0,
              display.height > 0,
              display.contains(region) else {
            return nil
        }

        return .region(
            displayID: displayID,
            sourceRect: CGRect(
                x: region.minX - display.minX,
                y: region.minY - display.minY,
                width: region.width,
                height: region.height
            )
        )
    }

    private static func isFinite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
    }
}

enum RecordingWriterSettings {
    static func supportedVideoCodecs(
        configuration: RecordingConfiguration,
        dimensions: CGSize,
        canApply: ([String: Any]) -> Bool
    ) -> Set<RecordingVideoCodec> {
        Set(RecordingVideoCodec.allCases.filter { codec in
            let settings = videoOutputSettings(
                configuration: configuration,
                dimensions: dimensions,
                codec: codec
            )
            return canApply(settings)
        })
    }

    static func videoOutputSettings(
        configuration: RecordingConfiguration,
        dimensions: CGSize,
        codec: RecordingVideoCodec? = nil
    ) -> [String: Any] {
        [
            AVVideoCodecKey: (codec ?? configuration.codec).avFoundationCodec,
            AVVideoWidthKey: NSNumber(value: Int(dimensions.width.rounded())),
            AVVideoHeightKey: NSNumber(value: Int(dimensions.height.rounded())),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: NSNumber(value: configuration.averageVideoBitrate),
                AVVideoExpectedSourceFrameRateKey: NSNumber(value: configuration.frameRateLimit),
            ],
        ]
    }

    static func audioOutputSettings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: NSNumber(value: 48_000),
            AVNumberOfChannelsKey: NSNumber(value: 2),
            AVEncoderBitRateKey: NSNumber(value: 128_000),
        ]
    }
}

private extension RecordingVideoCodec {
    var avFoundationCodec: AVVideoCodecType {
        switch self {
        case .h264:
            .h264
        case .hevc:
            .hevc
        }
    }
}
