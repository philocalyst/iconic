import Foundation

/// All errors possible in the Iconic tool, including Metal & CoreImage steps.
public enum IconicError: LocalizedError {
  // MARK: - CLI / File errors
  case missingArgument(String)
  case invalidPath(URL)
  case permissionDenied(URL, operation: String)
  case imageLoadFailed(URL)
  case cliFailure(command: String, code: Int32, output: String)
  case unexpected(String)

  // MARK: - Metal / CoreImage errors
  case metalInitializationFailed(String)
  case bufferCreationFailed
  case commandCreationFailed
  case calculationFailed
  case ciContextCreationFailed
  case ciImageRenderingFailed(String)
  case ciImageHasInfiniteExtent
  case metalTextureCreationFailed

  public var errorDescription: String? {
    switch self {
    // MARK: – CLI / File
    case .missingArgument(let desc):
      return desc
    case .invalidPath(let url):
      return "Invalid path: \(url.path)"
    case .permissionDenied(let url, let op):
      return "Permission denied (\(op)): \(url.path)"
    case .imageLoadFailed(let url):
      return "Could not load image at \(url.path)"
    case .cliFailure(let cmd, let code, let out):
      return "Command `\(cmd)` failed (\(code)): \(out)"
    case .unexpected(let msg):
      return "Unexpected error: \(msg)"

    // MARK: – Metal / CoreImage
    case .metalInitializationFailed(let reason):
      return "Failed to initialize Metal: \(reason)"
    case .bufferCreationFailed:
      return "Failed to create Metal buffer for bounding box."
    case .commandCreationFailed:
      return "Failed to create Metal command buffer or encoder."
    case .calculationFailed:
      return
        "Metal kernel failed to find a valid bounding box (e.g., image is "
        + "fully transparent or calculation error)."
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
