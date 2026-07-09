import Foundation

/// A single color-map entry with 16-bit red, green, blue components.
public struct ColorMapEntry: Sendable, Equatable {
    public let r: UInt16
    public let g: UInt16
    public let b: UInt16

    public init(r: UInt16, g: UInt16, b: UInt16) {
        self.r = r
        self.g = g
        self.b = b
    }
}

/// All server-to-client RFB message types.
public enum ServerMessage: Sendable, Equatable {

    /// Message type 0: A framebuffer update containing one or more rectangles.
    /// Note: actual pixel data is handled separately by encoding decoders;
    /// this carries only the rectangle headers.
    case framebufferUpdate(rectangles: [FramebufferRect])

    /// Message type 1: Updates to the color map (for indexed-color modes).
    case setColorMapEntries(firstColor: UInt16, colors: [ColorMapEntry])

    /// Message type 2: The server rings the bell.
    case bell

    /// Message type 3: The server's clipboard text has changed.
    case serverCutText(String)

    // MARK: - Message type IDs

    /// The RFB message-type byte for this message.
    public var messageType: UInt8 {
        switch self {
        case .framebufferUpdate:    return 0
        case .setColorMapEntries:   return 1
        case .bell:                 return 2
        case .serverCutText:        return 3
        }
    }

    // MARK: - Parsing

    /// Parse the header of a FramebufferUpdate message.
    ///
    /// Expects the reader to be positioned *after* the message-type byte.
    /// Reads: [padding] [number-of-rectangles UInt16] then each rectangle header.
    public static func parseFramebufferUpdate(reader: inout MessageReader) throws -> ServerMessage {
        _ = try reader.readUInt8() // padding byte
        let count = try reader.readUInt16()
        var rects: [FramebufferRect] = []
        rects.reserveCapacity(Int(count))
        for _ in 0..<count {
            let rect = try FramebufferRect(reader: &reader)
            rects.append(rect)
        }
        return .framebufferUpdate(rectangles: rects)
    }

    /// Parse a SetColorMapEntries message.
    ///
    /// Expects the reader to be positioned *after* the message-type byte.
    public static func parseSetColorMapEntries(reader: inout MessageReader) throws -> ServerMessage {
        _ = try reader.readUInt8() // padding
        let firstColor = try reader.readUInt16()
        let numberOfColors = try reader.readUInt16()
        var colors: [ColorMapEntry] = []
        colors.reserveCapacity(Int(numberOfColors))
        for _ in 0..<numberOfColors {
            let r = try reader.readUInt16()
            let g = try reader.readUInt16()
            let b = try reader.readUInt16()
            colors.append(ColorMapEntry(r: r, g: g, b: b))
        }
        return .setColorMapEntries(firstColor: firstColor, colors: colors)
    }

    /// Parse a ServerCutText message.
    ///
    /// Expects the reader to be positioned *after* the message-type byte.
    public static func parseServerCutText(reader: inout MessageReader) throws -> ServerMessage {
        try reader.skip(3) // padding
        let text = try reader.readString()
        return .serverCutText(text)
    }
}
