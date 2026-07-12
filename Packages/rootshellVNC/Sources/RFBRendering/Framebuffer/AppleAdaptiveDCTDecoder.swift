import Foundation
import RFBProtocol
import RFBRenderingC

enum AppleAdaptiveDCTError: Error, LocalizedError {
    case malformed(String)
    case unsupportedMessageType(UInt8)

    var errorDescription: String? {
        switch self {
        case .malformed(let detail): detail
        case .unsupportedMessageType(let type):
            "Unsupported Apple Adaptive DCT message type \(type)"
        }
    }

}

/// Stateful decoder for Apple's registered RFB encoding 1011. The server
/// sends quantization changes (type 2) independently from image commands
/// (type 0), and later image commands may reference tiles decoded by any
/// earlier rectangle, so one instance must live for the whole connection.
final class AppleAdaptiveDCTDecoder {
    struct BitReader {
        private let bytes: Data
        private var nextByteOffset = 0
        private var reservoir: UInt64 = 0
        private var reservoirBitCount = 0
        private(set) var bitOffset = 0

        init(_ bytes: Data) {
            self.bytes = bytes
        }

        var remainingBitCount: Int { bytes.count * 8 - bitOffset }

        mutating func readBits(_ count: Int) throws -> UInt32 {
            guard (0...32).contains(count), count <= remainingBitCount else {
                throw AppleAdaptiveDCTError.malformed(
                    "DCT command stream ended while reading \(count) bits")
            }
            guard count > 0 else { return 0 }
            while reservoirBitCount < count {
                let byte = bytes[bytes.startIndex + nextByteOffset]
                reservoir = (reservoir << 8) | UInt64(byte)
                reservoirBitCount += 8
                nextByteOffset += 1
            }
            let shift = reservoirBitCount - count
            let mask = count == 32 ? UInt64(UInt32.max) : (UInt64(1) << count) - 1
            let value = UInt32((reservoir >> shift) & mask)
            reservoirBitCount -= count
            bitOffset += count
            if reservoirBitCount == 0 {
                reservoir = 0
            } else {
                reservoir &= (UInt64(1) << reservoirBitCount) - 1
            }
            return value
        }

        /// Apple encodes a command's tile count as 0 => one tile, followed by
        /// a compact 4-bit form for 2...16. The escape value 15 is followed
        /// by one to three little-endian base-128 groups and a bias of 17.
        mutating func readCommandRunLength() throws -> Int {
            guard try readBits(1) != 0 else { return 1 }
            let short = Int(try readBits(4))
            guard short == 15 else { return short + 2 }

            var extended = 0
            for group in 0..<3 {
                let byte = Int(try readBits(8))
                extended |= (byte & 0x7f) << (group * 7)
                if byte & 0x80 == 0 { return extended + 17 }
            }
            return extended + 17
        }

        /// Signed Rice variant used for each plane's DC delta. A zero unary
        /// prefix has a dedicated zero/small-value form; larger prefixes
        /// add successively wider magnitude ranges followed by a sign bit.
        mutating func readSignedDCRice() throws -> Int {
            var prefix = 0
            while try readBits(1) != 0 {
                prefix += 1
                guard prefix < 40 else {
                    throw AppleAdaptiveDCTError.malformed("DCT DC Rice prefix exceeds 39 bits")
                }
            }

            if prefix == 0 {
                guard try readBits(1) != 0 else { return 0 }
                return try readBits(1) == 0 ? 1 : -1
            }

            let magnitude: Int
            let sign: UInt32
            switch prefix {
            case 1:
                let suffix = try readBits(2)
                magnitude = 2 + Int(suffix >> 1)
                sign = suffix & 1
            case 2:
                let suffix = try readBits(3)
                magnitude = 4 + Int(suffix >> 1)
                sign = suffix & 1
            default:
                let suffix = try readBits(4)
                magnitude = prefix * 8 + Int(suffix >> 1) - 16
                sign = suffix & 1
            }
            return sign == 0 ? magnitude : -magnitude
        }

        /// Returns Y, Cb, and Cr expanded to eight-bit lanes. Chroma is sent
        /// with six bits of precision and occupies the high six bits.
        mutating func readYCC20() throws -> (y: UInt8, cb: UInt8, cr: UInt8) {
            let y = UInt8(try readBits(8))
            let cb = UInt8(try readBits(6) << 2)
            let cr = UInt8(try readBits(6) << 2)
            return (y, cb, cr)
        }

        /// Decode one sparse low-amplitude coefficient. A nil value means
        /// the coefficient is zero; index 64 is the end-of-block sentinel.
        mutating func readSmallCoefficient(
            at index: Int,
            amplitude: Int
        ) throws -> (nextIndex: Int, value: Int?) {
            let code = try readBits(2)
            switch code {
            case 0:
                return (index + 1, nil)
            case 2:
                return (index + 1, amplitude)
            case 3:
                return (index + 1, -amplitude)
            default:
                guard try readBits(1) != 0 else { return (64, nil) }
                let shortSkip = Int(try readBits(2))
                guard shortSkip == 3 else {
                    return (index + shortSkip + 3, nil)
                }
                var skip = 6
                while true {
                    let group = Int(try readBits(3))
                    skip += group
                    if group != 7 { break }
                }
                guard index + skip < 64 else {
                    throw AppleAdaptiveDCTError.malformed(
                        "DCT zero run passes coefficient 63")
                }
                return (index + skip, nil)
            }
        }
    }

