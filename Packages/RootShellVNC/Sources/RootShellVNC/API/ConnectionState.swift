import Foundation
import RFBProtocol

/// The high-level connection state of a VNC session as exposed to the UI layer.
///
/// This is a simplified representation of the internal ``RFBProtocol/ConnectionState``
/// suitable for driving SwiftUI view logic.
///
/// Transitions follow a linear progression:
/// ```
/// idle -> connecting -> connected -> disconnecting -> disconnected
///                   \-> failed
/// ```
/// After reaching `disconnected` or `failed`, the session can be reused
/// by calling ``VNCSession/connect(credentials:)`` again.
public enum VNCConnectionState: Sendable, Equatable {
    /// No connection has been attempted.
    case idle

    /// A connection attempt is in progress (handshake, authentication).
    case connecting

    /// Successfully connected and receiving framebuffer updates.
    case connected

    /// A disconnect has been requested and is being processed.
    case disconnecting

    /// The connection has been closed.
    case disconnected

    /// The connection attempt failed with an error.
    case failed(String)

    /// Whether the session is currently connected and operational.
    public var isConnected: Bool {
        self == .connected
    }

    /// Whether a connection attempt is currently in progress.
    public var isConnecting: Bool {
        self == .connecting
    }

    /// Whether the session is in a terminal state that allows reconnection.
    public var canConnect: Bool {
        switch self {
        case .idle, .disconnected, .failed:
            return true
        case .connecting, .connected, .disconnecting:
            return false
        }
    }

    /// Create a `VNCConnectionState` from the internal protocol-level ``RFBProtocol/ConnectionState``.
    init(from protocolState: RFBProtocol.ConnectionState) {
        switch protocolState {
        case .idle:
            self = .idle
        case .connecting:
            self = .connecting
        case .waitingForProtocolVersion, .waitingForSecurityTypes,
             .authenticating(_), .waitingForAuthResult, .waitingForServerInit:
            self = .connecting
        case .operational:
            self = .connected
        case .disconnecting:
            self = .disconnecting
        case .disconnected:
            self = .disconnected
        case .failed(let error):
            self = .failed(error.localizedDescription)
        }
    }
}
