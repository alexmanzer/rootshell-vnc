import Foundation

/// Decodes the CopyRect encoding (type 1).
///
/// CopyRect is the simplest encoding: the rectangle's pixel data is
/// a copy of another region of the framebuffer. The encoded data is
/// just two UInt16 values — the source x and y coordinates.
public struct CopyRectDecoder: EncodingDecoder, Sendable {

    public init() {}

    public mutating func decode(
        reader: inout MessageReader,
        rect: FramebufferRect,
        pixelFormat: PixelFormat
    ) throws -> DecodedRect {
        let srcX = try reader.readUInt16()
        let srcY = try reader.readUInt16()
        return .copyRect(srcX: srcX, srcY: srcY)
    }
}
