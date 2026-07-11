import Foundation
import zlib

/// Persistent RFC 1950 zlib inflater used by the RFB Zlib and ZRLE encodings.
///
/// Both encodings keep one stream for the connection and delimit rectangles
/// with `Z_SYNC_FLUSH`; they are not independent compressed files. Apple's
/// Compression.framework `COMPRESSION_ZLIB` codec does not implement this
/// wrapped streaming behavior, so using it silently returns deflate bytes as
/// output and eventually reports a decompression error.
public final class RFBZlibStreamInflater: @unchecked Sendable {
    private var stream = z_stream()
    private var initialized = false

    public init() throws {
        let status = inflateInit_(
            &stream,
            zlibVersion(),
            Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else {
            throw VNCProtocolError.protocolViolation(
                "Failed to initialize zlib inflater (status \(status))")
        }
        initialized = true
    }

    deinit {
        if initialized {
            inflateEnd(&stream)
        }
    }

    /// Reset the persistent dictionary at an encoding-defined stream boundary.
    /// Tight carries four independent zlib streams and signals resets in the
    /// low nibble of each rectangle's compression-control byte.
    public func reset() throws {
        let status = inflateReset(&stream)
        guard status == Z_OK else {
            throw VNCProtocolError.protocolViolation(
                "Failed to reset zlib inflater (status \(status))")
        }
    }

    /// Inflate one rectangle's compressed bytes while preserving the stream
    /// dictionary for the next rectangle.
    public func decompress(_ input: Data, maxOutputSize: Int) throws -> Data {
        guard !input.isEmpty else {
            throw VNCProtocolError.protocolViolation("Empty zlib input")
        }
        guard maxOutputSize > 0 else {
            throw VNCProtocolError.protocolViolation("Invalid zlib output limit")
        }

        // Inflate directly into the final storage. The previous 64 KiB scratch
        // loop allocated and zeroed a new Array for every chunk and then copied
        // every produced byte again through Data.append. Large desktop updates
        // can contain tens of megabytes of tile data, making that avoidable
        // copying visible as input latency.
        var output = Data(count: maxOutputSize)
        var outputCount = 0

        try input.withUnsafeBytes { rawInput in
            guard let inputBase = rawInput.baseAddress?
                .assumingMemoryBound(to: Bytef.self) else {
                throw VNCProtocolError.protocolViolation("Empty zlib input")
            }
            stream.next_in = UnsafeMutablePointer(mutating: inputBase)
            stream.avail_in = uInt(input.count)

            try output.withUnsafeMutableBytes { rawOutput in
                guard let outputBase = rawOutput.baseAddress?
                    .assumingMemoryBound(to: Bytef.self) else {
                    throw VNCProtocolError.protocolViolation(
                        "Failed to allocate zlib output")
                }

                while true {
                    let remainingLimit = maxOutputSize - outputCount
                    guard remainingLimit > 0 else {
                        if stream.avail_in == 0 { return }
                        throw VNCProtocolError.protocolViolation(
                            "Zlib output exceeds \(maxOutputSize) bytes")
                    }

                    // zlib's avail_out is a uInt. Limit each call without
                    // introducing an intermediate scratch buffer.
                    let capacity = min(remainingLimit, Int(UInt32.max))
                    stream.next_out = outputBase.advanced(by: outputCount)
                    stream.avail_out = uInt(capacity)
                    let inputBefore = stream.avail_in
                    let status = inflate(&stream, Z_SYNC_FLUSH)
                    let produced = capacity - Int(stream.avail_out)
                    outputCount += produced

                    switch status {
                    case Z_OK:
                        // Z_SYNC_FLUSH boundaries return Z_OK with all supplied
                        // input consumed. The dictionary remains live for the
                        // next rectangle.
                        if stream.avail_in == 0 && produced < capacity { return }
                        if produced == 0 && stream.avail_in == inputBefore {
                            throw VNCProtocolError.protocolViolation(
                                "Zlib inflater made no progress")
                        }

                    case Z_STREAM_END:
                        // Some compatible servers send independent complete
                        // streams. Accept that form and reset for the next rect.
                        let resetStatus = inflateReset(&stream)
                        guard resetStatus == Z_OK else {
                            throw VNCProtocolError.protocolViolation(
                                "Failed to reset zlib inflater (status \(resetStatus))")
                        }
                        return

                    case Z_BUF_ERROR where stream.avail_in == 0:
                        return

                    default:
                        let detail = stream.msg.map { String(cString: $0) }
                            ?? "status \(status)"
                        throw VNCProtocolError.protocolViolation(
                            "Zlib decompression error: \(detail)")
                    }
                }
            }
        }

        output.count = outputCount
        return output
    }
}