    struct ImageMessage {
        let field1: UInt8
        let field2: UInt8
        let commandBytes: Data
        let dataBytes: Data
    }

    private(set) var lumaQuantization: [UInt16]
    private(set) var chromaQuantization: [UInt16]
    private var framebufferWidth = 0
    private var framebufferHeight = 0
    private var tileCoefficients: [Int16] = []
    private var tileQuality: [UInt8] = []
    private var tileMaps: [Int8] = []
    private var tileHasRefinedMap: [Bool] = []
    private var tileChromaCounts: [(cb: UInt8, cr: UInt8)] = []
    private var coefficientCache: [Int: CachedTile] = [:]
    private var cacheWriteIndex = 0
    private var cacheReadIndex = 0
    private var cachedSolidColor: UInt32?
    private var cachedPaletteFirst: UInt32?
    private var cachedPaletteSecond: UInt32?

    init() {
        lumaQuantization = Self.defaultLuma.map(UInt16.init)
        chromaQuantization = Self.defaultChroma.map(UInt16.init)
    }

    /// Remove the RFB UInt32 length prefix and apply a control message, or
    /// return the separated command/data streams for a type-0 image message.
    func ingest(_ payload: Data) throws -> ImageMessage? {
        guard payload.count >= 5 else {
            throw AppleAdaptiveDCTError.malformed("DCT payload is shorter than 5 bytes")
        }
        let base = payload.startIndex
        let length = Int(payload[base]) << 24
            | Int(payload[base + 1]) << 16
            | Int(payload[base + 2]) << 8
            | Int(payload[base + 3])
        guard length == payload.count - 4 else {
            throw AppleAdaptiveDCTError.malformed(
                "DCT length \(length) does not match \(payload.count - 4) bytes")
        }
        let message = payload.dropFirst(4)
        let type = message[message.startIndex]
        switch type {
        case 0:
            guard message.count >= 7 else {
                throw AppleAdaptiveDCTError.malformed("Type-0 message is shorter than 7 bytes")
            }
            let start = message.startIndex
            let dataOffset = Int(message[start + 3]) << 16
                | Int(message[start + 4]) << 8
                | Int(message[start + 5])
            guard dataOffset >= 6, dataOffset < message.count else {
                throw AppleAdaptiveDCTError.malformed(
                    "Type-0 data offset \(dataOffset) is outside \(message.count) bytes")
            }
            return ImageMessage(
                field1: message[start + 1],
                field2: message[start + 2],
                commandBytes: Data(message[(start + 6)..<(start + dataOffset)]),
                dataBytes: Data(message[(start + dataOffset)...]))

        case 1:
            // render() routes type 1 to the progressive-refinement/cache path
            // before calling ingest(). Keep direct ingestion side-effect free.
            return nil

        case 2:
            guard message.count == 129 else {
                throw AppleAdaptiveDCTError.malformed(
                    "Type-2 quantization message is \(message.count) bytes, expected 129")
            }
            lumaQuantization = message.dropFirst().prefix(64).map(UInt16.init)
            chromaQuantization = message.dropFirst(65).prefix(64).map(UInt16.init)
            return nil

        default:
            throw AppleAdaptiveDCTError.unsupportedMessageType(type)
        }
    }

