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
let appName = "iconic"
let maintainerName = "philocalyst"

let home_env = ProcessInfo.processInfo.environment["HOME"]
let resourcesPath: String
if let home = home_env {
	resourcesPath = home + ".local/share/" + appName + "/"
}

enum IconAssignmentError: Error, CustomStringConvertible {
	case missingArgument(description: String)
	case imageConversionFailed(description: String)
	case invalidSourceSize
	case invalidTargetDimensions
	case missingAlpha(description: String)
	case filterFailure(filter: String)
	case cliExecutionFailed(command: String, exitCode: Int32, errorOutput: String)
	case cliOutputParsingFailed(output: String, description: String)
	case invalidTrimCoordinates(description: String)
	case vipsNotFound(path: String)
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
		case .invalidImage(let pathOrReason):  // Modified to handle general invalid image issues
			return "Invalid Image: \(pathOrReason)"
		case .cliExecutionFailed(let command, let exitCode, let errorOutput):
			return
				"CLI command failed (Exit Code: \(exitCode)): '\(command)'. Error: \(errorOutput)"
		case .cliOutputParsingFailed(let output, let description):
			return "Failed to parse CLI output: \(description). Output was: '\(output)'"
		case .invalidTrimCoordinates(let description):
			return "Invalid Trim Coordinates: \(description)"  // Added prefix for clarity
		case .vipsNotFound(let path):
			return
				"Required command-line tool 'vips' not found at expected path: \(path). Please ensure libvips is installed and accessible."
		case .missingAlpha(let description):
			return description
		case .imageConversionFailed(let description):
			return description
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
		default:
			return "Failed"
		}
	}
}

extension CGBitmapInfo {
	public enum ComponentLayout {
		case bgra
		case abgr
		case argb
		case rgba
		case bgr
		case rgb

		var count: Int {
			switch self {
			case .bgr, .rgb: return 3
			default: return 4
			}
		}
	}

	public var componentLayout: ComponentLayout? {
		guard let alphaInfo = CGImageAlphaInfo(rawValue: rawValue & Self.alphaInfoMask.rawValue)
		else { return nil }
		let isLittleEndian = contains(.byteOrder32Little)

		if alphaInfo == .none {
			return isLittleEndian ? .bgr : .rgb
		}
		let alphaIsFirst =
			alphaInfo == .premultipliedFirst || alphaInfo == .first || alphaInfo == .noneSkipFirst

		if isLittleEndian {
			return alphaIsFirst ? .bgra : .abgr
		} else {
			return alphaIsFirst ? .argb : .rgba
		}
	}

	public var chromaIsPremultipliedByAlpha: Bool {
		let alphaInfo = CGImageAlphaInfo(rawValue: rawValue & Self.alphaInfoMask.rawValue)
		return alphaInfo == .premultipliedFirst || alphaInfo == .premultipliedLast
	}
}

extension CGColor {
	public static func create(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) -> CGColor {
		return CGColor(
			red: CGFloat(red) / 255,
			green: CGFloat(green) / 255,
			blue: CGFloat(blue) / 255,
			alpha: CGFloat(alpha) / 255
		)
	}
}

extension CIImage {
	// MARK: - Basic Operations
	//

	var pixelWidth: Int {
		return cgImage?.width ?? 0
	}

	var pixelHeight: Int {
		return cgImage?.height ?? 0
	}

