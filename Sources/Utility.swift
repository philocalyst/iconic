import AppKit
import CoreImage
import Foundation

/// Global utilities for file and image handling
enum FileUtils {
	/// Validate that the path exists & is readable/writable.
	static func validate(path: String) throws -> URL {
		let url = URL(fileURLWithPath: path)
		var isDir: ObjCBool = false
		guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
			throw IconicError.invalidPath(url)
		}
		guard FileManager.default.isReadableFile(atPath: path) else {
			throw IconicError.permissionDenied(url, operation: "read")
		}
		guard FileManager.default.isWritableFile(atPath: path) else {
			throw IconicError.permissionDenied(url, operation: "write")
		}
		return url
	}

	/// Load NSImage → CIImage
	static func loadCIImage(from url: URL) throws -> CIImage {
		guard
			let ns = NSImage(contentsOf: url),
			let rep = NSBitmapImageRep(data: ns.tiffRepresentation ?? Data()),
			let cg = rep.cgImage
		else {
			throw IconicError.imageLoadFailed(url)
		}
		return CIImage(cgImage: cg)
	}

	/// Returns all CGImage representations of an NSImage as CIImages.
	static func getAllCIImages(from ns: NSImage) -> [CIImage] {
		return ns.representations.compactMap {
			guard let br = $0 as? NSBitmapImageRep,
				let cg = br.cgImage
			else { return nil }
			return CIImage(cgImage: cg)
		}
	}

	/// Write an array of CIImages to a .iconset folder
	static func writeIconset(images: [CIImage], to folderURL: URL) throws {
		let log = AppLog.shared
		// create folder
		try FileManager.default.createDirectory(
			at: folderURL,
			withIntermediateDirectories: true,
			attributes: nil
		)
		let ctx = CIContext()
		for img in images {
			let w = Int(img.extent.width)
			let h = Int(img.extent.height)
			let fname = "\(w)x\(h).png"
			let outURL = folderURL.appendingPathComponent(fname)
			let cs = CGColorSpace(name: CGColorSpace.sRGB)!

			log.debug("Writing iconset image \(fname)")
			try ctx.writePNGRepresentation(
				of: img,
				to: outURL,
				format: .RGBA8,
				colorSpace: cs
			)
		}
	}

	/// Run a shell command
	@discardableResult
	static func runCommand(_ cmd: String, args: [String]) throws -> String {
		let p = Process()
		p.executableURL = URL(fileURLWithPath: cmd)
		p.arguments = args
		let outPipe = Pipe()
		let errPipe = Pipe()
		p.standardOutput = outPipe
		p.standardError = errPipe

		try p.run()
		p.waitUntilExit()

		let out =
			String(
				data: outPipe.fileHandleForReading.readDataToEndOfFile(),
				encoding: .utf8) ?? ""
		let err =
			String(
				data: errPipe.fileHandleForReading.readDataToEndOfFile(),
				encoding: .utf8) ?? ""

		if p.terminationStatus != 0 {
			throw IconicError.cliFailure(
				command: "\(cmd) \(args.joined(separator: " "))",
				code: p.terminationStatus,
				output: err.trimmingCharacters(in: .whitespacesAndNewlines)
			)
		}
		return out
	}
}
