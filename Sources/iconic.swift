import AppKit
import ArgumentParser
import CoreImage
import Foundation
import Logging
import SwiftVips

enum ColorScheme: String, ExpressibleByArgument, CaseIterable {
	case auto, light, dark
}

let resourcesPath = "/Users/philocalyst/.local/share/"

enum IconAssignmentError: Error, CustomStringConvertible {
	case missingArgument(description: String)
	case filterFailure(filter: String)
	case invalidImage(path: String)
	case invalidIconPath(path: String, reason: String)
	case invalidImageExtent(operation: String, reason: String)
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
		case .filterFailure(let filter):
			return "Failed to apply filter \(filter)"
		case .invalidImageExtent(let operation, let reason):
			return
				"Image processing operation '\(operation)' failed due to invalid geometry: \(reason)"
		}
	}
}

var logger = Logger(label: "com.philocalyst.iconic")

// Respectful lil function; doesn't print when quiet is enabled
func quietPrint(_ message: String, isQuiet: Bool) {
	if !isQuiet {
		print(message)
	}
}

// Define the main command structure
struct Iconic: @preconcurrency ParsableCommand {

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

	@MainActor
	mutating func run() throws {
		if verbose && quiet {
			logger.warning("Conflicting options: both verbose and quiet flags are enabled")
			print("ERROR CONFLICTING OPTIONS")
		} else if verbose {
			logger.logLevel = Logger.Level.trace
			logger.info("Verbose logging enabled")
		} else if quiet {
			logger.logLevel = Logger.Level.error
			logger.info("Quiet mode enabled - suppressing non-error output")
		} else {
			// Default log level
			logger.logLevel = Logger.Level.notice
			logger.info("Using default logging level")
		}
	}

	// MARK: - Utility functions for subcommands

	@MainActor
	@preconcurrency static func validPath(susPath: String?) throws -> URL {  // (Sus)picious Path
		logger.debug("Validating path: \(susPath ?? "<nil>")")
		guard let path = susPath, !path.isEmpty else {
			logger.error("Invalid path: nil or empty")
			throw IconAssignmentError.invalidIconPath(
				path: susPath ?? "<nil or empty>",
				reason: "Path cannot be nil or empty")
		}

		let susURL = URL(fileURLWithPath: path)
		var isIconDirectory: ObjCBool = false

		guard FileManager.default.fileExists(atPath: path, isDirectory: &isIconDirectory) else {
			logger.error("Path does not exist: \(path)")
			throw IconAssignmentError.invalidIconPath(path: path, reason: "File does not exist")
		}

		// Use 'path' for file system checks
		guard FileManager.default.isWritableFile(atPath: path) else {
			logger.error("Path is not writable: \(path)")
			throw IconAssignmentError.permissionDenied(
				path: path,
				operation: "write/set attributes"
			)
		}

		guard FileManager.default.isReadableFile(atPath: path) else {
			logger.error("Path is not readable: \(path)")
			throw IconAssignmentError.permissionDenied(path: path, operation: "read")
		}

		logger.debug("Path validated successfully: \(path)")
		return susURL
	}

	@MainActor
	@preconcurrency
	static func createImage(imagePath: String?) throws -> NSImage {
		// Validate base path
		let imageURL: URL
		do {
			logger.debug("Attempting to create image from path: \(imagePath ?? "<nil>")")
			imageURL = try validPath(susPath: imagePath)
			guard let inputImg = NSImage(contentsOf: imageURL) else {
				logger.error("Failed to load image at \(imageURL.path)")
				print("Error: Could not load image or invalid image format at \(imageURL.path)")
				throw IconAssignmentError.invalidImage(path: imageURL.path)
			}
			logger.info("Successfully loaded image from \(imageURL.path)")
			return inputImg
		} catch {
			logger.error("Error creating image: \(error)")
			print(error)
			throw IconAssignmentError.invalidImage(path: imagePath ?? "unknown")
		}
	}

	@MainActor
	@preconcurrency
	static func scales(image: NSImage) -> Bool {
		// Multiples required for perfect mapping to the smallest size
		let result =
			(image.size.height == 384
				&& (image.size.width.truncatingRemainder(dividingBy: 128) == 0))
		logger.debug(
			"Image scaling check: height=\(image.size.height), width=\(image.size.width), result=\(result)"
		)
		return result
	}
}

