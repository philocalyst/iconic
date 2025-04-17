import AppKit
import ArgumentParser
import Foundation
import Logging

@MainActor
struct SetIcon: @preconcurrency ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Apply an icon (.icns or .iconset) to a file/folder"
    )

    @OptionGroup var global: Iconic

    @Argument(help: "Icon file or folder")
    var iconPath: String

    @Argument(help: "Target file or folder")
    var targetPath: String

    @Flag(name: .shortAndLong, help: "Reveal in Finder after")
    var reveal = false

    mutating func run() throws {
        let log = AppLog.shared
        log.debug("SetIcon: icon=\(iconPath) target=\(targetPath)")

        // ensure both paths valid
        let iconURL = try FileUtils.validate(path: iconPath)
        let targetURL = try FileUtils.validate(path: targetPath)

        // load icon
        let imgURL: URL
        if iconURL.pathExtension.lowercased() == "iconset" {
            // pick the highest‐res png
            let contents = try FileManager.default.contentsOfDirectory(
                atPath: iconURL.path
            )
            guard
                let best =
                    contents
                    .filter({ $0.hasSuffix("1024.png") })
                    .first
            else {
                throw IconicError.unexpected("No 1024×1024.png in iconset")
            }
            imgURL = iconURL.appendingPathComponent(best)
        } else {
            imgURL = iconURL
        }

        guard
            let ns = NSImage(contentsOf: imgURL)
        else {
            throw IconicError.imageLoadFailed(imgURL)
        }

        let success = NSWorkspace.shared.setIcon(
            ns,
            forFile: targetURL.path,
            options: []
        )
        guard success else {
            throw IconicError.unexpected("NSWorkspace.setIcon failed")
        }

        log.info("Applied icon to \(targetURL.path)")
        if reveal {
            NSWorkspace.shared.selectFile(targetURL.path, inFileViewerRootedAtPath: "")
        }
    }
}
