# SwiftLint Debt Cleanup — Final Evidence

## Result
- **Lint**: `swiftlint lint --strict --config .swiftlint.yml` → **0 violations, 0 serious in 170 files** (baseline: 295 violations, 3 serious in 138 files).
- **App syntax**: all `App/SnapGlass/Sources/**/*.swift` pass `swiftc -parse` (exit 0).
- **Package tests**: all 8 packages pass `swift test`:
  - SharedKit 32, CaptureCore 24, OCRCore 37, BarcodeCore 5, AnnotationCore 18, ScrollCore 4, HistoryCore 54, AutomationCore 54.
- **xcodegen generate**: exit 0 (project regenerated with new split files).

## Final Split (this session)
- `EditableAnnotationCanvasView.swift` (482 → 270 lines): moved selection/resize methods out.
- `EditableAnnotationCanvasView+Selection.swift` (505 → 293 lines): kept selection drawing/hit-testing; moved interaction methods out.
- `EditableAnnotationCanvasView+Resize.swift` (new, 221 lines): `beginSelectionInteraction`, `updateCreationPreview`, `updateMove`, `updateResize`, `resizedTextNode`, `proportionalBounds`, `createNode`.
- Resolved the last `type_body_length` (class body 440 → under 400) and the resulting `file_length` on the Selection extension.

## Docs
- `CHANGELOG.md`: added `[Unreleased]` → `### Changed` entry for the lint cleanup.
- `Docs/CONTRIBUTING.md`: synced `identifier_name excluded` to `[id, URL, key, tag, qr]` (added `qr`), matching `.swiftlint.yml`.

## Notes
- swift-format warnings are **pre-existing and repo-wide** (untouched files like `App.swift` have 108, `AppearanceMode.swift` 9, root `Package.swift` 101). They are a separate tool/rule set from the SwiftLint debt this task targeted; not introduced by this work.
- Pre-existing build blocker (present in HEAD, not caused by this work): `project.yml` SwiftLint pre-build script uses invalid `--path` option for SwiftLint 0.65.1. App files verified via `swiftc -parse` only.
- Version stays `0.6.1`; CHANGELOG records under `[Unreleased]`.
