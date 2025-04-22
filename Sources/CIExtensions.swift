import CoreImage
import Foundation

/// Represents an x,y offset position
struct Offset {
    let x: Int
    let y: Int

    func toString() -> String {
        return "\(x)x\(y)"
    }
}

/// Parameters for the "engraving" step.
public struct EngravingInputs {
    /// Parameters for the blur down effect
    public struct BlurDown {
        let spreadPx: UInt32
        let pageY: Int
    }

    public struct Bezel {
        public let color: CIColor
        public let blur: BlurDown
        public let maskOp: String
        public let opacity: CGFloat

        public init(
            color: CIColor,
            blur: BlurDown,
            maskOp: String,
            opacity: CGFloat
        ) {
            self.color = color
            self.blur = blur
            self.maskOp = maskOp
            self.opacity = opacity
        }
    }

    public let fillColor: CIColor
    public let topBezel: Bezel
    public let bottomBezel: Bezel

    public init(
        fillColor: CIColor,
        topBezel: Bezel,
        bottomBezel: Bezel
    ) {
        self.fillColor = fillColor
        self.topBezel = topBezel
        self.bottomBezel = bottomBezel
    }
}

extension CIImage {
    /// Trim transparent margin via Metal‐accelerated bounding box detection.
    /// - Returns: A cropped CIImage or the original if fully transparent.
    @MainActor
    public func trimmingTransparentMargin() throws -> CIImage {
        let box = try MetalTrimmer.shared.boundingBox(of: self)
        guard !box.isNull else { return self }
        return self.cropped(to: box)
    }

    /// Flattens image layers
    func flatten() -> CIImage {
        // In CoreImage, flattening is handled through compositing
        // This is a simplified version assuming we're working with an existing composite
        return self
    }

    /// Sets page offset for the image
    func page(offset: Offset) -> CIImage {
        return self.transformed(
            by: CGAffineTransform(
                translationX: CGFloat(offset.x),
                y: CGFloat(offset.y)))
    }

    /// Applies motion blur in the downward direction
    func motionBlurDown(spreadPx: UInt32) -> CIImage {
        guard let filter = CIFilter(name: "CIMotionBlur") else {
            return self
        }

        filter.setValue(self, forKey: kCIInputImageKey)
        filter.setValue(Float(spreadPx), forKey: kCIInputRadiusKey)
        // -90 degrees for downward motion in CoreImage coordinates
        filter.setValue(-90 * CGFloat.pi / 180, forKey: kCIInputAngleKey)

        return filter.outputImage ?? self
    }

    /// Sets the background to transparent
    func backgroundNone() -> CIImage {
        // Preserve alpha channel
        return self.applyingFilter("CIMaskToAlpha")
    }

    /// Applies a blur down effect combining all the above operations
    func blurDown(blurDown: EngravingInputs.BlurDown) -> CIImage {
        return
            self
            .motionBlurDown(spreadPx: blurDown.spreadPx)
            .page(offset: Offset(x: 0, y: -blurDown.pageY))
    }

    public func tint(color: CIColor) throws -> CIImage {
        // Create a solid color image with the same dimensions
        let colorImage = CIImage(color: color).cropped(to: extent)

        // Use multiply blend mode for tinting
        guard let f = CIFilter(name: "CIMultiplyCompositing") else {
            throw IconicError.ciFailure("CIMultiplyCompositing missing")
        }
        f.setValue(colorImage, forKey: kCIInputImageKey)
        f.setValue(self, forKey: kCIInputBackgroundImageKey)
        guard let out = f.outputImage else {
            throw IconicError.ciFailure("Colorize failed")
        }
        return out
    }

