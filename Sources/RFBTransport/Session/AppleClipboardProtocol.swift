import Foundation
import RFBProtocol
import zlib

/// Text-only support for the private pasteboard extension used by Apple's
/// Screen Sharing client. Rich flavors are consumed and ignored so clipboard
/// interoperability can never take down the display session.
enum AppleClipboardProtocol {
    static let requestMessageType: UInt8 = 11
    static let autoPasteboardMessageType: UInt8 = 21
    static let packedScrapMessageType: UInt8 = 31
    static let packedScrapHeaderSize = 16
    static let maximumClipboardSize = 100 * 1024 * 1024
    static let compressionChunkSize = 64 * 1024

    static func requestMessage(requestID: UInt32 = 0) -> Data {
        var data = Data([requestMessageType, 0, 0, 0])
        appendUInt32BE(requestID, to: &data)
        return data
    }

    static func autoPasteboardMessage(enabled: Bool) -> Data {
        Data([
            autoPasteboardMessageType, 0,
            0, enabled ? 1 : 2,
            0, 0, 0, 0,
        ])
    }

    /// Serialize one UTF-8 text flavor using the packed-scrap message emitted
    /// by Apple's Screen Sharing client. Byte two remains zero because this is
    /// complete pasteboard data rather than a pasteboard promise.
    static func packedTextMessage(_ text: String) throws -> Data {
        let flavorType = Data("public.utf8-plain-text".utf8)
        let textData = Data(text.utf8)
        let fixedScrapSize = 4 + 4 + flavorType.count + 4 + 4 + 4
        guard textData.count <= maximumClipboardSize - fixedScrapSize else {
            throw VNCProtocolError.protocolViolation(
                "Apple clipboard size is out of range")
        }

        var scrap = Data(capacity: fixedScrapSize + textData.count)
        appendUInt32BE(1, to: &scrap) // one pasteboard item flavor
        appendUInt32BE(UInt32(flavorType.count), to: &scrap)
        scrap.append(flavorType)
        appendUInt32BE(0, to: &scrap) // no translation requested
        appendUInt32BE(0, to: &scrap) // no additional UTI tags
        appendUInt32BE(UInt32(textData.count), to: &scrap)
        scrap.append(textData)

        let compressed = try compress(scrap)
        guard !compressed.isEmpty,
              compressed.count <= maximumClipboardSize else {
            throw VNCProtocolError.protocolViolation(
                "Apple clipboard size is out of range")
        }

        var message = Data([
            packedScrapMessageType, 0, 0, 0,
            0, 0, 0, 0,
        ])
        appendUInt32BE(UInt32(scrap.count), to: &message)
        appendUInt32BE(UInt32(compressed.count), to: &message)
        message.append(compressed)
        return message
    }

    static func unpackText(
        compressed: Data,
        uncompressedSize: Int
    ) throws -> String? {
        guard uncompressedSize > 0,
              uncompressedSize <= maximumClipboardSize,
              !compressed.isEmpty,
              compressed.count <= maximumClipboardSize else {
            throw VNCProtocolError.protocolViolation(
                "Apple clipboard size is out of range")
        }

        // Apple clipboard data uses zlib-wrapped DEFLATE. Native client
        // uploads stop at a Z_SYNC_FLUSH boundary, while server responses may
        // also use a complete stream; the persistent inflater accepts both.
        let inflater = try RFBZlibStreamInflater()
        let scrap = try inflater.decompress(
            compressed,
            maxOutputSize: uncompressedSize + 1)
        guard scrap.count == uncompressedSize else {
            throw VNCProtocolError.protocolViolation(
                "Apple clipboard decompressed length mismatch")
        }
        return try extractText(from: scrap)
    }

    static func uint32BE(_ data: Data, at index: Int) -> UInt32? {
        guard index >= data.startIndex, index + 4 <= data.endIndex else {
            return nil
        }
        return UInt32(data[index]) << 24
            | UInt32(data[index + 1]) << 16
            | UInt32(data[index + 2]) << 8
            | UInt32(data[index + 3])
    }

