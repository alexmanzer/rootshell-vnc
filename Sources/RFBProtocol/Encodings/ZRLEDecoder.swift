import Foundation

/// Decodes the ZRLE encoding (type 16) — Zlib Run-Length Encoding.
///
/// ZRLE divides each rectangle into 64x64 tiles and compresses the
/// tile data with a single persistent zlib stream. Each tile has a
/// subencoding byte that describes how its pixels are packed:
///
/// - 0: Raw cpixels
/// - 1: Solid (single cpixel fills the entire tile)
/// - 2–16: Packed palette (palette of N cpixels, then packed indices)
/// - 17–127: Unused (treat as raw)
/// - 128: Plain RLE
/// - 129: Unused
/// - 130–255: Palette RLE (palette of N-128 cpixels, then RLE-encoded indices)
///
/// "cpixel" is a Compressed Pixel — for 32bpp true-color with 8-bit channels
/// and {red,green,blue}-max all 255, cpixel is 3 bytes instead of 4.
public final class ZRLEDecoder: EncodingDecoder, @unchecked Sendable {

    private let inflater: RFBZlibStreamInflater?

    public init() {
        inflater = try? RFBZlibStreamInflater()
    }

    // MARK: - EncodingDecoder

    public func decode(
        reader: inout MessageReader,
        rect: FramebufferRect,
        pixelFormat: PixelFormat
    ) throws -> DecodedRect {
        // Read compressed data
        let compressedLength = try reader.readUInt32()
        let compressedData = try reader.readBytes(Int(compressedLength))

        let bpp = pixelFormat.bytesPerPixel
        let cpixelSize = Self.cpixelSize(for: pixelFormat)
        let totalPixels = Int(rect.width) * Int(rect.height)

        // Decompress — we over-allocate because the decompressed size isn't
        // known exactly up front (tiles + metadata can exceed raw pixel size).
        let maxDecompressed = totalPixels * bpp + totalPixels + 65536
        guard let inflater else {
            throw VNCProtocolError.protocolViolation(
                "Failed to initialize system zlib stream")
        }
        let decompressed = try inflater.decompress(
            compressedData,
            maxOutputSize: maxDecompressed)

        // Decode tiles from the decompressed data
        var tileReader = MessageReader(data: decompressed)
        var output = Data(count: totalPixels * bpp)

        let rectWidth = Int(rect.width)
        let rectHeight = Int(rect.height)

        var tileY = 0
        while tileY < rectHeight {
            let tileH = min(64, rectHeight - tileY)
            var tileX = 0
            while tileX < rectWidth {
                let tileW = min(64, rectWidth - tileX)
                let tilePixels = tileW * tileH

                let subencoding = try tileReader.readUInt8()

                switch subencoding {
                case 0:
                    // Raw cpixels
                    try decodeTileRaw(
                        reader: &tileReader, output: &output,
                        tileX: tileX, tileY: tileY, tileW: tileW, tileH: tileH,
                        rectWidth: rectWidth, cpixelSize: cpixelSize, bpp: bpp, pixelFormat: pixelFormat
                    )

                case 1:
                    // Solid fill
                    let pixel = try readCPixelAsFullPixel(reader: &tileReader, cpixelSize: cpixelSize, bpp: bpp, pixelFormat: pixelFormat)
                    fillTile(
                        output: &output, pixel: pixel,
                        tileX: tileX, tileY: tileY, tileW: tileW, tileH: tileH,
                        rectWidth: rectWidth, bpp: bpp
                    )

                case 2...16:
                    // Packed palette
                    let paletteSize = Int(subencoding)
                    var palette: [[UInt8]] = []
                    palette.reserveCapacity(paletteSize)
                    for _ in 0..<paletteSize {
                        let p = try readCPixelAsFullPixel(reader: &tileReader, cpixelSize: cpixelSize, bpp: bpp, pixelFormat: pixelFormat)
                        palette.append(p)
                    }

                    let bitsPerIndex: Int
                    switch paletteSize {
                    case 2:      bitsPerIndex = 1
                    case 3...4:  bitsPerIndex = 2
                    default:     bitsPerIndex = 4
                    }

                    try decodePackedPalette(
                        reader: &tileReader, output: &output, palette: palette,
                        tileX: tileX, tileY: tileY, tileW: tileW, tileH: tileH,
                        rectWidth: rectWidth, bpp: bpp, bitsPerIndex: bitsPerIndex
                    )

                case 128:
                    // Plain RLE
                    try decodePlainRLE(
                        reader: &tileReader, output: &output,
                        tileX: tileX, tileY: tileY, tileW: tileW, tileH: tileH,
                        rectWidth: rectWidth, cpixelSize: cpixelSize, bpp: bpp,
                        tilePixels: tilePixels, pixelFormat: pixelFormat
                    )

                case 130...255:
                    // Palette RLE
                    let paletteSize = Int(subencoding) - 128
                    var palette: [[UInt8]] = []
                    palette.reserveCapacity(paletteSize)
                    for _ in 0..<paletteSize {
                        let p = try readCPixelAsFullPixel(reader: &tileReader, cpixelSize: cpixelSize, bpp: bpp, pixelFormat: pixelFormat)
                        palette.append(p)
                    }

                    try decodePaletteRLE(
                        reader: &tileReader, output: &output, palette: palette,
                        tileX: tileX, tileY: tileY, tileW: tileW, tileH: tileH,
                        rectWidth: rectWidth, bpp: bpp, tilePixels: tilePixels
                    )

                default:
                    // 17–127, 129: treat as raw per spec recommendations
                    try decodeTileRaw(
                        reader: &tileReader, output: &output,
                        tileX: tileX, tileY: tileY, tileW: tileW, tileH: tileH,
                        rectWidth: rectWidth, cpixelSize: cpixelSize, bpp: bpp, pixelFormat: pixelFormat
                    )
                }

                tileX += 64
            }
            tileY += 64
        }

        return .pixels(output)
    }