	func pixelColor(x: Int, y: Int) -> CGColor {
		assert(
			0..<pixelWidth ~= x && 0..<pixelHeight ~= y,
			"Pixel coordinates are out of bounds"
		)

		guard
			let cgImage = cgImage,
			let data = cgImage.dataProvider?.data,
			let dataPtr = CFDataGetBytePtr(data),
			let colorSpaceModel = cgImage.colorSpace?.model,
			let componentLayout = cgImage.bitmapInfo.componentLayout
		else {
			assertionFailure("Could not get a pixel of an image")
			return CGColor(gray: 0, alpha: 0)
		}

		assert(
			colorSpaceModel == .rgb,
			"The only supported color space model is RGB"
		)
		assert(
			cgImage.bitsPerPixel == 32 || cgImage.bitsPerPixel == 24,
			"A pixel is expected to be either 4 or 3 bytes in size"
		)

		let bytesPerRow = cgImage.bytesPerRow
		let bytesPerPixel = cgImage.bitsPerPixel / 8
		let pixelOffset = y * bytesPerRow + x * bytesPerPixel

		if componentLayout.count == 4 {
			let components = (
				dataPtr[pixelOffset + 0],
				dataPtr[pixelOffset + 1],
				dataPtr[pixelOffset + 2],
				dataPtr[pixelOffset + 3]
			)

			var alpha: UInt8 = 0
			var red: UInt8 = 0
			var green: UInt8 = 0
			var blue: UInt8 = 0

			switch componentLayout {
			case .bgra:
				alpha = components.3
				red = components.2
				green = components.1
				blue = components.0
			case .abgr:
				alpha = components.0
				red = components.3
				green = components.2
				blue = components.1
			case .argb:
				alpha = components.0
				red = components.1
				green = components.2
				blue = components.3
			case .rgba:
				alpha = components.3
				red = components.0
				green = components.1
				blue = components.2
			default:
				return CGColor(gray: 0, alpha: 0)
			}

			/// If chroma components are premultiplied by alpha and the alpha is `0`,
			/// keep the chroma components to their current values.
			if cgImage.bitmapInfo.chromaIsPremultipliedByAlpha, alpha != 0 {
				let invisibleUnitAlpha = 255 / CGFloat(alpha)
				red = UInt8((CGFloat(red) * invisibleUnitAlpha).rounded())
				green = UInt8((CGFloat(green) * invisibleUnitAlpha).rounded())
				blue = UInt8((CGFloat(blue) * invisibleUnitAlpha).rounded())
			}

			return CGColor.create(red: red, green: green, blue: blue, alpha: alpha)

		} else if componentLayout.count == 3 {
			let components = (
				dataPtr[pixelOffset + 0],
				dataPtr[pixelOffset + 1],
				dataPtr[pixelOffset + 2]
			)

			var red: UInt8 = 0
			var green: UInt8 = 0
			var blue: UInt8 = 0

			switch componentLayout {
			case .bgr:
				red = components.2
				green = components.1
				blue = components.0
			case .rgb:
				red = components.0
				green = components.1
				blue = components.2
			default:
				return CGColor(gray: 0, alpha: 0)
			}

			return CGColor.create(red: red, green: green, blue: blue, alpha: UInt8(255))

		} else {
			assertionFailure("Unsupported number of pixel components")
			return CGColor(gray: 0, alpha: 0)
		}
	}

	/// Colorizes the image with a specified fill color
	func fillColorize(color: CIColor) throws -> CIImage {
		guard let colorFilter = CIFilter(name: "CIColorMonochrome") else {
			throw IconAssignmentError.filterFailure(filter: "CIColorMonochrome")
		}

		colorFilter.setValue(self, forKey: kCIInputImageKey)
		colorFilter.setValue(color, forKey: kCIInputColorKey)
		colorFilter.setValue(1.0, forKey: kCIInputIntensityKey)

		guard let outputImage = colorFilter.outputImage else {
			throw IconAssignmentError.imageConversionFailed(description: "Failed to colorize image")
		}

		return outputImage
	}

	func resize(atRatio targetRatio: CGFloat, relativeTo baseDimension: CGSize)
		throws -> CIImage
	{
		guard let resizeFilter = CIFilter(name: "CILanczosScaleTransform") else {
			throw IconAssignmentError.filterFailure(filter: "CILanczosScaleTransform")
		}

		let sourceSize = self.extent.size
		guard sourceSize.width > 0 && sourceSize.height > 0 else {
			print("Warning: Input image has zero dimensions. Returning original image.")
			throw IconAssignmentError.invalidSourceSize
		}

		let targetSize = CGSize(
			width: baseDimension.width * targetRatio,
			height: baseDimension.height * targetRatio)

		guard targetSize.width > 0 && targetSize.height > 0 else {
			// Handle cases where baseDimension or targetRatio results in zero target size
			throw IconAssignmentError.invalidTargetDimensions
		}

		// The image needs to fit within the targetSize.
		let widthRatio = targetSize.width / sourceSize.width
		let heightRatio = targetSize.height / sourceSize.height

		// Minimum to bound-check
		let scale = min(widthRatio, heightRatio)

		// Ensure scale is positive
		guard scale > 0 else {
			// Only really possible if you have a non-positive input value
			throw IconAssignmentError.invalidTargetDimensions
		}

		resizeFilter.setValue(self, forKey: kCIInputImageKey)
		resizeFilter.setValue(scale, forKey: kCIInputScaleKey)
		// Aspect ratio needs to be one for even scaling
		resizeFilter.setValue(1.0, forKey: kCIInputAspectRatioKey)

		guard let resizedImage = resizeFilter.outputImage else {
			throw IconAssignmentError.filterFailure(filter: "CILanczosScaleTransform_Output")
		}

		return resizedImage
	}

