import Foundation
import RFBProtocol

/// Key material or channel state established by an authentication exchange.
public struct AuthenticationResult: Sendable, Equatable {
    /// Apple DH/SRP session key material usable for the post-auth encrypted
    /// control stream when the server enables it.
    public let appleSessionKey: Data?

    public init(appleSessionKey: Data? = nil) {
        self.appleSessionKey = appleSessionKey
    }
}

/// Protocol for VNC authentication mechanisms.
///
/// Each supported security type (VNC Auth, Apple DH, SRP) provides an
/// implementation that performs the complete authentication exchange
/// over the TCP connection.
public protocol Authenticator: Sendable {

    /// Perform the authentication handshake over the given connection.
    ///
    /// This method should read any challenge data from the server, compute
    /// the response, and send it. It should NOT read the SecurityResult —
    /// that is handled by the transport session.
    ///
    /// - Parameter connection: The TCP connection to the VNC server.
    /// - Throws: ``VNCProtocolError`` on authentication protocol errors.
    func authenticate(connection: TCPConnection) async throws -> AuthenticationResult
}