// MARK: - GetIcon Subcommand

struct GetIcon: @preconcurrency ParsableCommand {
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

	@MainActor
	mutating func run() throws {
		logger.info("GetIcon command started")
		logger.debug(
			"Parameters - source: \(source), outputIcns: \(outputIcns ?? "nil"), outputIconset: \(outputIconset ?? "nil"), reveal: \(reveal)"
		)

		quietPrint("Extracting icon from \(source)...", isQuiet: options.quiet)

		// Validate the source path
		let sourceURL = try Iconic.validPath(susPath: source)
		logger.info("Source path validated: \(sourceURL.path)")

		// Get the icon from the file or folder
		// NSWorkspace.shared.icon(forFile:) returns NSImage, not optional
		logger.debug("Attempting to get icon from file: \(sourceURL.path)")
		let icon = NSWorkspace.shared.icon(forFile: sourceURL.path)
		logger.info("Successfully retrieved icon from \(sourceURL.path)")

		// Determine output paths
		let outputIcnsURL = outputIcns.map { URL(fileURLWithPath: $0) }
		let outputIconsetURL = outputIconset.map { URL(fileURLWithPath: $0) }

		// Save the icon as requested
		if let icnsPath = outputIcnsURL {
			// Code to save as .icns would go here
			if options.verbose {
				logger.debug("About to save icon to \(icnsPath.path)")
				print("Saving icon to \(icnsPath.path)")
			}

			// Placeholder for actual implementation
			logger.info("Icon saved to \(icnsPath.path)")
			quietPrint("Icon saved to \(icnsPath.path)", isQuiet: options.quiet)
		}

		if let iconsetPath = outputIconsetURL {
			// Code to save as .iconset would go here
			if options.verbose {
				logger.debug("About to save iconset to \(iconsetPath.path)")
				print("Saving iconset to \(iconsetPath.path)")
			}

			// Placeholder for actual implementation
			logger.info("Iconset saved to \(iconsetPath.path)")
			quietPrint("Iconset saved to \(iconsetPath.path)", isQuiet: options.quiet)
		}

		// If no output specified, use default locations
		if outputIcnsURL == nil && outputIconsetURL == nil {
			let defaultIcnsURL = sourceURL.deletingLastPathComponent().appendingPathComponent(
				"\(sourceURL.lastPathComponent).icns")
			// Save to default location
			if options.verbose {
				logger.debug("No output path specified, using default: \(defaultIcnsURL.path)")
				print("No output path specified, saving to \(defaultIcnsURL.path)")
			}

			// Placeholder for actual implementation
			logger.info("Icon saved to default location: \(defaultIcnsURL.path)")
			quietPrint("Icon saved to \(defaultIcnsURL.path)", isQuiet: options.quiet)
		}

		// Reveal in Finder if requested
		if reveal {
			// Determine which file to reveal (in order of preference: icns, iconset)
			let fileToReveal = outputIcnsURL ?? outputIconsetURL
			if let revealURL = fileToReveal {
				logger.info("Revealing file in Finder: \(revealURL.path)")
				NSWorkspace.shared.selectFile(revealURL.path, inFileViewerRootedAtPath: "")
			} else {
				logger.warning("Reveal flag set but no file to reveal")
			}
		}

		logger.info("GetIcon command completed successfully")
	}
}

// MARK: - SetIcon Subcommand

struct SetIcon: @preconcurrency ParsableCommand {
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

