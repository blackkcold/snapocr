import CoreGraphics

extension OCRLine {
    /// Returns the editor-space box. The AppKit canvas and Core Graphics
    /// renderer both use a bottom-left origin, matching Vision coordinates.
    public var editorBoundingBox: CGRect {
        boundingBox
    }
}
