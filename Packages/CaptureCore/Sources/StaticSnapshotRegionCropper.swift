import CoreGraphics

/// Crops a selected region directly from the frame used by the static overlay.
public enum StaticSnapshotRegionCropper {
  /// Returns the original snapshot pixels inside a Quartz-coordinate region.
  ///
  /// The output is cropped at the source frame's actual pixel scale and is not
  /// resized. Invalid or cross-display regions throw `CaptureError.invalidRegion`.
  public static func crop(
    from snapshot: CGImage,
    areaRect: CGRect,
    displayFrame: CGRect
  ) throws -> CGImage {
    guard
      let pixelRect = RegionPixelMapping.pixelCropRect(
        areaRect: areaRect,
        displayFrame: displayFrame,
        imageSize: CGSize(width: snapshot.width, height: snapshot.height)
      )
    else {
      throw CaptureError.invalidRegion
    }
    guard let croppedImage = snapshot.cropping(to: pixelRect) else {
      throw CaptureError.invalidRegion
    }
    return croppedImage
  }
}
