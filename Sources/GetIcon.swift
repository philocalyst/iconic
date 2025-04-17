import AppKit
import ArgumentParser
import Foundation
import Logging

@MainActor
struct GetIcon: @preconcurrency ParsableCommand {
	static let configuration = CommandConfiguration(
		commandName: "get",
		abstract: "Extract the macOS icon from a file or folder"
	)

	@OptionGroup var global: Iconic

	@Argument(help: "Source file or folder")
	var source: String

	@Option(name: .long, help: "Write a .icns file here")
	var icns: String?

	@Option(name: .long, help: "Write a .iconset folder here")
	var iconset: String?

	@Flag(name: .shortAndLong, help: "Reveal result in Finder")
	var reveal = false

	mutating func run() throws {
		let log = AppLog.shared
		log.debug("GetIcon: source=\(source)")

		let srcURL = try FileUtils.validate(path: source)
		let icon = NSWorkspace.shared.icon(forFile: srcURL.path)
		log.info("Retrieved icon from \(srcURL.path)")

		// 1) .icns
		if let icnsPath = icns {
			let outURL = URL(fileURLWithPath: icnsPath)
			try saveAsICNS(icon, to: outURL)
			log.info("Wrote .icns to \(icnsPath)")
			if reveal {
				NSWorkspace.shared.selectFile(icnsPath, inFileViewerRootedAtPath: "")
			}
		}

		// 2) .iconset
		if let iconsetPath = iconset {
			let outURL = URL(fileURLWithPath: iconsetPath)
			try saveAsIconset(icon, to: outURL)
			log.info("Wrote .iconset to \(iconsetPath)")
			if reveal {
				NSWorkspace.shared.selectFile(iconsetPath, inFileViewerRootedAtPath: "")
			}
		}
	}

	/// Save as multi‐resolution .icns
	private func saveAsICNS(_ image: NSImage, to url: URL) throws {
		guard let data = image.tiffRepresentation else {
			throw IconicError.unexpected("No TIFF data to write")
		}
		try data.write(to: url)
	}

	/// Write out an .iconset by extracting each representation.
	private func saveAsIconset(_ image: NSImage, to folderURL: URL) throws {
		let cis = FileUtils.getAllCIImages(from: image)
		try FileUtils.writeIconset(images: cis, to: folderURL)
	}
}
