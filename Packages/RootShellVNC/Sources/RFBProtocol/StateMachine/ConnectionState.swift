import Foundation

/// The phases of an RFB connection lifecycle.
///
/// The state machine progresses through these states in a well-defined order
/// during connection setup, and can transition to `failed` or `disconnected`
/// from any state.
public enum ConnectionState: Sendable, Equatable {

    /// The initial state before a connection attempt.
    case idle

    /// A TCP connection is being established.
    case connecting

    /// Connected; waiting for the server's ProtocolVersion message.
    case waitingForProtocolVersion

    /// Sent our version; waiting for the server's security type list.
    case waitingForSecurityTypes

    /// Performing authentication with the selected security type.
    case authenticating(SecurityType)

    /// Authentication message sent; waiting for the server's auth result.
    case waitingForAuthResult

    /// Authenticated; waiting for the ServerInit message.
    case waitingForServerInit

    /// Fully operational — can exchange framebuffer updates and input events.
    case operational

    /// A graceful disconnect has been initiated.
    case disconnecting

    /// The connection has been cleanly terminated.
    case disconnected

    /// The connection failed with an error.
    case failed(VNCProtocolError)
}