	func center(overBase base: CIImage) throws -> CIImage {
		let baseExtent = base.extent
		let maskExtent = self.extent

		// Calculate the translation required to center
		let targetX = baseExtent.origin.x + (baseExtent.width - maskExtent.width) / 2.0
		let targetY = baseExtent.origin.y + (baseExtent.height - maskExtent.height) / 2.0
		let translateX = targetX - maskExtent.origin.x
		let translateY = targetY - maskExtent.origin.y

		print(targetX, targetY, translateX, translateY)

		// Apply translation transform
		let transform = CGAffineTransform(translationX: translateX, y: translateY)
		return self.transformed(by: transform)
	}

	/// Adjusts the opacity of the image
	func applyOpacity(_ opacity: CGFloat) throws -> CIImage {
		let outputImage = self.applyingFilter(
			"CIColorMatrix",
			parameters: [
				"inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
				"inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
				"inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
				"inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity),
				"inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
			])

		return outputImage
	}

	func engrave(sizeMask: CIImage, templateIcon: CIImage, inputs: EngravingInputs) throws
		-> CIImage
	{
		let fillColorized = try sizeMask.fillColorize(color: inputs.fillColor)

		let fill = try fillColorized.applyOpacity(0.5)

		let topBezelComplement = try sizeMask.negate()

		let topBezelColorized = try topBezelComplement.fillColorize(color: inputs.topBezel.color)

		let topBezelBlurred = try topBezelColorized.blurDown(radius: inputs.topBezel.blur)

		// Composite top bezel
		let topBezelMasked = try topBezelBlurred.maskDown(
			mask: sizeMask, operation: inputs.topBezel.maskOperation)

		let topBezel = try topBezelMasked.applyOpacity(inputs.topBezel.opacity)

		let bottomBezelColorized = try sizeMask.fillColorize(color: inputs.bottomBezel.color)

		let bottomBezelBlurred = try bottomBezelColorized.blurDown(radius: inputs.bottomBezel.blur)

		// Composite bottom bezel
		let bottomBezelMasked = try bottomBezelBlurred.maskDown(
			mask: sizeMask, operation: inputs.bottomBezel.maskOperation)

		// Set bottom bezel opacity
		let bottomBezel = try bottomBezelMasked.applyOpacity(inputs.bottomBezel.opacity)

		// Engraving
		let compositedWithBottom = try templateIcon.composite(
			over: bottomBezel, operation: "dissolve")

		let compositedWithFill = try compositedWithBottom.composite(
			over: fill, operation: "dissolve")

		return try compositedWithFill.composite(over: topBezel, operation: "dissolve")
	}

	func composite(over background: CIImage, operation: String = "dissolve") throws -> CIImage {
		let filterName: String

		switch operation {
		case "dissolve":
			filterName = "CISourceOverCompositing"
		case "multiply":
			filterName = "CIMultiplyBlendMode"
		case "screen":
			filterName = "CIScreenBlendMode"
		case "overlay":
			filterName = "CIOverlayBlendMode"
		default:
			filterName = "CISourceOverCompositing"
		}

		guard let filter = CIFilter(name: filterName) else {
			throw IconAssignmentError.filterFailure(filter: filterName)
		}

		filter.setValue(self, forKey: kCIInputImageKey)
		filter.setValue(background, forKey: kCIInputBackgroundImageKey)

		guard let outputImage = filter.outputImage else {
			throw IconAssignmentError.imageConversionFailed(
				description: "Failed to composite images")
		}

		return outputImage
	}

	func negate() throws -> CIImage {
		let outputImage = self.applyingFilter("CIColorInvert")
		return outputImage
	}

