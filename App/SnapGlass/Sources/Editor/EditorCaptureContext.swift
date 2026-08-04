import AnnotationCore
import CoreGraphics

public struct EditorCaptureContext: Equatable, Sendable {
    let captureMode: String?
    let supportsVerticalTrim: Bool
    let startsInVerticalTrim: Bool

    public static let standard = EditorCaptureContext(
        captureMode: nil,
        supportsVerticalTrim: false,
        startsInVerticalTrim: false
    )

    init(image: CGImage, captureMode: String?) {
        let isScrollingCapture = captureMode == "scroll"
        self.captureMode = captureMode
        self.supportsVerticalTrim = LongImageEditingPolicy.supportsVerticalTrim(
            imageWidth: image.width,
            imageHeight: image.height,
            isScrollingCapture: isScrollingCapture
        )
        self.startsInVerticalTrim = isScrollingCapture
    }

    private init(
        captureMode: String?,
        supportsVerticalTrim: Bool,
        startsInVerticalTrim: Bool
    ) {
        self.captureMode = captureMode
        self.supportsVerticalTrim = supportsVerticalTrim
        self.startsInVerticalTrim = startsInVerticalTrim
    }
}