    /// Decode the currently implemented type-0 tile commands directly into
    /// the framebuffer. The coefficient store is intentionally connection-
    /// scoped: later Apple refinement commands refer to these exact tiles.
    func render(
        rect: FramebufferRect,
        payload: Data,
        to framebuffer: Framebuffer,
        drawPixels: Bool = true
    ) throws {
        guard payload.count >= 5 else {
            throw AppleAdaptiveDCTError.malformed("DCT payload is shorter than 5 bytes")
        }
        if payload[payload.startIndex + 4] == 1 {
            try renderRefinement(
                rect: rect, payload: payload, to: framebuffer,
                drawPixels: drawPixels)
            return
        }
        guard let message = try ingest(payload) else { return }
        guard framebuffer.bytesPerPixel == 4 else {
            throw AppleAdaptiveDCTError.malformed("Apple DCT requires a 32-bit framebuffer")
        }
        ensureFramebuffer(width: framebuffer.width, height: framebuffer.height)

        var commands = BitReader(message.commandBytes)
        var data = BitReader(message.dataBytes)
        // VNCKit seeds its MSB reader from byte zero, shifts once, and starts
        // command decoding with seven live bits. The first bit is reserved.
        _ = try commands.readBits(1)
        let tilesWide = (Int(rect.width) + 7) / 8
        let tilesHigh = (Int(rect.height) + 7) / 8
        let tileCount = tilesWide * tilesHigh
        var tileNumber = 0
        var predictor = [Int16](repeating: 0, count: 192)
        var predictorQuality = 0
        var lastDCTPixels = [UInt32](repeating: 0, count: 64)
        var hasLastDCTPixels = false

        try framebuffer.withUnsafeMutablePixelBytes { base, width, height, bytesPerRow, _ in
            while tileNumber < tileCount {
                let command = Int(try commands.readBits(3))
                let run = min(try commands.readCommandRunLength(), tileCount - tileNumber)
                for _ in 0..<run {
                    let localX = tileNumber % tilesWide
                    let localY = tileNumber / tilesWide
                    let pixelX = Int(rect.x) + localX * 8
                    let pixelY = Int(rect.y) + localY * 8
                    let globalTileX = pixelX / 8
                    let globalTileY = pixelY / 8
                    let globalIndex = globalTileY * ((framebufferWidth + 7) / 8) + globalTileX

                    switch command {
                    case 0:
                        try renderSolidTile(
                            0xffff_ffff, x: pixelX, y: pixelY, base: base,
                            width: width, height: height, bytesPerRow: bytesPerRow)
                        clearTileState(globalIndex)

                    case 1:
                        guard tileNumber > 0 else {
                            throw AppleAdaptiveDCTError.malformed(
                                "DCT previous-tile command appears before the first tile")
                        }
                        // This is the previous tile in command order, not
                        // necessarily the tile immediately to our left. At a
                        // row boundary Apple repeats the rightmost tile from
                        // the preceding local row.
                        let sourceNumber = tileNumber - 1
                        let sourceLocalX = sourceNumber % tilesWide
                        let sourceLocalY = sourceNumber / tilesWide
                        let sourcePixelX = Int(rect.x) + sourceLocalX * 8
                        let sourcePixelY = Int(rect.y) + sourceLocalY * 8
                        let sourceGlobalX = sourcePixelX / 8
                        let sourceGlobalY = sourcePixelY / 8
                        let sourceGlobalIndex = sourceGlobalY
                            * ((framebufferWidth + 7) / 8) + sourceGlobalX
                        copyTile(
                            fromX: sourcePixelX, fromY: sourcePixelY,
                            toX: pixelX, toY: pixelY,
                            base: base, width: width, height: height,
                            bytesPerRow: bytesPerRow)
                        copyTileState(from: sourceGlobalIndex, to: globalIndex)

                    case 2:
                        guard pixelY >= 8 else {
                            throw AppleAdaptiveDCTError.malformed(
                                "DCT vertical-copy command appears at tile \(tileNumber) "
                                    + "(\(localX),\(localY))")
                        }
                        copyTile(
                            fromX: pixelX, fromY: pixelY - 8,
                            toX: pixelX, toY: pixelY,
                            base: base, width: width, height: height,
                            bytesPerRow: bytesPerRow)
                        copyTileState(
                            from: globalIndex - ((framebufferWidth + 7) / 8),
                            to: globalIndex)

                    case 3:
                        try renderTwoColorTile(
                            reader: &data, first: 0xffff_ffff, second: 0x0000_0000,
                            x: pixelX, y: pixelY, base: base, width: width,
                            height: height, bytesPerRow: bytesPerRow)
                        clearTileState(globalIndex)

                    case 4:
                        let subtype = Int(try data.readBits(2))
                        switch subtype {
                        case 0:
                            cachedSolidColor = try readBGRAColor(&data)
                            try renderSolidTile(
                                cachedSolidColor!, x: pixelX, y: pixelY, base: base,
                                width: width, height: height, bytesPerRow: bytesPerRow)
                        case 1:
                            guard let cachedSolidColor else {
                                throw AppleAdaptiveDCTError.malformed(
                                    "DCT fill reuses a color before defining it")
                            }
                            try renderSolidTile(
                                cachedSolidColor, x: pixelX, y: pixelY, base: base,
                                width: width, height: height, bytesPerRow: bytesPerRow)
                        case 2:
                            cachedPaletteFirst = try readBGRAColor(&data)
                            cachedPaletteSecond = try readBGRAColor(&data)
                            try renderTwoColorTile(
                                reader: &data, first: cachedPaletteFirst!,
                                second: cachedPaletteSecond!,
                                x: pixelX, y: pixelY, base: base, width: width,
                                height: height, bytesPerRow: bytesPerRow)
                        default:
                            guard let cachedPaletteFirst, let cachedPaletteSecond else {
                                throw AppleAdaptiveDCTError.malformed(
                                    "DCT two-color fill reuses a palette before defining it")
                            }
                            try renderTwoColorTile(
                                reader: &data, first: cachedPaletteFirst,
                                second: cachedPaletteSecond,
                                x: pixelX, y: pixelY, base: base, width: width,
                                height: height, bytesPerRow: bytesPerRow)
                        }
                        clearTileState(globalIndex)

                    case 5:
                        let coefficients: DecodedTile
                        let reusesPrevious = try data.readBits(1) != 0
                        if reusesPrevious {
                            coefficients = DecodedTile(
                                values: predictor, quality: predictorQuality)
                        } else {
                            do {
                                coefficients = try decodeNewTile(
                                    reader: &data, predictor: &predictor,
                                    lowCutoff: Int(message.field1),
                                    highCutoff: Int(message.field2))
                                predictorQuality = coefficients.quality
                            } catch {
                                throw AppleAdaptiveDCTError.malformed(
                                    "DCT tile \(tileNumber) command 5 failed at data bit "
                                        + "\(data.bitOffset): \(error.localizedDescription)")
                            }
                        }
                        store(coefficients, quality: coefficients.quality, at: globalIndex)
                        tileHasRefinedMap[globalIndex] = false
                        if drawPixels {
                            if !reusesPrevious || !hasLastDCTPixels {
                                decodeDCTTile(
                                    coefficients.values, into: &lastDCTPixels)
                                hasLastDCTPixels = true
                            }
                            renderPixelTile(
                                lastDCTPixels, x: pixelX, y: pixelY, base: base,
                                width: width, height: height, bytesPerRow: bytesPerRow)
                        }

                    case 6, 7:
                        let cacheIndex: Int
                        if command == 6 {
                            cacheIndex = Int(try data.readBits(16))
                        } else {
                            cacheReadIndex = nextCacheIndex(after: cacheReadIndex)
                            cacheIndex = cacheReadIndex
                        }
                        let cached = try cachedTile(at: cacheIndex)
                        store(cached.decoded, quality: cached.quality, at: globalIndex)
                        storeMap(cached, at: globalIndex)
                        if drawPixels {
                            decodeDCTTile(cached.decoded.values, into: &lastDCTPixels)
                            hasLastDCTPixels = true
                            renderPixelTile(
                                lastDCTPixels, x: pixelX, y: pixelY, base: base,
                                width: width, height: height, bytesPerRow: bytesPerRow)
                        }
                    default:
                        throw AppleAdaptiveDCTError.malformed("Invalid DCT tile command \(command)")
                    }
                    tileNumber += 1
                }
            }
        }
    }