	func blurDown(radius: CGFloat) throws -> CIImage {
		let outputImage = self.applyingFilter(
			"CIGaussianBlur", parameters: ["inputRadius": radius])

		return outputImage
	}

	func maskDown(mask: CIImage, operation: String) throws -> CIImage {
		switch operation {
		case "multiply", "default":
			guard let blendFilter = CIFilter(name: "CIBlendWithMask") else {
				throw IconAssignmentError.filterFailure(filter: "CIBlendWithMask")
			}

			blendFilter.setValue(self, forKey: kCIInputImageKey)
			blendFilter.setValue(CIImage.empty(), forKey: kCIInputBackgroundImageKey)
			blendFilter.setValue(mask, forKey: kCIInputMaskImageKey)

			guard let outputImage = blendFilter.outputImage else {
				throw IconAssignmentError.imageConversionFailed(description: "Failed to mask image")
			}

			return outputImage

		case "dst-in":

			guard let dstInFilter = CIFilter(name: "CISourceOutCompositing") else {
				throw IconAssignmentError.filterFailure(filter: "CISourceOutCompositing")
			}

			dstInFilter.setValue(self, forKey: kCIInputImageKey)
			dstInFilter.setValue(mask, forKey: kCIInputBackgroundImageKey)

			guard let outputImage = dstInFilter.outputImage else {
				throw IconAssignmentError.imageConversionFailed(
					description: "Failed to composite image")
			}

			return outputImage
		case "dst-out":
			guard let dstOutFilter = CIFilter(name: "CISourceInCompositing") else {
				throw IconAssignmentError.filterFailure(filter: "CISourceInCompositing")
			}

			dstOutFilter.setValue(self, forKey: kCIInputImageKey)
			dstOutFilter.setValue(mask, forKey: kCIInputBackgroundImageKey)

			guard let outputImage = dstOutFilter.outputImage else {
				throw IconAssignmentError.imageConversionFailed(
					description: "Failed to composite image")
			}

			return outputImage
		case "darken":
			guard let darkenFilter = CIFilter(name: "CIDarkenBlendMode") else {
				throw IconAssignmentError.filterFailure(filter: "CIDarkenBlendMode")
			}

			darkenFilter.setValue(self, forKey: kCIInputImageKey)
			darkenFilter.setValue(mask, forKey: kCIInputBackgroundImageKey)

			guard let outputImage = darkenFilter.outputImage else {
				throw IconAssignmentError.imageConversionFailed(
					description: "Failed to darken mask image")
			}

			return outputImage

		default:
			throw IconAssignmentError.invalidImageExtent(
				operation: "maskDown", reason: "Unknown mask operation: \(operation)")
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
			let maskk = try cropTransparentPadding(image: maskIcons[0])

			var convertedIcons: [CIImage] = []

			if maskIcons.count == folderIcons.count {
				for (mask, folder) in zip(maskIcons, folderIcons) {
					try convertedIcons.append(iconify(mask: mask, base: folder))
				}
			} else {
				for base in folderIcons {
					try convertedIcons.append(iconify(mask: maskk, base: base))
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
					try context.writePNGRepresentation(
						of: convertedIcon, to: icnsURL,
						format: .RGBA8,
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
		try validateImageExtents(mask: mask, base: base)

		let cropped_base = try cropTransparentPadding(image: base)

		let resizedMask = try mask.resize(
			atRatio: 0.5, relativeTo: cropped_base.extent.size)

		let centeredMask = try resizedMask.center(overBase: cropped_base)

		)
	}

	func validateImageExtents(mask: CIImage, base: CIImage) throws {
		let baseExtent = base.extent
		let maskExtent = mask.extent

		guard !baseExtent.isInfinite, !baseExtent.isEmpty,
			!maskExtent.isInfinite, !maskExtent.isEmpty
		else {
			throw IconAssignmentError.invalidImageExtent(
				operation: "Center and Composite Image",
				reason: "Base or mask image has an infinite or empty extent."
			)
		}
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
		let appearance = UserDefaults.standard.string(forKey: "AppleInterfaceStyle")
		return appearance == "Dark"
	}

	func cropTransparentPadding(image: CIImage) throws -> CIImage {

		let context = CIContext()
		guard let cgImage = context.createCGImage(image, from: image.extent) else {
			throw IconAssignmentError.imageConversionFailed(
				description: "Failed to create CGImage from CIImage")
		}

		let temporaryDirectory = FileManager.default.temporaryDirectory
		let inputFileName = UUID().uuidString + ".png"
		let inputFileURL = temporaryDirectory.appendingPathComponent(inputFileName)

		guard
			let destination = CGImageDestinationCreateWithURL(
				inputFileURL as CFURL, UTType.png.identifier as CFString, 1, nil)
		else {
			throw IconAssignmentError.imageConversionFailed(
				description: "Failed to create image destination for input")
		}

		CGImageDestinationAddImage(destination, cgImage, nil)
		guard CGImageDestinationFinalize(destination) else {
			// Ensure cleanup even if finalize fails but file might exist
			try? FileManager.default.removeItem(at: inputFileURL)
			throw IconAssignmentError.imageConversionFailed(
				description: "Failed to save temporary input image")
		}

		defer {
			try? FileManager.default.removeItem(at: inputFileURL)
		}

		let vipsPath = "/opt/homebrew/bin/vips"

		guard FileManager.default.fileExists(atPath: vipsPath) else {
			throw IconAssignmentError.vipsNotFound(path: vipsPath)
		}

		let findTrimArgs = [
			"find_trim", inputFileURL.path, "--background", "0", "--threshold", "0",
		]
		let findTrimOutput: String
		do {
			findTrimOutput = try runCommand(executable: vipsPath, arguments: findTrimArgs)
			print(findTrimArgs)
		} catch {
			throw IconAssignmentError.invalidImage(path: "find_trim failed: \(error)")
		}

		let coordsString = findTrimOutput.trimmingCharacters(in: .whitespacesAndNewlines)
		let coordsArray = coordsString.split(separator: "\n").map { String($0) }

		print(coordsArray)

		guard coordsArray.count == 4,
			let left = Int(coordsArray[0]),
			let top = Int(coordsArray[1]),
			let width = Int(coordsArray[2]),
			let height = Int(coordsArray[3])
		else {
			throw IconAssignmentError.cliOutputParsingFailed(
				output: findTrimOutput,
				description: "Failed to parse 4 integer coordinates from find_trim output.")
		}

		if width <= 0 || height <= 0 {
			return image
		}

		let outputFileName = UUID().uuidString + ".png"
		let outputFileURL = temporaryDirectory.appendingPathComponent(outputFileName)

		defer {
			try? FileManager.default.removeItem(at: outputFileURL)
		}

		let cropArgs = [
			"crop",
			inputFileURL.path,
			outputFileURL.path,
			String(left),
			String(top),
			String(width),
			String(height),
		]

		do {
			_ = try runCommand(executable: vipsPath, arguments: cropArgs)  // Output not needed here
		} catch {
			throw IconAssignmentError.invalidImage(path: "crop failed: \(error)")
		}

		guard let processedCIImage = CIImage(contentsOf: outputFileURL) else {
			throw IconAssignmentError.imageConversionFailed(
				description:
					"Failed to create CIImage from cropped file data at \(outputFileURL.path)")
		}

		// Temporary files are cleaned up by the defer statements

		return processedCIImage
	}

	// Helper function to run shell commands
	func runCommand(executable: String, arguments: [String]) throws -> String {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: executable)
		process.arguments = arguments

		let outputPipe = Pipe()
		let errorPipe = Pipe()
		process.standardOutput = outputPipe
		process.standardError = errorPipe

		do {
			try process.run()
			process.waitUntilExit()

			let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
			let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

			let output = String(data: outputData, encoding: .utf8) ?? ""
			let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

			if process.terminationStatus == 0 {
				return output
			} else {
				throw IconAssignmentError.cliExecutionFailed(
					command: "\(executable) \(arguments.joined(separator: " "))",
					exitCode: process.terminationStatus,
					errorOutput: errorOutput.isEmpty ? "No error output" : errorOutput
				)
			}
		} catch {
			// Catch errors from process.run() itself (e.g., executable not found, though we check earlier)
			throw IconAssignmentError.cliExecutionFailed(
				command: "\(executable) \(arguments.joined(separator: " "))",
				exitCode: -1,  // Indicate launch failure
				errorOutput: "Failed to launch process: \(error.localizedDescription)"
			)
		}
	}

}

Iconic.main()
