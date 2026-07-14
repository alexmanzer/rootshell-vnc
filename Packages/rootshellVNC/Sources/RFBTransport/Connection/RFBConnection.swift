import Foundation
import RFBProtocol

/// A reliable, ordered byte stream carrying one RFB session.
///
/// `TCPConnection` is the default implementation; hosts may inject their own
/// (an SSH direct-tcpip channel, a tssh tunnel, ...) through
/// `VNCConfiguration.transportProvider`. The transport session, authenticators,
/// and crypto channels are all written against this surface, so a conforming
/// type gets the complete RFB feature set except Apple's UDP media path.
///
/// Contracts implementations must uphold:
/// - **Buffering**: `read(upTo:)` must drain any user-space receive buffer
///   before touching the wire — earlier large receives may already hold bytes
///   that arrived glued to previous records, and bypassing the buffer would
///   reorder the stream. `read(exactly:)` returns exactly `count` bytes or
///   throws.
/// - **Errors**: throw ``VNCProtocolError`` where possible; use
///   `.connectionClosed` for EOF (including a partial read truncated by EOF)
///   and `.ioError` for transport failures. Reads and sends after `close()`
///   throw `.connectionClosed`.
/// - **Close**: `close()` must be idempotent and prompt — it releases any
///   suspended reads (which then throw `.connectionClosed`) and must not
///   invoke the disconnect handler for a locally requested close.
/// - **Disconnect handler**: report terminal transport-level failures that
///   occur outside an awaited read (for example a socket failed while the app
///   was suspended). At most one handler is installed at a time; installing
///   `nil` removes it.
public protocol RFBConnection: Sendable {

    /// Establish the transport. Throws on failure or timeout.
    func connect() async throws

    /// Read exactly `count` bytes. Throws on error or EOF.
    func read(exactly count: Int) async throws -> Data

    /// Read at least 1 and up to `maxCount` bytes, serving buffered bytes
    /// before the wire. Useful when the exact size is unknown.
    func read(upTo maxCount: Int) async throws -> Data

    /// Send data to the server. Throws on error.
    func send(_ data: Data) async throws

    /// Close the transport. Idempotent; safe to call at any time.
    func close() async

    /// Observe terminal transport failures that a pending read cannot report.
    func setDisconnectHandler(
        _ handler: (@Sendable (VNCProtocolError) -> Void)?
    ) async

    /// Snapshot the network route carrying this connection, when known.
    /// Tunneled transports typically cannot describe the underlying path
    /// and use the default `nil`.
    func pathCharacteristics() async -> NetworkPathCharacteristics?
}

extension RFBConnection {
    public func pathCharacteristics() async -> NetworkPathCharacteristics? {
        nil
    }
}
