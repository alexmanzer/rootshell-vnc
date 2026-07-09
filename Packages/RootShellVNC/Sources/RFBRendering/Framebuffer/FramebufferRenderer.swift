import Foundation
import CoreGraphics
import Compression
import RFBProtocol

// MARK: - Rendering Errors

/// Errors that can occur during framebuffer rendering operations.
public enum RenderingError: Error, Sendable, LocalizedError {
    case insufficientData(expected: Int, got: Int)
    case decompressionFailed(String)
    case unsupportedEncoding(Encoding)
    case invalidTileData(String)

    public var errorDescription: String? {
        switch self {
        case .insufficientData(let expected, let got):
            return "Insufficient data: expected \(expected) bytes, got \(got)"
        case .decompressionFailed(let detail):
            return "Decompression failed: \(detail)"
        case .unsupportedEncoding(let encoding):
            return "Unsupported encoding: \(encoding)"
        case .invalidTileData(let detail):
            return "Invalid tile data: \(detail)"
        }
    }
}

// MARK: - FramebufferRenderer

/// Applies decoded encoding data to the framebuffer.
public final class FramebufferRenderer: @unchecked Sendable {

    private let framebuffer: Framebuffer
    private let pixelFormat: PixelFormat
    private var rawDecoder: RawEncodingRenderer
    private var zlibDecoder: ZlibEncodingRenderer
    private var zrleDecoder: ZRLEEncodingRenderer

    public init(framebuffer: Framebuffer, pixelFormat: PixelFormat) {
        self.framebuffer = framebuffer
        self.pixelFormat = pixelFormat
        self.rawDecoder = RawEncodingRenderer()
        self.zlibDecoder = ZlibEncodingRenderer()
        self.zrleDecoder = ZRLEEncodingRenderer()
    }

    /// Apply a rectangle update to the framebuffer.
    /// `data` contains the encoding-specific payload.
    public func applyRect(rect: FramebufferRect, data: Data) throws {
        switch rect.encoding {
        case .raw:
            rawDecoder.render(
                rect: rect, data: data,
                to: framebuffer, pixelFormat: pixelFormat
            )
        case .zlib:
            try zlibDecoder.render(
                rect: rect, data: data,
                to: framebuffer, pixelFormat: pixelFormat
            )
        case .zrle:
            try zrleDecoder.render(
                rect: rect, data: data,
                to: framebuffer, pixelFormat: pixelFormat
            )
        default:
            throw RenderingError.unsupportedEncoding(rect.encoding)
        }
    }

    /// Apply a CopyRect (data contains srcX, srcY as 2 UInt16s).
    public func applyCopyRect(rect: FramebufferRect, srcX: UInt16, srcY: UInt16) {
        framebuffer.copyRect(
            srcX: Int(srcX),
            srcY: Int(srcY),
            dstX: Int(rect.x),
            dstY: Int(rect.y),
            width: Int(rect.width),
            height: Int(rect.height)
        )
    }

    /// Get a snapshot of the current framebuffer.
    public func snapshot() -> CGImage? {
        framebuffer.createImage()
    }

    /// Handle desktop resize.
    public func handleDesktopResize(width: UInt16, height: UInt16) {
        framebuffer.resize(width: Int(width), height: Int(height))
    }
}

// MARK: - Raw Encoding Renderer

/// Renders Raw encoding data to framebuffer.
/// Raw encoding is simply pixel data in left-to-right, top-to-bottom order.
struct RawEncodingRenderer {

    func render(
        rect: FramebufferRect,
        data: Data,
        to framebuffer: Framebuffer,
        pixelFormat: PixelFormat
    ) {
        framebuffer.update(
            x: Int(rect.x),
            y: Int(rect.y),
            width: Int(rect.width),
            height: Int(rect.height),
            data: data
        )
    }
}

// MARK: - Zlib Encoding Renderer

/// Renders Zlib encoding data to framebuffer.
/// Maintains a persistent zlib decompression stream across rectangles,
/// as required by the RFB specification.
final class ZlibEncodingRenderer {

    private var stream: UnsafeMutablePointer<compression_stream>
    private var streamInitialized: Bool = false

    init() {
        stream = .allocate(capacity: 1)
        stream.pointee = compression_stream(
            dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!,
            dst_size: 0,
            src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!,
            src_size: 0,
            state: nil
        )
    }

    deinit {
        if streamInitialized {
            compression_stream_destroy(stream)
        }
        stream.deallocate()
    }

