import AnnotationCore
import CaptureCore
import CoreGraphics
import Foundation

/// Capture-time identity and presentation carried into an editor session.
///
/// The context records which capture produced the image, whether the image may
/// be trimmed vertically as a long screenshot, and the history entry and mockup
/// style the tab opened with. A tab keeps its context current as the history
/// write finishes and the share style changes.
public struct EditorCaptureContext: Equatable, Sendable {
    let captureMode: String?
    let supportsVerticalTrim: Bool
    let startsInVerticalTrim: Bool
    var sourceEntryID: UUID?
    var mockupStyle: MockupStyle?

    /// A context for an image that did not come from a capture, such as a dropped file.
    public static let standard = EditorCaptureContext(
        captureMode: nil,
        supportsVerticalTrim: false,
        startsInVerticalTrim: false
    )

    /// Builds the context for a captured image from its mode and dimensions.
    ///
    /// Scrolling captures open in vertical trim; other images support it only
    /// when they are long enough for the long-image workflow.
    ///
    /// - Parameters:
    ///   - image: The captured image, used to decide whether vertical trim applies.
    ///   - captureMode: The mode string from the capture, such as `"window"` or `"scroll"`.
    ///   - sourceEntryID: The history entry that will receive the edits, when one exists.
    ///   - mockupStyle: The share appearance selected at capture time, if any.
    /// - Returns: A context describing this capture.
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
