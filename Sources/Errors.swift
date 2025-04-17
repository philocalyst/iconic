import Foundation

/// All errors possible in the Iconic tool.
public enum IconicError: LocalizedError {
	case missingArgument(String)
	case invalidPath(URL)
	case permissionDenied(URL, operation: String)
	case imageLoadFailed(URL)
	case metalFailure(String)
	case ciFailure(String)
	case cliFailure(command: String, code: Int32, output: String)
	case unexpected(String)

	public var errorDescription: String? {
		switch self {
		case .missingArgument(let desc):
			return desc
		case .invalidPath(let url):
			return "Invalid path: \(url.path)"
		case .permissionDenied(let url, let op):
			return "Permission denied (\(op)): \(url.path)"
		case .imageLoadFailed(let url):
			return "Could not load image at \(url.path)"
		case .metalFailure(let msg):
			return "Metal error: \(msg)"
		case .ciFailure(let msg):
			return "CoreImage error: \(msg)"
		case .cliFailure(let cmd, let code, let out):
			return "Command `\(cmd)` failed (\(code)): \(out)"
		case .unexpected(let msg):
			return "Unexpected error: \(msg)"
		}
	}
}