    func render(
        rect: FramebufferRect,
        data: Data,
        to framebuffer: Framebuffer,
        pixelFormat: PixelFormat
    ) throws {
        // Zlib encoding wire format: 4-byte length prefix, then zlib-compressed raw pixel data
        guard data.count >= 4 else {
            throw RenderingError.insufficientData(expected: 4, got: data.count)
        }

        let compressedLength = Int(data[data.startIndex]) << 24
            | Int(data[data.startIndex + 1]) << 16
            | Int(data[data.startIndex + 2]) << 8
            | Int(data[data.startIndex + 3])

        let compressedData = data.dropFirst(4)
        guard compressedData.count >= compressedLength else {
            throw RenderingError.insufficientData(
                expected: compressedLength,
                got: compressedData.count
            )
        }

        let compressedSlice = compressedData.prefix(compressedLength)
        let decompressed = try decompress(compressedSlice)

        framebuffer.update(
            x: Int(rect.x),
            y: Int(rect.y),
            width: Int(rect.width),
            height: Int(rect.height),
            data: decompressed
        )
    }

    private func decompress(_ data: Data) throws -> Data {
        // Initialize the stream on first use. The zlib stream is persistent
        // across rectangles as per the RFB spec.
        if !streamInitialized {
            let status = compression_stream_init(
                stream,
                COMPRESSION_STREAM_DECODE,
                COMPRESSION_ZLIB
            )
            guard status == COMPRESSION_STATUS_OK else {
                throw RenderingError.decompressionFailed("Failed to initialize zlib stream")
            }
            streamInitialized = true
        }

        return try data.withUnsafeBytes { srcBuffer -> Data in
            guard let srcBase = srcBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw RenderingError.decompressionFailed("Empty compressed data")
            }

            stream.pointee.src_ptr = srcBase
            stream.pointee.src_size = srcBuffer.count

            // Use a manually managed buffer so the pointer remains stable
            var outputCapacity = max(srcBuffer.count * 4, 4096)
            var outputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: outputCapacity)
            var totalWritten = 0

            while true {
                stream.pointee.dst_ptr = outputBuffer.advanced(by: totalWritten)
                stream.pointee.dst_size = outputCapacity - totalWritten

                let status = compression_stream_process(stream, 0)

                let bytesWritten = (outputCapacity - totalWritten) - stream.pointee.dst_size
                totalWritten += bytesWritten

                switch status {
                case COMPRESSION_STATUS_OK:
                    if stream.pointee.src_size == 0 {
                        // All input consumed
                        let result = Data(bytes: outputBuffer, count: totalWritten)
                        outputBuffer.deallocate()
                        return result
                    }
                    // Need more output space — reallocate
                    let newCapacity = outputCapacity * 2
                    let newBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: newCapacity)
                    newBuffer.initialize(from: outputBuffer, count: totalWritten)
                    outputBuffer.deallocate()
                    outputBuffer = newBuffer
                    outputCapacity = newCapacity
                    continue

                case COMPRESSION_STATUS_END:
                    let result = Data(bytes: outputBuffer, count: totalWritten)
                    outputBuffer.deallocate()
                    return result

                case COMPRESSION_STATUS_ERROR:
                    outputBuffer.deallocate()
                    throw RenderingError.decompressionFailed("Zlib decompression error")

                default:
                    let result = Data(bytes: outputBuffer, count: totalWritten)
                    outputBuffer.deallocate()
                    return result
                }
            }
        }
    }
}

// MARK: - ZRLE Encoding Renderer

/// Renders ZRLE (Zlib Run-Length Encoding) data to framebuffer.
/// ZRLE compresses tile-based data with a persistent zlib stream.
///
/// Wire format: 4-byte length, then zlib-compressed tile data.
/// Tile data is processed in 64x64 pixel tiles, left-to-right, top-to-bottom.
final class ZRLEEncodingRenderer {

    private var stream: UnsafeMutablePointer<compression_stream>
    private var streamInitialized: Bool = false

    init() {
        stream = .allocate(capacity: 1)
        stream.pointee = compression_stream(
            dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!,
            dst_size: 0,
            src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!,
            src_size: 0,
            state: nil
        )
    }

    deinit {
        if streamInitialized {
            compression_stream_destroy(stream)
        }
        stream.deallocate()
    }

