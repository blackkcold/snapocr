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
    @AppStorage(PreferenceKeys.screenshotShelfEnabled)
    private var screenshotShelfEnabled = PreferenceDefaults.screenshotShelfEnabled
    @AppStorage(PreferenceKeys.screenshotShelfCount)
    private var screenshotShelfCount = PreferenceDefaults.screenshotShelfCount
    @AppStorage(PreferenceKeys.screenshotShelfCardHeight)
    private var screenshotShelfCardHeight = PreferenceDefaults.screenshotShelfCardHeight
    @AppStorage(PreferenceKeys.screenshotShelfImageOpacity)
    private var screenshotShelfImageOpacity = PreferenceDefaults.screenshotShelfImageOpacity
    @AppStorage(PreferenceKeys.screenshotShelfAnchor)
    private var screenshotShelfAnchorRaw = PreferenceDefaults.screenshotShelfAnchor
    @AppStorage(PreferenceKeys.screenshotShelfCollapseToRail)
    private var screenshotShelfCollapseToRail = PreferenceDefaults.screenshotShelfCollapseToRail

    private var screenshotShelfAnchor: Binding<ScreenshotShelfAnchor> {
        Binding(
            get: { ScreenshotShelfAnchor(rawValue: screenshotShelfAnchorRaw) ?? .top },
            set: { screenshotShelfAnchorRaw = $0.rawValue }
        )
    }

    var body: some View {
        ScrollView {
            PreferencesCardGrid {
                screenshotShelfCard
                afterCaptureCard

                imageCard
            }
        }
    }

    private var screenshotShelfCard: some View {
        PreferencesCard {
            PreferencesCardHeader(systemImage: "rectangle.stack", title: "Screenshot Shelf")

            Toggle("Enable screenshot shelf", isOn: $screenshotShelfEnabled)

            Stepper(
                "Number of screenshots: \(screenshotShelfCount)",
                value: $screenshotShelfCount,
                in: 1...6
            )
            .disabled(!screenshotShelfEnabled)

            VStack(alignment: .leading) {
                LabeledContent("Card height") {
                    Text(screenshotShelfCardHeight, format: .number.precision(.fractionLength(0)))
                        .monospacedDigit()
                }
                Slider(value: $screenshotShelfCardHeight, in: 64...160, step: 4)
            }
            .disabled(!screenshotShelfEnabled)

            VStack(alignment: .leading) {
                LabeledContent("Image opacity") {
                    Text(screenshotShelfImageOpacity, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                }
                Slider(value: $screenshotShelfImageOpacity, in: 0.2...1, step: 0.05)
            }
            .disabled(!screenshotShelfEnabled)

            VStack(alignment: .leading, spacing: 8) {
                Text("Position")
                    .font(.subheadline.weight(.medium))
                ShelfPositionPicker(selection: screenshotShelfAnchor)
            }
            .disabled(!screenshotShelfEnabled)

            Toggle("Collapse to rail when idle", isOn: $screenshotShelfCollapseToRail)
                .disabled(!screenshotShelfEnabled)

            PreferencesCardCaption(
                text: "The rail tab stays visible; move the pointer to it to expand again."
            )
            PreferencesCardCaption(
                text: "The shelf hangs below the menu bar by default. Drag thumbnails to reorder."
            )
            PreferencesCardCaption(
                text: "Shelf items are kept only for the current session unless saved to History."
            )
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
                text: """
                    Static snapshot freezes the screen when selection starts; \
                    selection is canceled if a screen cannot be captured.
                    """
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
