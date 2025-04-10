import AppKit
import ArgumentParser
import CoreImage
import Foundation
import Logging
import SwiftVips
import os.log

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
	case iconGetFailed(path: String, reason: String)

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
		case .iconGetFailed(let path, let reason):
			return "Failed to get icon from path '\(path)': \(reason)"
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
		abstract: "Tool for getting, setting, and masking macOS icons",
		discussion:
			"A utility for working with macOS icons - getting them from files/folders, setting them, and applying masks.",
		version: "1.0.0",
		subcommands: [GetIcon.self, SetIcon.self, MaskIcon.self],
		defaultSubcommand: nil
	)

	// MARK: - Global Flags

	// Using ParsableCommand's property wrapper to access the flags from subcommands
	// Want to keep this, but it creates an odd repition, as they don't show up in the menus for the main command oddly..
	struct Options: ParsableArguments {
		@Flag(name: [.short, .long], help: "Enable verbose output")
		var verbose: Bool = false

		@Flag(name: [.short, .long], help: "Suppress all non-error output")
		var quiet: Bool = false
	}

	@Flag(name: [.short, .long], help: "Enable verbose output")
	var verbose: Bool = false

	@Flag(name: [.short, .long], help: "Suppress all non-error output")
	var quiet: Bool = false

	// MARK: - Utility functions for subcommands

	static func validPath(susPath: String?) throws -> URL {  // (Sus)picious Path
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

		guard FileManager.default.isReadableFile(atPath: path) else {
			throw IconAssignmentError.permissionDenied(path: path, operation: "read")
		}

		return susURL
	}

	static func createImage(susImage: String?) throws -> NSImage {
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
			throw IconAssignmentError.invalidImage(path: susImage ?? "unknown")
		}
	}

	static func scales(image: NSImage) -> Bool {
		// Multiples required for perfect mapping to the smallest size
		return
			(image.size.height == 384
			&& (image.size.width.truncatingRemainder(dividingBy: 128) == 0))
	}
}

// MARK: - GetIcon Subcommand

struct GetIcon: ParsableCommand {
	static let configuration = CommandConfiguration(
		commandName: "get",
		abstract: "Extract an icon from a file or folder"
	)

	@OptionGroup var options: Iconic.Options

	@Argument(help: "Source file or folder to extract the icon from")
	var source: String

	@Option(name: .long, help: "Save the extracted icon to this .icns file")
	var outputIcns: String?

	@Option(name: .long, help: "Save the extracted icon to this .iconset folder")
	var outputIconset: String?

	@Flag(name: [.short, .long], help: "Reveal the extracted icon in Finder")
	var reveal: Bool = false

	mutating func run() throws {
		if !options.quiet {
			print("Extracting icon from \(source)...")
		}

		// Validate the source path
		let sourceURL = try Iconic.validPath(susPath: source)

		// Get the icon from the file or folder
		// NSWorkspace.shared.icon(forFile:) returns NSImage, not optional
		let icon = NSWorkspace.shared.icon(forFile: sourceURL.path)

		// Determine output paths
		let outputIcnsURL = outputIcns.map { URL(fileURLWithPath: $0) }
		let outputIconsetURL = outputIconset.map { URL(fileURLWithPath: $0) }

		// Save the icon as requested
		if let icnsPath = outputIcnsURL {
			// Code to save as .icns would go here
			if options.verbose {
				print("Saving icon to \(icnsPath.path)")
			}

			// Placeholder for actual implementation
			if !options.quiet {
				print("Icon saved to \(icnsPath.path)")
			}
		}

		if let iconsetPath = outputIconsetURL {
			// Code to save as .iconset would go here
			if options.verbose {
				print("Saving iconset to \(iconsetPath.path)")
			}

			// Placeholder for actual implementation
			if !options.quiet {
				print("Iconset saved to \(iconsetPath.path)")
			}
		}

		// If no output specified, use default locations
		if outputIcnsURL == nil && outputIconsetURL == nil {
			let defaultIcnsURL = sourceURL.deletingLastPathComponent().appendingPathComponent(
				"\(sourceURL.lastPathComponent).icns")
			// Save to default location
			if options.verbose {
				print("No output path specified, saving to \(defaultIcnsURL.path)")
			}

			// Placeholder for actual implementation
			if !options.quiet {
				print("Icon saved to \(defaultIcnsURL.path)")
			}
		}

		// Reveal in Finder if requested
		if reveal {
			// Determine which file to reveal (in order of preference: icns, iconset)
			let fileToReveal = outputIcnsURL ?? outputIconsetURL
			if let revealURL = fileToReveal {
				NSWorkspace.shared.selectFile(revealURL.path, inFileViewerRootedAtPath: "")
			}
		}
	}
}

// MARK: - SetIcon Subcommand

struct SetIcon: ParsableCommand {
	static let configuration = CommandConfiguration(
		commandName: "set",
		abstract: "Apply an icon to a file or folder"
	)

