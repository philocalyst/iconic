import AppKit
import CoreImage

extension FileUtils {
	static func createICNSFile(from images: [CIImage], at destinationURL: URL) throws {
		// Create an NSImage to hold all representations
		let icnsImage = NSImage(size: NSSize(width: 1024, height: 1024))

		// Add each image as a representation with its proper size
		for ciImage in images {
			let ciContext = CIContext()
			guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
				continue
			}

			let rep = NSBitmapImageRep(cgImage: cgImage)
			rep.size = ciImage.extent.size
			icnsImage.addRepresentation(rep)
		}

		// Create the ICNS data structure
		var icnsData = Data()

		// Add ICNS header ("icns")
		icnsData.append(contentsOf: [0x69, 0x63, 0x6E, 0x73])

		// Reserve space for the file size (4 bytes)
		let fileSizePosition = icnsData.count
		icnsData.append(contentsOf: [0, 0, 0, 0])

		// Process each image representation
		for rep in icnsImage.representations {
			guard let bitmapRep = rep as? NSBitmapImageRep else { continue }

			// Get the size and determine icon type
			let width = Int(bitmapRep.size.width)
			let osType: [UInt8]

			switch width {
			case 16: osType = [0x69, 0x63, 0x73, 0x34]  // "ics4" for 16x16
			case 32: osType = [0x69, 0x63, 0x73, 0x38]  // "ics8" for 32x32
			case 64: osType = [0x69, 0x63, 0x36, 0x34]  // "ic64" for 64x64
			case 128: osType = [0x69, 0x63, 0x31, 0x32]  // "ic12" for 128x128
			case 256: osType = [0x69, 0x63, 0x30, 0x38]  // "ic08" for 256x256
			case 512: osType = [0x69, 0x63, 0x30, 0x39]  // "ic09" for 512x512
			case 1024: osType = [0x69, 0x63, 0x31, 0x30]  // "ic10" for 1024x1024
			default: continue  // Skip unsupported sizes
			}

			// Convert to PNG data
			guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
				continue
			}

			// Add type
			icnsData.append(contentsOf: osType)

			// Add data length (type + length + data)
			let dataLength = UInt32(8 + pngData.count).bigEndian
			withUnsafeBytes(of: dataLength) { bytes in
				icnsData.append(contentsOf: bytes)
			}

			// Add image data
			icnsData.append(pngData)
		}

		// Update total file size
		let fileSize = UInt32(icnsData.count).bigEndian
		withUnsafeBytes(of: fileSize) { bytes in
			for i in 0..<4 {
				icnsData[fileSizePosition + i] = bytes[i]
			}
		}

		// Write to file
		try icnsData.write(to: destinationURL)
	}
}