    // MARK: - CPixel

    /// Determine cpixel size: 3 bytes for 32bpp true-color with 8-bit channels,
    /// otherwise same as bytesPerPixel.
    public static func cpixelSize(for pf: PixelFormat) -> Int {
        if pf.bitsPerPixel == 32 && pf.trueColor && pf.depth <= 24
            && pf.redMax == 255 && pf.greenMax == 255 && pf.blueMax == 255 {
            return 3
        }
        return pf.bytesPerPixel
    }

    /// Read a cpixel and expand it to a full pixel (bpp bytes).
    private func readCPixelAsFullPixel(
        reader: inout MessageReader,
        cpixelSize: Int,
        bpp: Int,
        pixelFormat: PixelFormat
    ) throws -> [UInt8] {
        let bytes = try reader.readBytes(cpixelSize)
        if cpixelSize == 3 && bpp == 4 {
            // cpixel is 3 bytes in the order determined by byte order.
            // For ZRLE, cpixel bytes are always in the order:
            //   byte0 = least significant byte of the pixel value
            //   byte1 = middle byte
            //   byte2 = most significant byte
            // This corresponds to the lowest 3 bytes of the pixel value
            // in little-endian order.
            var pixel = [UInt8](repeating: 0, count: 4)
            pixel[0] = bytes[0]
            pixel[1] = bytes[1]
            pixel[2] = bytes[2]
            pixel[3] = 0xFF // alpha
            return pixel
        }
        return Array(bytes)
    }

    // MARK: - Tile decoders

    private func decodeTileRaw(
        reader: inout MessageReader,
        output: inout Data,
        tileX: Int, tileY: Int, tileW: Int, tileH: Int,
        rectWidth: Int, cpixelSize: Int, bpp: Int, pixelFormat: PixelFormat
    ) throws {
        for row in 0..<tileH {
            for col in 0..<tileW {
                let pixel = try readCPixelAsFullPixel(reader: &reader, cpixelSize: cpixelSize, bpp: bpp, pixelFormat: pixelFormat)
                let outOffset = ((tileY + row) * rectWidth + (tileX + col)) * bpp
                for b in 0..<bpp {
                    output[outOffset + b] = pixel[b]
                }
            }
        }
    }

