# Draft: SnapGlass Three Bug Fixes

## Requirements (confirmed)
- Bug A: Screenshots are shifted/displaced — coordinate system mismatch between AppKit (Y-up) and Quartz/CGDisplay (Y-down)
- Bug B: Selected OCR glyphs "jump" — drawSelectedOCRText redraws with approximate system font instead of preserving original pixels
- Bug C: 2048px OCR downsampling ceiling — MemoryGuard.maxImageWidth limits resolution, losing small text

## Technical Decisions (from user evidence)
- SCDisplay.frame and CGDisplayBounds use global Quartz Y-down points
- sourceRect is display-local Quartz → convert by subtracting display origin, NO second Y-flip
- AreaSelectionPanel converts through a main-display-based formula (likely wrong for non-main displays)
- SCKAdapter.pixelCropRect likely has erroneous second Y-flip
- Unselected OCR glyphs are screenshot pixels (correct); drawSelectedOCRText redraws selected glyphs (wrong)
- 2048 is MemoryGuard.maxImageWidth, not Apple Vision limit
- Current downsampling loses small text, only checks width

## Scope Boundaries
- INCLUDE: Fix three bugs with minimal targeted changes
- EXCLUDE: Broad canonical coordinate architecture rewrite, new dependencies, cloud OCR, CI/xcodeproj/permission changes, commits, releases, unrelated refactors

## Test Strategy
- 159 @Test declarations in current checkout
- Need to confirm automated test infrastructure exists
- Need mixed-display/scale tests for coordinate fixes

## Open Questions
- Awaiting explore agent results for exact file paths and code analysis
