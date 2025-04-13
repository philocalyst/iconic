import AppKit
import ArgumentParser
import CoreImage
import Foundation
import Logging
import Metal
import MetalKit
import UniformTypeIdentifiers

final class LoggerProvider: @unchecked Sendable {
	static let shared = LoggerProvider()

	// Using a lock here to protect access to the internalLogger
	private let lock = NSLock()

	private var internalLogger: Logger

	private init() {
		self.internalLogger = Logger(label: "com.philocalyst.iconic")
		self.internalLogger.logLevel = .notice
	}

	func configure(level: Logger.Level) {
		lock.lock()
		defer {
			lock.unlock()
		}
		self.internalLogger.logLevel = level
		internalLogger.info("Logger level configured to: \(level.rawValue)")
	}

	func getLogger() -> Logger {
		lock.lock()
		defer {
			lock.unlock()
		}
		// This returns a copy holding the current configuration
		return internalLogger
	}
}

enum ColorScheme: String, ExpressibleByArgument, CaseIterable {
	case auto, light, dark
}

let appName = "iconic"
let maintainerName = "philocalyst"

let resourcesPath: String? = ProcessInfo.processInfo.environment["HOME"].map { homeDir in
	"\(homeDir)/.local/share/\(appName)/"
}

struct EngravingInputs {
	let fillColor: CIColor
	let topBezel: BezelSettings
	let bottomBezel: BezelSettings

	struct BezelSettings {
		let color: CIColor
		let blur: CGFloat
		let maskOperation: String
		let opacity: CGFloat
	}
}

enum ImageTrimError: LocalizedError {
	case metalInitializationFailed(String)
	case bufferCreationFailed
	case commandCreationFailed
	case calculationFailed
	case ciContextCreationFailed
	case ciImageRenderingFailed(String)
	case ciImageHasInfiniteExtent
	case metalTextureCreationFailed

	var errorDescription: String? {
		switch self {
		case .metalInitializationFailed(let reason):
			return "Failed to initialize Metal: \(reason)"
		case .bufferCreationFailed:
			return "Failed to create Metal buffer for bounding box."
		case .commandCreationFailed:
			return "Failed to create Metal command buffer or encoder."
		case .calculationFailed:
			return
				"Metal kernel failed to find a valid bounding box (e.g., image is fully transparent or calculation error)."
		case .ciContextCreationFailed:
			return "Failed to create CIContext for rendering."
		case .ciImageRenderingFailed(let reason):
			return "Failed to render CIImage to Metal texture: \(reason)"
		case .ciImageHasInfiniteExtent:
			return "Cannot process CIImage with infinite extent."
		case .metalTextureCreationFailed:
			return "Failed to create Metal texture for rendering CIImage."
		}
	}
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

@preconcurrency final class MetalTrimmingContext {

	let log = LoggerProvider.shared.getLogger()

	// Shared instance for the program
	static let shared = try! MetalTrimmingContext()

	let device: MTLDevice
	let commandQueue: MTLCommandQueue
	let pipelineState: MTLComputePipelineState
	let ciContext: CIContext  // Needed for rendering the CIImage to texture

	// This constant is for matching the struct the metal engine uses to calculate the bounding box
	enum BBoxIndex: Int {
		case minX = 0
		case minY = 1
		case maxX = 2
		case maxY = 3
		static let count = 4
	}

