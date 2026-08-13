import Foundation
import RFBProtocol

/// TLV (Type-Length-Value) parser and serializer for Apple SRP authentication messages.
///
/// Wire format per entry:
/// - type:   UInt8 (1 byte)
/// - length: UInt32 big-endian (4 bytes)
/// - value:  `length` bytes
///
/// Known TLV types:
/// ```
/// 0x01 = username
/// 0x02 = salt
/// 0x03 = public key (B from server, A from client)
/// 0x04 = proof (M1 from client, M2 from server)
/// 0x05 = generator (g)
/// 0x06 = prime (N)
/// 0x07 = RSA public key (DER-encoded)
/// 0x08 = iterations (UInt32 big-endian)
/// 0x09 = PBKDF key length
/// ```
public struct SRPBinaryBuffer: Sendable {

    // MARK: - TLV type constants

    public static let typeUsername:    UInt8 = 0x01
    public static let typeSalt:       UInt8 = 0x02
    public static let typePublicKey:  UInt8 = 0x03
    public static let typeProof:      UInt8 = 0x04
    public static let typeGenerator:  UInt8 = 0x05
    public static let typePrime:      UInt8 = 0x06
    public static let typeRSAKey:     UInt8 = 0x07
    public static let typeIterations: UInt8 = 0x08
    public static let typePBKDFLen:   UInt8 = 0x09

    // MARK: - Parsing

    /// Parse a TLV buffer into a dictionary of type -> value.
    ///
    /// If the same type appears multiple times, the last occurrence wins.
    ///
    /// - Parameter data: The raw TLV data.
    /// - Returns: Dictionary mapping TLV type bytes to their value data.
    /// - Throws: ``VNCProtocolError`` if the data is malformed.
    public static func parse(data: Data) throws -> [UInt8: Data] {
        var result: [UInt8: Data] = [:]
        var offset = data.startIndex

        while offset < data.endIndex {
            // Need at least 5 bytes for type + length
            guard offset + 5 <= data.endIndex else {
                throw VNCProtocolError.protocolViolation(
                    "SRP TLV truncated: need 5 bytes for header at offset \(offset - data.startIndex), "
                    + "have \(data.endIndex - offset)")
            }

            let type = data[offset]
            offset += 1

            let length = UInt32(data[offset]) << 24
                       | UInt32(data[offset + 1]) << 16
                       | UInt32(data[offset + 2]) << 8
                       | UInt32(data[offset + 3])
            offset += 4

            let intLength = Int(length)
            guard offset + intLength <= data.endIndex else {
                throw VNCProtocolError.protocolViolation(
                    "SRP TLV value truncated: type=0x\(String(type, radix: 16)), "
                    + "declared length=\(length), available=\(data.endIndex - offset)")
            }

            let value = Data(data[offset..<(offset + intLength)])
            offset += intLength

            result[type] = value
        }

        return result
    }

    // MARK: - Serialization

    /// Serialize a dictionary of type -> value into TLV wire format.
    ///
    /// Entries are written in ascending order of their type byte for determinism.
    ///
    /// - Parameter entries: Dictionary of TLV entries to serialize.
    /// - Returns: The serialized TLV data.
    public static func serialize(entries: [UInt8: Data]) -> Data {
        let sortedKeys = entries.keys.sorted()
        var result = Data()

        for key in sortedKeys {
            guard let value = entries[key] else { continue }
            result.append(key)

            // Length as UInt32 big-endian
            let length = UInt32(value.count)
            result.append(UInt8((length >> 24) & 0xFF))
            result.append(UInt8((length >> 16) & 0xFF))
            result.append(UInt8((length >> 8) & 0xFF))
            result.append(UInt8(length & 0xFF))

            result.append(value)
        }

        return result
    }

    // MARK: - Helpers

    /// Extract a UInt32 from a 4-byte big-endian data value.
    public static func readUInt32(_ data: Data) -> UInt32 {
        guard data.count >= 4 else { return 0 }
        let base = data.startIndex
        return UInt32(data[base]) << 24
             | UInt32(data[base + 1]) << 16
             | UInt32(data[base + 2]) << 8
             | UInt32(data[base + 3])
    }

    /// Serialize a UInt32 to 4-byte big-endian data.
    public static func writeUInt32(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ])
    }
}
