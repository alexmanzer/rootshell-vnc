import Foundation

/// Result of decoding a single rectangle's pixel data.
public enum DecodedRect: Sendable, Equatable {
    /// Raw pixel data in the connection's pixel format. The data length
    /// equals `width * height * bytesPerPixel`.
    case pixels(Data)

    /// A CopyRect result: the source coordinates to copy from within
    /// the existing framebuffer.
    case copyRect(srcX: UInt16, srcY: UInt16)
}

/// Protocol for decoding a specific RFB encoding's pixel data from a
/// `MessageReader`.
///
/// Implementations consume exactly the bytes for one rectangle's encoded
/// data from the reader and return either raw pixel data or a copy
/// instruction.
public protocol EncodingDecoder {
    /// Decode one rectangle's encoded pixel data.
    ///
    /// - Parameters:
    ///   - reader: The message reader positioned at the start of this
    ///             rectangle's encoding-specific data (after the rect header).
    ///   - rect: The rectangle header (position, size, encoding).
    ///   - pixelFormat: The negotiated pixel format.
    /// - Returns: The decoded pixel data or a copy instruction.
    mutating func decode(
        reader: inout MessageReader,
        rect: FramebufferRect,
        pixelFormat: PixelFormat
    ) throws -> DecodedRect
}