    func render(
        rect: FramebufferRect,
        data: Data,
        to framebuffer: Framebuffer,
        pixelFormat: PixelFormat
    ) throws {
        guard data.count >= 4 else {
            throw RenderingError.insufficientData(expected: 4, got: data.count)
        }

        let compressedLength = Int(data[data.startIndex]) << 24
            | Int(data[data.startIndex + 1]) << 16
            | Int(data[data.startIndex + 2]) << 8
            | Int(data[data.startIndex + 3])

        let compressedData = data.dropFirst(4)
        guard compressedData.count >= compressedLength else {
            throw RenderingError.insufficientData(
                expected: compressedLength,
                got: compressedData.count
            )
        }

        let compressedSlice = compressedData.prefix(compressedLength)
        let tileData = try decompress(compressedSlice)

        // ZRLE uses "CPIXELs" — for 32bpp true-colour with certain conditions,
        // CPIXELs are 3 bytes; otherwise they are bytesPerPixel bytes.
        let usesCompactPixel = pixelFormat.bitsPerPixel == 32
            && pixelFormat.trueColor
            && pixelFormat.depth <= 24
        let cpixelSize = usesCompactPixel ? 3 : pixelFormat.bytesPerPixel

        var offset = tileData.startIndex
        let rectX = Int(rect.x)
        let rectY = Int(rect.y)
        let rectW = Int(rect.width)
        let rectH = Int(rect.height)

        // Process tiles in 64x64 blocks
        var tileY = 0
        while tileY < rectH {
            let tileHeight = min(64, rectH - tileY)
            var tileX = 0

            while tileX < rectW {
                let tileWidth = min(64, rectW - tileX)

                guard offset < tileData.endIndex else {
                    throw RenderingError.invalidTileData("Ran out of tile data")
                }

                let subencoding = Int(tileData[offset])
                offset += 1

                if subencoding == 0 {
                    // Raw CPIXEL data
                    let needed = tileWidth * tileHeight * cpixelSize
                    guard offset + needed <= tileData.endIndex else {
                        throw RenderingError.invalidTileData(
                            "Raw tile needs \(needed) bytes"
                        )
                    }

                    let pixels = expandCPixels(
                        tileData[offset ..< offset + needed],
                        count: tileWidth * tileHeight,
                        cpixelSize: cpixelSize,
                        pixelFormat: pixelFormat
                    )
                    framebuffer.update(
                        x: rectX + tileX,
                        y: rectY + tileY,
                        width: tileWidth,
                        height: tileHeight,
                        data: pixels
                    )
                    offset += needed

                } else if subencoding == 1 {
                    // Solid tile — single CPIXEL fills the entire tile
                    guard offset + cpixelSize <= tileData.endIndex else {
                        throw RenderingError.invalidTileData("Solid tile needs \(cpixelSize) bytes")
                    }
                    let pixel = expandSingleCPixel(
                        tileData[offset ..< offset + cpixelSize],
                        cpixelSize: cpixelSize,
                        pixelFormat: pixelFormat
                    )
                    framebuffer.fillRect(
                        x: rectX + tileX,
                        y: rectY + tileY,
                        width: tileWidth,
                        height: tileHeight,
                        pixel: pixel
                    )
                    offset += cpixelSize

                } else if subencoding >= 2 && subencoding <= 16 {
                    // Packed palette: subencoding = palette size
                    let paletteSize = subencoding
                    let paletteBytes = paletteSize * cpixelSize
                    guard offset + paletteBytes <= tileData.endIndex else {
                        throw RenderingError.invalidTileData("Palette needs \(paletteBytes) bytes")
                    }

                    // Read palette
                    var palette: [Data] = []
                    palette.reserveCapacity(paletteSize)
                    for i in 0 ..< paletteSize {
                        let pOffset = offset + i * cpixelSize
                        let expanded = expandSingleCPixel(
                            tileData[pOffset ..< pOffset + cpixelSize],
                            cpixelSize: cpixelSize,
                            pixelFormat: pixelFormat
                        )
                        palette.append(expanded)
                    }
                    offset += paletteBytes

                    // Determine bits per index
                    let bitsPerIndex: Int
                    if paletteSize <= 2 {
                        bitsPerIndex = 1
                    } else if paletteSize <= 4 {
                        bitsPerIndex = 2
                    } else {
                        bitsPerIndex = 4
                    }

                    // Read packed pixel indices
                    let indicesPerByte = 8 / bitsPerIndex
                    let mask = (1 << bitsPerIndex) - 1

                    let bpp = framebuffer.bytesPerPixel
                    var pixelRow = Data(capacity: tileWidth * bpp)

                    for row in 0 ..< tileHeight {
                        pixelRow.removeAll(keepingCapacity: true)

                        var byteIndex = 0
                        for col in 0 ..< tileWidth {
                            let posInByte = col % indicesPerByte
                            if posInByte == 0 && col > 0 {
                                byteIndex += 1
                            }

                            guard offset + byteIndex < tileData.endIndex else {
                                throw RenderingError.invalidTileData(
                                    "Ran out of packed palette data"
                                )
                            }

                            let byte = Int(tileData[offset + byteIndex])
                            let shift = (indicesPerByte - 1 - posInByte) * bitsPerIndex
                            let index = (byte >> shift) & mask

                            if index < palette.count {
                                pixelRow.append(palette[index])
                            } else {
                                // Invalid index; fill with black
                                pixelRow.append(
                                    contentsOf: [UInt8](repeating: 0, count: bpp)
                                )
                            }
                        }

                        // Each row is padded to a byte boundary
                        let bytesForRow = (tileWidth * bitsPerIndex + 7) / 8
                        offset += bytesForRow

                        framebuffer.update(
                            x: rectX + tileX,
                            y: rectY + tileY + row,
                            width: tileWidth,
                            height: 1,
                            data: pixelRow
                        )
                    }

                } else if subencoding == 128 {
                    // Plain RLE
                    let bpp = framebuffer.bytesPerPixel
                    var pixels = Data(capacity: tileWidth * tileHeight * bpp)
                    var pixelsRemaining = tileWidth * tileHeight

                    while pixelsRemaining > 0 {
                        guard offset + cpixelSize <= tileData.endIndex else {
                            throw RenderingError.invalidTileData("RLE ran out of pixel data")
                        }

                        let pixel = expandSingleCPixel(
                            tileData[offset ..< offset + cpixelSize],
                            cpixelSize: cpixelSize,
                            pixelFormat: pixelFormat
                        )
                        offset += cpixelSize

                        // Read run length
                        var runLength = 1
                        while offset < tileData.endIndex {
                            let byte = Int(tileData[offset])
                            offset += 1
                            runLength += byte
                            if byte != 255 { break }
                        }

                        runLength = min(runLength, pixelsRemaining)
                        for _ in 0 ..< runLength {
                            pixels.append(pixel)
                        }
                        pixelsRemaining -= runLength
                    }

                    framebuffer.update(
                        x: rectX + tileX,
                        y: rectY + tileY,
                        width: tileWidth,
                        height: tileHeight,
                        data: pixels
                    )

                } else if subencoding >= 130 {
                    // Palette RLE: subencoding - 128 = palette size
                    let paletteSize = subencoding - 128
                    let paletteBytes = paletteSize * cpixelSize
                    guard offset + paletteBytes <= tileData.endIndex else {
                        throw RenderingError.invalidTileData(
                            "Palette RLE needs \(paletteBytes) bytes"
                        )
                    }

                    var palette: [Data] = []
                    palette.reserveCapacity(paletteSize)
                    for i in 0 ..< paletteSize {
                        let pOffset = offset + i * cpixelSize
                        let expanded = expandSingleCPixel(
                            tileData[pOffset ..< pOffset + cpixelSize],
                            cpixelSize: cpixelSize,
                            pixelFormat: pixelFormat
                        )
                        palette.append(expanded)
                    }
                    offset += paletteBytes

                    let bpp = framebuffer.bytesPerPixel
                    var pixels = Data(capacity: tileWidth * tileHeight * bpp)
                    var pixelsRemaining = tileWidth * tileHeight

                    while pixelsRemaining > 0 {
                        guard offset < tileData.endIndex else {
                            throw RenderingError.invalidTileData("Palette RLE ran out of data")
                        }

                        let indexByte = Int(tileData[offset])
                        offset += 1

                        let paletteIndex = indexByte & 0x7F
                        let pixel: Data
                        if paletteIndex < palette.count {
                            pixel = palette[paletteIndex]
                        } else {
                            pixel = Data(repeating: 0, count: bpp)
                        }

                        if (indexByte & 0x80) != 0 {
                            // Run-length encoded entry
                            var runLength = 1
                            while offset < tileData.endIndex {
                                let byte = Int(tileData[offset])
                                offset += 1
                                runLength += byte
                                if byte != 255 { break }
                            }
                            runLength = min(runLength, pixelsRemaining)
                            for _ in 0 ..< runLength {
                                pixels.append(pixel)
                            }
                            pixelsRemaining -= runLength
                        } else {
                            // Single pixel
                            pixels.append(pixel)
                            pixelsRemaining -= 1
                        }
                    }

                    framebuffer.update(
                        x: rectX + tileX,
                        y: rectY + tileY,
                        width: tileWidth,
                        height: tileHeight,
                        data: pixels
                    )

                } else {
                    // Subencoding 17-127 and 129 are unused/invalid
                    throw RenderingError.invalidTileData(
                        "Invalid ZRLE subencoding: \(subencoding)"
                    )
                }

                tileX += 64
            }
            tileY += 64
        }
    }

