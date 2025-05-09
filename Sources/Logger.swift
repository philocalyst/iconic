import Logging

/// Global application logger.
enum AppLog {
  // Using let makes the shared state immutable and concurrency-safe
  static let shared: Logger = {
    var log = Logger(label: "com.philocalyst.iconic")
    log.logLevel = .notice
    return log
  }()

  /// Change the global logging level at runtime.
  static func configure(_ level: Logger.Level) {
    // Direct way of setting log level - this is safer
    var newLogger = Logger(label: "com.philocalyst.iconic")
    newLogger.logLevel = level

    // Log with the new logger
    newLogger.info("Log level set to \(level)")
  }
}
