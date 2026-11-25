import CaptureCore
import Foundation
import SwiftUI

extension RecordingExportView {
    func outputModeTitle(_ mode: RecordingExportOutputMode) -> Text {
        switch mode {
        case .mp4Video: Text("MP4 video")
        case .mixedAudio: Text("Mixed audio")
        case .separatedAudio: Text("Audio tracks")
        }
    }

    func localizedSummaryLabel(_ label: String) -> Text {
        Text(LocalizedStringKey(label))
    }

    func disabledReasonText(_ reason: ExportDisabledReason) -> String {
        switch reason {
        case .emptySelection:
            AppLocalization.string("Select one or more published segments to export.")
        case .overLimit(let seconds):
            AppLocalization.string("Export exceeds the 1:59:30 limit by %@.", Self.duration(seconds))
        case .incompatibleCodec:
            AppLocalization.string(
                "Selected video segments use incompatible codecs. Export them separately or choose audio-only."
            )
        case .missingSource:
            AppLocalization.string(
                "A selected source is unavailable. Use Locate to inspect the recording folder or deselect that segment."
            )
        case .destinationUnavailable:
            AppLocalization.string("Choose an existing writable destination folder and a valid output name.")
        case .passthroughUnsupported:
            AppLocalization.string("Video passthrough cannot preserve this trim. Adjust the trim or choose audio-only.")
        }
    }

    func messageText(_ message: RecordingExportViewMessage) -> String {
        switch message {
        case .listingFailed:
            return AppLocalization.string("Could not read completed recordings from the configured recording folder.")
        case .sessionUnavailable:
            return AppLocalization.string(
                "This recording is no longer available. Refresh the session list and try again."
            )
        case .previewUnavailable:
            return AppLocalization.string(
                "This segment is not available for preview. Use Locate to inspect the recording folder."
            )
        case .previewFailed:
            return AppLocalization.string("Audio preview could not be started.")
        case .export(let error):
            return exportErrorText(error)
        case .recoveryScanFailed:
            return AppLocalization.string("Could not check for unfinished recordings.")
        case .recoveryFailed:
            return AppLocalization.string("Could not save this recording. The original folder was kept.")
        case .discardFailed:
            return AppLocalization.string("Could not move this recording to the Trash. The recording was kept.")
        }
    }

    func exportErrorText(_ error: ExportError) -> String {
        switch error {
        case .emptySelection:
            return AppLocalization.string("Select one or more published segments to export.")
        case .overLimit(let seconds):
            return AppLocalization.string("Export exceeds the 1:59:30 limit by %@.", Self.duration(seconds))
        case .incompatibleCodec:
            return AppLocalization.string(
                "Selected video segments use incompatible codecs. Export them separately or choose audio-only."
            )
        case .missingSource:
            return AppLocalization.string(
                // swiftlint:disable:next line_length
                "A selected source is unavailable. The original recording was kept; use Locate or choose another segment."
            )
        case .destinationUnavailable:
            return AppLocalization.string(
                "The destination is unavailable. The original recording was kept; choose an existing folder."
            )
        case .passthroughUnsupported:
            return AppLocalization.string(
                // swiftlint:disable:next line_length
                "Video passthrough is unavailable for this trim. The original recording was kept; adjust the trim or choose audio-only."
            )
        case .exportInProgress:
            return AppLocalization.string("An export is already in progress.")
        case .cancelled(let stagingURL):
            guard let stagingURL else {
                return AppLocalization.string("Export cancelled. The original recording was kept.")
            }
            return AppLocalization.string(
                "Export cancelled. The original and staging output were kept at %@.",
                stagingURL.path
            )
        case .publishFailed(let stagingURL):
            guard let stagingURL else {
                return AppLocalization.string(
                    "Export failed. The original recording was kept; choose another destination and retry."
                )
            }
            return AppLocalization.string(
                "Export failed. The original and staging output were kept at %@.",
                stagingURL.path
            )
        }
    }

    func plannedOutput(_ spec: ExportOutputSpec) -> String {
        let name: String
        switch spec.shape {
        case .singleFile(let fileExtension):
            name = "\(spec.destination.stem).\(fileExtension)"
        case .directory:
            name = "\(spec.destination.stem)/"
        }
        return AppLocalization.string(
            "Planned output: %@",
            spec.destination.directory.appendingPathComponent(name).path
        )
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = [.pad]
        formatter.maximumUnitCount = 3
        return formatter.string(from: max(0, seconds.isFinite ? seconds : 0)) ?? "0:00"
    }
}
