import Foundation

/// Events fed into the `ConnectionStateMachine` to drive state transitions.
///
/// Each event represents something that has happened — either received from
/// the network, from the user, or from an internal subsystem.
public enum ConnectionEvent: Sendable {

    /// The TCP connection has been established.
    case connected

    /// The server's ProtocolVersion message was received and parsed.
    case receivedProtocolVersion(ProtocolVersion)

    /// The server's security type list was received.
    case receivedSecurityTypes([SecurityType])

    /// RFB 3.3 carries one server-selected UInt32 security type. Unlike 3.7+
    /// the client must not echo a selection byte before authentication.
    case receivedServerSelectedSecurityType(SecurityType)

    /// The server sent an authentication challenge (e.g., VNC Auth 16-byte challenge).
    case receivedAuthChallenge(Data)

    /// Authentication succeeded (server sent auth result = 0).
    case authenticationSucceeded

    /// Authentication failed with a reason string from the server.
    case authenticationFailed(String)

    /// The ServerInit message was received and parsed.
    case receivedServerInit(ServerInit)

    /// A FramebufferUpdate message was received with the given rectangle headers.
    case receivedFramebufferUpdate([FramebufferRect])

    /// The server rang the bell.
    case receivedBell

    /// The server sent clipboard text.
    case receivedServerCutText(String)

    /// The server sent Apple encryption info.
    case receivedEncryptionInfo(AppleEncryptionInfo)

    /// The server sent Apple display information.
    case receivedAppleDisplayInfo(AppleDisplayInfo)

    /// The server offered a media stream.
    case receivedMediaStreamOffer(AppleMediaStreamOffer)

    /// The user requested a graceful disconnect.
    case userRequestedDisconnect

    /// The connection was lost due to an error.
    case connectionLost(VNCProtocolError)
}