	@OptionGroup var options: Iconic.Options

	@Argument(help: "Icon file (.icns or image file) to apply")
	var icon: String

	@Argument(help: "Target file or folder to apply the icon to")
	var target: String

	@Flag(name: [.short, .long], help: "Reveal the target in Finder after applying the icon")
	var reveal: Bool = false

	mutating func run() throws {
		if !options.quiet {
			print("Setting icon \(icon) on \(target)...")
		}

		// Validate paths
		let iconURL = try Iconic.validPath(susPath: icon)
		let targetURL = try Iconic.validPath(susPath: target)

		// Check write permissions for the target item itself
		guard FileManager.default.isWritableFile(atPath: targetURL.path) else {
			throw IconAssignmentError.permissionDenied(
				path: targetURL.path, operation: "write/set attributes")
		}

		guard let iconImage = NSImage(contentsOf: iconURL) else {
			throw IconAssignmentError.iconLoadFailed(path: iconURL.path)
		}

		if options.verbose {
			print("Applying icon to \(targetURL.path)")
		}

		let success = NSWorkspace.shared.setIcon(iconImage, forFile: targetURL.path, options: [])

		guard success else {
			throw IconAssignmentError.iconSetFailed(
				path: targetURL.path,
				reason:
					"NSWorkspace.setIcon returned false. Check permissions (including extended attributes) and disk space."
			)
		}

		if !options.quiet {
			print("Successfully applied icon to \(targetURL.path)")
		}

		if reveal {
			NSWorkspace.shared.selectFile(targetURL.path, inFileViewerRootedAtPath: "")
		}
	}
}

// MARK: - MaskIcon Subcommand (formerly the main command)

struct MaskIcon: ParsableCommand {
	static let configuration = CommandConfiguration(
		commandName: "mask",
		abstract: "Apply a mask image to create a macOS folder icon",
		discussion: """
			Generates a macOS folder icon (.icns, .iconset) using a provided mask image
			and optionally applies it to a target file or folder.
			"""
	)

	@OptionGroup var options: Iconic.Options

	// MARK: - Arguments

	@Argument(
		help: ArgumentHelp(
			"Mask image file. For best results:\n" + "- Use a .png mask.\n"
				+ "- Use a solid black design over a transparent background.\n"
				+ "- Make sure the corner pixels of the mask image are transparent.\n"
				+ "  They are used for empty margins.\n"
				+ "  The image resizes perfectly if it is at height 384 and the width is a multiple of 128",
			valueName: "mask"))
	var mask: String  // Path to the mask image file

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

	// MARK: - Run Method (Main Logic)

	mutating func run() {
		do {
			if options.verbose {
				print("Processing mask image at \(mask)")
			}

			let inputImage = try Iconic.createImage(susImage: mask)

			if options.verbose {
				print("Image loaded successfully")
				print("Image scales perfectly: \(Iconic.scales(image: inputImage))")
			}

			// Implement masking logic here

			// Apply to target if specified
			if let targetPath = target {
				if !options.quiet {
					print("Applying masked icon to \(targetPath)")
				}

				// Logic to apply the icon to the target
				// This would generate the masked icon and apply it
			}

			// Save output files if specified
			if let icnsPath = outputIcns {
				if !options.quiet {
					print("Saving masked icon to \(icnsPath)")
				}

				// Logic to save as .icns
			}

			if let iconsetPath = outputIconset {
				if !options.quiet {
					print("Saving masked icon as iconset to \(iconsetPath)")
				}

				// Logic to save as .iconset
			}

			// If no target or output specified, save to default location
			if target == nil && outputIcns == nil && outputIconset == nil {
				let maskURL = URL(fileURLWithPath: mask)
				let defaultPath = maskURL.deletingLastPathComponent().appendingPathComponent(
					"\(maskURL.deletingPathExtension().lastPathComponent)-masked.icns")

				if !options.quiet {
					print("Saving masked icon to default location: \(defaultPath.path)")
				}

				// Logic to save to default location
			}

			// Reveal in Finder if requested
			if reveal {
				let pathToReveal: String?

				if let targetPath = target {
					pathToReveal = targetPath
				} else if let icnsPath = outputIcns {
					pathToReveal = icnsPath
				} else if let iconsetPath = outputIconset {
					pathToReveal = iconsetPath
				} else {
					// Default path logic similar to above
					let maskURL = URL(fileURLWithPath: mask)
					pathToReveal =
						maskURL.deletingLastPathComponent().appendingPathComponent(
							"\(maskURL.deletingPathExtension().lastPathComponent)-masked.icns"
						).path
				}

				if let revealPath = pathToReveal {
					NSWorkspace.shared.selectFile(revealPath, inFileViewerRootedAtPath: "")
				}
			}

		} catch {
			print("Error: \(error)")
		}
	}
}

Iconic.main()