	private init() throws {
		// Retrieve the metal device, using the default processor
		guard let defaultDevice = MTLCreateSystemDefaultDevice() else {
			throw ImageTrimError.metalInitializationFailed("Could not create default Metal device.")
		}

		self.device = defaultDevice
		log.info("MetalTrimmingContext: Using Metal device: \(device.name)")

		guard let queue = device.makeCommandQueue() else {
			throw ImageTrimError.metalInitializationFailed("Could not create command queue.")
		}
		self.commandQueue = queue

		// CIConext backed by metal device
		self.ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
		log.info("MetalTrimmingContext: CIContext created.")

		// Loading the metal library and our custom kernel function
		let kernelFunction: MTLFunction
		do {
			// Try loading the default library from the default location (main)
			let library = try device.makeDefaultLibrary(bundle: .main)
			guard let function = library.makeFunction(name: "findBoundingBox") else {
				throw ImageTrimError.metalInitializationFailed(
					"Kernel 'findBoundingBox' not found in default library.")
			}
			kernelFunction = function
			print("Loaded kernel function from default library.")
		} catch {
			// If loading the precompiled from that location doesn't work, try to compile ourselves.
			print("Default library not found or kernel missing. Trying to compile from source...")
			let metalFileURL = URL(
				fileURLWithPath: "/Users/philocalyst/Projects/iconic/Sources/SmartTrim.metal"
			)  // Stand-in pathing

			guard FileManager.default.fileExists(atPath: metalFileURL.path) else {
				throw ImageTrimError.metalInitializationFailed(
					"SmartTrim.metal not found at \(metalFileURL.path). Cannot compile from source."
				)
			}

			// Compilation
			do {
				let source = try String(contentsOf: metalFileURL, encoding: .utf8)
				let library = try device.makeLibrary(source: source, options: nil)
				guard let function = library.makeFunction(name: "findBoundingBox") else {
					throw ImageTrimError.metalInitializationFailed(
						"Kernel 'findBoundingBox' not found after compiling source.")
				}
				kernelFunction = function
				print("Successfully compiled kernel function from source.")
			} catch let compileError {
				throw ImageTrimError.metalInitializationFailed(
					"Could not compile Metal source: \(compileError.localizedDescription)")
			}
		}

		// Create the compute pipeline state using the kernel function.
		do {
			self.pipelineState = try device.makeComputePipelineState(function: kernelFunction)
		} catch {
			throw ImageTrimError.metalInitializationFailed(
				"Could not create compute pipeline state: \(error.localizedDescription)")
		}
	}
}

// MARK: - CIImage Extension (Existing + New Metal Bounding Box)
extension CIImage {

	}

	var pixelHeight: Int {
		return cgImage?.height ?? 0
	}



