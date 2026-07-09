import Foundation

/// A 16-byte pixel format descriptor as defined in the RFB specification.
///
/// Wire layout (16 bytes total):
/// ```
///  Byte 0:    bits-per-pixel   (8, 16, or 32)
///  Byte 1:    depth            (number of useful bits)
///  Byte 2:    big-endian-flag  (0 = little-endian, nonzero = big-endian)
///  Byte 3:    true-colour-flag (0 = colour map, nonzero = true colour)
///  Bytes 4-5: red-max          (big-endian UInt16)
///  Bytes 6-7: green-max        (big-endian UInt16)
///  Bytes 8-9: blue-max         (big-endian UInt16)
///  Byte 10:   red-shift
///  Byte 11:   green-shift
///  Byte 12:   blue-shift
///  Bytes 13-15: padding (3 bytes, must be zero)
/// ```
public struct PixelFormat: Sendable, Equatable {

    public let bitsPerPixel: UInt8
    public let depth: UInt8
    public let bigEndian: Bool
    public let trueColor: Bool
    public let redMax: UInt16
    public let greenMax: UInt16
    public let blueMax: UInt16
    public let redShift: UInt8
    public let greenShift: UInt8
    public let blueShift: UInt8

    /// The fixed wire size of a pixel format.
    public static let wireSize = 16

    // MARK: - Init

    public init(
        bitsPerPixel: UInt8,
        depth: UInt8,
        bigEndian: Bool,
        trueColor: Bool,
        redMax: UInt16,
        greenMax: UInt16,
        blueMax: UInt16,
        redShift: UInt8,
        greenShift: UInt8,
        blueShift: UInt8
    ) {
        self.bitsPerPixel = bitsPerPixel
        self.depth = depth
        self.bigEndian = bigEndian
        self.trueColor = trueColor
        self.redMax = redMax
        self.greenMax = greenMax
        self.blueMax = blueMax
        self.redShift = redShift
        self.greenShift = greenShift
        self.blueShift = blueShift
    }

    // MARK: - Parsing

    /// Parse a `PixelFormat` from exactly 16 bytes of `data`.
    public init(data: Data) throws {
        guard data.count >= Self.wireSize else {
            throw VNCProtocolError.protocolViolation("PixelFormat needs 16 bytes, got \(data.count)")
        }

        let base = data.startIndex
        bitsPerPixel = data[base]
        depth = data[base + 1]
        bigEndian = data[base + 2] != 0
        trueColor = data[base + 3] != 0
        redMax = UInt16(data[base + 4]) << 8 | UInt16(data[base + 5])
        greenMax = UInt16(data[base + 6]) << 8 | UInt16(data[base + 7])
        blueMax = UInt16(data[base + 8]) << 8 | UInt16(data[base + 9])
        redShift = data[base + 10]
        greenShift = data[base + 11]
        blueShift = data[base + 12]
        // bytes 13-15 are padding, ignored
    }

    // MARK: - Serialization

    /// Serialize this pixel format to its 16-byte wire representation.
    public func wireBytes() -> Data {
        var buf = Data(count: 16)
        buf[0] = bitsPerPixel
        buf[1] = depth
        buf[2] = bigEndian ? 1 : 0
        buf[3] = trueColor ? 1 : 0
        buf[4] = UInt8(redMax >> 8)
        buf[5] = UInt8(redMax & 0xFF)
        buf[6] = UInt8(greenMax >> 8)
        buf[7] = UInt8(greenMax & 0xFF)
        buf[8] = UInt8(blueMax >> 8)
        buf[9] = UInt8(blueMax & 0xFF)
        buf[10] = redShift
        buf[11] = greenShift
        buf[12] = blueShift
        buf[13] = 0 // padding
        buf[14] = 0
        buf[15] = 0
        return buf
    }

    // MARK: - Presets

    /// 32-bit BGRA with 8 bits per channel — native macOS/iOS pixel order.
    public static let bgra8888 = PixelFormat(
        bitsPerPixel: 32,
        depth: 24,
        bigEndian: false,
        trueColor: true,
        redMax: 255,
        greenMax: 255,
        blueMax: 255,
        redShift: 16,
        greenShift: 8,
        blueShift: 0
    )

    /// 32-bit RGB with 8 bits per channel, big-endian byte order.
    public static let rgb888 = PixelFormat(
        bitsPerPixel: 32,
        depth: 24,
        bigEndian: true,
        trueColor: true,
        redMax: 255,
        greenMax: 255,
        blueMax: 255,
        redShift: 16,
        greenShift: 8,
        blueShift: 0
    )

    // MARK: - Helpers

    /// Bytes per pixel (1, 2, or 4).
    public var bytesPerPixel: Int {
        Int(bitsPerPixel) / 8
    }
}
