import AVFoundation
import CoreGraphics
import ScreenCaptureKit
import Testing

@testable import CaptureCore

struct RecordingConfigurationTests {
    @Test func defaultsTo1080p30H264WithoutSystemAudio() {
        let configuration = RecordingConfiguration()

        #expect(configuration.codec == .h264)
        #expect(configuration.resolutionLimit == CGSize(width: 1_920, height: 1_080))
        #expect(configuration.frameRateLimit == 30)
        #expect(configuration.averageVideoBitrate == 8_000_000)
        #expect(!configuration.capturesSystemAudio)
    }

    @Test func activeConfigurationIsUnaffectedByLaterPreferenceChanges() {
        var preferredCodec = RecordingVideoCodec.h264
        var preferredResolution = CGSize(width: 1_920, height: 1_080)
        var preferredFrameRate = 30
        var preferredBitrate = 8_000_000
        var includesSystemAudio = false
        let sessionConfiguration = RecordingConfiguration(
            codec: preferredCodec,
            resolutionLimit: preferredResolution,
            frameRateLimit: preferredFrameRate,
            averageVideoBitrate: preferredBitrate,
            capturesSystemAudio: includesSystemAudio
        )

        preferredCodec = .hevc
        preferredResolution = CGSize(width: 3_840, height: 2_160)
        preferredFrameRate = 60
        preferredBitrate = 20_000_000
        includesSystemAudio = true

        #expect(sessionConfiguration == RecordingConfiguration(
            codec: .h264,
            resolutionLimit: CGSize(width: 1_920, height: 1_080),
            frameRateLimit: 30,
            averageVideoBitrate: 8_000_000,
            capturesSystemAudio: false
        ))
    }

    @Test func outputDimensionsCapWithoutUpscalingOrChangingAspectRatio() {
        let configuration = RecordingConfiguration()

        let smallerSource = CGSize(width: 1_280, height: 720)
        #expect(configuration.outputDimensions(for: smallerSource) == smallerSource)

        let oversizedSource = CGSize(width: 3_840, height: 2_160)
        #expect(configuration.outputDimensions(for: oversizedSource) == CGSize(width: 1_920, height: 1_080))

        let nonSixteenByNineSource = CGSize(width: 2_560, height: 1_600)
        let fittedSize = configuration.outputDimensions(for: nonSixteenByNineSource)
        #expect(fittedSize == CGSize(width: 1_728, height: 1_080))
        #expect(abs(fittedSize.width / fittedSize.height - nonSixteenByNineSource.width / nonSixteenByNineSource.height) < 0.001)
    }

    @Test func rejectsCodecUnavailableFromTheEncoder() {
        let configuration = RecordingConfiguration(codec: .hevc)

        #expect(throws: RecordingConfigurationError.self) {
            try configuration.validate(supportedCodecs: [.h264])
        }
    }

    @Test func validatesRecordingSettingsWithoutAssumingEncoderCapabilities() throws {
        try RecordingConfiguration(codec: .hevc).validate()
    }

    @Test func discoversOnlyCodecsAcceptedByTheWriterCapabilityProbe() {
        let configuration = RecordingConfiguration(codec: .hevc)

        let supportedCodecs = RecordingWriterSettings.supportedVideoCodecs(
            configuration: configuration,
            dimensions: CGSize(width: 1_920, height: 1_080)
        ) { settings in
            settings[AVVideoCodecKey] as? AVVideoCodecType == .hevc
        }

        #expect(supportedCodecs == [.hevc])
    }

    @Test func rejectsSystemAudioWhenAACFormatIsUnavailable() {
        let configuration = RecordingConfiguration(capturesSystemAudio: true)

        #expect(throws: RecordingConfigurationError.self) {
            try configuration.validate(supportedCodecs: [.h264], supportsAACSystemAudio: false)
        }
    }

    @Test func bitrateRecommendationScalesWithCodecPixelsAndFrameRate() {
        let hdSize = CGSize(width: 1_920, height: 1_080)
        let h264AtThirtyFPS = RecordingConfiguration.recommendedAverageVideoBitrate(
            codec: .h264,
            sourceDimensions: hdSize,
            frameRate: 30
        )
        let h264AtSixtyFPS = RecordingConfiguration.recommendedAverageVideoBitrate(
            codec: .h264,
            sourceDimensions: hdSize,
            frameRate: 60
        )
        let h264AtFourK = RecordingConfiguration.recommendedAverageVideoBitrate(
            codec: .h264,
            sourceDimensions: CGSize(width: 3_840, height: 2_160),
            frameRate: 30
        )
        let hevcAtThirtyFPS = RecordingConfiguration.recommendedAverageVideoBitrate(
            codec: .hevc,
            sourceDimensions: hdSize,
            frameRate: 30
        )

        #expect(h264AtThirtyFPS == 8_000_000)
        #expect(h264AtSixtyFPS > h264AtThirtyFPS)
        #expect(h264AtFourK > h264AtThirtyFPS)
        #expect(hevcAtThirtyFPS < h264AtThirtyFPS)
    }

    @Test func videoWriterSettingsUseTheSessionCodecDimensionsAndBitrate() {
        let configuration = RecordingConfiguration(
            codec: .hevc,
            resolutionLimit: CGSize(width: 1_280, height: 720),
            frameRateLimit: 60,
            averageVideoBitrate: 5_000_000
        )

        let settings = RecordingWriterSettings.videoOutputSettings(
            configuration: configuration,
            dimensions: CGSize(width: 1_280, height: 720)
        )
        let compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any]

        #expect(settings[AVVideoCodecKey] as? AVVideoCodecType == .hevc)
        #expect((settings[AVVideoWidthKey] as? NSNumber)?.intValue == 1_280)
        #expect((settings[AVVideoHeightKey] as? NSNumber)?.intValue == 720)
        #expect((compression?[AVVideoAverageBitRateKey] as? NSNumber)?.intValue == 5_000_000)
        #expect((compression?[AVVideoExpectedSourceFrameRateKey] as? NSNumber)?.intValue == 60)
    }

    @Test func systemAudioWriterSettingsUseAacAtTheSpecifiedDefaultFormat() {
        let settings = RecordingWriterSettings.audioOutputSettings()

        #expect((settings[AVSampleRateKey] as? NSNumber)?.intValue == 48_000)
        #expect((settings[AVNumberOfChannelsKey] as? NSNumber)?.intValue == 2)
        #expect((settings[AVEncoderBitRateKey] as? NSNumber)?.intValue == 128_000)
    }

    @Test func streamSettingsApplyFrameRateScalingAndOptionalSystemAudio() {
        let configuration = RecordingConfiguration(
            frameRateLimit: 60,
            capturesSystemAudio: true
        )

        let streamConfiguration = RecordingStreamSettings.make(
            configuration: configuration,
            sourceDimensions: CGSize(width: 3_840, height: 2_160)
        )

        #expect(streamConfiguration.width == 1_920)
        #expect(streamConfiguration.height == 1_080)
        #expect(CMTimeGetSeconds(streamConfiguration.minimumFrameInterval) == 1.0 / 60.0)
        #expect(streamConfiguration.queueDepth == 3)
        #expect(streamConfiguration.capturesAudio)
        #expect(streamConfiguration.sampleRate == 48_000)
        #expect(streamConfiguration.channelCount == 2)
    }

    @Test func regionSourceUsesCoordinatesLocalToItsSelectedDisplay() {
        let source = RecordingSource.makeRegion(
            displayID: 12,
            quartzRect: CGRect(x: 2_020, y: 100, width: 800, height: 600),
            displayFrame: CGRect(x: 1_920, y: 0, width: 2_560, height: 1_440)
        )

        #expect(source == .region(displayID: 12, sourceRect: CGRect(x: 100, y: 100, width: 800, height: 600)))
    }

    @Test func regionSourceRejectsRectanglesOutsideOneDisplay() {
        let source = RecordingSource.makeRegion(
            displayID: 12,
            quartzRect: CGRect(x: 900, y: 100, width: 200, height: 100),
            displayFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
        )

        #expect(source == nil)
    }
}