		let log = LoggerProvider.shared.getLogger()


			)









		} else {
			assertionFailure("Unsupported number of pixel components")
			return CGColor(gray: 0, alpha: 0)
		}
	}

	/// Responsible for detecting the bounding box of non-transparent pixels
	/// Assumes that transparency is defined by the alpha channel, and an alpha threshold (Defined in the metal source)
	/// Returning a bounding box as a CGRect that correspounds to the image's coordinate space from its extent origin.
	// If the image is fully transparent, has no dimensions, or has infinite extent; returns as a CGRect.null.
	/// Throwing erros as ImageTrimError
	func getAliveImage() throws -> CGRect {
		let log = LoggerProvider.shared.getLogger()
		let metalContext = MetalTrimmingContext.shared  // Get shared context
		let device = metalContext.device
		let commandQueue = metalContext.commandQueue
		let pipelineState = metalContext.pipelineState
		let ciContext = metalContext.ciContext
		typealias BBoxIndex = MetalTrimmingContext.BBoxIndex  // Use enum from context

		let imageExtent = self.extent
		guard !imageExtent.isInfinite, imageExtent.width > 0, imageExtent.height > 0 else {
			log.info(
				"Cannot find bounding box: CIImage has zero size or infinite extent: \(imageExtent.debugDescription)",
			)
			return .null
		}

		let textureWidth = Int(imageExtent.width.rounded(.up))
		let textureHeight = Int(imageExtent.height.rounded(.up))

		// Create substrate Metal Texture
		let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
			pixelFormat: .bgra8Unorm,
			width: textureWidth,
			height: textureHeight,
			mipmapped: false
		)
		textureDescriptor.usage = [.shaderRead, .renderTarget]  // Readable by kernel, writable by CIContext
		textureDescriptor.storageMode = .private

		guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
			throw ImageTrimError.metalTextureCreationFailed
		}
		texture.label = "BoundingBox Render Target Texture"

		// Render CIImage to Metal Texture
		let renderCommandBuffer = commandQueue.makeCommandBuffer()
		renderCommandBuffer?.label = "CIImage Render To Texture CB"

		// Determine render bounds and colorspace
		let renderBounds = CGRect(
			origin: .zero, size: CGSize(width: textureWidth, height: textureHeight))
		let renderImage = self.transformed(
			by: .init(translationX: -imageExtent.origin.x, y: -imageExtent.origin.y))  // Adjust origin to 0,0 for rendering to expectations
		let colorSpace = self.colorSpace ?? CGColorSpaceCreateDeviceRGB()  // Ensure valid colorspace

		ciContext.render(
			renderImage,
			to: texture,
			commandBuffer: renderCommandBuffer,
			bounds: renderBounds,
			colorSpace: colorSpace)

		renderCommandBuffer?.commit()
		renderCommandBuffer?.waitUntilCompleted()  // Wait for rendering to finish the rest of the functions run

		if let error = renderCommandBuffer?.error {
			throw ImageTrimError.ciImageRenderingFailed(
				"GPU error during CIContext render: \(error.localizedDescription)")
		}
		log.debug("CIImage rendered to Metal texture for bounding box calculation.")

		// Create results buffer
		let bufferSize = BBoxIndex.count * MemoryLayout<UInt32>.stride
		guard
			let boundingBoxBuffer = device.makeBuffer(
				length: bufferSize, options: [.storageModeShared])
		else {
			throw ImageTrimError.bufferCreationFailed
		}
		boundingBoxBuffer.label = "Bounding Box Result Buffer"

		// Initialize buffer (min coords = max value, max coords = 0)
		let bufferPointer = boundingBoxBuffer.contents().bindMemory(
			to: UInt32.self, capacity: BBoxIndex.count)
		bufferPointer[BBoxIndex.minX.rawValue] = UInt32.max
		bufferPointer[BBoxIndex.minY.rawValue] = UInt32.max
		bufferPointer[BBoxIndex.maxX.rawValue] = 0
		bufferPointer[BBoxIndex.maxY.rawValue] = 0

		// Encode and Dispatch Compute Kernel
		guard let computeCommandBuffer = commandQueue.makeCommandBuffer() else {
			throw ImageTrimError.commandCreationFailed
		}
		computeCommandBuffer.label = "Find Bounding Box Compute CB"

		guard let computeCommandEncoder = computeCommandBuffer.makeComputeCommandEncoder() else {
			throw ImageTrimError.commandCreationFailed
		}
		computeCommandEncoder.label = "Find Bounding Box Encoder"

		computeCommandEncoder.setComputePipelineState(pipelineState)
		computeCommandEncoder.setTexture(texture, index: 0)  // Input texture at index 0
		computeCommandEncoder.setBuffer(boundingBoxBuffer, offset: 0, index: 0)  // Output buffer at index 0

		// Calculate threadgroups
		let threadsPerGroupWidth = pipelineState.threadExecutionWidth
		let threadsPerGroupHeight =
			pipelineState.maxTotalThreadsPerThreadgroup / threadsPerGroupWidth
		let threadsPerThreadgroup = MTLSize(
			width: threadsPerGroupWidth, height: threadsPerGroupHeight, depth: 1)
		let numThreadgroups = MTLSize(
			width: (texture.width + threadsPerGroupWidth - 1) / threadsPerGroupWidth,
			height: (texture.height + threadsPerGroupHeight - 1) / threadsPerGroupHeight,
			depth: 1
		)

		computeCommandEncoder.dispatchThreadgroups(
			numThreadgroups, threadsPerThreadgroup: threadsPerThreadgroup)
		computeCommandEncoder.endEncoding()

		// Execute, read
		let startTime = DispatchTime.now()
		computeCommandBuffer.commit()
		computeCommandBuffer.waitUntilCompleted()  // Wait for GPU kernel execution
		let endTime = DispatchTime.now()

		let nanoTime = endTime.uptimeNanoseconds - startTime.uptimeNanoseconds
		let timeIntervalMilliseconds = Double(nanoTime) / 1_000_000.0
		log.info("Metal bounding box compute time: \(timeIntervalMilliseconds) ms")

		if let error = computeCommandBuffer.error {
			throw ImageTrimError.metalInitializationFailed(
				"GPU command execution failed: \(error.localizedDescription)")
		}

		// Read results back from buffer
		// Re-bind pointer just in case with the storage mode and wait until completed..
		let resultPointer = boundingBoxBuffer.contents().bindMemory(
			to: UInt32.self, capacity: BBoxIndex.count)
		let minX = Int(resultPointer[BBoxIndex.minX.rawValue])
		let minY = Int(resultPointer[BBoxIndex.minY.rawValue])
		let maxX = Int(resultPointer[BBoxIndex.maxX.rawValue])
		let maxY = Int(resultPointer[BBoxIndex.maxY.rawValue])

		// Check if any non-transparent pixels were found
		if minX == Int(UInt32.max) || minX > maxX || minY > maxY {
			log.info("Metal bounding box calculation found no non-transparent pixels.")
			return .null  // Indicate nothing was found
		}

		// Adjust coordinates back relative to the original image's extent origin
		let finalMinX = CGFloat(minX) + imageExtent.origin.x
		let finalMinY = CGFloat(minY) + imageExtent.origin.y
		let boundingWidth = CGFloat(maxX - minX + 1)
		let boundingHeight = CGFloat(maxY - minY + 1)

		let boundingBox = CGRect(
			x: finalMinX, y: finalMinY, width: boundingWidth, height: boundingHeight)

		log.debug("Metal found bounding box: \(boundingBox.debugDescription)")
		return boundingBox
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

