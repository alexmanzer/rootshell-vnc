import Foundation

/// The ServerInit message sent by the server after authentication,
/// describing the framebuffer dimensions, pixel format, and desktop name.
///
/// Wire layout:
/// ```
///  Bytes 0-1:   framebuffer-width  (big-endian UInt16)
///  Bytes 2-3:   framebuffer-height (big-endian UInt16)
///  Bytes 4-19:  pixel-format       (16 bytes)
///  Bytes 20-23: name-length        (big-endian UInt32)
///  Bytes 24..:  name-string        (UTF-8, `name-length` bytes)
/// ```
public struct ServerInit: Sendable, Equatable {

    public let framebufferWidth: UInt16
    public let framebufferHeight: UInt16
    public let pixelFormat: PixelFormat
    public let name: String

    // MARK: - Init

    public init(
        framebufferWidth: UInt16,
        framebufferHeight: UInt16,
        pixelFormat: PixelFormat,
        name: String
    ) {
        self.framebufferWidth = framebufferWidth
        self.framebufferHeight = framebufferHeight
        self.pixelFormat = pixelFormat
        self.name = name
    }

    /// Parse a `ServerInit` from a `MessageReader`.
    public init(reader: inout MessageReader) throws {
        self.framebufferWidth = try reader.readUInt16()
        self.framebufferHeight = try reader.readUInt16()
        self.pixelFormat = try reader.readPixelFormat()
        self.name = try reader.readString()
    }

    /// Minimum wire size (without name bytes): 2 + 2 + 16 + 4 = 24 bytes.
    public static let minWireSize = 24
}
