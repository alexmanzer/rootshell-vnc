import Foundation

// MARK: - Apple Encryption Info

/// Apple-specific encryption information pseudo-encoding payload.
///
/// Sent as the data portion of a rectangle with encoding `encryptionInfo` (-267).
public struct AppleEncryptionInfo: Sendable, Equatable {
    /// The cipher mode requested (e.g., AES-128-CTR, AES-256-GCM).
    public let cipherMode: UInt32
    /// The key length in bits.
    public let keyLength: UInt32

    public init(cipherMode: UInt32, keyLength: UInt32) {
        self.cipherMode = cipherMode
        self.keyLength = keyLength
    }

    /// Parse from a `MessageReader`. Reads 8 bytes.
    public init(reader: inout MessageReader) throws {
        self.cipherMode = try reader.readUInt32()
        self.keyLength = try reader.readUInt32()
    }

    /// Serialize to wire format (8 bytes, big-endian).
    public func wireBytes() -> Data {
        var data = Data(count: 8)
        data[0] = UInt8((cipherMode >> 24) & 0xFF)
        data[1] = UInt8((cipherMode >> 16) & 0xFF)
        data[2] = UInt8((cipherMode >> 8)  & 0xFF)
        data[3] = UInt8(cipherMode & 0xFF)
        data[4] = UInt8((keyLength >> 24) & 0xFF)
        data[5] = UInt8((keyLength >> 16) & 0xFF)
        data[6] = UInt8((keyLength >> 8)  & 0xFF)
        data[7] = UInt8(keyLength & 0xFF)
        return data
    }
}

// MARK: - Apple Display Info

/// Apple-specific display information pseudo-encoding payload.
///
/// Sent as the data portion of a rectangle with encoding `serverDisplayInfo` (-300).
public struct AppleDisplayInfo: Sendable, Equatable {
    /// Index of the display on the server (0-based).
    public let displayIndex: UInt32
    /// Horizontal origin of this display in the virtual screen coordinate space.
    public let originX: Int32
    /// Vertical origin of this display in the virtual screen coordinate space.
    public let originY: Int32
    /// Width of the display in pixels.
    public let width: UInt32
    /// Height of the display in pixels.
    public let height: UInt32
    /// Bitfield flags (e.g., primary display, retina, etc.).
    public let flags: UInt32

    public init(
        displayIndex: UInt32,
        originX: Int32,
        originY: Int32,
        width: UInt32,
        height: UInt32,
        flags: UInt32
    ) {
        self.displayIndex = displayIndex
        self.originX = originX
        self.originY = originY
        self.width = width
        self.height = height
        self.flags = flags
    }

    /// Parse from a `MessageReader`. Reads 24 bytes.
    public init(reader: inout MessageReader) throws {
        self.displayIndex = try reader.readUInt32()
        self.originX = try reader.readInt32()
        self.originY = try reader.readInt32()
        self.width = try reader.readUInt32()
        self.height = try reader.readUInt32()
        self.flags = try reader.readUInt32()
    }
}

// MARK: - Apple Media Stream Offer

/// Apple-specific media streaming offer pseudo-encoding payload.
///
/// Sent as the data portion of a rectangle with Apple's
/// `RFBMediaStreamMessage1Encoding` (0x0000044f).
public struct AppleMediaStreamOffer: Sendable, Equatable {
    /// Current macOS `RFBMediaStreamMessage1` rectangle payload size.
    public static let wirePayloadSize = 36

    /// Identifier for this stream, used in the answer.
    public let streamID: UInt32
    /// Raw `RFBMediaStreamMessage1` payload.
    public let rawPayload: Data
    /// Native media message version from bytes 0...1.
    public let messageVersion: UInt16?
    /// Native media message type from bytes 2...3. Message 1 is the offer.
    public let messageType: UInt16?
    /// UDP port advertised for the audio stream in native message 1.
    public let audioStreamUDPPort: UInt16?
    /// Native audio stream flags from message 1.
    public let audioStreamFlags: UInt32?
    /// UDP port advertised for the primary video stream in native message 1.
    public let videoStream1UDPPort: UInt16?
    /// Native primary video stream flags from message 1.
    public let videoStream1Flags: UInt32?
    /// UDP port advertised for the secondary video stream in native message 1.
    public let videoStream2UDPPort: UInt16?
    /// Display count inferred from the native secondary-video flag byte.
    public let videoStreamDisplayCount: Int?
    /// FourCC-style codec type (e.g., `avc1` for H.264, `hvc1` for HEVC).
    public let codecType: UInt32
    /// Stream width in pixels.
    public let width: UInt32
    /// Stream height in pixels.
    public let height: UInt32
    /// Frames per second (fixed-point or integer depending on server).
    public let frameRate: UInt32

