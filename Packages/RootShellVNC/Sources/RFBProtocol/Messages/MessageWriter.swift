import Foundation

/// Serializes RFB client messages to their wire-format `Data` representation.
///
/// All methods are static — `MessageWriter` is a namespace, not an instance type.
public enum MessageWriter: Sendable {

    // MARK: - Client → Server messages

    /// Serialize a SetPixelFormat message (type 0).
    ///
    /// Wire layout: [0] [padding×3] [pixel-format×16]  = 20 bytes.
    public static func writeSetPixelFormat(_ pf: PixelFormat) -> Data {
        var data = Data(count: 20)
        data[0] = 0  // message type
        data[1] = 0  // padding
        data[2] = 0
        data[3] = 0
        let pfBytes = pf.wireBytes()
        data.replaceSubrange(4..<20, with: pfBytes)
        return data
    }

    /// Serialize a SetEncodings message (type 2).
    ///
    /// Wire layout: [2] [padding] [number-of-encodings UInt16] [encoding×Int32]...
    public static func writeSetEncodings(_ encodings: [Encoding]) -> Data {
        let count = encodings.count
        var data = Data(count: 4 + count * 4)
        data[0] = 2  // message type
        data[1] = 0  // padding
        writeUInt16(UInt16(count), into: &data, at: 2)
        for (i, enc) in encodings.enumerated() {
            writeInt32(enc.rawValue, into: &data, at: 4 + i * 4)
        }
        return data
    }

    /// Serialize a FramebufferUpdateRequest message (type 3).
    ///
    /// Wire layout: [3] [incremental] [x UInt16] [y UInt16] [width UInt16] [height UInt16] = 10 bytes.
    public static func writeFramebufferUpdateRequest(
        incremental: Bool,
        x: UInt16,
        y: UInt16,
        width: UInt16,
        height: UInt16
    ) -> Data {
        var data = Data(count: 10)
        data[0] = 3
        data[1] = incremental ? 1 : 0
        writeUInt16(x, into: &data, at: 2)
        writeUInt16(y, into: &data, at: 4)
        writeUInt16(width, into: &data, at: 6)
        writeUInt16(height, into: &data, at: 8)
        return data
    }

    /// Serialize a KeyEvent message (type 4).
    ///
    /// Wire layout: [4] [down-flag] [padding×2] [key UInt32] = 8 bytes.
    public static func writeKeyEvent(downFlag: Bool, key: UInt32) -> Data {
        var data = Data(count: 8)
        data[0] = 4
        data[1] = downFlag ? 1 : 0
        data[2] = 0  // padding
        data[3] = 0
        writeUInt32(key, into: &data, at: 4)
        return data
    }

    /// Serialize a PointerEvent message (type 5).
    ///
    /// Wire layout: [5] [button-mask] [x UInt16] [y UInt16] = 6 bytes.
    public static func writePointerEvent(buttonMask: UInt8, x: UInt16, y: UInt16) -> Data {
        var data = Data(count: 6)
        data[0] = 5
        data[1] = buttonMask
        writeUInt16(x, into: &data, at: 2)
        writeUInt16(y, into: &data, at: 4)
        return data
    }

    /// Serialize a ClientCutText message (type 6).
    ///
    /// Wire layout: [6] [padding×3] [length UInt32] [text bytes] = 8 + length.
    public static func writeClientCutText(_ text: String) -> Data {
        let textBytes = Data(text.utf8)
        var data = Data(count: 8 + textBytes.count)
        data[0] = 6
        data[1] = 0  // padding
        data[2] = 0
        data[3] = 0
        writeUInt32(UInt32(textBytes.count), into: &data, at: 4)
        if !textBytes.isEmpty {
            data.replaceSubrange(8..<(8 + textBytes.count), with: textBytes)
        }
        return data
    }

    /// Serialize Apple's client media-stream configuration request.
    ///
    /// Current macOS Screen Sharing sends this `0x21` message after ServerInit
    /// and before accepting the `RFBMediaStreamMessage1Encoding` offer. The
    /// payload is an Apple-private structure; these defaults match the local
    /// Screen Sharing client and request one accelerated video stream.
    public static func writeAppleMediaStreamConfiguration() -> Data {
        let payload = Data([
            0x00, 0x01, 0x00, 0x00,
            0x00, 0x02, 0x00, 0x00,
            0x00, 0x06, 0x00, 0x00,
            0x00, 0x02, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x1a, 0x00, 0x00,
            0x00, 0x03, 0x00, 0x00,
            0x00, 0x01, 0xb0, 0x00,
            0x0c, 0x03, 0x90, 0x00,
            0x00, 0x00, 0x00, 0x40,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00,
        ])

        var data = Data(capacity: 4 + payload.count)
        data.append(0x21)
        data.append(0x00)
        data.append(UInt8((payload.count >> 8) & 0xFF))
        data.append(UInt8(payload.count & 0xFF))
        data.append(payload)
        return data
    }

    /// Serialize Apple's client media-stream request.
    ///
    /// macOS Screen Sharing sends this `0x12` message immediately after the
    /// `0x21` media-stream configuration. It prompts the server to send the
    /// `RFBMediaStreamMessage1Encoding` offer rectangle.
    public static func writeAppleMediaStreamRequest() -> Data {
        Data([
            0x12, 0x00, 0x00, 0x01,
            0x00, 0x01, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x01,
            0x0a, 0x00, 0x00, 0x01,
        ])
    }

    // MARK: - Handshake messages

    /// Serialize a ProtocolVersion handshake response (12 bytes).
    public static func writeProtocolVersion(_ version: ProtocolVersion) -> Data {
        version.wireBytes()
    }

    /// Serialize a security type selection (1 byte).
    public static func writeSecurityType(_ type: SecurityType) -> Data {
        Data([type.rawValue])
    }

    // MARK: - Helpers

    private static func writeUInt16(_ value: UInt16, into data: inout Data, at offset: Int) {
        data[offset]     = UInt8(value >> 8)
        data[offset + 1] = UInt8(value & 0xFF)
    }

    private static func writeUInt32(_ value: UInt32, into data: inout Data, at offset: Int) {
        data[offset]     = UInt8((value >> 24) & 0xFF)
        data[offset + 1] = UInt8((value >> 16) & 0xFF)
        data[offset + 2] = UInt8((value >> 8)  & 0xFF)
        data[offset + 3] = UInt8(value & 0xFF)
    }

    private static func writeInt32(_ value: Int32, into data: inout Data, at offset: Int) {
        writeUInt32(UInt32(bitPattern: value), into: &data, at: offset)
    }
}
