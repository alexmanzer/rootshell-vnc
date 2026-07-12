import Foundation

/// Represents an RFB protocol version as exchanged during the handshake.
///
/// The wire format is exactly 12 bytes: `"RFB XXX.YYY\n"` where XXX and YYY
/// are zero-padded 3-digit decimal numbers for major and minor version.
public struct ProtocolVersion: Sendable, Equatable, CustomStringConvertible {

    // MARK: - Properties

    public let major: UInt16
    public let minor: UInt16

    // MARK: - Well-known versions

    public static let v3_3  = ProtocolVersion(major: 3, minor: 3)
    public static let v3_7  = ProtocolVersion(major: 3, minor: 7)
    public static let v3_8  = ProtocolVersion(major: 3, minor: 8)

    /// Apple Remote Desktop uses this non-standard version to signal its
    /// proprietary authentication and encoding extensions.
    public static let apple  = ProtocolVersion(major: 3, minor: 889)

    // MARK: - Init

    public init(major: UInt16, minor: UInt16) {
        self.major = major
        self.minor = minor
    }

    // MARK: - Wire format (12 bytes)

    /// The fixed size of a protocol version message on the wire.
    public static let wireSize = 12

    /// Parse a `ProtocolVersion` from the first 12 bytes of `data`.
    ///
    /// Expected format: `RFB 003.008\n` (ASCII).
    public init(data: Data) throws {
        guard data.count >= Self.wireSize else {
            throw VNCProtocolError.protocolViolation("Protocol version message too short (\(data.count) bytes)")
        }

        // Validate prefix "RFB "
        let prefix = data[data.startIndex..<data.startIndex + 4]
        guard prefix.elementsEqual("RFB ".utf8) else {
            throw VNCProtocolError.protocolViolation("Invalid protocol version prefix")
        }

        // Bytes 4..6 = major (3 ASCII digits)
        let majorSlice = data[data.startIndex + 4 ..< data.startIndex + 7]
        guard let majorStr = String(bytes: majorSlice, encoding: .ascii),
              let majorVal = UInt16(majorStr) else {
            throw VNCProtocolError.protocolViolation("Cannot parse major version")
        }

        // Byte 7 must be '.'
        guard data[data.startIndex + 7] == UInt8(ascii: ".") else {
            throw VNCProtocolError.protocolViolation("Expected '.' separator in protocol version")
        }

        // Bytes 8..10 = minor (3 ASCII digits)
        let minorSlice = data[data.startIndex + 8 ..< data.startIndex + 11]
        guard let minorStr = String(bytes: minorSlice, encoding: .ascii),
              let minorVal = UInt16(minorStr) else {
            throw VNCProtocolError.protocolViolation("Cannot parse minor version")
        }

        // Byte 11 must be '\n'
        guard data[data.startIndex + 11] == UInt8(ascii: "\n") else {
            throw VNCProtocolError.protocolViolation("Expected newline at end of protocol version")
        }

        self.major = majorVal
        self.minor = minorVal
    }

    /// Serialize this version to its 12-byte wire representation.
    public func wireBytes() -> Data {
        let str = String(format: "RFB %03d.%03d\n", major, minor)
        return Data(str.utf8)
    }

    // MARK: - CustomStringConvertible

    public var description: String {
        "RFB \(major).\(minor)"
    }

    // MARK: - Helpers

    /// Whether this version is at least as new as the given version.
    public func isAtLeast(_ other: ProtocolVersion) -> Bool {
        if major != other.major { return major > other.major }
        return minor >= other.minor
    }

    /// Whether the server signalled Apple Remote Desktop extensions.
    public var isApple: Bool {
        major == 3 && minor == 889
    }
}
