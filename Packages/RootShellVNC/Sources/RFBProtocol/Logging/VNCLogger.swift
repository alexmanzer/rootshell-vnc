import Foundation
import os

/// A lightweight logging facade for VNC protocol components.
///
/// Wraps `os.Logger` with category-based routing and optional hex-dump
/// output in DEBUG builds.
public struct VNCLogger: Sendable {

    // MARK: - Subsystem

    /// The unified logging subsystem for all VNC components.
    public static let subsystem = "com.rootshell.vnc"

    // MARK: - Categories

    /// Logger for RFB protocol-level events (handshake, messages, encoding).
    public static let `protocol` = VNCLogger(category: "Protocol")

    /// Logger for network transport (TCP, TLS, streams).
    public static let transport = VNCLogger(category: "Transport")

    /// Logger for framebuffer rendering and display.
    public static let rendering = VNCLogger(category: "Rendering")

    /// Logger for authentication and encryption operations.
    public static let auth = VNCLogger(category: "Auth")

    /// Logger for session lifecycle events.
    public static let session = VNCLogger(category: "Session")

    // MARK: - Private state

    public let logger: os.Logger
    public let category: String

    // MARK: - Init

    /// Create a logger with the given category.
    public init(category: String) {
        self.category = category
        self.logger = os.Logger(subsystem: Self.subsystem, category: category)
    }

    // MARK: - Log methods

    /// Log at trace level (most verbose, for detailed protocol dumps).
    public func trace(_ message: String) {
        logger.trace("\(message, privacy: .public)")
    }

    /// Log at debug level (developer diagnostics).
    public func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }

    /// Log at info level (general informational messages).
    public func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    /// Log at warning level (unexpected but recoverable conditions).
    public func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
    }

    /// Log at error level (failures that affect operation).
    public func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }

    // MARK: - Hex dump (DEBUG builds only)

    /// In DEBUG builds, log a hex dump of the first `maxBytes` of `data`.
    /// In release builds this is a no-op.
    public func hexDump(_ label: String, data: Data, maxBytes: Int = 64) {
        #if DEBUG
        let count = min(data.count, maxBytes)
        let slice = data.prefix(count)
        let hex = slice.map { String(format: "%02x", $0) }.joined(separator: " ")
        let suffix = data.count > maxBytes ? " ... (\(data.count) bytes total)" : ""
        let msg = "\(label): \(hex)\(suffix)"
        logger.debug("\(msg, privacy: .public)")
        #endif
    }
}