    private func ensureFramebuffer(width: Int, height: Int) {
        guard width != framebufferWidth || height != framebufferHeight else { return }
        framebufferWidth = width
        framebufferHeight = height
        let count = ((width + 7) / 8) * ((height + 7) / 8)
        tileCoefficients = [Int16](repeating: 0, count: count * 192)
        tileQuality = [UInt8](repeating: 0, count: count)
        tileMaps = [Int8](repeating: 0, count: count * 99)
        tileHasRefinedMap = [Bool](repeating: false, count: count)
        tileChromaCounts = Array(repeating: (0, 0), count: count)
        coefficientCache.removeAll(keepingCapacity: true)
        cacheWriteIndex = 0
        cacheReadIndex = 0
    }

    private func clearTileState(_ index: Int) {
        guard tileQuality.indices.contains(index) else { return }
        tileQuality[index] = 0
        tileHasRefinedMap[index] = false
        tileChromaCounts[index] = (0, 0)
        let start = index * 192
        tileCoefficients.replaceSubrange(start..<(start + 192), with: repeatElement(0, count: 192))
        let mapStart = index * 99
        tileMaps.replaceSubrange(mapStart..<(mapStart + 99), with: repeatElement(0, count: 99))
    }

    private func copyTileState(from source: Int, to destination: Int) {
        guard tileQuality.indices.contains(source), tileQuality.indices.contains(destination) else {
            return
        }
        tileQuality[destination] = tileQuality[source]
        tileHasRefinedMap[destination] = tileHasRefinedMap[source]
        tileChromaCounts[destination] = tileChromaCounts[source]
        let sourceStart = source * 192
        let destinationStart = destination * 192
        let copy = Array(tileCoefficients[sourceStart..<(sourceStart + 192)])
        tileCoefficients.replaceSubrange(
            destinationStart..<(destinationStart + 192), with: copy)
        if tileHasRefinedMap[source] {
            let sourceMapStart = source * 99
            let destinationMapStart = destination * 99
            let mapCopy = Array(tileMaps[sourceMapStart..<(sourceMapStart + 99)])
            tileMaps.replaceSubrange(
                destinationMapStart..<(destinationMapStart + 99), with: mapCopy)
        }
    }

    private func store(_ decoded: DecodedTile, quality: Int, at index: Int) {
        guard tileQuality.indices.contains(index) else { return }
        tileQuality[index] = UInt8(clamping: quality)
        let start = index * 192
        tileCoefficients.replaceSubrange(start..<(start + 192), with: decoded.values)
    }

    private struct DecodedTile {
        var values: [Int16]
        let quality: Int
    }

    private struct CachedTile {
        let decoded: DecodedTile
        let map: [Int8]
        let quality: Int
        let cbCount: UInt8
        let crCount: UInt8
    }

    private func storeMap(_ cached: CachedTile, at index: Int) {
        guard tileQuality.indices.contains(index), cached.map.count == 99 else { return }
        let start = index * 99
        tileMaps.replaceSubrange(start..<(start + 99), with: cached.map)
        tileHasRefinedMap[index] = true
        tileChromaCounts[index] = (cached.cbCount, cached.crCount)
    }

    private func cachedTile(at index: Int) throws -> CachedTile {
        guard index > 0, index < 65_000, let cached = coefficientCache[index] else {
            throw AppleAdaptiveDCTError.malformed(
                "DCT references unavailable coefficient-cache tile \(index)")
        }
        return cached
    }

    private func nextCacheIndex(after index: Int) -> Int {
        index >= 64_999 ? 1 : index + 1
    }

