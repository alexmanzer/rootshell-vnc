import Foundation

/// Decodes the Raw encoding (type 0): uncompressed pixel data.
///
/// The data is simply `width * height * bytesPerPixel` bytes of pixel
/// data in the negotiated pixel format, in left-to-right, top-to-bottom order.
public struct RawDecoder: EncodingDecoder, Sendable {

    public init() {}

    public mutating func decode(
        reader: inout MessageReader,
        rect: FramebufferRect,
        pixelFormat: PixelFormat
    ) throws -> DecodedRect {
        let byteCount = Int(rect.width) * Int(rect.height) * pixelFormat.bytesPerPixel
        let data = try reader.readBytes(byteCount)
        return .pixels(data)
    }
}
