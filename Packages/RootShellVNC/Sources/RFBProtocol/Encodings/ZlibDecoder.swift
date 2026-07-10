import Foundation

/// Decodes the Zlib encoding (type 6).
///
/// Zlib encoding uses a single zlib compression stream that persists across
/// all rectangles in a connection. Each rectangle's data is prefixed with a
/// UInt32 compressed length, followed by that many bytes of zlib-compressed
/// pixel data. The decompressed data is raw pixels in the negotiated format.
///
/// **Important:** The zlib stream must be maintained across rectangles — you
/// cannot create a new decompressor for each rectangle.
public final class ZlibDecoder: EncodingDecoder, @unchecked Sendable {

    private let inflater: RFBZlibStreamInflater?

    public init() {
        // Keep the existing non-throwing decoder API and surface an unlikely
        // zlib ABI/version mismatch when decode is first attempted.
        inflater = try? RFBZlibStreamInflater()
    }

    // MARK: - EncodingDecoder

    public func decode(
        reader: inout MessageReader,
        rect: FramebufferRect,
        pixelFormat: PixelFormat
    ) throws -> DecodedRect {
        let compressedLength = try reader.readUInt32()
        let compressedData = try reader.readBytes(Int(compressedLength))

        let expectedSize = Int(rect.width) * Int(rect.height) * pixelFormat.bytesPerPixel
        guard let inflater else {
            throw VNCProtocolError.protocolViolation(
                "Failed to initialize system zlib stream")
        }
        let decompressed = try inflater.decompress(
            compressedData,
            maxOutputSize: expectedSize)
        guard decompressed.count == expectedSize else {
            throw VNCProtocolError.protocolViolation(
                "Zlib rectangle decoded \(decompressed.count) bytes; expected \(expectedSize)")
        }

        return .pixels(decompressed)
    }
}