    private func renderRefinement(
        rect: FramebufferRect, payload: Data, to framebuffer: Framebuffer,
        drawPixels: Bool
    ) throws {
        let base = payload.startIndex
        let length = Int(payload[base]) << 24 | Int(payload[base + 1]) << 16
            | Int(payload[base + 2]) << 8 | Int(payload[base + 3])
        guard length == payload.count - 4, length >= 4 else {
            throw AppleAdaptiveDCTError.malformed("Malformed DCT type-1 message length")
        }
        guard framebuffer.bytesPerPixel == 4 else {
            throw AppleAdaptiveDCTError.malformed("Apple DCT requires a 32-bit framebuffer")
        }
        let threshold1 = Int(payload[base + 5])
        let threshold2 = Int(payload[base + 6])
        guard threshold1 < 16, threshold2 < 21 else {
            throw AppleAdaptiveDCTError.malformed(
                "DCT refinement thresholds \(threshold1),\(threshold2) exceed Apple limits")
        }
        var bits = BitReader(Data(payload.dropFirst(7)))
        ensureFramebuffer(width: framebuffer.width, height: framebuffer.height)
        let tilesWide = (Int(rect.width) + 7) / 8
        let tilesHigh = (Int(rect.height) + 7) / 8
        let framebufferTilesWide = (framebufferWidth + 7) / 8
        var pixels = [UInt32](repeating: 0, count: 64)

        try framebuffer.withUnsafeMutablePixelBytes { raw, width, height, bytesPerRow, _ in
            for tileNumber in 0..<(tilesWide * tilesHigh) {
                let localX = tileNumber % tilesWide
                let localY = tileNumber / tilesWide
                let pixelX = Int(rect.x) + localX * 8
                let pixelY = Int(rect.y) + localY * 8
                let globalIndex = (pixelY / 8) * framebufferTilesWide + pixelX / 8
                guard tileQuality.indices.contains(globalIndex) else {
                    throw AppleAdaptiveDCTError.malformed(
                        "DCT refinement tile lies outside the framebuffer")
                }
                let command = Int(try bits.readBits(2))
                let cached: CachedTile?
                switch command {
                case 0:
                    cached = nil
                case 1:
                    let refined = try refineTile(
                        at: globalIndex, reader: &bits,
                        threshold1: threshold1, threshold2: threshold2)
                    cacheWriteIndex = nextCacheIndex(after: cacheWriteIndex)
                    coefficientCache[cacheWriteIndex] = refined
                    cached = refined
                case 2:
                    cached = nil
                case 3:
                    let cacheIndex: Int
                    if try bits.readBits(1) != 0 {
                        cacheReadIndex = nextCacheIndex(after: cacheReadIndex)
                        cacheIndex = cacheReadIndex
                    } else {
                        cacheIndex = Int(try bits.readBits(16))
                    }
                    cached = try cachedTile(at: cacheIndex)
                default:
                    cached = nil
                }
                guard let cached else { continue }
                store(cached.decoded, quality: cached.quality, at: globalIndex)
                storeMap(cached, at: globalIndex)
                if drawPixels {
                    decodeDCTTile(cached.decoded.values, into: &pixels)
                    renderPixelTile(
                        pixels, x: pixelX, y: pixelY, base: raw,
                        width: width, height: height, bytesPerRow: bytesPerRow)
                }
            }
        }
    }

    private func refineTile(
        at index: Int, reader: inout BitReader,
        threshold1: Int, threshold2: Int
    ) throws -> CachedTile {
        let mapStart = index * 99
        let old: [Int8]
        let chromaCounts: (cb: UInt8, cr: UInt8)
        if tileHasRefinedMap[index] {
            old = Array(tileMaps[mapStart..<(mapStart + 99)])
            chromaCounts = tileChromaCounts[index]
        } else {
            old = mapFromCoefficientState(at: index)
            chromaCounts = (1, 1)
        }
        guard chromaCounts.cb == 1, chromaCounts.cr == 1 else {
            throw AppleAdaptiveDCTError.malformed(
                "DCT refinement requires single-coefficient chroma predictors")
        }
        var map = [Int8](repeating: 0, count: 99)
        map[0] = old[0]
        let targetY = Int(try reader.readBits(6))
        let oldY = Int(tileQuality[index])
        var next = min(oldY, targetY + 1)
        if oldY > 14 {
            if targetY == 0 {
                next = 1
            } else if next >= 2 {
                for coefficient in 1..<next {
                    map[coefficient] = try adjustByOne(old[coefficient], reader: &reader)
                }
            }
            if next <= targetY {
                for coefficient in next...targetY where coefficient < 64 {
                    map[coefficient] = try adjustOrRead(
                        old[coefficient], bits: 3, reader: &reader)
                }
            }
        } else {
            if next >= 2 {
                for coefficient in 1..<next {
                    map[coefficient] = try adjustOrRead(
                        old[coefficient], bits: 3, reader: &reader)
                }
            } else {
                next = 1
            }
            if next <= targetY {
                for coefficient in next...targetY where coefficient < 64 {
                    map[coefficient] = try adjustOrRead(
                        old[coefficient], bits: 4, reader: &reader)
                }
            }
        }
        map[84] = try adjustByOne(old[84], reader: &reader)
        try decodeLuminanceACHuffman(
            reader: &reader, into: &map, base: 84, maximum: threshold1)
        map[64] = try adjustByOne(old[64], reader: &reader)
        try decodeLuminanceACHuffman(
            reader: &reader, into: &map, base: 64, maximum: threshold2)

        let quality = min(64, targetY + 1)
        let decoded = decodedTile(from: map, quality: quality)
        return CachedTile(
            decoded: decoded, map: map, quality: quality,
            cbCount: UInt8(threshold2 + 1), crCount: UInt8(threshold1 + 1))
    }

