import Foundation

/// Errors that can occur during RFB protocol handling.
public enum VNCProtocolError: Error, Sendable, Equatable, LocalizedError {

    /// Received a message that does not belong in the current state.
    case unexpectedMessage

    /// The server's protocol version is not supported.
    case unsupportedVersion

    /// Authentication failed, with an optional reason from the server.
    case authenticationFailed(String)

    /// A generic protocol violation with a human-readable description.
    case protocolViolation(String)

    /// The server used an encoding we do not support.
    case unsupportedEncoding(Int32)

    /// The connection was closed by the remote end.
    case connectionClosed

    /// An operation timed out.
    case timeout

    /// An underlying I/O error occurred.
    /// Wrapped as a string description for Sendable + Equatable conformance.
    case ioError(String)

    // MARK: - LocalizedError

    public var errorDescription: String? {
        switch self {
        case .unexpectedMessage:
            return "Unexpected message for the current connection state."
        case .unsupportedVersion:
            return "The server's RFB protocol version is not supported."
        case .authenticationFailed(let reason):
            return "Authentication failed: \(reason)"
        case .protocolViolation(let detail):
            return "Protocol violation: \(detail)"
        case .unsupportedEncoding(let id):
            return "Unsupported encoding type: \(id)"
        case .connectionClosed:
            return "The connection was closed."
        case .timeout:
            return "The operation timed out."
        case .ioError(let detail):
            return "I/O error: \(detail)"
        }
    }
}
