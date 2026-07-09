import Foundation

/// Error thrown when a `MessageReader` runs out of data.
public enum MessageReaderError: Error, Sendable, LocalizedError {
    /// There are fewer bytes remaining than the read operation requires.
    case unexpectedEnd(needed: Int, available: Int)

    public var errorDescription: String? {
        switch self {
        case .unexpectedEnd(let needed, let available):
            return "Unexpected end of data: needed \(needed) bytes but only \(available) available."
        }
    }
}

/// A pull-based binary reader for RFB protocol messages.
///
/// `MessageReader` wraps a `Data` buffer and provides sequential reads of
/// fixed-width integers (big-endian), byte slices, and composite RFB types.
///
/// This type is intentionally *not* `Sendable` — it holds mutable parsing
/// state and is designed for local, single-threaded use.
public struct MessageReader {

    // MARK: - Storage

    private let data: Data
    private var offset: Int

    // MARK: - Init

    /// Create a new reader over the given data buffer.
    public init(data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    // MARK: - Position

    /// The current byte position within the buffer.
    public var position: Int {
        offset - data.startIndex
    }

    /// The number of unread bytes remaining.
    public var remaining: Int {
        data.endIndex - offset
    }

    // MARK: - Primitives

    /// Read a single byte and advance the position.
    public mutating func readUInt8() throws -> UInt8 {
        try ensureAvailable(1)
        let value = data[offset]
        offset += 1
        return value
    }

    /// Read a big-endian `UInt16` and advance the position by 2.
    public mutating func readUInt16() throws -> UInt16 {
        try ensureAvailable(2)
        let value = UInt16(data[offset]) << 8
                  | UInt16(data[offset + 1])
        offset += 2
        return value
    }

    /// Read a big-endian `UInt32` and advance the position by 4.
    public mutating func readUInt32() throws -> UInt32 {
        try ensureAvailable(4)
        let value = UInt32(data[offset])     << 24
                  | UInt32(data[offset + 1]) << 16
                  | UInt32(data[offset + 2]) << 8
                  | UInt32(data[offset + 3])
        offset += 4
        return value
    }

    /// Read a big-endian `Int32` and advance the position by 4.
    public mutating func readInt32() throws -> Int32 {
        let raw = try readUInt32()
        return Int32(bitPattern: raw)
    }

    /// Read exactly `count` bytes and advance the position.
    public mutating func readBytes(_ count: Int) throws -> Data {
        guard count >= 0 else {
            throw MessageReaderError.unexpectedEnd(needed: count, available: remaining)
        }
        try ensureAvailable(count)
        let slice = data[offset ..< offset + count]
        offset += count
        return Data(slice)
    }

    /// Skip `count` bytes without returning them.
    public mutating func skip(_ count: Int) throws {
        try ensureAvailable(count)
        offset += count
    }

    // MARK: - Composite types

    /// Read a length-prefixed UTF-8 string (UInt32 length prefix, then that many bytes).
    public mutating func readString() throws -> String {
        let length = try readUInt32()
        let bytes = try readBytes(Int(length))
        guard let str = String(data: bytes, encoding: .utf8) else {
            // Fall back to latin1 which never fails
            return String(data: bytes, encoding: .isoLatin1) ?? ""
        }
        return str
    }

    /// Read a 16-byte `PixelFormat`.
    public mutating func readPixelFormat() throws -> PixelFormat {
        let bytes = try readBytes(PixelFormat.wireSize)
        return try PixelFormat(data: bytes)
    }

    /// Read a complete `ServerInit` message.
    public mutating func readServerInit() throws -> ServerInit {
        return try ServerInit(reader: &self)
    }

    /// Read a `FramebufferRect` header (12 bytes).
    public mutating func readFramebufferRect() throws -> FramebufferRect {
        return try FramebufferRect(reader: &self)
    }

    // MARK: - Private

    private func ensureAvailable(_ count: Int) throws {
        guard remaining >= count else {
            throw MessageReaderError.unexpectedEnd(needed: count, available: remaining)
        }
    }
}