    private func adjustByOne(
        _ coefficient: Int8, reader: inout BitReader
    ) throws -> Int8 {
        let adjustment = Int(try reader.readBits(1))
        let value = Int(coefficient)
        if value > 0 { return Int8(clamping: value + adjustment) }
        if value < 0 { return Int8(clamping: value - adjustment) }
        guard adjustment != 0 else { return 0 }
        return try reader.readBits(1) == 0 ? 1 : -1
    }

    private func adjustOrRead(
        _ coefficient: Int8, bits: Int, reader: inout BitReader
    ) throws -> Int8 {
        let value = Int(coefficient)
        guard value != 0 else {
            return Int8(clamping: try reader.readSignedDCRice())
        }
        let adjustment = Int(try reader.readBits(bits))
        let signedAdjustment = value < 0 ? -adjustment : adjustment
        return Int8(clamping: value + signedAdjustment)
    }

    private func decodedTile(from map: [Int8], quality: Int) -> DecodedTile {
        var values = [Int16](repeating: 0, count: 192)
        for coefficient in 0..<64 {
            values[Self.zigzag[coefficient]] = Int16(map[coefficient])
        }
        for coefficient in 0..<20 {
            values[64 + Self.zigzag[coefficient]] = Int16(map[64 + coefficient])
        }
        for coefficient in 0..<15 {
            values[128 + Self.zigzag[coefficient]] = Int16(map[84 + coefficient])
        }
        return DecodedTile(values: values, quality: quality)
    }

    private func mapFromCoefficientState(at index: Int) -> [Int8] {
        var map = [Int8](repeating: 0, count: 99)
        let start = index * 192
        for coefficient in 0..<64 {
            map[coefficient] = Int8(clamping:
                tileCoefficients[start + Self.zigzag[coefficient]])
        }
        map[64] = Int8(clamping: tileCoefficients[start + 64])
        map[84] = Int8(clamping: tileCoefficients[start + 128])
        return map
    }

    private func decodeNewTile(
        reader: inout BitReader,
        predictor: inout [Int16],
        lowCutoff: Int,
        highCutoff: Int
    ) throws -> DecodedTile {
        let reuseChroma = try reader.readBits(1) != 0
        let cutoff = try reader.readBits(1) != 0 ? highCutoff : lowCutoff
        var values = [Int16](repeating: 0, count: 192)
        if reuseChroma {
            values[64] = predictor[64]
            values[128] = predictor[128]
        } else {
            values[64] = Int16(clamping:
                (halfTowardZero(predictor[64]) - (try reader.readSignedDCRice())) * 2)
            values[128] = Int16(clamping:
                (halfTowardZero(predictor[128]) - (try reader.readSignedDCRice())) * 2)
        }
        values[0] = Int16(clamping: Int(predictor[0]) - (try reader.readSignedDCRice()))

        var coefficient = 1
        while coefficient < 64 {
            let amplitude: Int
            if cutoff < 15 {
                amplitude = coefficient < cutoff ? 8 : 16
            } else {
                amplitude = coefficient < cutoff ? 2 : 8
            }
            if try reader.readBits(1) == 0 {
                let result = try reader.readSmallCoefficient(
                    at: coefficient, amplitude: amplitude)
                if let value = result.value {
                    values[Self.zigzag[coefficient]] = Int16(clamping: value)
                }
                coefficient = result.nextIndex
                continue
            }

            let raw = try readLargeCoefficient(
                reader: &reader, coefficient: coefficient)
            let shift: Int
            if cutoff < 15 {
                shift = coefficient < cutoff ? 3 : 4
            } else {
                shift = coefficient < cutoff ? 1 : 3
            }
            values[Self.zigzag[coefficient]] = Int16(clamping: raw << shift)
            coefficient += 1
        }
        predictor = values
        return DecodedTile(values: values, quality: cutoff)
    }

    private func readLargeCoefficient(
        reader: inout BitReader,
        coefficient: Int
    ) throws -> Int {
        let maximumPrefix = coefficient < 6 ? 34 : 20
        var prefix = 0
        while try reader.readBits(1) != 0 {
            prefix += 1
            guard prefix < maximumPrefix else {
                throw AppleAdaptiveDCTError.malformed("DCT AC prefix is too long")
            }
        }
        let magnitude: Int
        let sign: UInt32
        if coefficient < 6 {
            if prefix <= 3 {
                let suffix = try reader.readBits(3)
                magnitude = prefix * 4 + Int(suffix >> 1) + 2
                sign = suffix & 1
            } else {
                let suffix = try reader.readBits(4)
                magnitude = prefix * 8 + Int(suffix >> 1) - 14
                sign = suffix & 1
            }
        } else if prefix == 0 {
            let suffix = try reader.readBits(2)
            magnitude = 2 + Int(suffix >> 1)
            sign = suffix & 1
        } else if prefix == 1 {
            let suffix = try reader.readBits(3)
            magnitude = 4 + Int(suffix >> 1)
            sign = suffix & 1
        } else {
            let suffix = try reader.readBits(4)
            magnitude = prefix * 8 + Int(suffix >> 1) - 8
            sign = suffix & 1
        }
        return sign == 0 ? magnitude : -magnitude
    }

    private func halfTowardZero(_ value: Int16) -> Int {
        Int(value) / 2
    }

    private func readBGRAColor(_ reader: inout BitReader) throws -> UInt32 {
        let color = try reader.readYCC20()
        return bgra(y: color.y, cb: color.cb, cr: color.cr)
    }

