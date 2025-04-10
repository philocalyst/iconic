import AppKit
import ArgumentParser
import CoreImage
import Foundation
import Logging
import SwiftVips
import os.log

// Define the ColorScheme enum for the --color-scheme option
enum ColorScheme: String, ExpressibleByArgument, CaseIterable {
	case auto, light, dark
}

enum IconAssignmentError: Error, CustomStringConvertible {
	case missingArgument(description: String)
	case invalidImage(path: String)
	case invalidIconPath(path: String, reason: String)
	case invalidTargetPath(path: String, reason: String)
	case iconLoadFailed(path: String)
	case iconSetFailed(path: String, reason: String)
	case permissionDenied(path: String, operation: String)
	case unexpectedError(message: String)

	var description: String {
		switch self {
		case .missingArgument(let description):
			return description
		case .invalidImage(let path):
			return "Image at \(path) is invalid"
		case .invalidIconPath(let path, let reason):
			return "Invalid icon path '\(path)': \(reason)"
		case .invalidTargetPath(let path, let reason):
			return "Invalid target path '\(path)': \(reason)"
		case .iconLoadFailed(let path):
			return
				"Failed to load image from icon path '\(path)' (ensure it's a valid image format like .icns, .png, .jpg)."
		case .iconSetFailed(let path, let reason):
			return "Failed to set icon for target path '\(path)': \(reason)"
		case .permissionDenied(let path, let operation):
			return "Permission denied for '\(operation)' operation on path: \(path)"
		case .unexpectedError(let message):
			return "An unexpected error occurred: \(message)"
		}
	}
}

let logger = Logger(
	subsystem: Bundle.main.bundleIdentifier ?? "com.script.iconassignment", category: "icon-setter")

// Define the main command structure
struct Iconic: ParsableCommand {

	// MARK: - Configuration

	static let configuration = CommandConfiguration(
		commandName: "iconic",
		abstract: "Applies a mask image to a macOS folder icon.",
		discussion: """
			Generates a macOS folder icon (.icns, .iconset) using a provided mask image
			and optionally applies it to a target file or folder.
			""",
		version: "1.0.0"  // Optional: Specify your tool's version
	)

	// MARK: - Arguments

	@Argument(
		help: ArgumentHelp(
			"Mask image file. For best results:\n" + "- Use a .png mask.\n"
				+ "- Use a solid black design over a transparent background.\n"
				+ "- Make sure the corner pixels of the mask image are transparent.\n"
				+ "  They are used for empty margins.\n"
				+ "  The image resizes perfectly if it is at height 384 and the width is a multiple of 128",
			valueName: "mask"))
	var mask: String?  // Path to the mask image file

	@Argument(
		help: ArgumentHelp(
			"Target file or folder. If specified, the resulting icon will be "
				+ "applied to the target. Otherwise (unless --output-icns or "
				+ "--output-iconset is specified), output files will be created "
				+ "next to the mask.",
			valueName: "target"))
	var target: String?  // Optional path to the target file/folder

	// MARK: - Options

	@Option(
		name: .long,
		help: ArgumentHelp(
			"Write the `.icns` file to the given path. (Will be written even if a target is also specified.)",
			valueName: "icns-file"))
	var outputIcns: String?

	@Option(
		name: .long,
		help: ArgumentHelp(
			"Write the `.iconset` folder to the given path. (Will be written even if a target is also specified.)",
			valueName: "iconset-folder"))
	var outputIconset: String?

	@Flag(
		name: [.short, .long],
		help:
			"Reveal either the target, `.icns`, or `.iconset` (in that order of preference) in Finder."
	)
	var reveal: Bool = false  // Defaults to false

	@Option(
		name: .long,
		help: ArgumentHelp(
			"Version of the macOS folder icon, e.g. \"14.2.1\". Defaults to the version currently running.",
			valueName: "macos-version"))
	var macOS: String?  // Default logic needs to be implemented in run()

	@Option(
		name: .long,
		help: ArgumentHelp(
			"Color scheme — auto matches the current system value.",
			valueName: "color-scheme"))
	var colorScheme: ColorScheme = .auto  // Default value set here

	@Flag(
		name: .long,
		help: "Don't trim margins from the mask. By default, transparent margins are trimmed.")
	var noTrim: Bool = false  // Defaults to false (meaning trimming is enabled by default)

	@Flag(
		name: [.short, .long],
		help: "Detailed output. Also sets `--no-progress` (if progress indicator is implemented).")
	var verbose: Bool = false  // Defaults to false

	// MARK: - Run Method (Main Logic)

	mutating func run() {
		var inputImage: NSImage
		do {
			inputImage = try createImage(susImage: mask)
			print(scales(image: inputImage))
		} catch {
			print("Image creation failed")
		}

	}

	private func scales(image: NSImage) -> Bool {
		// Multiples required for perfect mapping to the smallest size
		return
			(image.size.height == 384
			&& (image.size.width.truncatingRemainder(dividingBy: 128) == 0))
	}

	private func validPath(susPath: String?) throws -> URL {  // (Sus)picious Path
		guard let path = susPath, !path.isEmpty else {
			throw IconAssignmentError.invalidIconPath(
				path: susPath ?? "<nil or empty>",
				reason: "Path cannot be nil or empty")
		}

		let susURL = URL(fileURLWithPath: path)
		var isIconDirectory: ObjCBool = false

		guard FileManager.default.fileExists(atPath: path, isDirectory: &isIconDirectory) else {
			throw IconAssignmentError.invalidIconPath(path: path, reason: "File does not exist")
		}

		// Use 'path' for file system checks
		guard FileManager.default.isWritableFile(atPath: path) else {
			throw IconAssignmentError.permissionDenied(
				path: path,
				operation: "write/set attributes"
			)
		}

		guard !isIconDirectory.boolValue else {
			throw IconAssignmentError.invalidIconPath(
				path: path, reason: "Path must be a file, not a directory")
		}

		guard FileManager.default.isReadableFile(atPath: path) else {
			throw IconAssignmentError.permissionDenied(path: path, operation: "read")
		}

		return susURL
	}

	private func createImage(susImage: String?) throws -> NSImage {
		// Validate base path
		let imageURL: URL
		do {
			imageURL = try validPath(susPath: susImage)
			guard let inputImg = NSImage(contentsOf: imageURL) else {
				print("Error: Could not load image or invalid image format at \(imageURL.path)")
				throw IconAssignmentError.invalidImage(path: imageURL.path)
			}
			return inputImg
		} catch {
			print(error)
		}

		return NSImage.init()
	}

	private func assignIcon(iconURL: URL, targetURL: URL) throws {
		// Check write permissions for the target item itself.
		guard FileManager.default.isWritableFile(atPath: targetURL.path) else {
			throw IconAssignmentError.permissionDenied(
				path: targetURL.path, operation: "write/set attributes")
		}

		guard let icon = NSImage(contentsOf: iconURL) else {
			throw IconAssignmentError.iconLoadFailed(path: iconURL.path)
		}

		let success = NSWorkspace.shared.setIcon(icon, forFile: targetURL.path, options: [])

		guard success else {
			throw IconAssignmentError.iconSetFailed(
				path: targetURL.path,
				reason:
					"NSWorkspace.setIcon returned false. Check permissions (including extended attributes) and disk space."
			)
		}

		logger.info("Successfully assigned icon '\(iconURL.path)' to target '\(targetURL.path)'")
	}
}

// MARK: - Entry Point

Iconic.main()
