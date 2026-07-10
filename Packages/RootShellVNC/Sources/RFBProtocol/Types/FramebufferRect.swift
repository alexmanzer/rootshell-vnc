import Foundation

/// Header for a single rectangle within a FramebufferUpdate server message.
///
/// Wire layout (12 bytes):
/// ```
///  Bytes 0-1:  x-position  (big-endian UInt16)
///  Bytes 2-3:  y-position  (big-endian UInt16)
///  Bytes 4-5:  width       (big-endian UInt16)
///  Bytes 6-7:  height      (big-endian UInt16)
///  Bytes 8-11: encoding    (big-endian Int32)
/// ```
public struct FramebufferRect: Sendable, Equatable {

    public let x: UInt16
    public let y: UInt16
    public let width: UInt16
    public let height: UInt16
    public let encoding: Encoding

    /// The fixed wire size of a rectangle header.
    public static let wireSize = 12

    // MARK: - Init

    public init(x: UInt16, y: UInt16, width: UInt16, height: UInt16, encoding: Encoding) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.encoding = encoding
    }

    /// Parse a rectangle header from a `MessageReader`.
    public init(reader: inout MessageReader) throws {
        self.x = try reader.readUInt16()
        self.y = try reader.readUInt16()
        self.width = try reader.readUInt16()
        self.height = try reader.readUInt16()
        let encodingRaw = try reader.readInt32()
        self.encoding = Encoding(rawValue: encodingRaw)
    }

    /// Total pixel count for this rectangle.
    public var pixelCount: Int {
        Int(width) * Int(height)
    }

    /// Whether this rectangle announces a usable framebuffer geometry.
    ///
    /// `ExtendedDesktopSize` overloads the rectangle's `y` field with a
    /// status code when replying to a client-initiated layout request. A
    /// nonzero status is a rejection, not a resize.
    public var isSuccessfulDesktopResize: Bool {
        guard width > 0, height > 0 else { return false }
        switch encoding {
        case .desktopSize:
            return true
        case .extendedDesktopSize:
            return y == 0
        default:
            return false
        }
    }
}