    private func renderSolidTile(
        _ color: UInt32, x: Int, y: Int, base: UnsafeMutableRawPointer,
        width: Int, height: Int, bytesPerRow: Int
    ) throws {
        let maxX = min(x + 8, width)
        let maxY = min(y + 8, height)
        guard x >= 0, y >= 0, x < maxX, y < maxY else { return }
        for row in y..<maxY {
            let pixels = base.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt32.self)
            for column in x..<maxX { pixels[column] = color.littleEndian }
        }
    }

    private func copyTile(
        fromX: Int, fromY: Int, toX: Int, toY: Int,
        base: UnsafeMutableRawPointer, width: Int, height: Int, bytesPerRow: Int
    ) {
        let pixelCount = min(8, width - max(fromX, toX))
        let rowCount = min(8, min(height - fromY, height - toY))
        guard fromX >= 0, fromY >= 0, toX >= 0, toY >= 0,
              pixelCount > 0, rowCount > 0 else { return }
        for row in stride(from: rowCount - 1, through: 0, by: -1) {
            let source = base.advanced(by: (fromY + row) * bytesPerRow + fromX * 4)
            let destination = base.advanced(by: (toY + row) * bytesPerRow + toX * 4)
            memmove(destination, source, pixelCount * 4)
        }
    }

    private func renderTwoColorTile(
        reader: inout BitReader, first: UInt32, second: UInt32,
        x: Int, y: Int, base: UnsafeMutableRawPointer,
        width: Int, height: Int, bytesPerRow: Int
    ) throws {
        var rowControl = UInt8(try reader.readBits(8))
        for row in 0..<8 {
            let isUniformFirst = rowControl & 0x80 != 0
            let mask = isUniformFirst ? 0 : UInt8(try reader.readBits(8))
            rowControl <<= 1
            guard y + row < height else { continue }
            let pixels = base.advanced(by: (y + row) * bytesPerRow).assumingMemoryBound(to: UInt32.self)
            for column in 0..<8 where x + column < width {
                let color = isUniformFirst
                    ? first
                    : (mask & (0x80 >> column) == 0 ? second : first)
                pixels[x + column] = color.littleEndian
            }
        }
    }

    private func decodeLuminanceACHuffman(
        reader: inout BitReader,
        into map: inout [Int8],
        base: Int,
        maximum: Int
    ) throws {
        guard maximum > 0 else { return }
        var coefficient = 1
        while coefficient <= maximum {
            var code = 0
            var firstCode = 0
            var valueIndex = 0
            var symbol: UInt8?
            for length in 1...16 {
                code = (code << 1) | Int(try reader.readBits(1))
                let count = Self.luminanceACCodeCounts[length - 1]
                let delta = code - firstCode
                if delta >= 0, delta < count {
                    symbol = Self.luminanceACValues[valueIndex + delta]
                    break
                }
                valueIndex += count
                firstCode = (firstCode + count) << 1
            }
            guard let symbol else {
                throw AppleAdaptiveDCTError.malformed("Invalid DCT refinement Huffman code")
            }
            let zeroRun = Int(symbol >> 4)
            let amplitudeBits = Int(symbol & 0x0f)
            if amplitudeBits == 0 {
                if zeroRun == 15 {
                    coefficient += 16
                    continue
                }
                return
            }
            coefficient += zeroRun
            guard coefficient <= maximum else { return }
            var amplitude = Int(try reader.readBits(amplitudeBits))
            let midpoint = 1 << (amplitudeBits - 1)
            if amplitude < midpoint {
                amplitude -= (1 << amplitudeBits) - 1
            }
            let destination = base + coefficient
            if map.indices.contains(destination) {
                map[destination] = Int8(clamping: amplitude)
            }
            coefficient += 1
        }
    }

    private func decodeDCTTile(
        _ coefficients: [Int16], into tile: inout [UInt32]
    ) {
        coefficients.withUnsafeBufferPointer { coefficientBuffer in
            lumaQuantization.withUnsafeBufferPointer { lumaBuffer in
                chromaQuantization.withUnsafeBufferPointer { chromaBuffer in
                    tile.withUnsafeMutableBufferPointer { tileBuffer in
                        rfb_apple_dct_tile_bgra(
                            tileBuffer.baseAddress,
                            coefficientBuffer.baseAddress,
                            lumaBuffer.baseAddress,
                            chromaBuffer.baseAddress)
                    }
                }
            }
        }
    }

    private func renderPixelTile(
        _ tile: [UInt32], x: Int, y: Int,
        base: UnsafeMutableRawPointer, width: Int, height: Int, bytesPerRow: Int
    ) {
        for row in 0..<8 where y + row < height {
            let pixels = base.advanced(by: (y + row) * bytesPerRow).assumingMemoryBound(to: UInt32.self)
            for column in 0..<8 where x + column < width {
                let index = row * 8 + column
                pixels[x + column] = tile[index].littleEndian
            }
        }
    }

    /// Integer DCT_ISLOW used by stb_image. VNCKit wraps the same routine;
    /// retaining its shifts and biases makes scalar and SIMD output identical.
    private func inverseDCT(
        _ coefficients: [Int16], offset: Int, quantization: [UInt16]
    ) -> [UInt8] {
        var data = [Int](repeating: 0, count: 64)
        for index in 0..<64 {
            let product = Int(coefficients[offset + index]) * Int(quantization[index])
            data[index] = Int(Int16(truncatingIfNeeded: product))
        }
        var intermediate = [Int](repeating: 0, count: 64)
        for column in 0..<8 {
            if (1..<8).allSatisfy({ data[column + $0 * 8] == 0 }) {
                let dc = data[column] * 4
                for row in 0..<8 { intermediate[column + row * 8] = dc }
            } else {
                let result = Self.idct1D((0..<8).map { data[column + $0 * 8] })
                for row in 0..<8 {
                    intermediate[column + row * 8] = (result[row] + 512) >> 10
                }
            }
        }
        var output = [UInt8](repeating: 0, count: 64)
        for row in 0..<8 {
            let result = Self.idct1D(Array(intermediate[(row * 8)..<(row * 8 + 8)]))
            for column in 0..<8 {
                output[row * 8 + column] = UInt8(clamping:
                    (result[column] + 65_536 + (128 << 17)) >> 17)
            }
        }
        return output
    }

    private static func idct1D(_ s: [Int]) -> [Int] {
        var p2 = s[2]
        var p3 = s[6]
        var p1 = (p2 + p3) * 2_217
        var t2 = p1 + p3 * -7_567
        var t3 = p1 + p2 * 3_135
        p2 = s[0]
        p3 = s[4]
        let t0Even = (p2 + p3) * 4_096
        let t1Even = (p2 - p3) * 4_096
        let x0 = t0Even + t3
        let x3 = t0Even - t3
        let x1 = t1Even + t2
        let x2 = t1Even - t2

        var t0 = s[7]
        var t1 = s[5]
        t2 = s[3]
        t3 = s[1]
        p3 = t0 + t2
        var p4 = t1 + t3
        p1 = t0 + t3
        p2 = t1 + t2
        let p5 = (p3 + p4) * 4_816
        t0 *= 1_223
        t1 *= 8_410
        t2 *= 12_586
        t3 *= 6_149
        p1 = p5 + p1 * -3_685
        p2 = p5 + p2 * -10_497
        p3 *= -8_034
        p4 *= -1_597
        t3 += p1 + p4
        t2 += p2 + p3
        t1 += p2 + p4
        t0 += p1 + p3
        return [x0 + t3, x1 + t2, x2 + t1, x3 + t0,
                x3 - t0, x2 - t1, x1 - t2, x0 - t3]
    }

    private func bgra(y: UInt8, cb: UInt8, cr: UInt8) -> UInt32 {
        let yFixed = (Int(y) << 20) + (1 << 19)
        let cbSigned = Int(cb) - 128
        let crSigned = Int(cr) - 128
        let red = UInt32(UInt8(clamping:
            (yFixed + crSigned * (5_743 << 8)) >> 20))
        let greenTerm = (cbSigned * -(1_410 << 8)) & ~0xffff
        let green = UInt32(UInt8(clamping:
            (yFixed + crSigned * -(2_925 << 8) + greenTerm) >> 20))
        let blue = UInt32(UInt8(clamping:
            (yFixed + cbSigned * (7_258 << 8)) >> 20))
        return 0xff00_0000 | red << 16 | green << 8 | blue
    }
    private static let zigzag = [
         0,  1,  8, 16,  9,  2,  3, 10,
        17, 24, 32, 25, 18, 11,  4,  5,
        12, 19, 26, 33, 40, 48, 41, 34,
        27, 20, 13,  6,  7, 14, 21, 28,
        35, 42, 49, 56, 57, 50, 43, 36,
        29, 22, 15, 23, 30, 37, 44, 51,
        58, 59, 52, 45, 38, 31, 39, 46,
        53, 60, 61, 54, 47, 55, 62, 63,
    ]

    // The refinement stream uses the standard JPEG luminance AC table.
    // These canonical counts/values are equivalent to the 13-node lookup
    // table embedded in Apple's and Screens' Adaptive DCT decoders.
    private static let luminanceACCodeCounts = [
        0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 125,
    ]
    private static let luminanceACValues: [UInt8] = [
        0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12,
        0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
        0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08,
        0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0,
        0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16,
        0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
        0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39,
        0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
        0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
        0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
        0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79,
        0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
        0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98,
        0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
        0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6,
        0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5,
        0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4,
        0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
        0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea,
        0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
        0xf9, 0xfa,
    ]

    /// JPEG-derived defaults embedded in both Apple's and Screens' decoder.
    private static let defaultLuma: [UInt8] = [
        16, 11, 11, 14, 24, 22, 24, 33,
        11, 12, 11, 11, 26, 18, 19, 23,
        13, 13, 14, 24, 20, 21, 22, 28,
        13, 17, 14, 21, 23, 25, 34, 34,
        17, 22, 18, 25, 31, 32, 34, 44,
        24, 20, 17, 27, 35, 40, 44, 54,
        30, 35, 28, 30, 34, 44, 54, 64,
        35, 30, 33, 38, 45, 55, 65, 75,
    ]
    private static let defaultChroma: [UInt8] = [
        19, 19, 24, 47, 76, 99, 99, 99,
        19, 21, 26, 66, 99, 99, 99, 99,
        24, 26, 56, 99, 99, 99, 99, 99,
        47, 66, 99, 99, 99, 99, 99, 99,
        76, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
    ]
}
