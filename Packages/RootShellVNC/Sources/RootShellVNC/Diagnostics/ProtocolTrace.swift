import Foundation
import RFBProtocol

/// Records all protocol messages with timestamps for debugging and diagnostics.
///
/// `ProtocolTrace` maintains a bounded circular buffer of protocol messages
/// exchanged between the client and server. Each entry includes a timestamp,
/// direction, message type, byte count, and optional hex dump (DEBUG only).
///
/// This class is thread-safe and can be accessed from any isolation domain.
///
/// Usage:
/// ```swift
/// let trace = ProtocolTrace(maxEntries: 5000)
/// trace.recordSent(type: "KeyEvent", data: messageData)
/// trace.recordReceived(type: "FramebufferUpdate", data: updateData)
///
/// let entries = trace.getEntries()
/// let json = try trace.exportJSON()
/// ```
public final class ProtocolTrace: @unchecked Sendable {

    // MARK: - TraceEntry

    /// A single recorded protocol message.
    public struct TraceEntry: Sendable, Codable {
        /// When the message was sent or received.
        public let timestamp: Date

        /// Whether the message was sent by the client or received from the server.
        public let direction: Direction

        /// A human-readable name for the message type (e.g., "KeyEvent", "FramebufferUpdate").
        public let messageType: String

        /// The total byte count of the message on the wire.
        public let byteCount: Int

        /// A hex dump of the first 64 bytes of the message (DEBUG builds only).
        /// In release builds, this is always `nil`.
        public let hexDump: String?

        /// Optional human-readable details about the message content.
        public let details: String?

        /// The direction of a protocol message.
        public enum Direction: String, Sendable, Codable {
            /// A message sent from the client to the server.
            case sent

            /// A message received from the server.
            case received
        }
    }

    // MARK: - Properties

    private let lock = NSLock()
    private var entries: [TraceEntry] = []
    private let maxEntries: Int

    // MARK: - Init

    /// Create a protocol trace recorder.
    ///
    /// - Parameter maxEntries: The maximum number of entries to retain.
    ///   When the limit is reached, the oldest entries are discarded.
    ///   Defaults to 10,000.
    public init(maxEntries: Int = 10_000) {
        self.maxEntries = maxEntries
    }

    // MARK: - Recording

    /// Record a message sent from the client to the server.
    ///
    /// - Parameters:
    ///   - type: A human-readable name for the message type.
    ///   - data: The raw message data.
    ///   - details: Optional additional details about the message.
    public func recordSent(type: String, data: Data, details: String? = nil) {
        record(direction: .sent, type: type, data: data, details: details)
    }

    /// Record a message received from the server.
    ///
    /// - Parameters:
    ///   - type: A human-readable name for the message type.
    ///   - data: The raw message data.
    ///   - details: Optional additional details about the message.
    public func recordReceived(type: String, data: Data, details: String? = nil) {
        record(direction: .received, type: type, data: data, details: details)
    }

    // MARK: - Retrieval

    /// Get all recorded trace entries.
    ///
    /// - Returns: An array of trace entries in chronological order.
    public func getEntries() -> [TraceEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    /// Get the number of recorded entries.
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// Export all trace entries as JSON data.
    ///
    /// - Returns: JSON-encoded trace data.
    /// - Throws: Encoding errors.
    public func exportJSON() throws -> Data {
        let entriesToExport = getEntries()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(entriesToExport)
    }

    /// Clear all recorded entries.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
    }

    // MARK: - Private

    private func record(
        direction: TraceEntry.Direction,
        type: String,
        data: Data,
        details: String?
    ) {
        let hexDump: String?
        #if DEBUG
        hexDump = Self.hexDump(data: data, maxBytes: 64)
        #else
        hexDump = nil
        #endif

        let entry = TraceEntry(
            timestamp: Date(),
            direction: direction,
            messageType: type,
            byteCount: data.count,
            hexDump: hexDump,
            details: details
        )

        lock.lock()
        defer { lock.unlock() }

        entries.append(entry)

        // Trim to maxEntries by removing oldest entries
        if entries.count > maxEntries {
            let excess = entries.count - maxEntries
            entries.removeFirst(excess)
        }
    }

    /// Generate a hex dump string for the first N bytes of data.
    private static func hexDump(data: Data, maxBytes: Int) -> String? {
        guard !data.isEmpty else { return nil }
        let bytesToDump = data.prefix(maxBytes)
        var result = ""
        result.reserveCapacity(bytesToDump.count * 3)

        for (index, byte) in bytesToDump.enumerated() {
            if index > 0 {
                if index % 16 == 0 {
                    result += "\n"
                } else {
                    result += " "
                }
            }
            result += String(format: "%02X", byte)
        }

        if data.count > maxBytes {
            result += " ... (\(data.count) bytes total)"
        }

        return result
    }
}
