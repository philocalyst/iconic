# Changelog

All notable changes to this project will be documented in this file.

This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2025-04-22

### Added

-   **Initial Project:** Basic structure for the `iconic` command-line tool.
-   **Core Subcommands:**
    -   `get`: Extract icons from files/folders into `.icns` or `.iconset` formats.
    -   `set`: Apply an existing icon file (`.icns` or image) to a target file/folder.
    -   `mask`: Apply a PNG mask to macOS folder icon templates (Big Sur style).
        -   Automatically loads light/dark templates based on system appearance.
        -   Processes multiple icon resolutions found in `.icns` templates.
        -   Generates output as `.icns` or `.iconset`.
        -   Optionally applies the generated icon directly to a target.
-   **Advanced Masking Effect:**
    -   "Engraving" effect for `mask` command, featuring configurable fill color, top/bottom bezels (color, opacity), and a `BlurDown` effect (motion blur + vertical offset).
-   **Image Processing:**
    -   Metal-accelerated transparent margin trimming for input images and templates.
    -   Image scaling (`scaled`) with aspect ratio preservation and optional reduction via `ratio`.
    -   Image centering (`centering`).
    -   Numerous `CIImage` extensions for effects: `fillColorize`, `applyOpacity`, `composite` (various blend/composite modes), `negate`, `blurDown`, `maskDown`, `dissolve`, `darken`, `tint`, `invertedAlphaWhiteBackground`.
-   **Utilities:**
    -   Structured logging via `swift-log` (`AppLog`) with `--verbose` and `--quiet` flags.
    -   File system utilities (`FileUtils`) for path validation, image loading (`CIImage`), `.iconset` writing, and extracting all representations from `NSImage`.
    -   Custom `.icns` file generation (`FileUtils.createICNSFile`), removing dependency on `iconutil`.
    -   Helper function to run external shell commands (`runCommand`).
    -   Debug image dumping capability for intermediate steps in the `engrave` process.
-   **Project Configuration:**
    -   `Package.swift` defining dependencies (`ArgumentParser`, `Logging`) and targets.
    -   `Package.resolved` file.
    -   `.gitignore` file.
-   **Error Handling:** Centralized `IconicError` enum for consistent error reporting.
-   **Resources:** Embedded Big Sur light and dark folder icon templates (`.icns`).

### Changed

-   **Architecture:** Refactored from a single command structure to subcommands (`get`, `set`, `mask`).
-   **Code Organization:** Major refactor into separate source files (`CIExtensions.swift`, `Errors.swift`, `FileUtils.swift`, `GetIcon.swift`, `Logger.swift`, `MaskIcon.swift`, `MetalInterface.swift`, `MetalTrimmer.swift`, `SetIcon.swift`, `Utility.swift`).
-   **Cropping:** Replaced external `vips` CLI dependency for cropping with an internal Metal-accelerated `MetalTrimmer` using a custom `findBoundingBox` kernel.
-   **Logging:** Replaced initial `os.log` with a `swift-log` based `AppLog` singleton provider for configurable log levels.
-   **`.icns` Generation:** Replaced external `iconutil` CLI dependency with internal `FileUtils.createICNSFile` implementation.
-   **Engraving Effect:**
    -   Refactored bezel parameters to use a `BlurDown` struct (combining motion blur and offset) instead of simple Gaussian blur radius.
    -   Iteratively refined filter choices, compositing steps (`dissolve` blend), and default parameters for the effect.
    -   Improved `fillColorize` implementation using `CIConstantColorGenerator` and `CISourceInCompositing`.
-   **Image Processing:**
    -   Enhanced `scaled(toFit:)` function to accept a `ratio` for further reduction.
    -   Improved `invertedAlphaWhiteBackground` implementation.
    -   Adjusted vertical centering logic.
-   **Concurrency:** Added `@MainActor` and `@preconcurrency` annotations for improved safety.
-   **Configuration:** Resource path determination is now dynamic based on the `HOME` environment variable.
-   **Dark Mode Detection:** Switched from `NSApp.effectiveAppearance` to `UserDefaults` for checking `AppleInterfaceStyle`.
-   **MaskIcon Output:** Changed final image generation to use the directly engraved image per size, instead of overlaying it onto the original template base.

### Removed

-   **Dependencies:**
    -   Removed `SwiftVips` package dependency.
    -   Removed reliance on the `vips` command-line tool.
    -   Removed reliance on the `iconutil` command-line tool.
-   **Code:**
    -   Removed old `vips`-based `cropTransparentPadding` function.
    -   Removed old logging systems (`os.log`, initial `LoggerProvider`).
    -   Removed old error types (`ImageTrimError`, `IconAssignmentError`).
    -   Removed old Metal context (`MetalTrimmingContext`).
    -   Removed temporary/debug `writeAtPath` function.
    -   Removed local dependency path configuration from `Package.swift`.

### Fixed

-   Correctly use PNG format (`writePNGRepresentation`) instead of JPEG when writing `.iconset` folders.
-   Corrected negative Y-axis direction for `pageY` offset in `blurDown` effect.
-   Fixed centering calculation logic multiple times during development.
-   Handled cases where mask and template `.icns` files might have different numbers of image representations.
-   Resolved minor bugs in argument handling and variable naming during initial development.

[Unreleased]: https://github.com/philocalyst/iconic/compare/v1.0.0...HEAD
[0.1.0]: https://github.com/philocalyst/iconic/compare/b987dfb6906d50af74baaca10d35dfae9efb5e98...70d568eb8110bb7773f731d735a2224b2fdf0c63
