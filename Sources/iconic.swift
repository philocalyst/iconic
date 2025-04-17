import AppKit
import ArgumentParser
import Logging

@main
struct Iconic: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "iconic",
        abstract: "macOS icon get/set/mask utility",
        version: "1.0.0",
        subcommands: [GetIcon.self, SetIcon.self, MaskIcon.self]
    )

    @Flag(name: .shortAndLong, help: "Verbose logging.")
    var verbose = false

    @Flag(name: .shortAndLong, help: "Quiet (errors only).")
    var quiet = false

    mutating func run() throws {
        // configure global log level
        if verbose {
            AppLog.configure(.debug)
        } else if quiet {
            AppLog.configure(.error)
        } else {
            AppLog.configure(.notice)
        }
        AppLog.shared.info("Starting iconic…")
    }
}