// Respectful lil function; doesn't print when quiet is enabled
func quietPrint(_ message: String, isQuiet: Bool) {
	if !isQuiet {
		print(message)
	}
}

// Define the main command structure
@main
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

	mutating func run() throws {
		var log = LoggerProvider.shared.getLogger()
		if verbose && quiet {
			log.warning("Conflicting options: both verbose and quiet flags are enabled")
			print("ERROR CONFLICTING OPTIONS")
		} else if verbose {
			log.logLevel = Logger.Level.trace
			log.info("Verbose logging enabled")
		} else if quiet {
			log.logLevel = Logger.Level.error
			log.info("Quiet mode enabled - suppressing non-error output")
		} else {
			// Default log level
			log.logLevel = Logger.Level.notice
			log.info("Using default logging level")
		}
	}

	// MARK: - Utility functions for subcommands

	static func validPath(susPath: String?) throws -> URL {  // (Sus)picious Path
		let log = LoggerProvider.shared.getLogger()
		log.debug("Validating path: \(susPath ?? "<nil>")")
		guard let path = susPath, !path.isEmpty else {
			log.error("Invalid path: nil or empty")
			throw IconAssignmentError.invalidIconPath(
				path: susPath ?? "<nil or empty>",
				reason: "Path cannot be nil or empty")
		}

		let susURL = URL(fileURLWithPath: path)
		var isIconDirectory: ObjCBool = false

		guard FileManager.default.fileExists(atPath: path, isDirectory: &isIconDirectory) else {
			log.error("Path does not exist: \(path)")
			throw IconAssignmentError.invalidIconPath(path: path, reason: "File does not exist")
		}

		// Use 'path' for file system checks
		guard FileManager.default.isWritableFile(atPath: path) else {
			log.error("Path is not writable: \(path)")
			throw IconAssignmentError.permissionDenied(
				path: path,
				operation: "write/set attributes"
			)
		}

		guard FileManager.default.isReadableFile(atPath: path) else {
			log.error("Path is not readable: \(path)")
			throw IconAssignmentError.permissionDenied(path: path, operation: "read")
		}

		log.debug("Path validated successfully: \(path)")
		return susURL
	}

	static func createImage(imagePath: String?) throws -> NSImage {
		let log = LoggerProvider.shared.getLogger()
		// Validate base path
		let imageURL: URL
		do {
			log.debug("Attempting to create image from path: \(imagePath ?? "<nil>")")
			imageURL = try validPath(susPath: imagePath)
			guard let inputImg = NSImage(contentsOf: imageURL) else {
				log.error("Failed to load image at \(imageURL.path)")
				print("Error: Could not load image or invalid image format at \(imageURL.path)")
				throw IconAssignmentError.invalidImage(path: imageURL.path)
			}
			log.info("Successfully loaded image from \(imageURL.path)")
			return inputImg
		} catch {
			log.error("Error creating image: \(error)")
			print(error)
			throw IconAssignmentError.invalidImage(path: imagePath ?? "unknown")
		}
	}

	static func scales(image: NSImage) -> Bool {
		let log = LoggerProvider.shared.getLogger()
		// Multiples required for perfect mapping to the smallest size
		let result =
			(image.size.height == 384
				&& (image.size.width.truncatingRemainder(dividingBy: 128) == 0))
		log.debug(
			"Image scaling check: height=\(image.size.height), width=\(image.size.width), result=\(result)"
		)
		return result
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
		let log = LoggerProvider.shared.getLogger()
		log.info("GetIcon command started")
		log.debug(
			"Parameters - source: \(source), outputIcns: \(outputIcns ?? "nil"), outputIconset: \(outputIconset ?? "nil"), reveal: \(reveal)"
		)

		quietPrint("Extracting icon from \(source)...", isQuiet: options.quiet)

		// Validate the source path
		let sourceURL = try Iconic.validPath(susPath: source)
		log.info("Source path validated: \(sourceURL.path)")

		// Get the icon from the file or folder
		// NSWorkspace.shared.icon(forFile:) returns NSImage, not optional
		log.debug("Attempting to get icon from file: \(sourceURL.path)")
		let icon = NSWorkspace.shared.icon(forFile: sourceURL.path)
		log.info("Successfully retrieved icon from \(sourceURL.path)")

		// Determine output paths
		let outputIcnsURL = outputIcns.map { URL(fileURLWithPath: $0) }
		let outputIconsetURL = outputIconset.map { URL(fileURLWithPath: $0) }

		// Save the icon as requested
		if let icnsPath = outputIcnsURL {
			// Code to save as .icns would go here
			if options.verbose {
				log.debug("About to save icon to \(icnsPath.path)")
				print("Saving icon to \(icnsPath.path)")
			}

			// Placeholder for actual implementation
			log.info("Icon saved to \(icnsPath.path)")
			quietPrint("Icon saved to \(icnsPath.path)", isQuiet: options.quiet)
		}

		if let iconsetPath = outputIconsetURL {
			// Code to save as .iconset would go here
			if options.verbose {
				log.debug("About to save iconset to \(iconsetPath.path)")
				print("Saving iconset to \(iconsetPath.path)")
			}

			// Placeholder for actual implementation
			log.info("Iconset saved to \(iconsetPath.path)")
			quietPrint("Iconset saved to \(iconsetPath.path)", isQuiet: options.quiet)
		}

		// If no output specified, use default locations
		if outputIcnsURL == nil && outputIconsetURL == nil {
			let defaultIcnsURL = sourceURL.deletingLastPathComponent().appendingPathComponent(
				"\(sourceURL.lastPathComponent).icns")
			// Save to default location
			if options.verbose {
				log.debug("No output path specified, using default: \(defaultIcnsURL.path)")
				print("No output path specified, saving to \(defaultIcnsURL.path)")
			}

			// Placeholder for actual implementation
			log.info("Icon saved to default location: \(defaultIcnsURL.path)")
			quietPrint("Icon saved to \(defaultIcnsURL.path)", isQuiet: options.quiet)
		}

		// Reveal in Finder if requested
		if reveal {
			// Determine which file to reveal (in order of preference: icns, iconset)
			let fileToReveal = outputIcnsURL ?? outputIconsetURL
			if let revealURL = fileToReveal {
				log.info("Revealing file in Finder: \(revealURL.path)")
				NSWorkspace.shared.selectFile(revealURL.path, inFileViewerRootedAtPath: "")
			} else {
				log.warning("Reveal flag set but no file to reveal")
			}
		}

		log.info("GetIcon command completed successfully")
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
		let log = LoggerProvider.shared.getLogger()
		log.info("SetIcon command started")
		log.debug("Parameters - icon: \(icon), target: \(target), reveal: \(reveal)")

		quietPrint("Setting icon \(icon) on \(target)...", isQuiet: options.quiet)

		// Validate paths
		let iconURL = try Iconic.validPath(susPath: icon)
		let targetURL = try Iconic.validPath(susPath: target)
		log.info("Paths validated - icon: \(iconURL.path), target: \(targetURL.path)")

		// Check write permissions for the target item itself
		guard FileManager.default.isWritableFile(atPath: targetURL.path) else {
			log.error("Permission denied: Cannot write to target \(targetURL.path)")
			throw IconAssignmentError.permissionDenied(
				path: targetURL.path, operation: "write/set attributes")
		}

		guard let iconImage = NSImage(contentsOf: iconURL) else {
			log.error("Failed to load icon image from \(iconURL.path)")
			throw IconAssignmentError.iconLoadFailed(path: iconURL.path)
		}
		log.info("Successfully loaded icon image from \(iconURL.path)")

		if options.verbose {
			log.debug("About to apply icon to \(targetURL.path)")
			print("Applying icon to \(targetURL.path)")
		}

		log.debug("Calling NSWorkspace.setIcon")
		let success = NSWorkspace.shared.setIcon(iconImage, forFile: targetURL.path, options: [])

		guard success else {
			log.error("NSWorkspace.setIcon failed for \(targetURL.path)")
			throw IconAssignmentError.iconSetFailed(
				path: targetURL.path,
				reason:
					"NSWorkspace.setIcon returned false. Check permissions (including extended attributes) and disk space."
			)
		}

		log.info("Successfully applied icon to \(targetURL.path)")
		quietPrint("Successfully applied icon to \(targetURL.path)", isQuiet: options.quiet)

		if reveal {
			log.info("Revealing target in Finder: \(targetURL.path)")
			NSWorkspace.shared.selectFile(targetURL.path, inFileViewerRootedAtPath: "")
		}

		log.info("SetIcon command completed successfully")
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

	mutating func run() async {
		let log = LoggerProvider.shared.getLogger()
		log.info("MaskIcon command started")
		log.debug(
			"Parameters - mask: \(mask), target: \(target ?? "nil"), outputIcns: \(outputIcns ?? "nil"), outputIconset: \(outputIconset ?? "nil")"
		)
		log.debug(
			"Additional parameters - reveal: \(reveal), macOS: \(macOS ?? "nil"), colorScheme: \(colorScheme), noTrim: \(noTrim)"
		)

		do {
			if options.verbose {
				log.debug("About to process mask image: \(mask)")
				print("Processing mask image at \(mask)")
			}

			log.info("Loading input image from \(mask)")
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
				log.debug("Image loaded successfully")
				print("Image loaded successfully")
				log.debug("Checking if image scales perfectly")
				print("Image scales perfectly: \(Iconic.scales(image: maskImage))")
			}

			// Implement masking logic here
			log.info("Performing masking operation")

			// Apply to target if specified
			if let targetPath = target {
				log.info("Target specified, will apply icon to: \(targetPath)")
				quietPrint("Applying masked icon to \(targetPath)", isQuiet: options.quiet)

				// Logic to apply the icon to the target
				// This would generate the masked icon and apply it
			}

			// Save output files if specified
			if let icnsPath = outputIcns {
				log.info("Saving masked icon to specified .icns path: \(icnsPath)")

				// Logic to save as .icns
			}

			if let iconsetPath = outputIconset {
				log.info("Saving masked icon to specified .iconset path: \(iconsetPath)")
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

				log.info(
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
					log.info("Revealing file in Finder: \(revealPath)")
					NSWorkspace.shared.selectFile(revealPath, inFileViewerRootedAtPath: "")
				}
			}

			log.info("MaskIcon command completed successfully")

		} catch {
			log.error("Error in MaskIcon: \(error)")
			print("Error: \(error)")
		}
	}

	func getAllCIImages(from nsImage: NSImage) -> [CIImage] {
		// Iterate through all the representations, $0 represents the current.
		// Mutate into bitmap representation.
		// Assuming the cast succeeds, get the cgimage property.
		// Unwrap the cgImage and init the CIImage using the current prop
		return nsImage.representations.compactMap {
			($0 as? NSBitmapImageRep)?.cgImage.flatMap { CIImage(cgImage: $0) }
		}
	}

	func iconify(mask: CIImage, base: CIImage) async throws -> CIImage {
		try validateImageExtents(mask: mask, base: base)

		let cropped_base = try await cropPadding(image: base)

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
	func isDarkMode() -> Bool {
		let appearance = UserDefaults.standard.string(forKey: "AppleInterfaceStyle")
		return appearance == "Dark"
	}

	func cropPadding(image: CIImage) async throws -> CIImage {
		print("Creating Metal texture...")

		print("Running Metal kernel to find bounding box...")
		let boundingBox = try await image.getAliveImage()  // Timing is inside here now

		let croppedImage = image.cropped(to: boundingBox)
		return croppedImage
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
