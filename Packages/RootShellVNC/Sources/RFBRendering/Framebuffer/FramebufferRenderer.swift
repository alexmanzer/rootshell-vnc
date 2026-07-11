import Foundation
import CoreGraphics
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

/// Result of applying one complete server framebuffer update off the UI actor.
public struct FramebufferRenderBatchResult: @unchecked Sendable {
    public let image: CGImage?
    public let resizedWidth: UInt16?
    public let resizedHeight: UInt16?
    /// Non-nil only when this update carried a Cursor pseudo-encoding rect.
    public let cursorUpdate: RemoteCursorUpdate?
    public let issues: [String]
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

    /// Apply every rectangle in one server update in wire order and snapshot
    /// once. Keeping this operation on a serial rendering queue preserves the
    /// persistent Zlib/ZRLE dictionary without blocking the main actor.
    ///
    /// Pass `snapshot: false` to apply rects without paying for the
    /// full-framebuffer image copy — the result's `image` is nil and the
    /// caller publishes a later snapshot instead.
    public func applyBatch(
        _ rects: [(FramebufferRect, Data)],
        snapshot takeSnapshot: Bool = true
    ) -> FramebufferRenderBatchResult {
        var resizedWidth: UInt16?
        var resizedHeight: UInt16?
        var cursorUpdate: RemoteCursorUpdate?
        var issues: [String] = []

        for (rect, data) in rects {
            switch rect.encoding {
            case .copyRect:
                guard data.count >= 4 else {
                    issues.append("CopyRect payload is shorter than 4 bytes")
                    continue
                }
                let srcX = UInt16(data[data.startIndex]) << 8
                    | UInt16(data[data.startIndex + 1])
                let srcY = UInt16(data[data.startIndex + 2]) << 8
                    | UInt16(data[data.startIndex + 3])
                applyCopyRect(rect: rect, srcX: srcX, srcY: srcY)

            case .desktopSize, .extendedDesktopSize:
                guard rect.isSuccessfulDesktopResize else { continue }
                handleDesktopResize(width: rect.width, height: rect.height)
                resizedWidth = rect.width
                resizedHeight = rect.height

            case .cursor:
                // Cosmetic: the local system pointer adopts this shape.
                // Never fail the update over a malformed cursor payload.
                if let update = RemoteCursorDecoder.decode(
                    rect: rect, data: data, pixelFormat: pixelFormat) {
                    cursorUpdate = update
                }

            case .encryptionInfo, .serverDisplayInfo,
                 .mediaStreamOffer, .mediaStreamAnswer:
                break

            default:
                do {
                    try applyRect(rect: rect, data: data)
                } catch {
                    issues.append(
                        "Failed to apply rect (\(rect.encoding)): "
                            + error.localizedDescription)
                }
            }
        }

        return FramebufferRenderBatchResult(
            image: takeSnapshot ? snapshot() : nil,
            resizedWidth: resizedWidth,
            resizedHeight: resizedHeight,
            cursorUpdate: cursorUpdate,
            issues: issues)
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
    private let inflater = try? RFBZlibStreamInflater()

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
        guard let inflater else {
            throw RenderingError.decompressionFailed(
                "Failed to initialize system zlib stream")
        }
        let expectedSize = Int(rect.width) * Int(rect.height)
            * pixelFormat.bytesPerPixel
        let decompressed: Data
        do {
            decompressed = try inflater.decompress(
                Data(compressedSlice),
                maxOutputSize: expectedSize)
        } catch {
            throw RenderingError.decompressionFailed(error.localizedDescription)
        }
        guard decompressed.count == expectedSize else {
            throw RenderingError.decompressionFailed(
                "Zlib rectangle decoded \(decompressed.count) bytes; expected \(expectedSize)")
        }

        framebuffer.update(
            x: Int(rect.x),
            y: Int(rect.y),
            width: Int(rect.width),
            height: Int(rect.height),
            data: decompressed
        )
    }
}

// MARK: - ZRLE Encoding Renderer

/// Renders ZRLE (Zlib Run-Length Encoding) data to framebuffer.
/// ZRLE compresses tile-based data with a persistent zlib stream.
///
/// Wire format: 4-byte length, then zlib-compressed tile data.
/// Tile data is processed in 64x64 pixel tiles, left-to-right, top-to-bottom.
final class ZRLEEncodingRenderer {
    private let inflater = try? RFBZlibStreamInflater()

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
        guard let inflater else {
            throw RenderingError.decompressionFailed(
                "Failed to initialize system zlib stream")
        }
        let totalPixels = Int(rect.width) * Int(rect.height)
        let maximumTileBytes = totalPixels * pixelFormat.bytesPerPixel
            + totalPixels + 65_536
        let tileData: Data
        do {
            tileData = try inflater.decompress(
                Data(compressedSlice),
                maxOutputSize: maximumTileBytes)
        } catch {
            throw RenderingError.decompressionFailed(error.localizedDescription)
        }

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

