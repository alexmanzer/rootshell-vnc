import Foundation
import Compression

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

    // MARK: - Decompression state

    private var streamInitialized = false
    // Initialize with placeholder values; real pointers are set before each use.
    nonisolated(unsafe) private var stream = compression_stream(
        dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!,
        dst_size: 0,
        src_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!,
        src_size: 0,
        state: nil
    )

    public init() {}

    deinit {
        if streamInitialized {
            compression_stream_destroy(&stream)
        }
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
        let decompressed = try decompress(compressedData, expectedOutputSize: expectedSize)

        return .pixels(decompressed)
    }

    // MARK: - Private

    private func decompress(_ input: Data, expectedOutputSize: Int) throws -> Data {
        if !streamInitialized {
            let status = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
            guard status == COMPRESSION_STATUS_OK else {
                throw VNCProtocolError.protocolViolation("Failed to initialize zlib decompression stream")
            }
            streamInitialized = true
        }

        var output = Data(count: expectedOutputSize)

        let result: Data = try input.withUnsafeBytes { inputPtr in
            guard let inputBase = inputPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw VNCProtocolError.protocolViolation("Empty compressed data")
            }

            stream.src_ptr = inputBase
            stream.src_size = input.count

            return try output.withUnsafeMutableBytes { outputPtr in
                guard let outputBase = outputPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    throw VNCProtocolError.protocolViolation("Failed to allocate output buffer")
                }

                stream.dst_ptr = outputBase
                stream.dst_size = expectedOutputSize

                let status = compression_stream_process(&stream, 0)

                switch status {
                case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                    let produced = expectedOutputSize - stream.dst_size
                    return Data(bytes: outputBase, count: produced)
                case COMPRESSION_STATUS_ERROR:
                    throw VNCProtocolError.protocolViolation("Zlib decompression error")
                default:
                    throw VNCProtocolError.protocolViolation("Unexpected compression status: \(status)")
                }
            }
        }

        return result
    }
}