    /// Returns a CIImage in which the original alpha is inverted:
    /// transparent → white, opaque → transparent.
    func invertedAlphaWhiteBackground() -> CIImage? {
        let extent = self.extent

        // 1) Create white & clear images
        let white = CIImage(color: .white)
            .cropped(to: extent)
        let clear = CIImage(
            color: CIColor(
                red: 0,
                green: 0,
                blue: 0,
                alpha: 0)
        )
        .cropped(to: extent)

        // 2) Extract original alpha into a mask
        guard
            let extractAlpha = CIFilter(
                name: "CIColorMatrix",
                parameters: [
                    kCIInputImageKey: self,
                    "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    // keep only the α channel
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                    "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                ])?.outputImage
        else {
            print("Failed to extract alpha")
            return nil
        }

        // 3) Invert that alpha mask: α → 1 - α
        guard
            let invertedMask = CIFilter(
                name: "CIColorMatrix",
                parameters: [
                    kCIInputImageKey: extractAlpha,
                    // no color channels
                    "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    // invert alpha
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: -1),
                    // bias of +1 => 1 - α
                    "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                ])?.outputImage
        else {
            print("Failed to invert alpha")
            return nil
        }

        // 4) Blend white over clear, using the inverted-mask as the α mask
        guard
            let blend = CIFilter(name: "CIBlendWithAlphaMask")
        else {
            print("Failed to create CIBlendWithAlphaMask")
            return nil
        }
        blend.setValue(white, forKey: kCIInputImageKey)
        blend.setValue(clear, forKey: kCIInputBackgroundImageKey)
        blend.setValue(invertedMask, forKey: kCIInputMaskImageKey)

        return blend.outputImage
    }

    /// Fills the image with the provided color
    public func fillColorize(color: CIColor) throws -> CIImage {
        // 1) Make a solid‐color image the same size as self
        guard let constantColor = CIFilter(name: "CIConstantColorGenerator") else {
            throw IconicError.ciFailure("CIConstantColorGenerator missing")
        }
        constantColor.setValue(color, forKey: kCIInputColorKey)
        // the generator is infinite in extent, so crop it to ours
        guard let colorImage = constantColor.outputImage?.cropped(to: extent) else {
            throw IconicError.ciFailure("failed to generate color image")
        }

        // 2) Composite it “source‑in” your original alpha
        guard let sourceIn = CIFilter(name: "CISourceInCompositing") else {
            throw IconicError.ciFailure("CISourceInCompositing missing")
        }
        sourceIn.setValue(colorImage, forKey: kCIInputImageKey)
        sourceIn.setValue(self, forKey: kCIInputBackgroundImageKey)

        guard let output = sourceIn.outputImage else {
            throw IconicError.ciFailure("Colorize compositing failed")
        }

        // 3) Crop back to the original image’s extent
        return output.cropped(to: extent)
    }

    func dissolve(over destination: CIImage) throws -> CIImage {
        return try self.composite(over: destination, filterName: "CIOverlayBlendMode")
    }

    /// Simple normalized dissolve (opacity) blend.
    public func applyingOpacity(_ alpha: CGFloat) throws -> CIImage {
        let a = max(0, min(1, alpha))
        guard let f = CIFilter(name: "CIColorMatrix") else {
            throw IconicError.ciFailure("CIColorMatrix missing")
        }
        // keep RGB, multiply A by `a`
        f.setValue(self, forKey: kCIInputImageKey)
        f.setValue(
            CIVector(x: 0, y: 0, z: 0, w: a),
            forKey: "inputAVector")
        guard let out = f.outputImage else {
            throw IconicError.ciFailure("Alpha adjust failed")
        }
        return out
    }

    /// General compositing (sourceOver by default).
    public func composite(
        over bg: CIImage,
        filterName: String = "CISourceOverCompositing"
    ) throws -> CIImage {
        guard let f = CIFilter(name: filterName) else {
            throw IconicError.ciFailure("Filter \(filterName) missing")
        }
        f.setValue(self, forKey: kCIInputImageKey)
        f.setValue(bg, forKey: kCIInputBackgroundImageKey)
        guard let out = f.outputImage else {
            throw IconicError.ciFailure("Composite (\(filterName)) failed")
        }
        return out
    }

    /// Invert alpha: black = opaque, white = transparent.
    public func invertedMask() throws -> CIImage {
        guard let f = CIFilter(name: "CIColorInvert") else {
            throw IconicError.ciFailure("CIColorInvert missing")
        }
        f.setValue(self, forKey: kCIInputImageKey)
        guard let out = f.outputImage else {
            throw IconicError.ciFailure("Invert failed")
        }
        return out.cropped(to: extent)
    }

    /// Simple Gaussian blur.
    public func blurred(radius r: CGFloat) throws -> CIImage {
        guard let f = CIFilter(name: "CIGaussianBlur") else {
            throw IconicError.ciFailure("CIGaussianBlur missing")
        }
        f.setValue(self, forKey: kCIInputImageKey)
        f.setValue(max(0, r), forKey: kCIInputRadiusKey)
        guard let out = f.outputImage else {
            throw IconicError.ciFailure("Blur failed")
        }
        return out
    }

    /// Blend with mask using a variety of operations.
    public func masked(
        by mask: CIImage,
        operation: String
    ) throws -> CIImage {
        let op = operation.lowercased()
        let name: String
        switch op {
        case "dst-in", "sourcein":
            name = "CISourceInCompositing"
        case "dst-out", "sourceout":
            name = "CISourceOutCompositing"
        case "multiply", "blend":
            name = "CIBlendWithMask"
        default:
            throw IconicError.ciFailure("Unknown mask op \(operation)")
        }

        guard let f = CIFilter(name: name) else {
            throw IconicError.ciFailure("Filter \(name) missing")
        }
        f.setValue(self, forKey: kCIInputImageKey)
        if name == "CIBlendWithMask" {
            f.setValue(
                CIImage.empty().cropped(to: extent),
                forKey: kCIInputBackgroundImageKey)
            f.setValue(mask, forKey: kCIInputMaskImageKey)
        } else {
            f.setValue(mask, forKey: kCIInputBackgroundImageKey)
        }
        guard let out = f.outputImage else {
            throw IconicError.ciFailure("\(name) failed")
        }
        return out
    }

    /// Scale to fit within `maxSize`, preserve aspect, then apply `ratio`.
    public func scaled(
        toFit maxSize: CGSize,
        ratio: CGFloat = 1
    ) throws -> CIImage {
        guard let f = CIFilter(name: "CILanczosScaleTransform") else {
            throw IconicError.ciFailure("Lanczos missing")
        }

        let sz = extent.size
        // basic scale to fill maxSize preserving aspect
        let baseScale = min(
            maxSize.width / sz.width,
            maxSize.height / sz.height)
        guard baseScale > 0, ratio > 0 else {
            throw IconicError.ciFailure("Bad scale or ratio")
        }

        // divide by ratio so ratio>1 makes it smaller
        let finalScale = baseScale / ratio

        f.setValue(self, forKey: kCIInputImageKey)
        f.setValue(finalScale, forKey: kCIInputScaleKey)
        f.setValue(1.0, forKey: kCIInputAspectRatioKey)

        guard let out = f.outputImage else {
            throw IconicError.ciFailure("Scale failed")
        }
        return out
    }

    /// Center this image over `bg` by translation.
    public func centering(over bg: CIImage) -> CIImage {
        let be = bg.extent
        let me = extent
        let tx = be.minX + (be.width - me.width) / 2 - me.minX
        let ty = (be.minY + (be.height - me.height) / 2 - me.minY) * 0.87  // Normalize (Always off for some reason?)
        return transformed(by: CGAffineTransform(translationX: tx, y: ty))
    }

    /// Perform the "engraving" sequence.
    public func engrave(
        with mask: CIImage,
        template: CIImage,
        inputs: EngravingInputs
    ) throws -> CIImage {

        // MARK: ––– SETUP DEBUG DUMP FOLDER
        // one random run‑ID, so all files for this invocation share the same suffix
        let runID = Int.random(in: 1000...10000)
        // e.g. /var/.../T/engrave_debug_<runID>
        let debugDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("engrave_debug_\(runID)")

        try? FileManager.default.createDirectory(
            at: debugDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // helper that renders & writes a CIImage to disk as PNG
        func dump(_ image: CIImage, stepName: String) {
            let context = CIContext()
            let fileURL =
                debugDir
                .appendingPathComponent("step_\(stepName)_\(runID).png")
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!

            do {
                print("writing to \(fileURL)")
                try context.writePNGRepresentation(
                    of: image,
                    to: fileURL,
                    format: .RGBA8,
                    colorSpace: cs
                )
            } catch {
                print("⚠️ failed to dump \(stepName): \(error)")
            }
        }

        // 1) fill
        let fillMono = try mask.fillColorize(color: inputs.fillColor)
        dump(fillMono, stepName: "1_fillColorize")

        let fill = try fillMono.applyingOpacity(0.5).tint(
            color: CIColor(red: 0.0, green: 0.0, blue: 0.0))

        dump(fill, stepName: "1_fillOpacity")

        // 2) top bezel
        let topInv = mask.invertedAlphaWhiteBackground().unsafelyUnwrapped
        dump(topInv, stepName: "2_topInvert")

        let topCol = try topInv.tint(color: inputs.topBezel.color)
        dump(topCol, stepName: "2_topColorize")

        let topBlur = topCol.blurDown(blurDown: inputs.topBezel.blur)
        dump(topBlur, stepName: "2_topBlur")

        let topMaskd = try topBlur.masked(
            by: mask,
            operation: inputs.topBezel.maskOp
        )
        dump(topMaskd, stepName: "2_topMasked")

        let topFinal = try topMaskd.applyingOpacity(inputs.topBezel.opacity)
        dump(topFinal, stepName: "2_topOpacity")

        // 3) bottom bezel
        let botCol = try mask.fillColorize(color: inputs.bottomBezel.color)
        dump(botCol, stepName: "3_bottomColorize")

        let botBlur = botCol.blurDown(blurDown: inputs.bottomBezel.blur)
        dump(botBlur, stepName: "3_bottomBlur")

        let botMaskd = try botBlur.masked(
            by: mask,
            operation: inputs.bottomBezel.maskOp
        )
        dump(botMaskd, stepName: "3_bottomMasked")

        let botFinal = try botMaskd.applyingOpacity(inputs.bottomBezel.opacity)
        dump(botFinal, stepName: "3_bottomOpacity")

        // 4) composite: base behind bottom, then fill, then top
        let step1 = try botFinal.dissolve(
            over: fill,
        )
        dump(step1, stepName: "4_composite_bot")

        let step2 = try step1.dissolve(
            over: topFinal,
        )
        dump(step2, stepName: "4_composite_fill")

        dump(template, stepName: "TEMPLATE")

        let step3 = try step2.dissolve(
            over: template,
        )
        dump(step3, stepName: "4_composite_top")

        return step3
    }
}