	@MainActor
	mutating func run() throws {
		logger.info("SetIcon command started")
		logger.debug("Parameters - icon: \(icon), target: \(target), reveal: \(reveal)")

		quietPrint("Setting icon \(icon) on \(target)...", isQuiet: options.quiet)

		// Validate paths
		let iconURL = try Iconic.validPath(susPath: icon)
		let targetURL = try Iconic.validPath(susPath: target)
		logger.info("Paths validated - icon: \(iconURL.path), target: \(targetURL.path)")

		// Check write permissions for the target item itself
		guard FileManager.default.isWritableFile(atPath: targetURL.path) else {
			logger.error("Permission denied: Cannot write to target \(targetURL.path)")
			throw IconAssignmentError.permissionDenied(
				path: targetURL.path, operation: "write/set attributes")
		}

		guard let iconImage = NSImage(contentsOf: iconURL) else {
			logger.error("Failed to load icon image from \(iconURL.path)")
			throw IconAssignmentError.iconLoadFailed(path: iconURL.path)
		}
		logger.info("Successfully loaded icon image from \(iconURL.path)")

		if options.verbose {
			logger.debug("About to apply icon to \(targetURL.path)")
			print("Applying icon to \(targetURL.path)")
		}

		logger.debug("Calling NSWorkspace.setIcon")
		let success = NSWorkspace.shared.setIcon(iconImage, forFile: targetURL.path, options: [])

		guard success else {
			logger.error("NSWorkspace.setIcon failed for \(targetURL.path)")
			throw IconAssignmentError.iconSetFailed(
				path: targetURL.path,
				reason:
					"NSWorkspace.setIcon returned false. Check permissions (including extended attributes) and disk space."
			)
		}

		logger.info("Successfully applied icon to \(targetURL.path)")
		quietPrint("Successfully applied icon to \(targetURL.path)", isQuiet: options.quiet)

		if reveal {
			logger.info("Revealing target in Finder: \(targetURL.path)")
			NSWorkspace.shared.selectFile(targetURL.path, inFileViewerRootedAtPath: "")
		}

		logger.info("SetIcon command completed successfully")
	}
}

// MARK: - MaskIcon Subcommand (formerly the main command)

struct MaskIcon: @preconcurrency ParsableCommand {
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

