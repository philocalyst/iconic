import CoreImage
import Foundation
import Metal

/// A singleton to detect the minimal non‐transparent bounding
/// rectangle of a CIImage via a Metal kernel.
@MainActor
final class MetalTrimmer: @unchecked Sendable {
	static let shared = try! MetalTrimmer()

	let device: MTLDevice
	let queue: MTLCommandQueue
	let pipelineState: MTLComputePipelineState
	let ciContext: CIContext

	private init() throws {
		guard let dev = MTLCreateSystemDefaultDevice() else {
			throw IconicError.metalFailure("No Metal device available")
		}
		device = dev

		guard let q = device.makeCommandQueue() else {
			throw IconicError.metalFailure("Failed creating command queue")
		}
		queue = q
		ciContext = CIContext(mtlDevice: device)

		// Load our custom kernel
		let library = try MetalKernelLoader.loadLibrary(device: device)
		guard let fn = library.makeFunction(name: "findBoundingBox") else {
			throw IconicError.metalFailure("Kernel `findBoundingBox` not found")
		}
		pipelineState = try device.makeComputePipelineState(function: fn)
	}

	/// Runs the `findBoundingBox` kernel on `image` and returns
	/// its smallest non‐transparent rect, or `.null` if none.
	func boundingBox(of image: CIImage) throws -> CGRect {
		let extent = image.extent
		guard
			extent.width > 0,
			extent.height > 0,
			!extent.isInfinite
		else {
			return .null
		}

		// 1) Create a Metal texture to render into
		let w = Int(extent.width.rounded(.up))
		let h = Int(extent.height.rounded(.up))
		let desc = MTLTextureDescriptor.texture2DDescriptor(
			pixelFormat: .bgra8Unorm,
			width: w,
			height: h,
			mipmapped: false
		)
		desc.usage = [.shaderRead, .renderTarget]
		desc.storageMode = .private

		guard let texture = device.makeTexture(descriptor: desc) else {
			throw IconicError.metalFailure("Failed creating texture")
		}

		// 2) Render the CIImage into that texture
		let cb = queue.makeCommandBuffer()!
		let shifted = image.transformed(
			by: CGAffineTransform(
				translationX: -extent.origin.x,
				y: -extent.origin.y)
		)
		let colorspace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
		ciContext.render(
			shifted,
			to: texture,
			commandBuffer: cb,
			bounds: CGRect(x: 0, y: 0, width: w, height: h),
			colorSpace: colorspace
		)
		cb.commit()
		cb.waitUntilCompleted()
		if let e = cb.error {
			throw IconicError.ciFailure("CI render failed: \(e)")
		}

		// 3) Create a small shared buffer to collect min/max coords
		let bufSize = 4 * MemoryLayout<UInt32>.stride
		let outBuf = device.makeBuffer(
			length: bufSize,
			options: .storageModeShared
		)!
		let ptr = outBuf.contents().bindMemory(
			to: UInt32.self,
			capacity: 4
		)
		// initialize: min = maxUInt32, max = 0
		ptr[0] = UInt32.max
		ptr[1] = UInt32.max
		ptr[2] = 0
		ptr[3] = 0

		// 4) Dispatch the compute kernel
		let ccb = queue.makeCommandBuffer()!
		let encoder = ccb.makeComputeCommandEncoder()!
		encoder.setComputePipelineState(pipelineState)
		encoder.setTexture(texture, index: 0)
		encoder.setBuffer(outBuf, offset: 0, index: 0)

		let tw = pipelineState.threadExecutionWidth
		let th = pipelineState.maxTotalThreadsPerThreadgroup / tw
		let tg = MTLSize(width: tw, height: th, depth: 1)
		let grid = MTLSize(
			width: (w + tw - 1) / tw,
			height: (h + th - 1) / th,
			depth: 1
		)
		encoder.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
		encoder.endEncoding()
		ccb.commit()
		ccb.waitUntilCompleted()
		if let e = ccb.error {
			throw IconicError.metalFailure("Compute failed: \(e)")
		}

		// 5) Read back and compute CGRect
		let minX = Int(ptr[0])
		let minY = Int(ptr[1])
		let maxX = Int(ptr[2])
		let maxY = Int(ptr[3])
		guard minX <= maxX, minY <= maxY else {
			return .null
		}

		// convert back into image coords
		let x = CGFloat(minX) + extent.origin.x
		let y = CGFloat(minY) + extent.origin.y
		let wF = CGFloat(maxX - minX + 1)
		let hF = CGFloat(maxY - minY + 1)
		return CGRect(x: x, y: y, width: wF, height: hF)
	}
}
