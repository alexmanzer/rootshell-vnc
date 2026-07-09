import Foundation

/// Connection credentials for a VNC server.
public struct VNCCredentials: Sendable {
    /// The hostname or IP address of the VNC server.
    public let host: String

    /// The port number to connect to (typically 5900).
    public let port: UInt16

    /// The VNC password for authentication.
    public let password: String

    /// An optional username, used by authentication schemes that require it
    /// (e.g., Apple Remote Desktop, SRP).
    public let username: String?

    /// Create new VNC connection credentials.
    ///
    /// - Parameters:
    ///   - host: The hostname or IP address of the VNC server.
    ///   - port: The port number (default 5900).
    ///   - password: The VNC password.
    ///   - username: Optional username for schemes that require it.
    public init(host: String, port: UInt16 = 5900, password: String, username: String? = nil) {
        self.host = host
        self.port = port
        self.password = password
        self.username = username
    }
}
