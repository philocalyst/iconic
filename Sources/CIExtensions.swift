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

    /// Applies a tinted monochrome color.
    public func fillColorize(color: CIColor) throws -> CIImage {
        guard let f = CIFilter(name: "CIColorMonochrome") else {
            throw IconicError.ciFailure("CIColorMonochrome missing")
        }
        f.setValue(self, forKey: kCIInputImageKey)
        f.setValue(color, forKey: kCIInputColorKey)
        f.setValue(1.0, forKey: kCIInputIntensityKey)
        guard let out = f.outputImage else {
            throw IconicError.ciFailure("Colorize failed")
        }
        return out.cropped(to: extent)
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

    /// Scale to fit within `maxSize`, preserve aspect.
    public func scaled(toFit maxSize: CGSize) throws -> CIImage {
        guard
            let f = CIFilter(name: "CILanczosScaleTransform")
        else {
            throw IconicError.ciFailure("Lanczos missing")
        }
        let sz = extent.size
        let scale = min(
            maxSize.width / sz.width,
            maxSize.height / sz.height)
        guard scale > 0 else {
            throw IconicError.ciFailure("Bad scale")
        }
        f.setValue(self, forKey: kCIInputImageKey)
        f.setValue(scale, forKey: kCIInputScaleKey)
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
        let ty = be.minY + (be.height - me.height) / 2 - me.minY
        return transformed(by: CGAffineTransform(translationX: tx, y: ty))
    }

    /// Perform the "engraving" sequence.
    public func engrave(
        with mask: CIImage,
        template: CIImage,
        inputs: EngravingInputs
    ) throws -> CIImage {
        // 1) fill
        let fillMono = try mask.fillColorize(color: inputs.fillColor)
        let fill = try fillMono.applyingOpacity(0.5)

        // 2) top bezel
        let topInv = try mask.invertedMask()
        let topCol = try topInv.fillColorize(color: inputs.topBezel.color)
        let topBlur = try topCol.blurred(radius: inputs.topBezel.blurRadius)
        let topMaskd = try topBlur.masked(
            by: mask,
            operation: inputs.topBezel.maskOp
        )
        let topFinal = try topMaskd.applyingOpacity(inputs.topBezel.opacity)

        // 3) bottom bezel
        let botCol = try mask.fillColorize(color: inputs.bottomBezel.color)
        let botBlur = try botCol.blurred(radius: inputs.bottomBezel.blurRadius)
        let botMaskd = try botBlur.masked(
            by: mask,
            operation: inputs.bottomBezel.maskOp
        )
        let botFinal = try botMaskd.applyingOpacity(inputs.bottomBezel.opacity)

        // 4) composite: base behind bottom, then fill, then top
        let step1 = try template.composite(
            over: botFinal,
            filterName: "CISourceOverCompositing")
        let step2 = try step1.composite(
            over: fill,
            filterName: "CISourceOverCompositing")
        let step3 = try step2.composite(
            over: topFinal,
            filterName: "CISourceOverCompositing")

        return step3
    }
}
