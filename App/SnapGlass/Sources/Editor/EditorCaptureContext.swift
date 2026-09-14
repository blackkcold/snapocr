import AnnotationCore
import CoreGraphics
import Foundation

public struct EditorCaptureContext: Equatable, Sendable {
    let captureMode: String?
    let supportsVerticalTrim: Bool
    let startsInVerticalTrim: Bool
    let sourceEntryID: UUID?

    public static let standard = EditorCaptureContext(
        captureMode: nil,
        supportsVerticalTrim: false,
        startsInVerticalTrim: false
    )

    public static func capture(
        image: CGImage, captureMode: String?, sourceEntryID: UUID? = nil
    ) -> EditorCaptureContext {
        let isScrollingCapture = captureMode == "scroll"
        return EditorCaptureContext(
            captureMode: captureMode,
            supportsVerticalTrim: LongImageEditingPolicy.supportsVerticalTrim(
                imageWidth: image.width,
                imageHeight: image.height,
                isScrollingCapture: isScrollingCapture
            ),
            startsInVerticalTrim: isScrollingCapture,
            sourceEntryID: sourceEntryID
        )
    }

    init(image: CGImage, captureMode: String?) {
        self = .capture(image: image, captureMode: captureMode)
    }

    init(
        captureMode: String?,
        supportsVerticalTrim: Bool,
        startsInVerticalTrim: Bool,
        sourceEntryID: UUID? = nil
    ) {
        self.captureMode = captureMode
        self.supportsVerticalTrim = supportsVerticalTrim
        self.startsInVerticalTrim = startsInVerticalTrim
        self.sourceEntryID = sourceEntryID
    }
}