    public init(
        streamID: UInt32,
        codecType: UInt32,
        width: UInt32,
        height: UInt32,
        frameRate: UInt32,
        rawPayload: Data = Data(),
        messageVersion: UInt16? = nil,
        messageType: UInt16? = nil,
        audioStreamUDPPort: UInt16? = nil,
        audioStreamFlags: UInt32? = nil,
        videoStream1UDPPort: UInt16? = nil,
        videoStream1Flags: UInt32? = nil,
        videoStream2UDPPort: UInt16? = nil,
        videoStreamDisplayCount: Int? = nil
    ) {
        self.streamID = streamID
        self.rawPayload = rawPayload
        self.messageVersion = messageVersion ?? Self.readUInt16(rawPayload, at: 0)
        self.messageType = messageType ?? Self.readUInt16(rawPayload, at: 2)
        self.audioStreamUDPPort = audioStreamUDPPort ?? Self.readUInt16(rawPayload, at: 10)
        self.audioStreamFlags = audioStreamFlags ?? Self.readUInt32(rawPayload, at: 12)
        self.videoStream1UDPPort = videoStream1UDPPort ?? Self.readUInt16(rawPayload, at: 16)
        self.videoStream1Flags = videoStream1Flags ?? Self.readUInt32(rawPayload, at: 18)
        self.videoStream2UDPPort = videoStream2UDPPort ?? Self.readUInt16(rawPayload, at: 22)
        self.videoStreamDisplayCount = videoStreamDisplayCount
            ?? Self.videoStreamDisplayCount(rawPayload)
        self.codecType = codecType
        self.width = width
        self.height = height
        self.frameRate = frameRate
    }

    /// Parse from a `MessageReader`. Reads the remaining offer payload.
    ///
    /// Current macOS servers send a 36-byte `RFBMediaStreamMessage1` payload.
    /// Only the first UInt32 is known to be the stream identifier; the rest is
    /// opaque setup material and must be preserved for diagnostics.
    public init(reader: inout MessageReader) throws {
        let payload = reader.remaining > 0 ? try reader.readBytes(reader.remaining) : Data()
        self.rawPayload = payload
        self.messageVersion = Self.readUInt16(payload, at: 0)
        self.messageType = Self.readUInt16(payload, at: 2)
        self.audioStreamUDPPort = Self.readUInt16(payload, at: 10)
        self.audioStreamFlags = Self.readUInt32(payload, at: 12)
        self.videoStream1UDPPort = Self.readUInt16(payload, at: 16)
        self.videoStream1Flags = Self.readUInt32(payload, at: 18)
        self.videoStream2UDPPort = Self.readUInt16(payload, at: 22)
        self.videoStreamDisplayCount = Self.videoStreamDisplayCount(payload)

        var payloadReader = MessageReader(data: payload)
        self.streamID = payload.count >= 4 ? try payloadReader.readUInt32() : 0
        self.codecType = 0
        self.width = 0
        self.height = 0
        self.frameRate = 0
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 1 < data.count else { return nil }
        let index = data.startIndex + offset
        return UInt16(data[index]) << 8 | UInt16(data[index + 1])
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 3 < data.count else { return nil }
        let index = data.startIndex + offset
        return UInt32(data[index]) << 24
            | UInt32(data[index + 1]) << 16
            | UInt32(data[index + 2]) << 8
            | UInt32(data[index + 3])
    }

    private static func videoStreamDisplayCount(_ data: Data) -> Int? {
        guard 24 < data.count else { return nil }
        return data[data.startIndex + 24] & 0x01 == 0 ? 1 : 2
    }
}

// MARK: - Apple Media Stream Answer

/// Response to an `AppleMediaStreamOffer`, indicating whether the client
/// accepts the offered media stream.
public struct AppleMediaStreamAnswer: Sendable, Equatable {
    /// The stream ID from the offer.
    public let streamID: UInt32
    /// Whether the client accepts this stream.
    public let accepted: Bool

    public init(streamID: UInt32, accepted: Bool) {
        self.streamID = streamID
        self.accepted = accepted
    }

    /// Parse from a `MessageReader`. Reads 5 bytes (UInt32 + UInt8).
    public init(reader: inout MessageReader) throws {
        let first = try reader.readUInt8()
        if first == 0x12, reader.remaining >= 7 {
            try reader.skip(2)
            let subtype = try reader.readUInt8()
            let stream = try reader.readUInt16()
            let rejected = try reader.readUInt8()
            _ = try reader.readUInt8()
            self.streamID = UInt32(stream)
            self.accepted = subtype == 0x02 && rejected == 0
        } else {
            let b1 = try reader.readUInt8()
            let b2 = try reader.readUInt8()
            let b3 = try reader.readUInt8()
            self.streamID = UInt32(first) << 24
                | UInt32(b1) << 16
                | UInt32(b2) << 8
                | UInt32(b3)
            let flag = try reader.readUInt8()
            self.accepted = flag != 0
        }
    }

    /// Serialize to the client-to-server media stream answer observed from
    /// Apple's Screen Sharing client.
    public func wireBytes() -> Data {
        var data = Data(count: 8)
        data[0] = 0x12
        data[1] = 0x00
        data[2] = 0x00
        data[3] = 0x02
        let stream = UInt16(truncatingIfNeeded: streamID)
        data[4] = UInt8((stream >> 8) & 0xFF)
        data[5] = UInt8(stream & 0xFF)
        data[6] = accepted ? 0x00 : 0x01
        data[7] = 0x00
        return data
    }
}
