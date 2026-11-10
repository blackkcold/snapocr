import AnnotationCore
import CaptureCore
import CoreGraphics
import Foundation

public struct EditorCaptureContext: Equatable, Sendable {
    let captureMode: String?
    let supportsVerticalTrim: Bool
    let startsInVerticalTrim: Bool
    var sourceEntryID: UUID?
    var mockupStyle: MockupStyle?

    public static let standard = EditorCaptureContext(
        captureMode: nil,
        supportsVerticalTrim: false,
        startsInVerticalTrim: false
    )

    public static func capture(
        image: CGImage,
        captureMode: String?,
        sourceEntryID: UUID? = nil,
        mockupStyle: MockupStyle? = nil
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
            sourceEntryID: sourceEntryID,
            mockupStyle: mockupStyle
        )
    }

    init(image: CGImage, captureMode: String?) {
        self = .capture(image: image, captureMode: captureMode)
    }

    init(
        captureMode: String?,
        supportsVerticalTrim: Bool,
        startsInVerticalTrim: Bool,
        sourceEntryID: UUID? = nil,
        mockupStyle: MockupStyle? = nil
    ) {
        self.captureMode = captureMode
        self.supportsVerticalTrim = supportsVerticalTrim
        self.startsInVerticalTrim = startsInVerticalTrim
        self.sourceEntryID = sourceEntryID
        self.mockupStyle = mockupStyle
    }
}
