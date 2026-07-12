import Foundation

/// Actions emitted by the `ConnectionStateMachine` in response to events.
///
/// Each action represents a side effect that the transport layer should
/// perform — sending data, updating UI, or tearing down the connection.
public enum ConnectionAction: Sendable {

    /// Send our ProtocolVersion to the server.
    case sendProtocolVersion(ProtocolVersion)

    /// Send our chosen security type to the server.
    case sendSecurityType(SecurityType)

    /// Perform authentication with the given security type and challenge data.
    case performAuthentication(SecurityType, Data)

    /// Send an authentication response (e.g., DES-encrypted challenge).
    case sendAuthResponse(Data)

    /// Send a ClientInit message to request shared access to the desktop.
    case requestServerInit

    /// Send a SetPixelFormat message.
    case sendSetPixelFormat(PixelFormat)

    /// Send a SetEncodings message.
    case sendSetEncodings([Encoding])

    /// Send a FramebufferUpdateRequest.
    case sendFramebufferUpdateRequest(incremental: Bool, width: UInt16, height: UInt16)

    /// The framebuffer has been updated with the given rectangles.
    case updateFramebuffer([FramebufferRect])

    /// Notify the user that the server rang the bell.
    case notifyBell

    /// Notify the user of server clipboard text.
    case notifyClipboard(String)

    /// Report an error to the caller.
    case reportError(VNCProtocolError)

    /// Close the connection.
    case disconnect

    /// Send an encryption response to the server.
    case sendEncryptionResponse

    /// Send a media stream answer to the server.
    case sendMediaStreamAnswer(AppleMediaStreamAnswer)
}
