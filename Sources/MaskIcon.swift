import AppKit
import ArgumentParser
import CoreImage
import Foundation
import Logging

@MainActor
struct MaskIcon: @preconcurrency ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "mask",
    abstract: "Apply a PNG mask to the macOS folder icon template"
  )

  @OptionGroup var global: Iconic

  @Argument(help: "Mask image (.png)")
  var maskPath: String

  @Argument(help: "Optional target to apply icon to")
  var targetPath: String?

  @Option(name: .long, help: "Write .icns here")
  var icns: String?

  @Option(name: .long, help: "Write .iconset here")
  var iconset: String?

  @Flag(name: .long, help: "Reveal result in Finder")
  var reveal = false

  mutating func run() throws {
    let log = AppLog.shared
    log.debug("MaskIcon: mask=\(maskPath)")

    // 1) Load mask CIImage
    let maskURL = try FileUtils.validate(path: maskPath)
    let maskCI = try FileUtils.loadCIImage(from: maskURL)

    // 2) Trim padding
    let trimmedMask = try maskCI.cropped(to: maskCI.getAliveImage())

    let size = CGSize(width: 200, height: 200)
    let finalRect = CGRect(origin: .zero, size: size)

    // Create a clear background with a defined, finite extent
    let transparentBackground = CIImage(color: .clear)
      .cropped(to: finalRect)  // Extent should be (0,0,200,200)

    // Create the red square, translated
    let redSquare = CIImage(color: .red)
      .cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))  // Extent: (0,0,100,100)
      .transformed(by: .init(translationX: 50, y: 50))  // Extent: (50,50,100,100)

    // Composite the finite-extent square over the finite-extent background
    // The extent of the result should be the union, covering (0,0,200,200)
    let runID = Int.random(in: 1000...10000)
    // e.g. /var/.../T/engrave_debug_<runID>
    let debugDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("engrave_debug_\(runID)")

    try? FileManager.default.createDirectory(
      at: debugDir,
      withIntermediateDirectories: true,
      attributes: nil
    )

    let testImage = redSquare.composited(over: transparentBackground)
    testImage.dump(testImage, stepName: "1_fillColorize", debugDir: debugDir, runID: runID)

    // --- Debug: Check extent immediately after creation ---
    print("--- Running Revised Test Case ---")
    print("Test Image Extent BEFORE Trimming: \(testImage.extent)")
    // --- End Debug ---

    // Now try trimming this testImage
    do {
      // It's crucial that MetalTrimmer uses testImage.extent correctly inside
      let trimmedTest = try testImage.cropped(to: testImage.getAliveImage())
      print("Test Image Extent AFTER Trimming: \(trimmedTest.extent)")
      print("--- End Revised Test Case ---")
    } catch {
      print("Error trimming test image: \(error)")
    }

    // 3) Load folder‐template .icns from resources
    //    (expects ~/.local/share/iconic/bigsur-folder-(light|dark).icns)
    let home = ProcessInfo.processInfo.environment["HOME"]!
    let swatch = isDarkMode() ? "dark" : "light"
    let tmplPath = "\(home)/.local/share/iconic/bigsur-folder-\(swatch).icns"
    let tmplURL = try FileUtils.validate(path: tmplPath)
    guard let tmplNS = NSImage(contentsOf: tmplURL) else {
      throw IconicError.imageLoadFailed(tmplURL)
    }
    let tmplCIs = FileUtils.getAllCIImages(from: tmplNS)
    // e.g. /var/.../T/engrave_debug_<runID>

    // 4) For each size, produce one masked CIImage
    var finalImages: [CIImage] = []
    for baseCI in tmplCIs {
      // a) crop transparent of base
      let crop = try baseCI.cropped(to: baseCI.getAliveImage())
      let context = CIContext()
      let cs = CGColorSpace(name: CGColorSpace.sRGB)!

      print(debugDir)
      do {
        try context.writePNGRepresentation(
          of: trimmedMask,
          to: debugDir,
          format: .RGBA8,
          colorSpace: cs
        )
      } catch {
      }

      // b) resize mask to fit base
      let resizedMask = try trimmedMask.scaled(toFit: crop.extent.size, ratio: 1.0)
      // c) center it
      let centered = resizedMask.centering(over: crop)
      // d) composite: here we engrave with bezel etc.
      let inputs = EngravingInputs(
        fillColor: CIColor(red: 8 / 255, green: 134 / 255, blue: 206 / 255),
        topBezel: EngravingInputs.Bezel(
          color: CIColor(red: 58 / 255, green: 152 / 255, blue: 208 / 255),
          blur: .init(spreadPx: 0, pageY: 2),
          maskOp: "dst-in",
          opacity: 0.5
        ),
        bottomBezel: EngravingInputs.Bezel(
          color: CIColor(red: 174 / 255, green: 225 / 255, blue: 253 / 255),
          blur: .init(spreadPx: 2, pageY: 2),
          maskOp: "dst-out",
          opacity: 0.75
        )
      )
      let engraved = try crop.engrave(
        with: centered,
        template: crop,
        inputs: inputs
      )
      finalImages.append(engraved)
    }

    // 5) Write outputs
    if let iconsetPath = iconset {
      let outURL = URL(fileURLWithPath: iconsetPath)
      try FileUtils.writeIconset(images: finalImages, to: outURL)
      log.info("Wrote iconset to \(iconsetPath)")
      if reveal {
        NSWorkspace.shared.selectFile(iconsetPath, inFileViewerRootedAtPath: "")
      }
    }

    if let icnsPath = icns {
      let outURL = URL(fileURLWithPath: icnsPath)
      try FileUtils.createICNSFile(from: finalImages, at: outURL)
      log.info("Wrote icns to \(icnsPath)")
      if reveal {
        NSWorkspace.shared.selectFile(icnsPath, inFileViewerRootedAtPath: "")
      }
    }

    // 6) Optionally apply to target
    if let t = targetPath {
      let icnsToUse: URL
      if let icns = icns {
        icnsToUse = URL(fileURLWithPath: icns)
      } else {
        // build a temp .icns
        let tmpI = URL(fileURLWithPath: NSTemporaryDirectory())
          .appendingPathComponent(UUID().uuidString + ".icns")
        try FileUtils.createICNSFile(from: finalImages, at: tmpI)
        icnsToUse = tmpI
      }

      let targetURL = try FileUtils.validate(path: t)
      guard
        let ns = NSImage(contentsOf: icnsToUse)
      else {
        throw IconicError.imageLoadFailed(icnsToUse)
      }
      let ok = NSWorkspace.shared.setIcon(
        ns,
        forFile: targetURL.path,
        options: []
      )
      guard ok else {
        throw IconicError.unexpected("Failed to apply icon")
      }
      log.info("Applied masked icon to \(targetURL.path)")
      if reveal {
        NSWorkspace.shared.selectFile(targetURL.path, inFileViewerRootedAtPath: "")
      }
    }
  }

  private func isDarkMode() -> Bool {
    let v = UserDefaults.standard.string(forKey: "AppleInterfaceStyle")
    return v?.lowercased() == "dark"
  }
}