    private func fillTile(
        output: inout Data,
        pixel: [UInt8],
        tileX: Int, tileY: Int, tileW: Int, tileH: Int,
        rectWidth: Int, bpp: Int
    ) {
        for row in 0..<tileH {
            for col in 0..<tileW {
                let outOffset = ((tileY + row) * rectWidth + (tileX + col)) * bpp
                for b in 0..<bpp {
                    output[outOffset + b] = pixel[b]
                }
            }
        }
    }

    private func decodePackedPalette(
        reader: inout MessageReader,
        output: inout Data,
        palette: [[UInt8]],
        tileX: Int, tileY: Int, tileW: Int, tileH: Int,
        rectWidth: Int, bpp: Int, bitsPerIndex: Int
    ) throws {
        let mask: UInt8 = (1 << bitsPerIndex) - 1

        for row in 0..<tileH {
            var bitBuffer: UInt8 = 0
            var bitsRemaining = 0

            for col in 0..<tileW {
                if bitsRemaining == 0 {
                    bitBuffer = try reader.readUInt8()
                    bitsRemaining = 8
                }

                bitsRemaining -= bitsPerIndex
                let index = Int((bitBuffer >> bitsRemaining) & mask)
                let pixel = index < palette.count ? palette[index] : palette[0]

                let outOffset = ((tileY + row) * rectWidth + (tileX + col)) * bpp
                for b in 0..<bpp {
                    output[outOffset + b] = pixel[b]
                }
            }
            // Any remaining bits in the byte at the end of each row are discarded.
        }
    }

    private func decodePlainRLE(
        reader: inout MessageReader,
        output: inout Data,
        tileX: Int, tileY: Int, tileW: Int, tileH: Int,
        rectWidth: Int, cpixelSize: Int, bpp: Int, tilePixels: Int,
        pixelFormat: PixelFormat
    ) throws {
        var pixelsDecoded = 0
        while pixelsDecoded < tilePixels {
            let pixel = try readCPixelAsFullPixel(reader: &reader, cpixelSize: cpixelSize, bpp: bpp, pixelFormat: pixelFormat)
            var runLength = 1
            // Read run-length extension bytes
            while true {
                let b = try reader.readUInt8()
                runLength += Int(b)
                if b != 255 { break }
            }

            for _ in 0..<runLength {
                guard pixelsDecoded < tilePixels else { break }
                let row = pixelsDecoded / tileW
                let col = pixelsDecoded % tileW
                let outOffset = ((tileY + row) * rectWidth + (tileX + col)) * bpp
                for b in 0..<bpp {
                    output[outOffset + b] = pixel[b]
                }
                pixelsDecoded += 1
            }
        }
    }

    private func decodePaletteRLE(
        reader: inout MessageReader,
        output: inout Data,
        palette: [[UInt8]],
        tileX: Int, tileY: Int, tileW: Int, tileH: Int,
        rectWidth: Int, bpp: Int, tilePixels: Int
    ) throws {
        var pixelsDecoded = 0
        while pixelsDecoded < tilePixels {
            let indexByte = try reader.readUInt8()
            let paletteIndex = Int(indexByte & 0x7F)
            let pixel = paletteIndex < palette.count ? palette[paletteIndex] : palette[0]

            var runLength: Int
            if indexByte & 0x80 != 0 {
                // Run-length encoded
                runLength = 1
                while true {
                    let b = try reader.readUInt8()
                    runLength += Int(b)
                    if b != 255 { break }
                }
            } else {
                runLength = 1
            }

            for _ in 0..<runLength {
                guard pixelsDecoded < tilePixels else { break }
                let row = pixelsDecoded / tileW
                let col = pixelsDecoded % tileW
                let outOffset = ((tileY + row) * rectWidth + (tileX + col)) * bpp
                for b in 0..<bpp {
                    output[outOffset + b] = pixel[b]
                }
                pixelsDecoded += 1
            }
        }
    }

}
