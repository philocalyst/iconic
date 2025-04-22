# Welcome to Iconic!

Iconic is a command-line utility for macOS designed to make managing file and folder icons easier. It allows you to get, set, and apply masks to icons using `.icns` or `.iconset` formats. It leverages powerful (oooh) macOS frameworks like Core Image and Metal for efficient image processing.

## Brief Summary

The `iconic` tool provides three main functions:

1.  **`get`**: Extract the existing icon from a file or folder and save it as an `.icns` file or an `.iconset` folder.
2.  **`set`**: Apply an icon (from an `.icns` file or `.iconset` folder) to a target file or folder.
3.  **`mask`**: Apply a custom PNG mask onto the standard macOS folder icon template, creating a stylized folder icon, and optionally apply it to a target folder. This uses a sophisticated "engraving" effect with configurable bezels and colors.

It utilizes Metal for fast, GPU-accelerated trimming of transparent pixels around icons and Core Image for various effects and compositing operations.

## Screenshot

*(Placeholder: You can add a screenshot demonstrating the tool's usage or the resulting masked icon here)*

```shell
# Example Usage: Masking a folder icon
iconic mask --icns custom-icon.icns --reveal MyProjectIcon.png ~/Projects/MyProject

# Result: custom-icon.icns created and applied to ~/Projects/MyProject
```

## Get Started

To get started, you'll need to build and [install](#installation) the tool.

## Tutorial / Usage

The `iconic` tool is invoked via the command line. It supports global options for logging verbosity:

* `--verbose`: Enable detailed debug logging.
* `--quiet`: Suppress informational messages, showing only errors.

### Commands

#### 1. `iconic get`

Extracts the icon associated with a given file or folder.

**Usage:**
`iconic get <source_path> [--icns <output.icns>] [--iconset <output_dir.iconset>] [--reveal]`

* `<source_path>`: The file or folder to get the icon from.
* `--icns <output.icns>`: (Optional) Path to save the extracted icon as an `.icns` file.
* `--iconset <output_dir.iconset>`: (Optional) Path to save the extracted icon as an `.iconset` folder (containing multiple PNGs).
* `--reveal`: (Optional) Reveal the output file/folder in Finder upon completion.

**Example:**
`iconic get /Applications/Safari.app --icns Safari.icns`

#### 2. `iconic set`

Applies a custom icon to a file or folder.

**Usage:**
`iconic set <icon_path> <target_path> [--reveal]`

* `<icon_path>`: Path to the `.icns` file or `.iconset` folder containing the icon to apply. If an `.iconset` is provided, it uses the highest resolution image available.
* `<target_path>`: The file or folder to apply the icon to.
* `--reveal`: (Optional) Reveal the target file/folder in Finder upon completion.

**Example:**
`iconic set ~/Downloads/MyIcon.icns ~/Documents/MyReport.docx`

#### 3. `iconic mask`

Applies a PNG image as a mask onto the standard macOS folder icon template (Big Sur style). This creates an "engraved" look.

**Usage:**
`iconic mask <mask_path.png> [<target_path>] [--icns <output.icns>] [--iconset <output_dir.iconset>] [--reveal]`

* `<mask_path.png>`: Path to the PNG image to use as the mask. Transparency in the PNG defines the shape.
* `<target_path>`: (Optional) Path to a file or folder to apply the generated masked icon to.
* `--icns <output.icns>`: (Optional) Path to save the generated masked icon as an `.icns` file.
* `--iconset <output_dir.iconset>`: (Optional) Path to save the generated masked icon as an `.iconset` folder.
* `--reveal`: (Optional) Reveal the output file/folder or the target file/folder in Finder upon completion.

**Configuration & Dependencies:**

* **Folder Templates:** The `mask` command requires the standard Big Sur folder icon templates (`.icns` format) to be present in `~/.local/share/iconic/`. You need to name them `bigsur-folder-light.icns` and `bigsur-folder-dark.icns`. The tool automatically selects the correct template based on the current system appearance (Light/Dark mode). You will need to source these template files yourself (e.g., by extracting them from the system or finding them online).
* **Engraving Effect:** The engraving uses predefined parameters for fill color, top bezel, and bottom bezel, including colors, blurs, masking operations (`dst-in`, `dst-out`), and opacities. These are currently hardcoded in `MaskIcon.swift` within the `EngravingInputs` struct but could be exposed as command-line options in the future.

**Example:**
`iconic mask company-logo.png ~/MyProject --icns myproject.icns --reveal`

## Design Philosophy

* **Leverage Native Frameworks:** Utilize macOS-native technologies like AppKit, Core Image, and Metal for optimal performance and integration.
* **Performance:** Employ Metal for computationally intensive tasks like finding the bounding box of non-transparent pixels for efficient trimming.
* **Modularity:** Structure the tool into distinct subcommands (`get`, `set`, `mask`) using `swift-argument-parser` for clarity and maintainability.
* **Extensibility:** Use Core Image filters extensively, allowing for relatively easy addition of new image effects or adjustments.
* **User Experience:** Provide clear command-line arguments, informative logging (controlled by `--verbose`/`--quiet`), and optional Finder integration (`--reveal`).

## Building and Debugging

1.  **Clone the repository:**
    ```shell
    git clone <your-repo-url>
    cd iconic
    ```
2.  **Build:**
    * For Debug: `swift build`
    * For Release: `swift build -c release`
    The executable will be located at `.build/debug/iconic` or `.build/release/iconic`.

3.  **Debugging:**
    * Use the `--verbose` flag to see detailed log output, including image processing steps.
    * **Engraving Debug Dumps:** When running the `mask` command, the `engrave` function automatically saves intermediate image stages as PNG files to a temporary directory (e.g., `/var/folders/.../T/engrave_debug_<runID>/`). This is extremely useful for debugging the masking and compositing process. The path to the debug directory is printed to the console when using `--verbose`.

## Installation

1.  **Prerequisites:**
    * macOS 12.0 or later.
    * Xcode Command Line Tools (or full Xcode) installed (`xcode-select --install`).
    * **(For `mask` command):** Obtain `bigsur-folder-light.icns` and `bigsur-folder-dark.icns` template files. Create the directory `~/.local/share/iconic/` and place the template files inside it.
        ```shell
        mkdir -p ~/.local/share/iconic
        # Copy/move your template files here:
        cp path/to/bigsur-folder-light.icns ~/.local/share/iconic/
        cp path/to/bigsur-folder-dark.icns ~/.local/share/iconic/
        ```

2.  **Build the release version:**
    ```shell
    swift build -c release
    ```

3.  **Copy the executable to your PATH:**
    You can copy the compiled binary to a location included in your system's PATH environment variable, such as `/usr/local/bin` or a custom `~/bin` or `~/.local/bin` directory.
    ```shell
    # Example: Copying to /usr/local/bin
    sudo cp .build/release/iconic /usr/local/bin/iconic

    # Example: Copying to a local bin (ensure ~/bin is in your PATH)
    # mkdir -p ~/bin
    # cp .build/release/iconic ~/bin/iconic
    ```

4.  **Verify Installation:**
    Open a new terminal window and run:
    ```shell
    iconic --version
    ```

## Changelog

For details on recent changes, please see the [CHANGELOG.md](CHANGELOG.md) file.

## Libraries Used

* [swift-argument-parser](https://github.com/apple/swift-argument-parser) (by Apple): For parsing command-line arguments.
* [swift-log](https://github.com/apple/swift-log) (by Apple): For structured logging.
* **Native macOS Frameworks:**
    * AppKit
    * Core Image
    * Metal
    * Foundation

## Acknowledgements

This project relies heavily on the powerful graphics and application frameworks provided by Apple for macOS. The Metal-based transparency trimming kernel (`findBoundingBox`) provides efficient image analysis.

## License

This project is licensed under the terms specified in the [LICENSE](LICENSE) file.
