import SharedKit
import SwiftUI

struct CapturePreferencesView: View {
    @AppStorage(PreferenceKeys.captureOpenEditor)
    private var openEditor = PreferenceDefaults.captureOpenEditor
    @AppStorage(PreferenceKeys.captureCopyToClipboard)
    private var copyToClipboard = PreferenceDefaults.captureCopyToClipboard
    @AppStorage(PreferenceKeys.captureIncludeCursor)
    private var includeCursor = PreferenceDefaults.captureIncludeCursor
    @AppStorage(PreferenceKeys.captureAutoOCR)
    private var autoOCR = PreferenceDefaults.captureAutoOCR
    @AppStorage(PreferenceKeys.captureCopyOCRText)
    private var copyOCRText = PreferenceDefaults.captureCopyOCRText
    @AppStorage(PreferenceKeys.captureSelectionStyle)
    private var selectionStyle = PreferenceDefaults.captureSelectionStyle
    @AppStorage(PreferenceKeys.captureOverlayMode)
    private var overlayMode = PreferenceDefaults.captureOverlayMode
    @AppStorage(PreferenceKeys.captureHighResolution)
    private var highResolution = PreferenceDefaults.captureHighResolution
    @AppStorage(PreferenceKeys.captureImageFormat)
    private var imageFormat = PreferenceDefaults.captureImageFormat
    @AppStorage(PreferenceKeys.captureJPEGQuality)
    private var jpegQuality = PreferenceDefaults.captureJPEGQuality
    @AppStorage(PreferenceKeys.pickerDominantColorCount)
    private var pickerDominantColorCount = PreferenceDefaults.pickerDominantColorCount

    var body: some View {
        ScrollView {
            PreferencesCardGrid {
                afterCaptureCard

                imageCard
            }
        }
    }

    private var afterCaptureCard: some View {
        PreferencesCard {
            PreferencesCardHeader(systemImage: "camera.viewfinder", title: "After Capture")

            PreferencesCardCaption(
                text: """
                Area captures ask whether to copy or edit when you confirm the selection. \
                These settings apply to window, fullscreen, and scrolling captures.
                """
            )

            Toggle("Open annotation editor", isOn: $openEditor)
            TextEntryPreferencesView()
            Toggle("Copy image to clipboard", isOn: $copyToClipboard)
            Toggle("Run OCR automatically", isOn: $autoOCR)
            Toggle("Replace clipboard with recognized text", isOn: $copyOCRText)
                .disabled(!autoOCR)
                .help("When enabled, recognized text is copied automatically after capture.")
        }
    }

    private var imageCard: some View {
        PreferencesCard {
            PreferencesCardHeader(systemImage: "photo", title: "Image")

            Toggle("Include pointer", isOn: $includeCursor)
            Toggle("Native Retina resolution", isOn: $highResolution)

            Picker("Selection style", selection: $selectionStyle) {
                Text("Rectangle").tag(CaptureSelectionStyle.rectangle.rawValue)
                Text("Freeform").tag(CaptureSelectionStyle.freeform.rawValue)
            }
            .pickerStyle(.segmented)

            Picker("Overlay preview", selection: $overlayMode) {
                Text("Live screen").tag(CaptureOverlayMode.live.rawValue)
                Text("Static snapshot").tag(CaptureOverlayMode.snapshot.rawValue)
            }
            .pickerStyle(.segmented)

            PreferencesCardCaption(
                text: "Static snapshot freezes the screen when selection starts; unavailable screens appear black."
            )

            Picker("Saved image format", selection: $imageFormat) {
                Text("PNG (lossless)").tag(ImageFileFormat.png.rawValue)
                Text("JPEG (smaller)").tag(ImageFileFormat.jpeg.rawValue)
            }
            .pickerStyle(.menu)

            Picker("Number of dominant colors", selection: $pickerDominantColorCount) {
                ForEach(3...6, id: \.self) { count in
                    Text("\(count)").tag(count)
                }
            }
            .pickerStyle(.menu)

            if imageFormat == ImageFileFormat.jpeg.rawValue {
                VStack(alignment: .leading) {
                    LabeledContent("JPEG quality") {
                        Text(jpegQuality, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                    }
                    Slider(value: $jpegQuality, in: 0.5...1, step: 0.05)
                }
            }

            PreferencesCardCaption(text: "Freeform captures always use PNG to preserve transparency.")
        }
    }
}
