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
            String(localized: "Not connected to a VNC server", bundle: .module)
        case .alreadyConnected:
            String(localized: "Already connected to a VNC server", bundle: .module)
        case .connectionFailed(let msg):
            String(localized: "Connection failed: \(msg)", bundle: .module)
        case .authenticationFailed(let msg):
            String(localized: "Authentication failed: \(msg)", bundle: .module)
        case .protocolError(let err):
            String(localized: "Protocol error: \(err.localizedDescription)", bundle: .module)
        case .framebufferError(let msg):
            String(localized: "Framebuffer error: \(msg)", bundle: .module)
        case .unsupportedFeature(let msg):
            String(localized: "Unsupported feature: \(msg)", bundle: .module)
        }
    }
}
