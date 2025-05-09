import CoreImage
import Foundation
import Metal

/// A singleton to detect the minimal non‐transparent bounding
/// rectangle of a CIImage via a Metal kernel.

@MainActor
@preconcurrency final class MetalTrimmer {

  let log = AppLog.shared

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
      throw IconicError.metalInitializationFailed("Could not create default Metal device.")
    }

    self.device = defaultDevice
    log.info("MetalTrimmingContext: Using Metal device: \(device.name)")

    guard let queue = device.makeCommandQueue() else {
      throw IconicError.metalInitializationFailed("Could not create command queue.")
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
        throw IconicError.metalInitializationFailed(
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
        throw IconicError.metalInitializationFailed(
          "SmartTrim.metal not found at \(metalFileURL.path). Cannot compile from source."
        )
      }

      // Compilation
      do {
        let source = try String(contentsOf: metalFileURL, encoding: .utf8)
        let library = try device.makeLibrary(source: source, options: nil)
        guard let function = library.makeFunction(name: "findBoundingBox") else {
          throw IconicError.metalInitializationFailed(
            "Kernel 'findBoundingBox' not found after compiling source.")
        }
        kernelFunction = function
        print("Successfully compiled kernel function from source.")
      } catch let compileError {
        throw IconicError.metalInitializationFailed(
          "Could not compile Metal source: \(compileError.localizedDescription)")
      }
    }

    // Create the compute pipeline state using the kernel function.
    do {
      self.pipelineState = try device.makeComputePipelineState(function: kernelFunction)
    } catch {
      throw IconicError.metalInitializationFailed(
        "Could not create compute pipeline state: \(error.localizedDescription)")
    }
  }
}

@preconcurrency final class MetalTrimmingContext {

  let log = AppLog.shared

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

  public init() throws {

    // Retrieve the metal device, using the default processor

    guard let defaultDevice = MTLCreateSystemDefaultDevice() else {

      throw IconicError.metalInitializationFailed("Could not create default Metal device.")

    }

    self.device = defaultDevice

    log.info("MetalTrimmingContext: Using Metal device: \(device.name)")

    guard let queue = device.makeCommandQueue() else {

      throw IconicError.metalInitializationFailed("Could not create command queue.")

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

        throw IconicError.metalInitializationFailed(

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

        throw IconicError.metalInitializationFailed(

          "SmartTrim.metal not found at \(metalFileURL.path). Cannot compile from source."

        )

      }

      // Compilation

      do {

        let source = try String(contentsOf: metalFileURL, encoding: .utf8)

        let library = try device.makeLibrary(source: source, options: nil)

        guard let function = library.makeFunction(name: "findBoundingBox") else {

          throw IconicError.metalInitializationFailed(

            "Kernel 'findBoundingBox' not found after compiling source.")

        }

        kernelFunction = function

        print("Successfully compiled kernel function from source.")

      } catch let compileError {

        throw IconicError.metalInitializationFailed(

          "Could not compile Metal source: \(compileError.localizedDescription)")

      }

    }

    // Create the compute pipeline state using the kernel function.

    do {

      self.pipelineState = try device.makeComputePipelineState(function: kernelFunction)

    } catch {

      throw IconicError.metalInitializationFailed(

        "Could not create compute pipeline state: \(error.localizedDescription)")

    }

  }

}