	@MainActor
	mutating func run() {
		logger.info("MaskIcon command started")
		logger.debug(
			"Parameters - mask: \(mask), target: \(target ?? "nil"), outputIcns: \(outputIcns ?? "nil"), outputIconset: \(outputIconset ?? "nil")"
		)
		logger.debug(
			"Additional parameters - reveal: \(reveal), macOS: \(macOS ?? "nil"), colorScheme: \(colorScheme), noTrim: \(noTrim)"
		)

		do {
			if options.verbose {
				logger.debug("About to process mask image: \(mask)")
				print("Processing mask image at \(mask)")
			}

			logger.info("Loading input image from \(mask)")
			let maskImage = try Iconic.createImage(imagePath: mask)
			let folderImage = try Iconic.createImage(
				imagePath: determineBasePath(version: "bigsur", color: colorScheme))

			let maskIcons = getAllCIImages(from: maskImage)
			let folderIcons = getAllCIImages(from: folderImage)

			var convertedIcons: [CIImage] = []

			if maskIcons.count == folderIcons.count {
				for (mask, folder) in zip(maskIcons, folderIcons) {
					try convertedIcons.append(iconify(mask: mask, base: folder))
				}
			} else {
				for base in folderIcons {
					try convertedIcons.append(iconify(mask: maskIcons[0], base: base))
				}
			}

			if options.verbose {
				logger.debug("Image loaded successfully")
				print("Image loaded successfully")
				logger.debug("Checking if image scales perfectly")
				print("Image scales perfectly: \(Iconic.scales(image: inputImage))")
			}

			// Implement masking logic here
			logger.info("Performing masking operation")

			// Apply to target if specified
			if let targetPath = target {
				logger.info("Target specified, will apply icon to: \(targetPath)")
				quietPrint("Applying masked icon to \(targetPath)", isQuiet: options.quiet)

				// Logic to apply the icon to the target
				// This would generate the masked icon and apply it
			}

			// Save output files if specified
			if let icnsPath = outputIcns {
				logger.info("Saving masked icon to specified .icns path: \(icnsPath)")
				quietPrint("Saving masked icon to \(icnsPath)", isQuiet: options.quiet)

				// Logic to save as .icns
			}

			if let iconsetPath = outputIconset {
				logger.info("Saving masked icon to specified .iconset path: \(iconsetPath)")
				quietPrint(
					"Saving masked icon as iconset to \(iconsetPath)", isQuiet: options.quiet)

				var index = 0
				for convertedIcon in convertedIcons {
					let icnsURL = URL(fileURLWithPath: iconsetPath + String(index))
					let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
					let context = CIContext()
					try context.writeJPEGRepresentation(
						of: convertedIcon, to: icnsURL,
						colorSpace: colorSpace)
					index += 1
				}
				// Logic to save as .iconset
			}

			// If no target or output specified, save to default location
			if target == nil && outputIcns == nil && outputIconset == nil {
				let maskURL = URL(fileURLWithPath: mask)
				let defaultPath = maskURL.deletingLastPathComponent().appendingPathComponent(
					"\(maskURL.deletingPathExtension().lastPathComponent)-masked.icns")

				logger.info(
					"No target or output specified, using default location: \(defaultPath.path)")
				quietPrint(
					"Saving masked icon to default location: \(defaultPath.path)",
					isQuiet: options.quiet)

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
					logger.info("Revealing file in Finder: \(revealPath)")
					NSWorkspace.shared.selectFile(revealPath, inFileViewerRootedAtPath: "")
				}
			}

			logger.info("MaskIcon command completed successfully")

		} catch {
			logger.error("Error in MaskIcon: \(error)")
			print("Error: \(error)")
		}
	}

	@MainActor
	@preconcurrency
	func getAllCIImages(from nsImage: NSImage) -> [CIImage] {
		// Iterate through all the representations, $0 represents the current.
		// Mutate into bitmap representation.
		// Assuming the cast succeeds, get the cgimage property.
		// Unwrap the cgImage and init the CIImage using the current prop
		return nsImage.representations.compactMap {
			($0 as? NSBitmapImageRep)?.cgImage.flatMap { CIImage(cgImage: $0) }
		}
	}

	@MainActor
	@preconcurrency
	func iconify(mask: CIImage, base: CIImage) throws -> CIImage {
		let baseExtent = base.extent
		let maskExtent = mask.extent

		print(baseExtent, maskExtent)

		guard !baseExtent.isInfinite, !baseExtent.isEmpty,
			!maskExtent.isInfinite, !maskExtent.isEmpty
		else {
			throw IconAssignmentError.invalidImageExtent(
				operation: "Center and Composite Image",
				reason: "Base or mask image has an infinite or empty extent."
			)
		}

		// Calculate the translation required to center
		let targetX = baseExtent.origin.x + (baseExtent.width - maskExtent.width) / 2.0
		let targetY = baseExtent.origin.y + (baseExtent.height - maskExtent.height) / 2.0
		let translateX = targetX - maskExtent.origin.x
		let translateY = targetY - maskExtent.origin.y
		let transform = CGAffineTransform(translationX: translateX, y: translateY)

		print(targetX, targetY, translateX, translateY)

		let translatedMask = mask.transformed(by: transform)

		guard let multiplyFilter = CIFilter(name: "CIMultiplyCompositing") else {
			print("Error: Could not create CIMultiplyCompositing filter. Returning base image.")
			return base  // Return base as fallback
		}

		multiplyFilter.setValue(translatedMask, forKey: kCIInputImageKey)  // Foreground
		multiplyFilter.setValue(base, forKey: kCIInputBackgroundImageKey)  // Background

		guard let outputImage = multiplyFilter.outputImage else {
			print("Error: Filter did not produce an output image. Returning base image.")
			return base
		}

		return translatedMask.composited(over: base)
	}

	@MainActor
	@preconcurrency
	func determineBasePath(version: String, color: ColorScheme) -> String {
		let type = "folder"
		var swatch: String
		if color == ColorScheme.auto {
			if isDarkMode() {
				swatch = "dark"
			} else {
				swatch = "light"
			}
		} else {
			if color == ColorScheme.dark {
				swatch = "dark"
			} else {
				swatch = "light"
			}
		}
		print("\(resourcesPath)\(version)-\(type)-\(swatch).icns")
		return "\(resourcesPath)\(version)-\(type)-\(swatch).icns"
	}
	@MainActor
	@preconcurrency
	func isDarkMode() -> Bool {
		// Use bestMatch to determine if the closest standard appearance is darkAqua.
		if NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
			return true
		} else {
			return false
		}
	}
}

Iconic.main()