        // This is the format negotiated by the production client and by
        // ordinary 32-bit true-colour RFB servers. Decode straight from the
        // inflated tile stream into the framebuffer under one lock instead of
        // building a Data allocation per tile and locking once per tile/row.
        if cpixelSize == 3 && framebuffer.bytesPerPixel == 4 {
            try renderCompactBGRATiles(
                tileData,
                rectX: rectX,
                rectY: rectY,
                rectWidth: rectW,
                rectHeight: rectH,
                to: framebuffer)
            return
        }

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

    /// Fast path for the standard 3-byte BGR CPIXEL to 4-byte BGRA format.
    /// Tile decoding writes through a UInt32 pointer, eliminating intermediate
    /// pixels, rows, and tile buffers from the latency-sensitive path.
    private func renderCompactBGRATiles(
        _ tileData: Data,
        rectX: Int,
        rectY: Int,
        rectWidth: Int,
        rectHeight: Int,
        to framebuffer: Framebuffer
    ) throws {
        try framebuffer.withUnsafeMutablePixelBytes {
            destination, framebufferWidth, framebufferHeight, bytesPerRow, bytesPerPixel in
            guard bytesPerPixel == 4,
                  rectX >= 0, rectY >= 0,
                  rectWidth >= 0, rectHeight >= 0,
                  rectX + rectWidth <= framebufferWidth,
                  rectY + rectHeight <= framebufferHeight else {
                throw RenderingError.invalidTileData(
                    "ZRLE rectangle lies outside the framebuffer")
            }

            try tileData.withUnsafeBytes { rawTileBytes in
                guard let source = rawTileBytes.baseAddress?
                    .assumingMemoryBound(to: UInt8.self) else {
                    if rectWidth == 0 || rectHeight == 0 { return }
                    throw RenderingError.invalidTileData("Empty ZRLE tile data")
                }

                let sourceCount = rawTileBytes.count
                var offset = 0
                var tileY = 0
                while tileY < rectHeight {
                    let tileHeight = min(64, rectHeight - tileY)
                    var tileX = 0

                    while tileX < rectWidth {
                        let tileWidth = min(64, rectWidth - tileX)
                        let tilePixels = tileWidth * tileHeight
                        guard offset < sourceCount else {
                            throw RenderingError.invalidTileData(
                                "Ran out of compact ZRLE tile data")
                        }
                        let subencoding = Int(source[offset])
                        offset += 1

                        @inline(__always)
                        func pixel(at sourceOffset: Int) -> UInt32 {
                            UInt32(source[sourceOffset])
                                | (UInt32(source[sourceOffset + 1]) << 8)
                                | (UInt32(source[sourceOffset + 2]) << 16)
                                | 0xFF00_0000
                        }

                        @inline(__always)
                        func destinationRow(_ row: Int) -> UnsafeMutablePointer<UInt32> {
                            destination.advanced(
                                by: (rectY + tileY + row) * bytesPerRow
                                    + (rectX + tileX) * 4)
                                .assumingMemoryBound(to: UInt32.self)
                        }

                        @inline(__always)
                        func writeRun(
                            _ value: UInt32,
                            startingAt start: Int,
                            count: Int
                        ) {
                            var remaining = count
                            var position = start
                            while remaining > 0 {
                                let row = position / tileWidth
                                let column = position % tileWidth
                                let span = min(remaining, tileWidth - column)
                                let rowPointer = destinationRow(row)
                                for index in 0..<span {
                                    rowPointer[column + index] = value
                                }
                                position += span
                                remaining -= span
                            }
                        }

                        switch subencoding {
                        case 0:
                            let needed = tilePixels * 3
                            guard offset + needed <= sourceCount else {
                                throw RenderingError.invalidTileData(
                                    "Raw compact tile needs \(needed) bytes")
                            }
                            for row in 0..<tileHeight {
                                let rowPointer = destinationRow(row)
                                var sourceOffset = offset + row * tileWidth * 3
                                for column in 0..<tileWidth {
                                    rowPointer[column] = pixel(at: sourceOffset)
                                    sourceOffset += 3
                                }
                            }
                            offset += needed

                        case 1:
                            guard offset + 3 <= sourceCount else {
                                throw RenderingError.invalidTileData(
                                    "Solid compact tile needs 3 bytes")
                            }
                            let value = pixel(at: offset)
                            offset += 3
                            writeRun(value, startingAt: 0, count: tilePixels)

                        case 2...16:
                            let paletteSize = subencoding
                            let paletteByteCount = paletteSize * 3
                            guard offset + paletteByteCount <= sourceCount else {
                                throw RenderingError.invalidTileData(
                                    "Compact palette needs \(paletteByteCount) bytes")
                            }
                            var palette = [UInt32](
                                repeating: 0, count: paletteSize)
                            for index in 0..<paletteSize {
                                palette[index] = pixel(at: offset + index * 3)
                            }
                            offset += paletteByteCount

                            let bitsPerIndex: Int
                            switch paletteSize {
                            case 2: bitsPerIndex = 1
                            case 3...4: bitsPerIndex = 2
                            default: bitsPerIndex = 4
                            }
                            let indicesPerByte = 8 / bitsPerIndex
                            let mask = (1 << bitsPerIndex) - 1
                            let bytesForRow = (tileWidth * bitsPerIndex + 7) / 8
                            guard offset + bytesForRow * tileHeight <= sourceCount else {
                                throw RenderingError.invalidTileData(
                                    "Ran out of compact packed-palette data")
                            }

                            for row in 0..<tileHeight {
                                let rowPointer = destinationRow(row)
                                let packedRow = offset + row * bytesForRow
                                for column in 0..<tileWidth {
                                    let packed = Int(source[
                                        packedRow + column / indicesPerByte])
                                    let position = column % indicesPerByte
                                    let shift = (indicesPerByte - 1 - position)
                                        * bitsPerIndex
                                    let index = (packed >> shift) & mask
                                    rowPointer[column] = index < palette.count
                                        ? palette[index] : 0
                                }
                            }
                            offset += bytesForRow * tileHeight

                        case 128:
                            var pixelsWritten = 0
                            while pixelsWritten < tilePixels {
                                guard offset + 3 <= sourceCount else {
                                    throw RenderingError.invalidTileData(
                                        "Compact RLE ran out of pixel data")
                                }
                                let value = pixel(at: offset)
                                offset += 3
                                var runLength = 1
                                var foundRunEnd = false
                                while offset < sourceCount {
                                    let byte = Int(source[offset])
                                    offset += 1
                                    runLength += byte
                                    if byte != 255 {
                                        foundRunEnd = true
                                        break
                                    }
                                }
                                guard foundRunEnd else {
                                    throw RenderingError.invalidTileData(
                                        "Compact RLE has an incomplete run")
                                }
                                let clippedRun = min(
                                    runLength, tilePixels - pixelsWritten)
                                writeRun(
                                    value,
                                    startingAt: pixelsWritten,
                                    count: clippedRun)
                                pixelsWritten += clippedRun
                            }

                        case 130...255:
                            let paletteSize = subencoding - 128
                            let paletteByteCount = paletteSize * 3
                            guard offset + paletteByteCount <= sourceCount else {
                                throw RenderingError.invalidTileData(
                                    "Compact RLE palette needs \(paletteByteCount) bytes")
                            }
                            var palette = [UInt32](
                                repeating: 0, count: paletteSize)
                            for index in 0..<paletteSize {
                                palette[index] = pixel(at: offset + index * 3)
                            }
                            offset += paletteByteCount

                            var pixelsWritten = 0
                            while pixelsWritten < tilePixels {
                                guard offset < sourceCount else {
                                    throw RenderingError.invalidTileData(
                                        "Compact palette RLE ran out of data")
                                }
                                let indexByte = Int(source[offset])
                                offset += 1
                                let paletteIndex = indexByte & 0x7F
                                let value = paletteIndex < palette.count
                                    ? palette[paletteIndex] : 0
                                var runLength = 1
                                if indexByte & 0x80 != 0 {
                                    var foundRunEnd = false
                                    while offset < sourceCount {
                                        let byte = Int(source[offset])
                                        offset += 1
                                        runLength += byte
                                        if byte != 255 {
                                            foundRunEnd = true
                                            break
                                        }
                                    }
                                    guard foundRunEnd else {
                                        throw RenderingError.invalidTileData(
                                            "Compact palette RLE has an incomplete run")
                                    }
                                }
                                let clippedRun = min(
                                    runLength, tilePixels - pixelsWritten)
                                writeRun(
                                    value,
                                    startingAt: pixelsWritten,
                                    count: clippedRun)
                                pixelsWritten += clippedRun
                            }

                        default:
                            throw RenderingError.invalidTileData(
                                "Invalid ZRLE subencoding: \(subencoding)")
                        }

                        tileX += 64
                    }
                    tileY += 64
                }
            }
        }
    }

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

}