    // MARK: - CPIXEL expansion

    /// Expand a CPIXEL (compact pixel) to a full pixel in framebuffer format.
    /// For 32bpp true-colour, CPIXELs are 3 bytes in little-endian order: B, G, R
    /// and we expand to 4-byte BGRA.
    private func expandSingleCPixel(
        _ data: Data.SubSequence,
        cpixelSize: Int,
        pixelFormat: PixelFormat
    ) -> Data {
        if cpixelSize == 3 && pixelFormat.bytesPerPixel == 4 {
            // 3-byte CPIXEL -> 4-byte BGRA
            let base = data.startIndex
            var pixel = Data(count: 4)
            pixel[0] = data[base]       // Blue
            pixel[1] = data[base + 1]   // Green
            pixel[2] = data[base + 2]   // Red
            pixel[3] = 0xFF             // Alpha
            return pixel
        } else {
            return Data(data)
        }
    }

    /// Expand multiple CPIXELs to full pixels.
    private func expandCPixels(
        _ data: Data.SubSequence,
        count: Int,
        cpixelSize: Int,
        pixelFormat: PixelFormat
    ) -> Data {
        if cpixelSize == 3 && pixelFormat.bytesPerPixel == 4 {
            var result = Data(capacity: count * 4)
            var offset = data.startIndex
            for _ in 0 ..< count {
                result.append(data[offset])         // Blue
                result.append(data[offset + 1])     // Green
                result.append(data[offset + 2])     // Red
                result.append(0xFF)                  // Alpha
                offset += 3
            }
            return result
        } else {
            return Data(data)
        }
    }