    private static func extractText(from scrap: Data) throws -> String? {
        var cursor = scrap.startIndex
        while cursor < scrap.endIndex {
            let flavorCount = try readUInt32BE(scrap, cursor: &cursor)
            guard flavorCount <= 4_096 else {
                throw VNCProtocolError.protocolViolation(
                    "Apple clipboard flavor count is out of range")
            }

            for _ in 0..<flavorCount {
                let declaredType = try readPackedString(scrap, cursor: &cursor)
                // CopyPackedScrapData stores a per-flavor translation flag
                // before the UTI tag dictionary. It is metadata, not a count.
                _ = try readUInt32BE(scrap, cursor: &cursor)
                let tagCount = try readUInt32BE(scrap, cursor: &cursor)
                guard tagCount <= 4_096 else {
                    throw VNCProtocolError.protocolViolation(
                        "Apple clipboard UTI tag count is out of range")
                }
                var typeCandidates = [declaredType]
                for _ in 0..<tagCount {
                    let tagClass = try readPackedString(
                        scrap, cursor: &cursor)
                    let tagValue = try readPackedString(
                        scrap, cursor: &cursor)
                    typeCandidates.append(tagClass)
                    typeCandidates.append(tagValue)
                }

                let length = Int(try readUInt32BE(scrap, cursor: &cursor))
                guard length <= scrap.endIndex - cursor else {
                    throw VNCProtocolError.protocolViolation(
                        "Truncated Apple clipboard flavor")
                }
                let flavorData = Data(scrap[cursor..<cursor + length])
                cursor += length

                for type in typeCandidates {
                    if let text = decodeText(flavorData, type: type) {
                        return text
                    }
                }
            }
        }
        return nil
    }

    private static func decodeText(_ data: Data, type: String) -> String? {
        switch type {
        case "public.utf16-plain-text":
            if data.starts(with: [0xFE, 0xFF])
                || data.starts(with: [0xFF, 0xFE]) {
                return String(data: data, encoding: .utf16)
            }
            return String(data: data, encoding: .utf16BigEndian)
                ?? String(data: data, encoding: .utf16LittleEndian)
        case "public.utf8-plain-text", "public.plain-text", "NSStringPboardType":
            return String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
        default:
            return nil
        }
    }

    private static func readPackedString(
        _ data: Data,
        cursor: inout Int
    ) throws -> String {
        let length = Int(try readUInt32BE(data, cursor: &cursor))
        guard length <= data.endIndex - cursor else {
            throw VNCProtocolError.protocolViolation(
                "Truncated Apple clipboard UTI")
        }
        let bytes = Data(data[cursor..<cursor + length])
        cursor += length
        guard let string = String(data: bytes, encoding: .utf8) else {
            throw VNCProtocolError.protocolViolation(
                "Invalid Apple clipboard UTI")
        }
        return string
    }

    private static func readUInt32BE(
        _ data: Data,
        cursor: inout Int
    ) throws -> UInt32 {
        guard let value = uint32BE(data, at: cursor) else {
            throw VNCProtocolError.protocolViolation(
                "Truncated Apple clipboard scrap")
        }
        cursor += 4
        return value
    }

    private static func appendUInt32BE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private static func compress(_ input: Data) throws -> Data {
        var stream = z_stream()
        let initializeStatus = deflateInit_(
            &stream,
            Z_BEST_COMPRESSION,
            zlibVersion(),
            Int32(MemoryLayout<z_stream>.size))
        guard initializeStatus == Z_OK else {
            throw VNCProtocolError.ioError(
                "Could not initialize Apple clipboard zlib stream "
                    + "(status \(initializeStatus))")
        }
        defer { deflateEnd(&stream) }

        // compressBound is a useful allocation hint, but zlib does not
        // guarantee it is sufficient for Z_SYNC_FLUSH. Keep draining with the
        // same flush mode until deflate reports unused output space.
        var output = Data()
        output.reserveCapacity(min(
            Int(compressBound(uLong(input.count))),
            maximumClipboardSize))
        var chunk = Data(count: compressionChunkSize)

        try input.withUnsafeBytes { inputBytes in
            guard let inputBase = inputBytes
                .bindMemory(to: Bytef.self).baseAddress else {
                throw VNCProtocolError.ioError(
                    "Could not access Apple clipboard bytes")
            }
            stream.next_in = UnsafeMutablePointer(mutating: inputBase)
            stream.avail_in = uInt(input.count)

            repeat {
                let inputBefore = stream.avail_in
                let status = chunk.withUnsafeMutableBytes { outputBytes in
                    guard let outputBase = outputBytes
                        .bindMemory(to: Bytef.self).baseAddress else {
                        return Z_BUF_ERROR
                    }
                    stream.next_out = outputBase
                    stream.avail_out = uInt(compressionChunkSize)
                    return deflate(&stream, Z_SYNC_FLUSH)
                }
                let produced = compressionChunkSize - Int(stream.avail_out)
                guard status == Z_OK,
                      produced > 0 || stream.avail_in < inputBefore else {
                    throw VNCProtocolError.ioError(
                        "Could not compress Apple clipboard "
                            + "(zlib status \(status))")
                }
                output.append(chunk.prefix(produced))
                guard output.count <= maximumClipboardSize else {
                    throw VNCProtocolError.protocolViolation(
                        "Apple clipboard size is out of range")
                }
            } while stream.avail_in > 0 || stream.avail_out == 0
        }
        return output
    }
}
