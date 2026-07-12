import Foundation
import RFBProtocol

/// Public error type for the rootshellVNC framework.
///
/// These errors wrap lower-level protocol and transport errors into
/// a unified error type suitable for presentation to the user.
public enum VNCError: Error, Sendable, LocalizedError {
    /// An operation was attempted that requires an active connection,
    /// but no connection is currently established.
    case notConnected

    /// A connection attempt was made while already connected to a server.
    case alreadyConnected

    /// The TCP connection to the server failed.
    case connectionFailed(String)

    /// The VNC authentication handshake failed.
    case authenticationFailed(String)

    /// A lower-level RFB protocol error occurred.
    case protocolError(VNCProtocolError)

    /// An error occurred while managing the framebuffer.
    case framebufferError(String)

    /// The server requires a feature that this client does not support.
    case unsupportedFeature(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            "Not connected to a VNC server"
        case .alreadyConnected:
            "Already connected to a VNC server"
        case .connectionFailed(let msg):
            "Connection failed: \(msg)"
        case .authenticationFailed(let msg):
            "Authentication failed: \(msg)"
        case .protocolError(let err):
            "Protocol error: \(err.localizedDescription)"
        case .framebufferError(let msg):
            "Framebuffer error: \(msg)"
        case .unsupportedFeature(let msg):
            "Unsupported feature: \(msg)"
        }
    }
}