    // MARK: - Decompression

    private func decompress(_ data: Data) throws -> Data {
        if !streamInitialized {
            let status = compression_stream_init(
                stream,
                COMPRESSION_STREAM_DECODE,
                COMPRESSION_ZLIB
            )
            guard status == COMPRESSION_STATUS_OK else {
                throw RenderingError.decompressionFailed("Failed to initialize zlib stream")
            }
            streamInitialized = true
        }

        return try data.withUnsafeBytes { srcBuffer -> Data in
            guard let srcBase = srcBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw RenderingError.decompressionFailed("Empty compressed data")
            }

            stream.pointee.src_ptr = srcBase
            stream.pointee.src_size = srcBuffer.count

            // Use a manually managed buffer so the pointer remains stable
            var outputCapacity = max(srcBuffer.count * 4, 4096)
            var outputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: outputCapacity)
            var totalWritten = 0

            while true {
                stream.pointee.dst_ptr = outputBuffer.advanced(by: totalWritten)
                stream.pointee.dst_size = outputCapacity - totalWritten

                let status = compression_stream_process(stream, 0)

                let bytesWritten = (outputCapacity - totalWritten) - stream.pointee.dst_size
                totalWritten += bytesWritten

                switch status {
                case COMPRESSION_STATUS_OK:
                    if stream.pointee.src_size == 0 {
                        let result = Data(bytes: outputBuffer, count: totalWritten)
                        outputBuffer.deallocate()
                        return result
                    }
                    // Need more output space — reallocate
                    let newCapacity = outputCapacity * 2
                    let newBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: newCapacity)
                    newBuffer.initialize(from: outputBuffer, count: totalWritten)
                    outputBuffer.deallocate()
                    outputBuffer = newBuffer
                    outputCapacity = newCapacity
                    continue

                case COMPRESSION_STATUS_END:
                    let result = Data(bytes: outputBuffer, count: totalWritten)
                    outputBuffer.deallocate()
                    return result

                case COMPRESSION_STATUS_ERROR:
                    outputBuffer.deallocate()
                    throw RenderingError.decompressionFailed("ZRLE zlib decompression error")

                default:
                    let result = Data(bytes: outputBuffer, count: totalWritten)
                    outputBuffer.deallocate()
                    return result
                }
            }
        }
    }
}
