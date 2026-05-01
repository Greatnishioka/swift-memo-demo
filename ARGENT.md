# ARGENT.md

## Project Overview

This repository is a macOS Swift prototype named `StarWindow`. It is intentionally described in `README.md` as throwaway/experimental code for checking how far AppKit-based UI customization can go before rebuilding a production version from scratch.

The app lets the user load or drag an image of memo paper, trace a rough outline, extract/refine the paper contour, preview display settings, and open the result as a custom-shaped memo window.

## Tech Stack

- Swift Package Manager executable target: `StarWindow`
- Swift tools version: 5.9
- Platform: macOS 14+
- UI: SwiftUI hosted from an AppKit `NSApplication` / `NSWindow`
- Native frameworks used in the main source:
  - `AppKit`
  - `SwiftUI`
  - `Vision`
  - `CoreImage`
  - `UniformTypeIdentifiers`

There are no third-party package dependencies.

## Repository Layout

- `Package.swift`: SPM package definition for the `StarWindow` executable.
- `Sources/StarWindow/main.swift`: Entire app implementation. This file contains app startup, SwiftUI views, contour detection, mask rendering, preview editing, and custom window behavior.
- `Scripts/package-app.sh`: Builds a release binary and packages it into `dist/StarWindow.app`.
- `README.md`: Short Japanese note that this is experimental throwaway code.
- `dist/`: Generated app bundle and zip. Treat as build output unless the user explicitly asks to update packaged artifacts.

## Common Commands

Build the executable:

```sh
swift build
```

Build optimized release:

```sh
swift build -c release
```

Run from SPM:

```sh
swift run StarWindow
```

Package a `.app` bundle into `dist/StarWindow.app`:

```sh
Scripts/package-app.sh
```

The package script removes and recreates `dist/StarWindow.app`, copies `.build/release/StarWindow`, and writes `Contents/Info.plist`.

## Main Runtime Flow

1. `MemoPaperApp.main()` creates the shared `NSApplication`, attaches `AppDelegate`, sets regular activation policy, and starts the AppKit run loop.
2. `AppDelegate.applicationDidFinishLaunching` creates the main titled window and hosts `MemoPaperView`.
3. `MemoPaperView` handles image selection/drop, text entry, rough contour tracing, contour extraction, preview sheet presentation, and opening the final cutout window.
4. `applyTrace()` collects contour candidates from multiple extractors and lets `ContourCandidateSelector` choose the best candidate.
5. `MemoCreationPreviewSheet` lets the user adjust opacity, brightness, padding, blur, mask edits, text path, and detailed extraction.
6. `CutoutWindowManager` opens a shaped memo window backed by `CutoutMemoWindowView`.

## Important Types

- `AppDefaults`: Central tuning constants for opacity, contour padding, smoothing, candidate selection, rectangle detection, and detailed extraction.
- `MemoPreviewConfiguration`: Mutable configuration passed from preview into final window creation.
- `MemoPaperView`: Main app screen and top-level workflow coordinator.
- `CutoutImageRenderer`: Produces cropped/masked `NSImage` output from normalized contour bounds.
- `ContourPadding`: Expands normalized contours by pixel padding.
- `RectangularGuideContour`: Detects and builds rectangle-like contours from user traces.
- `ColoredPaperRectangleExtractor`: Finds colored rectangular paper inside a rectangular guide.
- `SubjectMaskExtractor`: Uses `VNGenerateForegroundInstanceMaskRequest` for foreground instance masks.
- `PreprocessedContourExtractor`: Applies Core Image preprocessing, then Vision contour detection.
- `GuidedBackgroundContourExtractor`: Estimates background/foreground difference inside the traced guide.
- `ContourDetector`: Raw Vision contour fallback.
- `ContourCandidateSelector`: Scores extraction candidates against the guide and applies source bias.
- `ContourSmoother`: Densifies, spike-removes, straightens, rounds, and smooths contours.
- `MemoCreationPreviewSheet`: Preview/editor UI for final memo appearance.
- `RasterContourMask`: Raster editing helper for pencil/eraser-style contour edits.
- `CutoutWindowManager`, `CutoutMemoWindow`, `CutoutHostingView`, `CutoutMemoWindowView`: Custom memo window stack.
- `ShapedTextEditor`, `ShapedNSTextView`, `TextExclusionPathBuilder`: Text editing constrained by custom paths.

## Coordinate System Notes

Most contour data is stored as normalized `CGPoint` values in image/UI space where `x` and `y` are clamped to `0...1`.

Vision and image APIs often use different Y-axis conventions. Several extractors explicitly convert between Vision crop coordinates, Core Graphics image coordinates, and SwiftUI preview coordinates. Be careful when changing:

- `visionCropPointToUI`
- `cropRect(for:imageWidth:imageHeight:)`
- `CutoutImageRenderer.cgPath(for:bounds:size:)`
- preview helper methods that map points into `previewRect`

Incorrect Y flipping will usually appear as contours mirrored vertically or masks offset from the paper.

## Editing Guidance

- Prefer small, targeted edits. The project is currently a single large prototype file, so broad refactors can create unnecessary risk.
- Keep default behavior centralized in `AppDefaults` when tuning extraction or rendering parameters.
- Preserve normalized contour conventions unless changing the whole pipeline deliberately.
- When changing extraction quality, test with at least rectangular paper and irregular/hand-traced paper cases because candidate source bias affects which extractor wins.
- Be cautious around `dist/`; it is generated by the package script and may already contain local build artifacts.
- The working tree may contain user edits. Do not revert unrelated changes.

## Verification Checklist

For code changes, at minimum run:

```sh
swift build
```

For packaging changes, run:

```sh
Scripts/package-app.sh
```

For UI or image-processing changes, manually verify:

- Launches on macOS 14+
- Image selection via open panel works
- File/image drag and drop works
- Rough tracing accepts points only inside the fitted image
- `被写体抽出` produces a plausible contour or falls back to the traced contour
- `メモ化` opens the preview sheet
- Preview sliders update crop opacity, brightness, padding, and blur
- Final custom window opens with the expected shape and text behavior

## Current Caveats

- There are no automated tests.
- The app is macOS-only and depends on Vision APIs available on macOS 14+.
- The main implementation is monolithic in `Sources/StarWindow/main.swift`.
- UI text is Japanese.
- `dist/StarWindow.app` and `dist/StarWindow.zip` are generated artifacts, not source of truth.
