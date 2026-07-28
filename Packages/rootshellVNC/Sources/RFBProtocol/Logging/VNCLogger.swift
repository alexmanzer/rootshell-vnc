import Foundation
import os

// MARK: - Relay

/// Severity of a relayed log record. Ordered so a host can filter cheaply.
public enum VNCLogLevel: Int, Sendable, Comparable, CaseIterable {
    case trace = 0
    case debug
    case info
    case warning
    case error

    public static func < (lhs: VNCLogLevel, rhs: VNCLogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Short uppercase tag used in relayed output.
    public var name: String {
        switch self {
        case .trace:   return "TRACE"
        case .debug:   return "DEBUG"
        case .info:    return "INFO"
        case .warning: return "WARN"
        case .error:   return "ERROR"
        }
    }

    /// Parse a host-supplied level name. Unrecognized input falls back to
    /// `.info` so a typo cannot silently disable the relay entirely.
    public static func named(_ name: String) -> VNCLogLevel {
        switch name.lowercased() {
        case "trace":            return .trace
        case "debug":            return .debug
        case "warning", "warn":  return .warning
        case "error":            return .error
        default:                 return .info
        }
    }
}

/// Process-wide fan-out for every ``VNCLogger`` record.
///
/// os.log is the primary sink and is unaffected by this. The relay exists so a
/// host application can additionally persist the VNC log stream somewhere a
/// user can retrieve it from a device, which os.log's `.private` records do not
/// allow. Nothing is relayed until a host installs a sink.
public enum VNCLogRelay {
    /// `(level, category, message)`. Invoked on whatever thread logged, so the
    /// sink must be cheap and thread-safe; buffer or hop internally if not.
    public typealias Sink = @Sendable (VNCLogLevel, String, String) -> Void

    private struct State {
        var sink: Sink?
        var minimumLevel: VNCLogLevel = .info
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// Install (or, with `nil`, remove) the host sink. Records below
    /// `minimumLevel` are dropped before the sink is called, so leaving the
    /// default at `.info` keeps the per-frame debug traffic out of the relay.
    public static func install(minimumLevel: VNCLogLevel = .info, sink: Sink?) {
        state.withLock { current in
            current.sink = sink
            current.minimumLevel = minimumLevel
        }
    }

    /// Whether a sink is currently installed. Callers can use this to skip
    /// building an expensive diagnostic string that only the relay would read.
    public static var isInstalled: Bool {
        state.withLock { $0.sink != nil }
    }

    static func emit(_ level: VNCLogLevel, category: String, message: @autoclosure () -> String) {
        let sink = state.withLock { current -> Sink? in
            guard let sink = current.sink, level >= current.minimumLevel else {
                return nil
            }
            return sink
        }
        guard let sink else { return }
        sink(level, category, message())
    }
}

// MARK: - Logger

/// A lightweight logging facade for VNC protocol components.
///
/// Wraps `os.Logger` with category-based routing and optional hex-dump
/// output in DEBUG builds. Every record is additionally offered to
/// ``VNCLogRelay`` so a host can persist the stream to a file.
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
        logger.trace("\(message, privacy: .private)")
        VNCLogRelay.emit(.trace, category: category, message: message)
    }

    /// Log at debug level (developer diagnostics).
    public func debug(_ message: String) {
        logger.debug("\(message, privacy: .private)")
        VNCLogRelay.emit(.debug, category: category, message: message)
    }

    /// Log at info level (general informational messages).
    public func info(_ message: String) {
        logger.info("\(message, privacy: .private)")
        VNCLogRelay.emit(.info, category: category, message: message)
    }

    /// Log at warning level (unexpected but recoverable conditions).
    public func warning(_ message: String) {
        logger.warning("\(message, privacy: .private)")
        VNCLogRelay.emit(.warning, category: category, message: message)
    }

    /// Log at error level (failures that affect operation).
    public func error(_ message: String) {
        logger.error("\(message, privacy: .private)")
        VNCLogRelay.emit(.error, category: category, message: message)
    }

    // MARK: - Hex dump (DEBUG builds only)

    /// In DEBUG builds, log a hex dump of the first `maxBytes` of `data`.
    /// In release builds this is a no-op.
    public func hexDump(_ label: String, data: Data, maxBytes: Int = 64) {
        #if DEBUG
        guard VNCDiagnostics.isEnabled("ROOTSHELL_VNC_TRACE_PROTOCOL_BYTES") else { return }
        let count = min(data.count, maxBytes)
        let slice = data.prefix(count)
        let hex = slice.map { String(format: "%02x", $0) }.joined(separator: " ")
        let suffix = data.count > maxBytes ? " ... (\(data.count) bytes total)" : ""
        let msg = "\(label): \(hex)\(suffix)"
        logger.debug("\(msg, privacy: .private)")
        #endif
    }
}
