import Foundation

/// One screen in an RFB `ExtendedDesktopSize` layout.
public struct RFBScreenLayout: Sendable, Equatable {
    public let id: UInt32
    public let x: UInt16
    public let y: UInt16
    public let width: UInt16
    public let height: UInt16
    public let flags: UInt32

    public init(
        id: UInt32,
        x: UInt16,
        y: UInt16,
        width: UInt16,
        height: UInt16,
        flags: UInt32
    ) {
        self.id = id
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.flags = flags
    }

    init(reader: inout MessageReader) throws {
        id = try reader.readUInt32()
        x = try reader.readUInt16()
        y = try reader.readUInt16()
        width = try reader.readUInt16()
        height = try reader.readUInt16()
        flags = try reader.readUInt32()
    }
}

/// Variable-length payload carried after an `ExtendedDesktopSize` rectangle.
///
/// The rectangle header carries the aggregate framebuffer size. Its payload
/// starts with a screen count and three padding bytes, followed by one 16-byte
/// layout record per screen. Treating this pseudo-encoding as payload-free
/// leaves those bytes in the TCP stream and desynchronizes the next message.
public struct ExtendedDesktopSizePayload: Sendable, Equatable {
    public static let headerWireSize = 4
    public static let screenWireSize = 16

    public let screens: [RFBScreenLayout]

    public init(data: Data) throws {
        var reader = MessageReader(data: data)
        let count = try reader.readUInt8()
        try reader.skip(3)

        var parsed: [RFBScreenLayout] = []
        parsed.reserveCapacity(Int(count))
        for _ in 0..<count {
            parsed.append(try RFBScreenLayout(reader: &reader))
        }
        screens = parsed
    }

    /// Complete payload length for a prefix whose first byte is `screenCount`.
    public static func wireSize(screenCount: UInt8) -> Int {
        headerWireSize + Int(screenCount) * screenWireSize
    }
}
